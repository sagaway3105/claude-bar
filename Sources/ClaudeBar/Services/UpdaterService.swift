import AppKit
import Sparkle

/// Sparkleによる自動アップデート。
///
/// 配布 .app は Developer ID署名 + 公証済みで、Sparkle.framework を Contents/Frameworks に
/// 同梱している。更新フィード（appcast.xml）は GitHub 上に置き、各バージョンの zip は
/// GitHub Releases から配信する。zip は EdDSA(SUPublicEDKey) で署名検証される。
///
/// デバッグ実行（.app ではない生バイナリ）では Sparkle の各種サービスが揃わないため無効化する。
@MainActor
final class UpdaterService: NSObject {
    private var updater: SPUUpdater?
    private var driver: SimpleUpdateDriver?

    /// .app として起動している時だけ有効（生バイナリ実行では Sparkle を起動しない）
    var isAvailable: Bool { updater != nil }

    /// 自動チェックのオン/オフ（設定と同期）
    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// 裏で自動ダウンロードし、「再起動してアップデート」の確認だけで適用する
    var automaticallyDownloadsUpdates: Bool {
        get { updater?.automaticallyDownloadsUpdates ?? false }
        set { updater?.automaticallyDownloadsUpdates = newValue }
    }

    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        // 標準UI（リリースノート付きウィンドウ）ではなく自前の最小ダイアログを使う
        let driver = SimpleUpdateDriver()
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: self)
        do {
            try updater.start()
            self.driver = driver
            self.updater = updater
        } catch {
            NSLog(L("update.sparkleFailed", error.localizedDescription))
        }
    }

    /// メニュー/設定からの「アップデートを確認」
    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    /// 定期チェックと同じサイレント確認（自動ダウンロード→「再起動して適用」の流れに乗る）
    func checkForUpdatesInBackground() {
        updater?.checkForUpdatesInBackground()
    }
}

extension UpdaterService: SPUUpdaterDelegate {
    /// 自動ダウンロードで更新がステージ済みになり「アプリ終了時にインストール」待ちに入った時。
    ///
    /// メニューバー常駐アプリはユーザーが自発的に終了しないため、放置すると
    /// Autoupdate プロセスが何日も待ち続け、その間に macOS が更新キャッシュを
    /// 掃除して壊れた状態になることがある（Issue #1 で3日間滞留を確認）。
    /// ここで最小ダイアログを一度だけ出し、承諾されたら即インストール＋再起動する。
    /// 見送られたら NO を返して Sparkle のスケジューラに任せる（終了時インストールは維持され、
    /// 一定期間後に再提示される）。
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        guard let driver, driver.confirmImmediateInstall(version: item.displayVersionString) else {
            return false
        }
        immediateInstallHandler()
        return true
    }
}
