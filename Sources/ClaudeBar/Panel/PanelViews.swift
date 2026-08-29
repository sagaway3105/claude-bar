import SwiftUI

struct PanelActions {
    var refresh: () -> Void = {}
    var quit: () -> Void = {}
    var toBubble: () -> Void = {}
    var toOverlay: () -> Void = {}
    var expand: () -> Void = {}
    var backToMenuBar: () -> Void = {}
    var pop: () -> Void = {}
    var settings: () -> Void = {}
    var login: () -> Void = {}
    var contentHeightChanged: (CGFloat) -> Void = { _ in }
    /// 旧OS表示（Liquid Glass無し）の切替。デバッグビルドのみ
    var toggleLegacy: () -> Void = {}
}

// MARK: - ルート（パネル/バブルは別ウィンドウ）
// ※「ぷるんっ/ポヨン」はSwiftUIで行うとガラスの円形マスクで切れるため、
//   PanelController.bounceAssembly()/bounceBubble()（レイヤー変形）で行う

struct PanelRootView: View {
    var state: AppState
    var settings: SettingsStore
    var actions: PanelActions

    var body: some View {
        UsagePanelView(state: state, settings: settings, actions: actions)
            .measureSize { size in
                actions.contentHeightChanged(size.height)
            }
            // ウィンドウは固定サイズなので、内容（ガラスごと）は上詰めで描く
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// バブル専用ウィンドウのルート（バブルはパネルと独立したウィンドウで共存する）。
/// **1つ表示のみ**を描く — 3つ表示は球ごとに独立したホスティングビューを
/// AppKit側で並べる（glassEffectが内側のレイヤーアニメーションを無視するため。
/// 経緯は TripleBallCanvas のコメント）
struct BubbleRootView: View {
    var state: AppState
    var settings: SettingsStore
    var cluster: TripleBubbleCluster
    var actions: PanelActions

    var body: some View {
        Group {
            if cluster.contentParked {
                // 非表示中は中身ごと畳む（無限アニメーションのCPU評価を止める）
                Color.clear
            } else {
                BubbleView(state: state, settings: settings, actions: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - OS適応ガラス
// macOS 26 = Liquid Glass（純正メニューと同じ質感）/ それ以前 = 従来のすりガラス(Material)

/// パネルの背景に敷く**標準マテリアル**（`NSVisualEffectView`）。
///
/// HIG「Materials」は素材を「Liquid Glass」と「standard materials」の2種類に分け、
/// **"Don't use Liquid Glass in the content layer. Instead, use Standard materials for
/// elements in the content layer, such as app backgrounds."** と明記している。
/// macOS の standard materials の開発者向け参照先は今も `NSVisualEffectView.Material`
/// （macOS 26.5 SDK でも .menu / .popover / .sidebar / .hudWindow は非推奨ではない）。
/// Liquid Glass はバブルやボタンのような「浮いている要素」だけに使う。
///
/// `.behindWindow` はウィンドウの**背後**（デスクトップや他アプリ）とブレンドする指定で、
/// メニューやポップオーバーと同じ仕組み。角丸は maskImage で付ける
/// （SwiftUI 側で clip すると背後採取と噛み合わないことがあるため）
struct PanelBackdrop: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var cornerRadius: CGFloat = 18

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active   // 非アクティブでも素材を保つ（メニューバーのパネルは常に前面扱い）
        view.material = material
        view.maskImage = Self.mask(cornerRadius: cornerRadius)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        if view.material != material { view.material = material }
    }

    /// 角丸のマスク。中央を伸縮させるので1枚で任意サイズに効く
    private static func mask(cornerRadius radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// パネル背景に使う素材。既定は **`.menu`**。
///
/// 白/黒背景でパネル内の輝度を実測して選んだ（2026-08-29）:
/// | 素材 | 白背景 | 黒背景 | 背景の通し量 |
/// | --- | --- | --- | --- |
/// | 旧: Liquid Glass + ティント20% | 106 | 41 | 26% |
/// | **.menu** | **105** | **37** | **26%** |
/// | .popover | 125 | 33 | 36%（透けすぎ） |
/// | .hudWindow | 166 | 26 | 55%（透けすぎ） |
///
/// `.menu` は「メニューバー由来のパネル」という意味論にも合い、調整済みのガラスと
/// 同じ濃さになる（HIG:「Choose materials based on semantic meaning」）。
/// 検証用: CLAUDEBAR_PANEL_MATERIAL=menu|popover|hud|sidebar|glass
enum PanelMaterialChoice {
    static let raw = ProcessInfo.processInfo.environment["CLAUDEBAR_PANEL_MATERIAL"] ?? "menu"
    static var usesGlass: Bool { raw == "glass" }
    static var material: NSVisualEffectView.Material {
        switch raw {
        case "popover": return .popover
        case "hud": return .hudWindow
        case "sidebar": return .sidebar
        default: return .menu
        }
    }
}

/// パネル背景: 26はLiquid Glass+ティント、旧OSはultraThinMaterial+同じティント。
/// ティント量はライト45% / ダーク20%。ダークを一度0（素のガラス）にしていたが、
/// 素通しが強すぎてシステムのコントロールセンター系パネルより明るく見えるため戻した
/// （`.tint(Color.clear)` は「ティント無し」と完全に同一であることも実測済み）
struct AdaptivePanelGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        // ダークのティント量（検証用: CLAUDEBAR_PANEL_TINT=0-100・既定20）。
        // 0だと素通しが強すぎて、システムのコントロールセンター系パネルより明るく見える
        // （2026-08-29に縞背景で0/20/35を撮り比べて20を採用。背景の模様は残しつつ落ち着く）
        let darkTint = envPercent("CLAUDEBAR_PANEL_TINT", default: 20)
        let tint = Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? darkTint : 0.45)
        if !PanelMaterialChoice.usesGlass {
            // 本線: 標準マテリアル（HIG準拠）。旧OSでも同じ経路なので分岐が要らない
            content.background(PanelBackdrop(material: PanelMaterialChoice.material))
        } else if #available(macOS 26.0, *), !forceLegacyUI {
            content.glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: 18))
        } else {
            content.background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 18).fill(tint)
                }
            )
        }
    }
}

/// バブルのガラス玉（1つ表示・3つ表示で共通）。
///
/// **ガラスは背景ではなく content へ掛ける。** Liquid Glass は64pt以下の小さい図形を
/// 「背景に応じて light/dark を反転する」材質として扱い、そのとき**ガラスの上に載る
/// 文字や記号も一緒に反転させる**（HIG: symbols and text on these elements follow a
/// monochromatic color scheme）。文字をガラスの content に入れて `.primary` で描くと、
/// 白い背景では自動で黒く、暗い背景では白くなる（2026-08-28実測）。
/// 背景に敷く方式ではこの自動反転が効かない。
///
/// 旧コメント（背景に敷いていた頃）: 単体バブル専用のガラス玉。ガラスを content ではなく背景の円に敷き、
/// 2倍で描いて0.5倍に縮める縮小レンズ合成を行う（%やリセット時刻は不透明のまま前面）。
/// 3つ表示も同じこのモディファイアを使う（球ごとにホスティングビューが分かれた
/// 2026-08-27の再設計以降、単体と完全に同じ組みにできるようになった）
struct SingleBubbleGlass: ViewModifier {
    /// 検証用: CLAUDEBAR_GLASS=clear で旧構成（.clear+縮小レンズ）に戻す
    static let useClear = ProcessInfo.processInfo.environment["CLAUDEBAR_GLASS"] == "clear"
    /// ガラスの背後に敷く下地の濃さ（検証用: CLAUDEBAR_BACKDROP 0-100）
    static let backdropOpacity = Double(ProcessInfo.processInfo.environment["CLAUDEBAR_BACKDROP"] ?? "0")! / 100
    /// 下地の入れ方（検証用: back / front / tint）
    static let mode = ProcessInfo.processInfo.environment["CLAUDEBAR_MODE"] ?? "back"

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !forceLegacyUI, !Self.useClear {
            // 本線: content へ掛ける（システムの自動反転に乗せるため）
            content
                .glassEffect(.regular, in: Circle())
                .bubbleClarity()
        } else {
            legacy(content)
        }
    }

    private func legacy(_ content: Content) -> some View {
        content.background {
            if #available(macOS 26.0, *), !forceLegacyUI {
                if Self.useClear {
                    // 旧構成: .clear + 2倍で描いて0.5倍に縮める（ぼかし実効半減）
                    GeometryReader { geo in
                        Circle().fill(.clear)
                            .glassEffect(.clear, in: Circle())
                            .frame(width: geo.size.width * 2, height: geo.size.height * 2)
                            .scaleEffect(0.5)
                            .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                } else {
                    // コントロールセンターのタイルと同じ構成:
                    // .regular（適応する材質。背景の明るさに応じて自らの明度を調整し、
                    // 縁のレンズも素のまま働く）を、縮小合成なしでそのまま使う。
                    // .clearは適応能力を持たないためAppleは暗幕とセットで使うよう指示しており、
                    // 暗幕なしの単体使用は明るい背景で消える（実測1.48:1）
                    ZStack {
                        // 黒い要素は全廃した（暗幕・ティント・ターミネーター・
                        // 影はいずれも「黒いブラー」として悪目立ちしたため）。
                        // 球体表現は白い光のみで作る
                        Circle().fill(.clear)
                            .glassEffect(.regular, in: Circle())
                            // 局所クリア化（既定オフ）。オンにすると外周ほどガラスを削る
                            .bubbleClarity()
                    }
                }
            } else {
                // 旧OS: Liquid Glassが無いのですりガラス（Material）で代替。
                // **背景に応じた自動反転が無い**ので、素材の濃さで外観側へ寄せる
                // （薄すぎると「ダーク外観×明るい背景」で白文字が沈む）
                Circle().fill(.ultraThinMaterial)
                    .opacity(0.72)
                    .bubbleClarity()
            }
        }
    }
}

/// Apple公式メニュー風の繊細なヘアライン縁取り
struct PanelSheen: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18)
            .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

/// セクション区切りのヘアライン（バッテリーメニュー等と同じ流儀）
struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(height: 1)
    }
}

/// コントロールセンターのモジュール風タイル背景
struct SectionTile: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - 展開パネル

struct UsagePanelView: View {
    var state: AppState
    var settings: SettingsStore
    var actions: PanelActions

    /// macOSのアクセントカラー準拠（設定でClaudeオレンジに切り替え可）
    private var baseTint: Color {
        settings.useSystemAccent ? Color(nsColor: .controlAccentColor) : .claudeOrange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Capsule().fill(.tertiary).frame(width: 36, height: 5)
                Spacer()
            }
            .padding(.top, 7)
            .contentShape(Rectangle())
            .modifier(GripDrag())

            // Apple公式メニューと同じ太字ヘッダ
            HStack(spacing: 7) {
                ClaudeLogoView(animating: state.isActive, color: .claudeOrange)
                    .frame(width: 16, height: 16)
                Text(L("panel.title"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if state.mode == .floating {
                    IconButton(systemName: "xmark.circle.fill", help: L("panel.backToMenuBar")) {
                        actions.backToMenuBar()
                    }
                }
            }
            .padding(.top, 2)
            .padding(.bottom, 12)

            if state.needsLogin {
                LoginSetupTile(actions: actions)
                    .padding(.bottom, 12)
            } else if let message = state.errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .modifier(SectionTile())
                .padding(.bottom, 12)
            }

            UsageGaugeView(title: L("panel.currentSession"), window: state.usage?.session, baseTint: baseTint)

            Hairline().padding(.vertical, 12)

            Text(L("panel.weeklyLimit"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 12) {
                UsageGaugeView(title: L("panel.allModels"), window: state.usage?.weeklyAll, baseTint: baseTint)
                UsageGaugeView(title: state.fableLabel, window: state.usage?.weeklyFable, baseTint: baseTint)

                if let extra = state.usage?.extra, extra.isEnabled {
                    ExtraUsageRow(extra: extra)
                }
            }

            Hairline().padding(.vertical, 10)

            HStack(spacing: 8) {
                Text(updatedText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                IconButton(systemName: "arrow.clockwise", help: L("panel.refreshNow")) { actions.refresh() }
                IconButton(systemName: "gearshape.fill", help: L("panel.settings")) { actions.settings() }
                IconButton(
                    systemName: "pin",
                    help: state.mode == .floating ? L("panel.backBelowMenuBar") : L("panel.overlayMode"),
                    activeState: state.mode == .floating,
                    activeTint: baseTint
                ) { actions.toOverlay() }
                IconButton(
                    help: state.bubbleActive ? L("panel.hideBubble") : L("panel.floatingMode"),
                    activeState: state.bubbleActive,
                    activeTint: baseTint,
                    icon: BubbleSparkleIcon()
                ) { actions.toBubble() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(width: 300)
        .modifier(AdaptivePanelGlass())
        .overlay(PanelSheen())
    }

    private var updatedText: String {
        guard let date = state.lastUpdated else { return L("panel.notFetched") }
        // 時刻はロケール準拠（日本語 "15:45"／英語(US) "3:45 PM"）にし、
        // 「更新」の語順は .strings 側で決める（英語は "Updated 3:45 PM"）
        return L("panel.updatedAt", UsageGaugeView.resetText(date))
    }
}

/// 初回セットアップ（アカウント連携）の導線タイル。
/// Claude Code未導入なら「①インストール→②ログイン」の2ステップに分岐する
struct LoginSetupTile: View {
    var actions: PanelActions
    @State private var cliInstalled = LoginHelper.claudeCLIInstalled
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("login.title"), systemImage: "person.crop.circle.badge.checkmark")
                .font(.caption.weight(.semibold))
            Text(cliInstalled
                ? L("login.description")
                : L("login.needsClaudeCode"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !cliInstalled {
                Button {
                    LoginHelper.copyInstallCommand()
                    copied = true
                } label: {
                    Label(copied ? L("login.copied") : L("login.copyInstall"),
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .tint(.claudeOrange)
            }
            Button {
                actions.login()
            } label: {
                Label(cliInstalled ? L("login.signIn") : L("login.signInStep"), systemImage: "terminal")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .tint(.claudeOrange)
        }
        .modifier(SectionTile())
        .task {
            // NSHostingViewはパネルを閉じても生き続け、開き直しでビューが作り直されないため、
            // タイル表示中は定期的に検出し直す（①実行後、少し待つか開き直せば②だけの表示になる）
            while !Task.isCancelled {
                cliInstalled = LoginHelper.claudeCLIInstalled
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L("panel.extraUsage"))
                .font(.system(size: 12))
            Spacer()
            Text(amountText)
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var amountText: String {
        let symbol = (extra.currency ?? "USD") == "USD" ? "$" : (extra.currency ?? "")
        let used = extra.usedCredits.map { String(format: "%.2f", $0) } ?? "0"
        if let limit = extra.monthlyLimit {
            return "\(symbol)\(used) / \(symbol)\(String(format: "%.0f", limit))"
        }
        return "\(symbol)\(used)"
    }
}

struct IconButton<Icon: View>: View {
    var help = ""
    /// nil=通常ボタン（ホバー時のみ丸背景）。true/false=トグル（常時グレー地、trueでアクセント色）
    var activeState: Bool? = nil
    var activeTint: Color = .accentColor
    let action: () -> Void
    let icon: Icon
    @State private var hovering = false

    init(help: String = "", activeState: Bool? = nil, activeTint: Color = .accentColor,
         icon: Icon, action: @escaping () -> Void) {
        self.help = help
        self.activeState = activeState
        self.activeTint = activeTint
        self.action = action
        self.icon = icon
    }

    var body: some View {
        Button(action: action) {
            icon.font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(HoverPressIconStyle(hovering: hovering, activeState: activeState, activeTint: activeTint))
        .onHover { hovering = $0 }
        .help(help)
    }
}

extension IconButton where Icon == Image {
    init(systemName: String, help: String = "", activeState: Bool? = nil,
         activeTint: Color = .accentColor, action: @escaping () -> Void) {
        self.init(help: help, activeState: activeState, activeTint: activeTint,
                  icon: Image(systemName: systemName), action: action)
    }
}

/// 単体のシャボン玉+キラキラ（線の十字）。SF Symbolsに無い組み合わせなのでPathで自前描画
struct BubbleSparkleIcon: View {
    /// 右上のキラキラ（十字）を描くか。設定ツールバーのアイコンでは
    /// プラス記号に見えてしまうため落とす
    var showsSparkle = true
    /// 線の太さの倍率。ツールバーでは隣に並ぶSF Symbolsより太く見えるので細める
    var lineWidthScale: CGFloat = 1

    var body: some View {
        // キラキラを出すときは右上を空けるため球を左下へ寄せて小さくする。
        // 出さないとき（ツールバー用）は中央・大きめにして、隣に並ぶSF Symbolsと
        // 同じ光学サイズに見えるようにする
        let center = showsSparkle ? CGPoint(x: 6.2, y: 9.8) : CGPoint(x: 8, y: 8)
        let radius: CGFloat = showsSparkle ? 5 : 6.4
        let sparkle = CGPoint(x: 13.1, y: 3.2)
        let arm: CGFloat = 2.5
        ZStack {
            Path { p in
                p.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                                        width: radius * 2, height: radius * 2))
            }
            .stroke(style: StrokeStyle(lineWidth: 1.4 * lineWidthScale))
            // シャボン玉のハイライト（左上の弧）
            Path { p in
                p.addArc(center: center, radius: radius * 0.6,
                         startAngle: .degrees(200), endAngle: .degrees(245), clockwise: false)
            }
            .stroke(style: StrokeStyle(lineWidth: 1.1 * lineWidthScale, lineCap: .round))
            // キラキラ: 均一な線幅の十字
            if showsSparkle {
                Path { p in
                    p.move(to: CGPoint(x: sparkle.x, y: sparkle.y - arm))
                    p.addLine(to: CGPoint(x: sparkle.x, y: sparkle.y + arm))
                    p.move(to: CGPoint(x: sparkle.x - arm, y: sparkle.y))
                    p.addLine(to: CGPoint(x: sparkle.x + arm, y: sparkle.y))
                }
                .stroke(style: StrokeStyle(lineWidth: 1.2 * lineWidthScale, lineCap: .round))
            }
        }
        .frame(width: 16, height: 16)
    }
}

/// Apple純正コントロール風のインタラクション:
/// ホバーで丸背景がふわっと出て、押下でわずかに沈む。
/// トグル型（activeState != nil）はCCと同じ常時グレー地・ON時はアクセント色+白アイコン
struct HoverPressIconStyle: ButtonStyle {
    var hovering: Bool
    var activeState: Bool? = nil
    var activeTint: Color = .accentColor

    func makeBody(configuration: Configuration) -> some View {
        let isOn = activeState == true
        let isToggle = activeState != nil
        return configuration.label
            .foregroundStyle(
                isOn ? AnyShapeStyle(Color.white)
                    : (hovering || configuration.isPressed || isToggle
                        ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            )
            .frame(width: 24, height: 24)
            .background(
                Circle().fill(
                    isOn
                        ? AnyShapeStyle(activeTint.opacity(configuration.isPressed ? 0.75 : 1))
                        : AnyShapeStyle(Color.primary.opacity(
                            configuration.isPressed ? 0.18 : (hovering ? 0.14 : (isToggle ? 0.09 : 0))
                        ))
                )
            )
            .contentShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

/// バブルの可読性スタイル。ライト/ダークで**別々の値**を持つ（1箇所に集約）。
///
/// 前提: ガラスは素通しなので、文字の背後には「アプリの外観と無関係な」
/// 画面内容が来る（ライトモードでも黒いエディタの上に浮くことがある）。
/// 文字色は外観に従う(.primary)ため、反対色のハロー+下地で
/// どんな背景でも読めるようにする。外観ごとに強さを変えられる
/// バブルの文字まわりの外観。**文字色そのものはここでは決めない** —
/// 2026-08-28以降、文字は `.primary` で描き、Liquid Glass の
/// 「小さい要素は背景に応じて light/dark を反転し、上に載る文字も一緒に反転する」
/// 仕様に乗せている。ここに残るのはハローと下地（どちらも既定オフ）
struct BubbleStyle {
    /// 文字の縁取り色（常に暗色。白文字を明るい背景でも成立させる）
    var haloColor: Color
    /// 縁取り3層の不透明度（細い縁 / 中間 / 広いにじみ）
    var haloOpacities: (tight: Double, mid: Double, wide: Double)
    /// 文字直下の下地（ぼかした小さな円）。全面の暗幕に加えて局所的に効かせる
    /// （全面だけで4.5:1を狙うと球が不透明な円盤になるため、局所で稼ぐ）
    var padColor: Color
    var padOpacity: Double

    /// 文字の縁取りハローの強さ。既定0＝使わない
    /// （旧OSの可読性は縁取りではなく「文字の裏のぼかしグレー」= BubbleTextPlate で担保する）。
    /// 検証用: CLAUDEBAR_HALO=0-100
    /// 環境変数は開発者が手で打つので、数値でない値が来ても落ちないようにする
    static let haloGain: Double = envPercent("CLAUDEBAR_HALO", default: 0)

    /// 文字裏の下地（旧OS用）の調整ノブ: CLAUDEBAR_PLATE_D / CLAUDEBAR_PLATE_L（不透明度%）
    static let plateOpacityDark = envPercent("CLAUDEBAR_PLATE_D", default: 70)
    static let plateOpacityLight = envPercent("CLAUDEBAR_PLATE_L", default: 68)
    static let plateWhiteDark = envPercent("CLAUDEBAR_PLATEW_D", default: 8)
    static let plateWhiteLight = envPercent("CLAUDEBAR_PLATEW_L", default: 93)

    static func plateOpacity(dark: Bool) -> Double { dark ? plateOpacityDark : plateOpacityLight }
    static func plateWhite(dark: Bool) -> Double { dark ? plateWhiteDark : plateWhiteLight }

    static func resolve(_ scheme: ColorScheme) -> BubbleStyle {
        switch scheme {
        case .dark:
            // ダークモードは球も背景も暗いので白文字。
            // ライトモードの黒文字と対で、外観に素直に従う
            return BubbleStyle(
                haloColor: .black,
                haloOpacities: (0.62 * haloGain, 0.42 * haloGain, 0.30 * haloGain),
                // 文字の裏に敷くぼかしグレー（旧OS用）。黒だと穴が空いて見えるのでグレー
                padColor: Color(white: BubbleStyle.plateWhite(dark: true)),
                padOpacity: BubbleStyle.plateOpacity(dark: true)
            )
        default:
            // ライトモードでも白文字。明るい背景では暗い縁取りと下地で成立させる
            return BubbleStyle(
                haloColor: .white,
                haloOpacities: (0.62 * haloGain, 0.42 * haloGain, 0.30 * haloGain),
                padColor: Color(white: BubbleStyle.plateWhite(dark: false)),
                padOpacity: BubbleStyle.plateOpacity(dark: false)
            )
        }
    }
}

/// **旧OS専用**: 文字の裏に敷くぼかしたグレーの下地。
///
/// macOS 26 では、ガラスが背景に応じて light/dark を反転し、その上に載る文字も
/// 一緒に反転するので何も要らない。旧OS（14/15）はその仕組みが無く、
/// 「ダーク外観 × 明るい背景」「ライト外観 × 暗い背景」で文字が沈むため、
/// 文字コラムの裏だけを外観と同じ側の色でぼかして持ち上げる。
/// 縁取り（ハロー）ではなく面で支えるので、細い字が汚れて見えない
struct BubbleTextPlate: View {
    /// 基準72ptに対するスケール
    var s: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if !usesLiquidGlass {
            let style = BubbleStyle.resolve(colorScheme)
            Ellipse()
                .fill(style.padColor.opacity(style.padOpacity))
                .frame(width: 42 * s, height: 40 * s)
                .blur(radius: 7 * s)
        }
    }
}

/// 素通しの膜の上でも文字が読めるようにする縁取りハロー（BubbleStyleに従う）。
/// 細い縁取り+中間+広いにじみの3層で、反対色の背景上でも字幕のように浮かせる
struct BubbleTextHalo: ViewModifier {
    var colorScheme: ColorScheme

    func body(content: Content) -> some View {
        let style = BubbleStyle.resolve(colorScheme)
        return content
            .shadow(color: style.haloColor.opacity(style.haloOpacities.tight), radius: 0.8)
            .shadow(color: style.haloColor.opacity(style.haloOpacities.mid), radius: 2)
            .shadow(color: style.haloColor.opacity(style.haloOpacities.wide), radius: 4.5)
    }
}

extension Color {
    /// 使用量リングの終端色。バー内で色が転ばないよう、ごく僅かに締めるだけ
    /// （以前は彩度1.3倍・明度0.8倍で、青→紫のように色相が動いて見えていた）
    var ringDeepened: Color {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return self }
        var h: CGFloat = 0, sat: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &sat, brightness: &b, alpha: &a)
        return Color(hue: h, saturation: min(1, sat * 1.06), brightness: b * 0.95, opacity: a)
    }
}

// MARK: - バブル（浮遊モード）

struct BubbleView: View {
    var state: AppState
    var settings: SettingsStore
    var actions: PanelActions
    @Environment(\.colorScheme) private var colorScheme


    private var usageWindow: UsageWindow? { state.usage?.window(for: settings.bubbleMetric) }
    private var value: Double { usageWindow?.utilization ?? 0 }

    private var percentText: String {
        state.usage == nil ? "–%" : "\(Int(value.rounded()))%"
    }

    private var metricCaption: String? {
        switch settings.bubbleMetric {
        case .session: return nil
        case .weekly: return L("panel.weekly")
        case .fable: return state.fableLabel
        }
    }

    private var tint: Color {
        if value >= 95 { return .red }
        if value >= 80 { return .orange }
        return settings.useSystemAccent ? Color(nsColor: .controlAccentColor) : .claudeOrange
    }

    /// バブルの直径（膨張率は現在1.0固定）
    private var diameter: CGFloat {
        PanelController.bubbleDiameter * PanelController.bubbleScaleFactor(for: value)
    }

    /// 装飾の基準スケール（72ptを1とする）。3つ表示の BubbleFace と同じ流儀
    private var sizeFactor: CGFloat { diameter / 72 }

    var body: some View {
        ZStack {
            // ガラス（Liquid Glass）に透過と屈折を全て任せる。
            // 上に敷く膜・照り・コースティクスは、ガラスが透かした像を
            // 塗り潰してしまうため全廃した（曇って見えた原因）
            // 拡散照明にもクリア化マスクを掛ける（3つ表示はガラス部分木ごと
            // マスクされるので、掛けないと単体だけパッチが白く濁って揃わない）
            BubbleDepthUnderlay(s: sizeFactor)
                .bubbleClarity()
            // 旧OSだけ、文字の裏にぼかしグレーを敷く（26は自動反転で足りる）
            BubbleTextPlate(s: sizeFactor)
            // 中身のゆらぎ（WobbleHost）は廃止した（2026-08-28ユーザー判断）。
            // ガラスを content 側へ掛ける構成では、球まるごとがウィンドウ単位の
            // ガラス群へ持ち上げられて内側のレイヤーアニメーションが効かないため、
            // 残しても描画に出ない
            Group {
                VStack(spacing: 0) {
                    // 待機中は通常色・消費中だけClaudeオレンジ（オレンジ=消費中のシグナルを守る）。
                    // 視認性は色ではなくサイズで確保（16ptで光条も太くなる）
                    ClaudeLogoView(
                        animating: state.isActive,
                        color: state.isActive ? .claudeOrange : Color.primary.opacity(0.72)
                    )
                    .frame(width: 16, height: 16)
                    Text(percentText)
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.4), value: percentText)
                        .modifier(BubbleTextHalo(colorScheme: colorScheme))
                    if let metricCaption {
                        Text(metricCaption)
                            .font(.system(size: 9))
                            .foregroundStyle(.primary.opacity(0.75))
                            .modifier(BubbleTextHalo(colorScheme: colorScheme))
                    }
                    // リミットのリセット時刻
                    if let resets = usageWindow?.resetsAt {
                        // バブル内は時刻だけ（↺は狭い球の中では記号が潰れて読みにくい。
                        // ホバーHUDは複数行の一覧なので、あちらには記号を残す）
                        Text(UsageGaugeView.resetText(resets))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(.primary.opacity(0.75))
                            .modifier(BubbleTextHalo(colorScheme: colorScheme))
                            .padding(.top, 1)
                    }
                }
            }

            // 立体感と光沢は単体/3つ表示で共通のコンポーネント（BubbleDecoration.swift）。
            // 深度層はリングと文字の下、陰と光沢は文字の上に置く
            BubbleShadingOverlay(s: sizeFactor, strength: BubbleShadingStrength.scaled(for: colorScheme))
            BubbleGlossOverlay(s: sizeFactor)

            // 使用量リング。溝は描かず進捗アークだけを見せる。
            // 虹（薄膜干渉）より前面に置き、ゲージの色が虹に染まらないようにする
            Circle()
                .trim(from: 0, to: max(0.003, min(value, 100) / 100))
                .stroke(
                    // ほぼ均一。バー内で色が変わると進捗ではなく装飾に見えるため、
                    // 立体感が出る最小限の差だけ残す
                    LinearGradient(
                        colors: [tint, tint.ringDeepened],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    style: StrokeStyle(lineWidth: 3.4 * sizeFactor, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(4 * sizeFactor)
        }
        .padding(3 * sizeFactor)
        // 3つ表示の BubbleFace と同じ比率（基準径72ptを1とするスケール駆動）。
        // 膨張を廃止したので「リングだけ固定サイズ」にする理由がなくなり、
        // 同じ64ptなら1つ表示とセッション球が完全に同じ見た目になる
        .frame(width: diameter, height: diameter)
        .animation(.bouncy(duration: 0.4), value: diameter)
        // ガラス玉は薄めに（26=Liquid Glass / 旧OS=すりガラス）。背景が透けて
        // 水晶玉のように見えるところまで落としている
        .modifier(SingleBubbleGlass())
        // 縁の光と虹は BubbleGlossOverlay（フレネル+薄膜干渉）に統合済み
        .contentShape(Circle())
        .contextMenu {
            #if DEBUG
            Button(forceLegacyUI ? "検証: 旧OS表示 → 通常へ戻す" : "検証: 旧OS表示に切り替え") {
                actions.toggleLegacy()
            }
            Divider()
            #endif
            Button(L("bubble.expandToPanel")) { actions.expand() }
            Button(L("bubble.closeBubble")) { actions.toBubble() }
            Divider()
            Button(L("bubble.settingsMenu")) { actions.settings() }
            Button(L("bubble.quit")) { actions.quit() }
        }
        .onChange(of: value) { _, newValue in
            if newValue >= 100 { actions.pop() }
        }
        .task {
            // すでに100%の状態でバブルにした場合も少し置いてから割れる
            try? await Task.sleep(for: .seconds(1.2))
            if value >= 100 { actions.pop() }
        }
        .help(L("bubble.helpSingle"))
    }
}

// MARK: - 割れる演出（シャボン玉の膜が弾ける）

/// 破裂の演出。**実物のシャボン玉の割れ方**に寄せている:
/// 膜は一瞬で縁へ引き戻され（虹色のリングが薄く広がって消える）、
/// その膜が表面張力で**小さな滴に分かれて飛び散る**。
/// 白い衝撃波のような「爆発」表現は使わない（シャボン玉には無い動き）
struct PopBurstView: View {
    var burstScale: CGFloat = 1
    @State private var expand = false

    /// 飛び散る滴。角度と距離は固定テーブル（毎回同じでも十分に自然に見える。
    /// 乱数を使うとプレビューやテストで結果が揺れる）
    private static let droplets: [(angle: Double, distance: CGFloat, size: CGFloat, delay: Double)] = [
        (  8, 1.00, 4.8, 0.00), ( 34, 0.82, 3.1, 0.02), ( 61, 1.10, 5.8, 0.00),
        ( 92, 0.74, 2.6, 0.03), (118, 1.02, 4.2, 0.01), (147, 0.88, 3.7, 0.02),
        (176, 1.12, 5.4, 0.00), (203, 0.78, 2.9, 0.03), (231, 0.96, 4.5, 0.01),
        (259, 1.06, 3.4, 0.02), (288, 0.84, 5.1, 0.00), (315, 1.00, 3.0, 0.03),
        (338, 0.90, 4.0, 0.01),
    ]

    var body: some View {
        ZStack {
            // ① 膜の縁: 虹色のリングがすっと広がって消える（膜が縁へ引かれる瞬間）
            Circle()
                .stroke(
                    AngularGradient(colors: [
                        .cyan.opacity(0.55), .purple.opacity(0.45), .pink.opacity(0.5),
                        .orange.opacity(0.35), .mint.opacity(0.45), .cyan.opacity(0.55),
                    ], center: .center),
                    lineWidth: expand ? 0.6 : 4
                )
                .frame(width: 74 * burstScale, height: 74 * burstScale)
                .scaleEffect(expand ? 1.28 : 1.0)
                .opacity(expand ? 0 : 0.95)

            // ② 飛び散る滴: 膜が表面張力で分かれたもの。外へ飛びながら少し落ちる
            ForEach(Array(Self.droplets.enumerated()), id: \.offset) { index, drop in
                Droplet(spec: drop, burstScale: burstScale, expand: expand)
            }

            // ③ 名残の霧（ごく薄く）
            Circle()
                .fill(.white.opacity(expand ? 0 : 0.10))
                .frame(width: 60 * burstScale, height: 60 * burstScale)
                .scaleEffect(expand ? 1.35 : 0.9)
                .blur(radius: expand ? 14 : 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) { expand = true }
        }
    }

    /// 滴1粒。虹色の膜のかけらなので、わずかに色を持たせる
    private struct Droplet: View {
        var spec: (angle: Double, distance: CGFloat, size: CGFloat, delay: Double)
        var burstScale: CGFloat
        var expand: Bool

        var body: some View {
            let radians = spec.angle * .pi / 180
            // リング（膜の縁）より外まで飛ばす。内側で消えると「弾けた」に見えない
            let travel = 78 * burstScale * spec.distance
            let x = cos(radians) * travel
            // 飛びながら少し落ちる（表面張力で飛んだ滴の弾道）
            let y = sin(radians) * travel + 7 * burstScale * spec.distance
            return Circle()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.95), tint.opacity(0.75)],
                        center: UnitPoint(x: 0.35, y: 0.3),
                        startRadius: 0, endRadius: spec.size * burstScale
                    )
                )
                .frame(width: spec.size * burstScale, height: spec.size * burstScale)
                // 出発点は膜の縁（球の輪郭）。そこから外へ散る
                .offset(x: expand ? x : cos(radians) * 34 * burstScale,
                        y: expand ? y : sin(radians) * 34 * burstScale)
                .scaleEffect(expand ? 0.45 : 1)
                .opacity(expand ? 0 : 1)
                .animation(.easeOut(duration: 0.5).delay(spec.delay), value: expand)
        }

        /// 角度ごとに薄膜干渉の色を割り当てる（虹の帯と同じ並び）
        private var tint: Color {
            let hue = (spec.angle / 360).truncatingRemainder(dividingBy: 1)
            return Color(hue: hue, saturation: 0.5, brightness: 1.0)
        }
    }
}
