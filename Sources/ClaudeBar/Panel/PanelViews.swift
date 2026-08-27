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

/// バブル専用ウィンドウのルート（バブルはパネルと独立したウィンドウで共存する）
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
            } else if settings.isTripleBubble {
                TripleBubbleView(state: state, settings: settings, cluster: cluster, actions: actions)
            } else {
                BubbleView(state: state, settings: settings, actions: actions)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - OS適応ガラス
// macOS 26 = Liquid Glass（純正メニューと同じ質感）/ それ以前 = 従来のすりガラス(Material)

/// パネル背景: 26はLiquid Glass+乳白ティント、旧OSはultraThinMaterial+同じティント。
/// ダークモードではwindowBackgroundColorがほぼ黒でガラスが純正パネルより暗く濁るため、
/// ティントを付けず素のガラスにする（純正のサウンドパネル等と同じ見え方）
struct AdaptivePanelGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let tint = Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0 : 0.45)
        if #available(macOS 26.0, *), !forceLegacyUI {
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

/// 単体バブル専用のガラス玉。ガラスを content ではなく背景の円に敷き、
/// 2倍で描いて0.5倍に縮める縮小レンズ合成を行う（%やリセット時刻は不透明のまま前面）。
/// 3つ表示（TripleBubbleGlass）に縮小合成を入れていないのは、150ptウィンドウ前提の
/// 2倍サンプリング領域が220ptウィンドウ+隣接球でどう干渉するか未検証のため
struct SingleBubbleGlass: ViewModifier {
    /// 検証用: CLAUDEBAR_GLASS=clear で旧構成（.clear+縮小レンズ）に戻す
    static let useClear = ProcessInfo.processInfo.environment["CLAUDEBAR_GLASS"] == "clear"
    /// ガラスの背後に敷く下地の濃さ（検証用: CLAUDEBAR_BACKDROP 0-100）
    static let backdropOpacity = Double(ProcessInfo.processInfo.environment["CLAUDEBAR_BACKDROP"] ?? "0")! / 100
    /// 下地の入れ方（検証用: back / front / tint）
    static let mode = ProcessInfo.processInfo.environment["CLAUDEBAR_MODE"] ?? "back"

    func body(content: Content) -> some View {
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
                // 旧OS: Liquid Glassが無いのですりガラス（Material）で代替
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
    var body: some View {
        let center = CGPoint(x: 6.2, y: 9.8)
        let sparkle = CGPoint(x: 13.1, y: 3.2)
        let arm: CGFloat = 2.5
        ZStack {
            Path { p in
                p.addEllipse(in: CGRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10))
            }
            .stroke(style: StrokeStyle(lineWidth: 1.4))
            // シャボン玉のハイライト（左上の弧）
            Path { p in
                p.addArc(center: center, radius: 3.0,
                         startAngle: .degrees(200), endAngle: .degrees(245), clockwise: false)
            }
            .stroke(style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
            // キラキラ: 均一な線幅の十字
            Path { p in
                p.move(to: CGPoint(x: sparkle.x, y: sparkle.y - arm))
                p.addLine(to: CGPoint(x: sparkle.x, y: sparkle.y + arm))
                p.move(to: CGPoint(x: sparkle.x - arm, y: sparkle.y))
                p.addLine(to: CGPoint(x: sparkle.x + arm, y: sparkle.y))
            }
            .stroke(style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
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
struct BubbleStyle {
    /// 文字色。外観によらず白（コントロールセンターと同じ白抜き）。
    /// 外観に従う黒文字+白ハロー方式はライトモードで中心を白く濁らせ、
    /// 黒背景では沈むという二重の不利があった
    var textColor: Color
    /// 文字の縁取り色（常に暗色。白文字を明るい背景でも成立させる）
    var haloColor: Color
    /// 縁取り3層の不透明度（細い縁 / 中間 / 広いにじみ）
    var haloOpacities: (tight: Double, mid: Double, wide: Double)
    /// 文字直下の下地（ぼかした小さな円）。全面の暗幕に加えて局所的に効かせる
    /// （全面だけで4.5:1を狙うと球が不透明な円盤になるため、局所で稼ぐ）
    var padColor: Color
    var padOpacity: Double
    /// 控えめな文字（リセット時刻・キャプション）の不透明度
    var secondaryTextOpacity: Double
    /// ロゴ（Claudeスパーク）の待機色。白文字より一段引いた明るいグレー
    /// （消費中はClaudeオレンジで、これは外観によらず共通）
    var logoIdleColor: Color

    static func resolve(_ scheme: ColorScheme) -> BubbleStyle {
        switch scheme {
        case .dark:
            // ダークモードは球も背景も暗いので白文字。
            // ライトモードの黒文字と対で、外観に素直に従う
            return BubbleStyle(
                textColor: .white,
                haloColor: .black,
                haloOpacities: (0, 0, 0),
                padColor: .black,
                padOpacity: 0.55,
                secondaryTextOpacity: 0.85,
                logoIdleColor: Color(white: 0.78)
            )
        default:
            // ライトモードでも白文字。明るい背景では暗い縁取りと下地で成立させる
            return BubbleStyle(
                textColor: Color(white: 0.12),
                haloColor: .white,
                haloOpacities: (0, 0, 0),
                padColor: .white,
                padOpacity: 0.55,
                secondaryTextOpacity: 0.75,
                logoIdleColor: Color(white: 0.62)
            )
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

    /// 使用量に応じて風船のように膨らむ（10%ごとに+1%、100%で1.1倍）
    private var sizeFactor: CGFloat {
        PanelController.bubbleScaleFactor(for: value)
    }

    var body: some View {
        ZStack {
            // ガラス（Liquid Glass）に透過と屈折を全て任せる。
            // 上に敷く膜・照り・コースティクスは、ガラスが透かした像を
            // 塗り潰してしまうため全廃した（曇って見えた原因）
            // 拡散照明にもクリア化マスクを掛ける（3つ表示はガラス部分木ごと
            // マスクされるので、掛けないと単体だけパッチが白く濁って揃わない）
            BubbleDepthUnderlay(s: sizeFactor)
                .bubbleClarity()
            // 中身のゆらぎはCAAnimation常駐（WobbleHost）。
            // 旧TimelineView(30fps)のbody再評価は待機中CPU約7%の主因だった
            WobbleHost {
                VStack(spacing: 0) {
                    // 待機中は通常色・消費中だけClaudeオレンジ（オレンジ=消費中のシグナルを守る）。
                    // 視認性は色ではなくサイズで確保（16ptで光条も太くなる）
                    ClaudeLogoView(
                        animating: state.isActive,
                        color: state.isActive ? .claudeOrange : BubbleStyle.resolve(colorScheme).logoIdleColor
                    )
                    .frame(width: 16, height: 16)
                    Text(percentText)
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .foregroundStyle(BubbleStyle.resolve(colorScheme).textColor)
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.4), value: percentText)
                        .modifier(BubbleTextHalo(colorScheme: colorScheme))
                    if let metricCaption {
                        Text(metricCaption)
                            .font(.system(size: 9))
                            .foregroundStyle(BubbleStyle.resolve(colorScheme).textColor.opacity(BubbleStyle.resolve(colorScheme).secondaryTextOpacity))
                            .modifier(BubbleTextHalo(colorScheme: colorScheme))
                    }
                    // リミットのリセット時刻
                    if let resets = usageWindow?.resetsAt {
                        // バブル内は時刻だけ（↺は狭い球の中では記号が潰れて読みにくい。
                        // ホバーHUDは複数行の一覧なので、あちらには記号を残す）
                        Text(UsageGaugeView.resetText(resets))
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(BubbleStyle.resolve(colorScheme).textColor.opacity(BubbleStyle.resolve(colorScheme).secondaryTextOpacity))
                            .modifier(BubbleTextHalo(colorScheme: colorScheme))
                            .padding(.top, 1)
                    }
                }
            }

            // 立体感と光沢は単体/3つ表示で共通のコンポーネント（BubbleDecoration.swift）。
            // 深度層はリングと文字の下、光沢層は文字の上に置く
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
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(4)
        }
        .padding(3)
        // フレームだけ拡大し、リングの太さ・ぼかし・中身（ロゴ/%）は固定サイズを保つ。
        // 3つ表示の BubbleSphere は装飾ごとスケールする別方針なので共通化していない
        .frame(width: 72 * sizeFactor, height: 72 * sizeFactor)
        .animation(.bouncy(duration: 0.4), value: sizeFactor)
        // ガラス玉は薄めに（26=Liquid Glass / 旧OS=すりガラス）。背景が透けて
        // 水晶玉のように見えるところまで落としている
        .modifier(SingleBubbleGlass())
        // 縁の光と虹は BubbleGlossOverlay（フレネル+薄膜干渉）に統合済み
        .contentShape(Circle())
        .contextMenu {
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

struct PopBurstView: View {
    var burstScale: CGFloat = 1
    @State private var expand = false

    var body: some View {
        ZStack {
            // 虹色の膜の縁が広がりながら薄れて消える
            Circle()
                .stroke(
                    AngularGradient(colors: [
                        .cyan.opacity(0.55), .purple.opacity(0.45), .pink.opacity(0.5),
                        .orange.opacity(0.35), .mint.opacity(0.45), .cyan.opacity(0.55),
                    ], center: .center),
                    lineWidth: expand ? 1 : 5
                )
                .frame(width: 76 * burstScale, height: 76 * burstScale)
                .scaleEffect(expand ? 1.55 : 1.0)
                .opacity(expand ? 0 : 0.9)

            // 白い衝撃波（ひと回り速く広がる）
            Circle()
                .stroke(.white.opacity(expand ? 0 : 0.5), lineWidth: 2)
                .frame(width: 60 * burstScale, height: 60 * burstScale)
                .scaleEffect(expand ? 2.0 : 0.8)

            // 霧のようにふわっと消える
            Circle()
                .fill(.white.opacity(expand ? 0 : 0.16))
                .frame(width: 70 * burstScale, height: 70 * burstScale)
                .scaleEffect(expand ? 1.5 : 0.9)
                .blur(radius: expand ? 16 : 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.5)) { expand = true }
        }
    }
}
