import Foundation
import Security

enum CredentialsError: LocalizedError, Equatable {
    case notFound
    case mcpOnly
    case missingProfileScope
    case expired
    case unreadable

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "Claude Codeの認証情報が見つかりません。ターミナルで claude にログインしてください。"
        case .mcpOnly:
            return "KeychainにOAuthトークンがありません。claude で再ログインしてください。"
        case .missingProfileScope:
            return "トークンに user:profile スコープがなく使用量を取得できません。claude /login し直してください。"
        case .expired:
            return "トークンが期限切れです。Claude Codeを一度使うと自動更新されます。"
        case .unreadable:
            return "認証情報を読み取れませんでした。"
        }
    }
}

struct Credentials {
    var accessToken: String
    var expiresAt: Date?
}

/// Claude CodeのOAuth認証情報を読み取り専用で流用する。
/// refreshはClaude Code本体に任せる（自前でrotateすると本体側のrefresh tokenが無効になるため）。
///
/// 秘密データの読み取りは `/usr/bin/security` サブプロセスのみで行う。Claude Codeの項目は
/// ACLパーティションが 'apple-tool:' のため、Apple署名のsecurityコマンドはダイアログなしで
/// 読める（Raycast ccusage拡張等と同方式・2026-07-27実機検証済み）。
///
/// このファイルでは SecItemCopyMatching による秘密データ読み取りを絶対に行わないこと。
/// アプリ側の署名とKeychain項目のACLが少しでも食い違うと抑制不能の許可ダイアログが出る
/// （自前キャッシュ項目ですらデバッグビルドとの署名不一致でダイアログ源になった実績あり）。
/// トークンのキャッシュはメモリのみ（元項目のmdat=属性照会・無音、が変わるまで再利用）。
enum CredentialsStore {
    private static let keychainService = "Claude Code-credentials"
    private static let legacyCacheService = "com.atsushisagae.ClaudeBar.token-cache"

    /// プロセス内キャッシュ（sourceMdatが一致する間はsecurity CLIの再実行を省く）
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var memoryCache: (sourceMdat: Double, creds: Credentials)?

    /// 旧バージョンが作ったKeychainキャッシュ項目の掃除。ACL不一致の許可ダイアログ源になるため
    /// v1.5.1で廃止した。削除のみ（読み取りしない）なのでダイアログは出ない
    nonisolated(unsafe) private static let legacyCacheCleanup: Void = {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: legacyCacheService,
        ]
        _ = SecItemDelete(query as CFDictionary)
    }()

    static func load() throws -> Credentials {
        _ = legacyCacheCleanup
        guard let mdat = sourceModificationDate() else {
            // Keychain項目なし → ファイル運用（読み取りにダイアログは出ない）
            guard let data = fileData() else { throw CredentialsError.notFound }
            return try fresh(parse(data))
        }
        // 元項目が書き換わっていない間はメモリキャッシュを使い、サブプロセス起動を省く
        if let cached = cachedCreds(sourceMdat: mdat.timeIntervalSince1970) {
            return try fresh(cached)
        }
        guard let data = securityCLIData() ?? fileData() else {
            throw CredentialsError.notFound
        }
        let creds = try parse(data)
        storeCache(creds, sourceMdat: mdat.timeIntervalSince1970)
        return try fresh(creds)
    }

    /// トークンがAPIに拒否された（401）ときに呼ぶ。次回loadで元項目を読み直す
    static func invalidateCache() {
        cacheLock.lock()
        memoryCache = nil
        cacheLock.unlock()
    }

    private static func cachedCreds(sourceMdat: Double) -> Credentials? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        guard let cached = memoryCache, cached.sourceMdat == sourceMdat else { return nil }
        return cached.creds
    }

    private static func storeCache(_ creds: Credentials, sourceMdat: Double) {
        cacheLock.lock()
        memoryCache = (sourceMdat, creds)
        cacheLock.unlock()
    }

    private static func fresh(_ creds: Credentials) throws -> Credentials {
        if let expiresAt = creds.expiresAt, expiresAt < Date() {
            throw CredentialsError.expired
        }
        return creds
    }

    /// 元項目の更新日時。属性のみの照会なので許可ダイアログは出ない
    private static func sourceModificationDate() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attrs = item as? [String: Any] else { return nil }
        return attrs[kSecAttrModificationDate as String] as? Date
    }

    /// Apple署名の /usr/bin/security で秘密データを読む（'apple-tool:'パーティション許可により
    /// ダイアログなし）。macOSでsecurityがハングする既知事例に備え3秒で打ち切る
    private static func securityCLIData() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: watchdog)
        do {
            try process.run()
        } catch {
            return nil
        }
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return nil }
        var data = pipe.fileHandleForReading.readDataToEndOfFile()
        if data.last == 0x0A { data.removeLast() } // 末尾改行
        return data.isEmpty ? nil : data
    }

    private static func fileData() -> Data? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        return try? Data(contentsOf: url)
    }

    static func parse(_ data: Data) throws -> Credentials {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CredentialsError.unreadable
        }
        guard let oauth = root["claudeAiOauth"] as? [String: Any] else {
            // Claude Code 2.1.x の一部環境では mcpOAuth のみが入っていることがある
            if root["mcpOAuth"] != nil { throw CredentialsError.mcpOnly }
            throw CredentialsError.unreadable
        }
        guard let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw CredentialsError.unreadable
        }
        if let scopes = oauth["scopes"] as? [String], !scopes.contains("user:profile") {
            throw CredentialsError.missingProfileScope
        }
        // expiresAt はエポックミリ秒。失効判定はキャッシュと合わせてload側で行う
        let expiresAt = (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token, expiresAt: expiresAt)
    }
}
