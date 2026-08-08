import AppKit

/// Claude Codeへのログイン導線。
/// Anthropicのポリシー上、第三者アプリが自前のClaude.aiログインを提供することは
/// 禁止されているため、公式CLIの `claude /login` へ誘導する。
@MainActor
enum LoginHelper {
    /// 公式のネイティブインストーラ（npm経由は非推奨になったため）
    static let installCommand = "curl -fsSL https://claude.ai/install.sh | bash"

    /// Claude Code CLIがインストール済みか。
    /// 探索はClaudeUsageBridgeと共有（ログインシェルは使わない: .zshrc走査がTCC確認を誘発するため）
    static var claudeCLIInstalled: Bool {
        ClaudeUsageBridge.claudeBinaryPath() != nil
    }

    /// npmインストールコマンドをクリップボードへ
    static func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand, forType: .string)
    }

    /// ターミナルで claude /login を起動する（失敗時はコマンドをコピーしてターミナルを開く）
    static func openLoginTerminal() {
        // 検出済みの実体の絶対パスで起動する。インストール判定は固定パス走査なので、
        // 裸の `claude` だとシェルのPATH/エイリアス次第で command not found になる環境がある
        let command: String
        if let path = ClaudeUsageBridge.claudeBinaryPath() {
            command = "'\(path)' /login"
        } else {
            command = "claude /login"
        }
        let source = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if error == nil { return }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminalURL, configuration: .init(), completionHandler: nil)
    }
}
