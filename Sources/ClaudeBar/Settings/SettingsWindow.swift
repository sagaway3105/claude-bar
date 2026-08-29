import AppKit
import SwiftUI

/// 設定ウィンドウ。**HIG「Settings」に沿ってツールバー＋ペイン分割**にしている:
/// カスタマイズ不可で常時表示のツールバー、`.preference` スタイル、タイトルは表示中ペイン名、
/// 最小化/ズームは淡色化、前回開いていたペインを復元。
///
/// 副次的な効果として、macOS 26 では**ツールバーを持つウィンドウが大きい角丸**になる
/// （タイトルバーのみのウィンドウは小さい角丸のまま。詳細は docs/WINDOW_CORNER_RADIUS.md）。
/// System Settings と同じ見た目にするには、これが唯一の公式に裏づけのある方法。

/// 設定のペイン（＝ツールバーの項目）
enum SettingsPane: String, CaseIterable {
    case general
    case bubble
    case notifications
    case system

    var itemIdentifier: NSToolbarItem.Identifier { .init("pane.\(rawValue)") }

    var title: String {
        switch self {
        case .general: return L("settings.general")
        case .bubble: return L("settings.bubble")
        case .notifications: return L("settings.notifications")
        case .system: return L("settings.system")
        }
    }

    /// ツールバーのアイコン。バブルだけはアプリ自前のシャボン玉アイコン
    /// （`BubbleSparkleIcon`＝🫧ボタンと同じ絵）を使う
    @MainActor
    var image: NSImage? {
        switch self {
        case .bubble:
            return Self.bubbleImage
        case .general:
            return NSImage(systemSymbolName: "gearshape", accessibilityDescription: title)
        case .notifications:
            return NSImage(systemSymbolName: "bell", accessibilityDescription: title)
        case .system:
            return NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: title)
        }
    }

    /// SwiftUI の `BubbleSparkleIcon`（キラキラ無し）を NSImage へ焼く。
    /// テンプレート画像にすることで、選択時のアクセント色・非選択時のグレーに
    /// システム側が塗り替えてくれる
    @MainActor
    private static let bubbleImage: NSImage? = {
        let renderer = ImageRenderer(
            // 線は 0.55 倍。等倍だと隣に並ぶSF Symbols（歯車・ベル）より明らかに太く見える
            content: BubbleSparkleIcon(showsSparkle: false, lineWidthScale: 0.55)
                .foregroundStyle(.black)   // テンプレート化するので色は塗り分けに使われない
                .frame(width: 18, height: 18)
        )
        renderer.scale = 2
        guard let cg = renderer.cgImage else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: 18, height: 18))
        image.isTemplate = true
        return image
    }()
}

struct SettingsView: View {
    /// 内容の幅。`.preference` は項目が独立した行に中央並びするので、
    /// タイトル行と取り合いにならず 380pt で4項目とも収まる
    /// （タイトル行に載せる `.automatic` では520pt必要だった）
    static let width: CGFloat = 380

    var pane: SettingsPane
    @Bindable var settings: SettingsStore
    var updater: UpdaterService?
    /// 週間モデル名（"Fable" 等）。表示名は状況で変わるため差し込みで扱う
    var fableLabel: String = "Fable"
    /// 旧OS表示（Liquid Glass 無し）の切替。デバッグビルドのみ使う
    var onToggleLegacy: () -> Void = {}
    #if DEBUG
    @State private var legacyOn = forceLegacyUI
    #endif

    var body: some View {
        Form {
            switch pane {
            case .general: generalSection
            case .bubble: bubbleSection
            case .notifications: notificationsSection
            case .system: systemSection
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsView.width)
        // Form(.grouped) は与えられた高さいっぱいに広がるので、内容ぶんだけの
        // 高さを NSHostingView.fittingSize で取れるように縦は縮める
        .fixedSize(horizontal: false, vertical: true)
    }

    // ペイン名がウィンドウタイトルに出るので、Section のヘッダは付けない
    // （「一般」ウィンドウの中に「一般」の見出しが二重に出るのを避ける）

    private var generalSection: some View {
        Section {
            Toggle(L("settings.launchAtLogin"), isOn: $settings.launchAtLogin)
                .disabled(!settings.canManageLoginItem)
            if !settings.canManageLoginItem {
                Text(L("settings.appOnlyNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Picker(L("settings.refreshInterval"), selection: $settings.pollIntervalMinutes) {
                Text(L("settings.oneMinute")).tag(1)
                Text(L("settings.twoMinutes")).tag(2)
                Text(L("settings.fiveMinutes")).tag(5)
            }
            Toggle(L("settings.useSystemAccent"), isOn: $settings.useSystemAccent)
        }
    }

    private var bubbleSection: some View {
        Section {
            Picker(L("settings.bubblesShown"), selection: $settings.bubbleCount) {
                Text(L("settings.one")).tag(1)
                Text(L("settings.three")).tag(3)
            }
            Picker(L("settings.metricShown"), selection: $settings.bubbleMetric) {
                Text(L("settings.metricSession")).tag(BubbleMetric.session)
                Text(L("settings.metricWeeklyAll")).tag(BubbleMetric.weekly)
                Text(L("settings.metricWeeklyModel", fableLabel)).tag(BubbleMetric.fable)
            }
            .disabled(settings.isTripleBubble)
            if settings.isTripleBubble {
                Text(L("settings.tripleNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Toggle(L("settings.reviveBubble"), isOn: $settings.reviveBubble)
            Toggle(L("settings.popSound"), isOn: $settings.popSound)
        }
    }

    private var notificationsSection: some View {
        Section {
            Toggle(L("settings.notifyThresholds"), isOn: $settings.notifyThresholds)
        }
    }

    @ViewBuilder
    private var systemSection: some View {
        Section {
            Toggle(L("settings.autoUpdate"), isOn: $settings.autoUpdate)
                .disabled(updater?.isAvailable != true)
                .onChange(of: settings.autoUpdate) { _, on in
                    updater?.automaticallyChecksForUpdates = on
                    updater?.automaticallyDownloadsUpdates = on
                }
            Button(L("settings.checkUpdatesNow")) { updater?.checkForUpdates() }
                .disabled(updater?.isAvailable != true)
            if updater?.isAvailable != true {
                Text(L("settings.appOnlyNote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            LabeledContent(L("settings.version"), value: Self.version)
            Button(L("settings.quitApp"), role: .destructive) { NSApp.terminate(nil) }
        }
        #if DEBUG
        // 開発ビルド限定の検証スイッチ（リリースには入らない）
        Section("開発") {
            Toggle("旧OS表示（Liquid Glass 無し）", isOn: Binding(
                get: { legacyOn },
                set: { _ in onToggleLegacy(); legacyOn = forceLegacyUI }
            ))
            Text("macOS 14/15 のフォールバック経路に切り替えます。バブルはその場で作り直され、パネルは次に開いたときに切り替わります。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        #endif
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate {
    /// 週間モデル名の表示に使う（設定画面のラベル差し込み用）
    weak var state: AppState?
    /// 旧OS表示の切替（デバッグビルドの検証用）。Main.swift から PanelController へ配線する
    var onToggleLegacy: () -> Void = {}
    private var window: NSWindow?
    private var hosting: NSHostingView<SettingsView>?
    private let settings: SettingsStore
    private let updater: UpdaterService?
    /// 表示中のペイン。HIG「Restore the most recently viewed pane」に従い記憶する
    private var pane: SettingsPane {
        didSet {
            UserDefaults.standard.set(pane.rawValue, forKey: Self.paneDefaultsKey)
            applyPane()
        }
    }
    private static let paneDefaultsKey = "settingsPane"
    /// 内容の高さに合わせてウィンドウを伸縮させる（ペインごとに行数が違うため）
    private var contentHeight: CGFloat = 0
    /// 初回だけ中央に置く。`build()` の時点では仮の高さなので、
    /// 内容の高さが確定してから center する（＝ペインごとに上下へずれない）。
    /// 2回目以降は中央へ戻さない（ユーザーが動かした位置を尊重する）
    private var didCenterOnce = false

    init(settings: SettingsStore, updater: UpdaterService? = nil) {
        self.settings = settings
        self.updater = updater
        let saved = UserDefaults.standard.string(forKey: Self.paneDefaultsKey)
        self.pane = saved.flatMap(SettingsPane.init(rawValue:)) ?? .general
        super.init()
    }

    func show() {
        if window == nil { build() }
        applyPane()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: SettingsView.width, height: 300),
            // ズーム/最小化ボタンは HIG に従い「出すが淡色化」する。
            // ボタンを出すには styleMask に含める必要がある（.zoom は .resizable が前提）
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.isReleasedWhenClosed = false
        w.standardWindowButton(.miniaturizeButton)?.isEnabled = false
        w.standardWindowButton(.zoomButton)?.isEnabled = false

        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false   // HIG: noncustomizable
        toolbar.displayMode = .iconAndLabel
        w.toolbar = toolbar
        // HIG が設定ウィンドウに挙げているスタイル（タイトルの下にアイコンを中央並べ）。
        // 旧システム環境設定から続く定番で、設定としては一番自然な配置。
        // なお macOS 26 では toolbarStyle で角丸が変わり（実測: automatic/unified=31.5pt、
        // unifiedCompact=23pt、expanded/preference=17.5pt）、こちらは小さい角丸側になる。
        // 角丸を System Settings に揃えるか、設定らしい配置を取るかはトレードオフで、
        // **配置を優先**した（角丸は macOS 27 で全ウィンドウ統一に戻る予告があるため）
        w.toolbarStyle = .preference

        let view = NSHostingView(
            rootView: SettingsView(
                pane: pane, settings: settings, updater: updater,
                fableLabel: state?.fableLabel ?? "Fable",
                onToggleLegacy: { [weak self] in self?.onToggleLegacy() }
            )
        )
        w.contentView = view
        window = w
        hosting = view
    }

    /// 表示中のペインを反映する（中身・タイトル・ツールバーの選択状態）
    private func applyPane() {
        guard let window else { return }
        hosting?.rootView = SettingsView(
            pane: pane, settings: settings, updater: updater,
            fableLabel: state?.fableLabel ?? "Fable",
            onToggleLegacy: { [weak self] in self?.onToggleLegacy() }
        )
        fitWindowToContent()
        // HIG: タイトルは表示中のペイン名にする
        window.title = pane.title
        window.toolbar?.selectedItemIdentifier = pane.itemIdentifier
    }

    /// ペインの内容ぶんの高さにウィンドウを合わせる（上端を固定して下へ伸ばす）
    private func fitWindowToContent() {
        guard let window, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let height = hosting.fittingSize.height
        guard height > 0, abs(height - contentHeight) > 1 else { return }
        contentHeight = height
        let size = NSSize(width: SettingsView.width, height: height)
        // 固定サイズにしてリサイズは許さない（HIG: 設定ウィンドウは安定した見た目を保つ）
        window.contentMinSize = size
        window.contentMaxSize = size
        let frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        var target = window.frame
        target.origin.y += target.height - frame.height   // 上端を固定
        target.size = frame.size
        window.setFrame(target, display: true, animate: window.isVisible && didCenterOnce)
        if !didCenterOnce {
            didCenterOnce = true
            window.center()
        }
    }

    @objc private func selectPane(_ sender: NSToolbarItem) {
        guard let selected = SettingsPane.allCases.first(where: { $0.itemIdentifier == sender.itemIdentifier })
        else { return }
        pane = selected
    }

    // MARK: - NSToolbarDelegate

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { SettingsPane.allCases.map(\.itemIdentifier) }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated {
            // 末尾に余白を入れて、最後の項目が**大きい角丸に食い込まない**ようにする。
            // WWDC25 310: "These larger corners ... can also clip content that sits close to
            // the edge of the window"。選択中の項目の角丸背景が窓の角と衝突して見える
            // .preference は項目が中央に並ぶので、角に食い込む心配はない
            return SettingsPane.allCases.map(\.itemIdentifier)
        }
    }

    /// 選択状態（アクティブなペインを常に示す）— HIG が明示的に求めている
    nonisolated func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { SettingsPane.allCases.map(\.itemIdentifier) }
    }

    nonisolated func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            guard let pane = SettingsPane.allCases.first(where: { $0.itemIdentifier == itemIdentifier })
            else { return nil }
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = pane.title
            item.paletteLabel = pane.title
            item.image = pane.image
            item.target = self
            item.action = #selector(selectPane(_:))
            return item
        }
    }
}
