import AppKit

/// 初回起動時のようこそダイアログ。閉じたらパネルを一度だけ自動展開して居場所を教える
@MainActor
enum OnboardingDialog {
    private static let shownKey = "onboardingShown"

    static func showIfNeeded(then openPanel: @escaping () -> Void) {
        // UIテスト（デバッグ注入）時はモーダルで操作を塞がない
        guard ProcessInfo.processInfo.environment["CLAUDEBAR_FAKE"] != "1" else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)

        // didFinishLaunchingを抜けてから表示する
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "ClaudeBarへようこそ"
            alert.informativeText = """
            メニューバーにClaudeプランの使用量を常時表示します。

            ・アイコンをクリックすると詳細パネルが開きます
            ・バブルを浮かせるモードがあります
            ・バブルは3回クリックすると弾けます
            ・設定画面で通知などを設定できます

            ときどき『キーチェーンに含まれるキー "Claude Code-credentials" へアクセス』というmacOSの確認が表示されます。Claude Codeのログイン情報で使用量を取得するための正常な動作なので、「許可」を押してください。
            """
            // 裸バイナリ起動でもフォルダアイコンにならないよう明示指定
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let icon = NSImage(contentsOf: iconURL) {
                alert.icon = icon
            }
            alert.addButton(withTitle: "パネルを開いてみる")
            alert.addButton(withTitle: "閉じる")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // アラートが閉じてから展開する
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { openPanel() }
        }
    }
}
