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
            alert.informativeText = L("onboarding.body")
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
