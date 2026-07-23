import AppKit

/// Claude Codeへのログイン導線。
/// Anthropicのポリシー上、第三者アプリが自前のClaude.aiログインを提供することは
/// 禁止されているため、公式CLIの `claude /login` へ誘導する。
@MainActor
enum LoginHelper {
    static let installCommand = "npm install -g @anthropic-ai/claude-code"

    /// Claude Code CLIがインストール済みか（固定パスの即時判定）
    static var claudeCLIInstalled: Bool {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        return [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            home + "/.local/bin/claude",
            home + "/.npm-global/bin/claude",
            home + "/.claude/local/claude",
            home + "/.volta/bin/claude",
            home + "/.asdf/shims/claude",
        ].contains { fm.isExecutableFile(atPath: $0) }
    }

    /// 固定パス外のインストール（nvm等）も拾うため、ログインシェルのPATHでも検出する
    static func detectCLIInstalled() async -> Bool {
        if claudeCLIInstalled { return true }
        return await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", "command -v claude >/dev/null 2>&1"]
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do {
                try process.run()
                process.waitUntilExit()
                return process.terminationStatus == 0
            } catch {
                return false
            }
        }.value
    }

    /// npmインストールコマンドをクリップボードへ
    static func copyInstallCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(installCommand, forType: .string)
    }

    /// ターミナルで claude /login を起動する（失敗時はコマンドをコピーしてターミナルを開く）
    static func openLoginTerminal() {
        let source = """
        tell application "Terminal"
            activate
            do script "claude /login"
        end tell
        """
        if let script = NSAppleScript(source: source) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if error == nil { return }
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("claude /login", forType: .string)
        let terminalURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.openApplication(at: terminalURL, configuration: .init(), completionHandler: nil)
    }
}
