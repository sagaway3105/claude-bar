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
}

/// Claude CodeのOAuth認証情報を読み取り専用で流用する。
/// refreshはClaude Code本体に任せる（自前でrotateすると本体側のrefresh tokenが無効になるため）。
enum CredentialsStore {
    private static let keychainService = "Claude Code-credentials"

    static func load() throws -> Credentials {
        let data: Data
        if let d = keychainData() {
            data = d
        } else if let d = fileData() {
            data = d
        } else {
            throw CredentialsError.notFound
        }
        return try parse(data)
    }

    private static func keychainData() -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else { return nil }
        return item as? Data
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
        // expiresAt はエポックミリ秒
        if let ms = oauth["expiresAt"] as? Double,
           Date(timeIntervalSince1970: ms / 1000) < Date() {
            throw CredentialsError.expired
        }
        return Credentials(accessToken: token)
    }
}
