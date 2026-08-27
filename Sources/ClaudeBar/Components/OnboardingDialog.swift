import AppKit

/// 初回起動時のようこそダイアログ。閉じたらパネルを一度だけ自動展開して居場所を教える
@MainActor
enum OnboardingDialog {
    private static let shownKey = "onboardingShown"

    static func showIfNeeded(then openPanel: @escaping () -> Void) {
        #if DEBUG
        // UIテスト（デバッグ注入）時はモーダルで操作を塞がない
        guard ProcessInfo.processInfo.environment["CLAUDEBAR_FAKE"] != "1" else { return }
        #endif
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: shownKey) else { return }
        defaults.set(true, forKey: shownKey)

        // didFinishLaunchingを抜けてから表示する
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = L("onboarding.welcome")
            alert.informativeText = """
            メニューバーにClaudeプランの使用量を常時表示します。

            ・アイコンをクリックすると詳細パネルが開きます
            ・バブルを浮かせるモードがあります
            ・バブルは3回クリックすると弾けます
            ・設定画面で通知などを設定できます

            使用量はClaude Codeから取得します。そのため初回に、macOSからフォルダなどへのアクセス許可を求める確認が一度だけ表示されることがあります。いずれも正常な動作なので「許可」を押してください（一度許可すれば以降は表示されません）。
            """
            // 裸バイナリ起動でもフォルダアイコンにならないよう明示指定
            if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
               let icon = NSImage(contentsOf: iconURL) {
                alert.icon = icon
            }
            alert.addButton(withTitle: L("onboarding.openPanel"))
            alert.addButton(withTitle: L("onboarding.close"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            // アラートが閉じてから展開する
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { openPanel() }
        }
    }
}
