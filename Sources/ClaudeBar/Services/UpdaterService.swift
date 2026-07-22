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
    private var controller: SPUStandardUpdaterController?

    /// .app として起動している時だけ有効（生バイナリ実行では Sparkle を起動しない）
    var isAvailable: Bool { controller != nil }

    /// 自動チェックのオン/オフ（設定と同期）
    var automaticallyChecksForUpdates: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        // startingUpdater: true で自動チェックのスケジューリングを開始する
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
        )
    }

    /// メニュー/設定からの「アップデートを確認」。進捗UIはSparkleが表示する
    func checkForUpdates() {
        controller?.updater.checkForUpdates()
    }
}
