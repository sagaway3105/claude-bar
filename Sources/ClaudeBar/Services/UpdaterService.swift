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
        let updater = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: nil)
        do {
            try updater.start()
            self.driver = driver
            self.updater = updater
        } catch {
            NSLog("Sparkleを開始できませんでした: \(error.localizedDescription)")
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
