import AppKit
import Sparkle

/// Sparkle標準の更新ウィンドウ（リリースノート・スキップ・進捗表示付き）を使わず、
/// NSAlertだけの最小構成に置き換えるカスタムUIドライバ。
/// ダウンロード・展開は無音で行い、ユーザーに見せるのは
/// 「再起動してアップデート」の確認ダイアログ1枚だけにする。
@MainActor
final class SimpleUpdateDriver: NSObject, SPUUserDriver {

    /// 手動チェック中か（背景チェックでは「最新です」やエラーを出さないための判定）
    private var userInitiated = false

    // MARK: - 表示するのはここだけ

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(runUpdateAlert())
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        reply(runUpdateAlert())
    }

    /// アプリアイコン＋メッセージ＋2択だけの確認ダイアログ
    private func runUpdateAlert() -> SPUUserUpdateChoice {
        let alert = NSAlert()
        alert.messageText = "新しいバージョンのClaudeBarがご利用できます！"
        alert.addButton(withTitle: "インストールして再起動")
        alert.addButton(withTitle: "後にする")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn ? .install : .dismiss
    }

    // MARK: - 手動チェック時だけ結果を知らせる

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if userInitiated {
            let alert = NSAlert()
            alert.messageText = "最新バージョンです"
            alert.informativeText = "アップデートはありません。"
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        acknowledgement()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        if userInitiated {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "アップデートを確認できませんでした"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        acknowledgement()
    }

    // MARK: - それ以外は無音

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
    func showDownloadInitiated(cancellation: @escaping () -> Void) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {}

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }

    func showUpdateInFocus() {}

    func dismissUpdateInstallation() {
        userInitiated = false
    }
}
