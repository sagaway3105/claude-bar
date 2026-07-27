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
/// 秘密データの読み取りは `/usr/bin/security` サブプロセスで行う。Claude Codeの項目は
/// ACLパーティションが 'apple-tool:' のため、Apple署名のsecurityコマンドはダイアログなしで
/// 読める（サードパーティアプリがSecurity.frameworkで読むと抑制不能の許可ダイアログが出る。
/// Raycast ccusage拡張等と同方式・2026-07-27実機検証済み）。このファイルでは
/// SecItemCopyMatchingによる秘密データ読み取りを絶対に行わないこと（ダイアログの原因になる）。
///
/// 読めたトークンはClaudeBar自身のKeychain項目（ACLは自分持ち＝ダイアログなし）に
/// キャッシュし、元項目の更新日時(mdat・属性のみの照会はダイアログなし)が変わるまで
/// サブプロセス起動を省く。
enum CredentialsStore {
    private static let keychainService = "Claude Code-credentials"
    private static let cacheService = "com.atsushisagae.ClaudeBar.token-cache"

    /// デバッグビルド（ad-hoc署名）は署名がビルドごとに変わり、過去のビルドが作った
    /// 自前キャッシュ項目とACL不一致になって許可ダイアログが出るため、キャッシュ項目を使わない
    /// （毎回security CLIで読む。リリースビルドはDeveloper ID署名固定なのでキャッシュ有効）
    #if DEBUG
    private static let useKeychainCache = false
    #else
    private static let useKeychainCache = true
    #endif

    static func load() throws -> Credentials {
        guard let mdat = sourceModificationDate() else {
            // Keychain項目なし → ファイル運用（読み取りにダイアログは出ない）
            guard let data = fileData() else { throw CredentialsError.notFound }
            return try fresh(parse(data))
        }
        if let cached = loadCache(), cached.sourceMdat == mdat.timeIntervalSince1970 {
            // 元項目が書き換わっていない間はキャッシュだけで判断し、秘密データに触れない
            return try fresh(Credentials(accessToken: cached.accessToken, expiresAt: cached.expiresAt))
        }
        guard let data = securityCLIData() ?? fileData() else {
            throw CredentialsError.notFound
        }
        let creds = try parse(data)
        saveCache(Cache(accessToken: creds.accessToken,
                        expiresAt: creds.expiresAt,
                        sourceMdat: mdat.timeIntervalSince1970))
        return try fresh(creds)
    }

    /// トークンがAPIに拒否された（401）ときに呼ぶ。次回loadで元項目を読み直す
    static func invalidateCache() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
        ]
        _ = SecItemDelete(query as CFDictionary)
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

    // MARK: - 自前キャッシュ項目

    private struct Cache: Codable {
        var accessToken: String
        var expiresAt: Date?
        var sourceMdat: Double
    }

    private static func loadCache() -> Cache? {
        guard useKeychainCache else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private static func saveCache(_ cache: Cache) {
        guard useKeychainCache, let data = try? JSONEncoder().encode(cache) else { return }
        invalidateCache()
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: cacheService,
            kSecAttrAccount as String: NSUserName(),
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]
        _ = SecItemAdd(attributes as CFDictionary, nil)
    }
}
