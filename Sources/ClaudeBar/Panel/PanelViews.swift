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
    var actions: PanelActions

    var body: some View {
        BubbleView(state: state, settings: settings, actions: actions)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - シャボン玉風の質感（虹色のリム + ハイライト）

struct IridescentRim<S: InsettableShape>: View {
    var shape: S
    var lineWidth: CGFloat = 1.5

    var body: some View {
        ZStack {
            shape
                .strokeBorder(
                    AngularGradient(colors: [
                        .cyan.opacity(0.28), .purple.opacity(0.22), .pink.opacity(0.26),
                        .orange.opacity(0.2), .mint.opacity(0.24), .cyan.opacity(0.28),
                    ], center: .center),
                    lineWidth: lineWidth
                )
                .blur(radius: 0.5)
            shape
                .strokeBorder(.white.opacity(0.25), lineWidth: 0.8)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - OS適応ガラス
// macOS 26 = Liquid Glass（純正メニューと同じ質感）/ それ以前 = 従来のすりガラス(Material)

/// パネル背景: 26はLiquid Glass+乳白ティント、旧OSはultraThinMaterial+同じティント
struct AdaptivePanelGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(
                .regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.45)),
                in: RoundedRectangle(cornerRadius: 18)
            )
        } else {
            content.background(
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 18)
                        .fill(Color(nsColor: .windowBackgroundColor).opacity(0.45))
                }
            )
        }
    }
}

/// バブルのガラス玉: 26は透明なLiquid Glass、旧OSはすりガラスの球
/// （ハイライト・コースティクス・虹色リムは自前描画なので全OS共通）
struct AdaptiveBubbleGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.clear, in: Circle())
        } else {
            content.background(Circle().fill(.ultraThinMaterial))
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
                Text("Claude 使用量")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if state.mode == .floating {
                    IconButton(systemName: "xmark.circle.fill", help: "メニューバーへ戻す") {
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

            UsageGaugeView(title: "現在のセッション", window: state.usage?.session, baseTint: baseTint)

            Hairline().padding(.vertical, 12)

            Text("週間制限")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 12) {
                UsageGaugeView(title: "すべてのモデル", window: state.usage?.weeklyAll, baseTint: baseTint)
                UsageGaugeView(title: state.fableLabel, window: state.usage?.weeklyFable, baseTint: baseTint)

                // ペース予測は上限に達しそうな時だけ警告として表示
                if case .willHit(let eta) = state.weeklyForecast {
                    ForecastRow(eta: eta)
                }
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
                IconButton(systemName: "arrow.clockwise", help: "今すぐ更新") { actions.refresh() }
                IconButton(systemName: "gearshape.fill", help: "設定") { actions.settings() }
                IconButton(
                    systemName: "pin.fill",
                    help: state.mode == .floating ? "メニューバー直下に戻す" : "オーバーレイモード（常に手前に表示）",
                    activeState: state.mode == .floating,
                    activeTint: baseTint
                ) { actions.toOverlay() }
                IconButton(
                    systemName: "bubbles.and.sparkles.fill",
                    help: state.bubbleActive ? "バブルを非表示" : "浮遊モード（バブル）",
                    activeState: state.bubbleActive,
                    activeTint: baseTint
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
        guard let date = state.lastUpdated else { return "未取得" }
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm 更新"
        return formatter.string(from: date)
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
            Label("アカウント連携", systemImage: "person.crop.circle.badge.checkmark")
                .font(.caption.weight(.semibold))
            Text(cliInstalled
                ? "Claude Codeの公式ログインで連携します。パスワードがこのアプリを経由することはありません"
                : "連携にはClaude Codeが必要です（未検出）。①でインストールしてから②でログインしてください")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !cliInstalled {
                Button {
                    LoginHelper.copyInstallCommand()
                    copied = true
                } label: {
                    Label(copied ? "コピーしました — ターミナルで実行してください" : "① インストールコマンドをコピー",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .tint(.claudeOrange)
            }
            Button {
                actions.login()
            } label: {
                Label(cliInstalled ? "Claude Codeにログイン" : "② Claude Codeにログイン", systemImage: "terminal")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderless)
            .tint(.claudeOrange)
        }
        .modifier(SectionTile())
        .task {
            // パネルを開くたびに検出し直す（①実行後に開き直せば②だけの表示になる）
            cliInstalled = LoginHelper.claudeCLIInstalled
        }
    }
}

struct ForecastRow: View {
    let eta: Date

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text("このペースだと \(Self.format(eta)) 頃に週間上限")
        }
        .font(.caption2)
        .foregroundStyle(.orange)
    }

    private static func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "M/d H:mm"
        return formatter.string(from: date)
    }
}

struct ExtraUsageRow: View {
    let extra: ExtraUsage

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("追加利用")
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

struct IconButton: View {
    let systemName: String
    var help = ""
    /// nil=通常ボタン（ホバー時のみ丸背景）。true/false=トグル（常時グレー地、trueでアクセント色）
    var activeState: Bool? = nil
    var activeTint: Color = .accentColor
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(HoverPressIconStyle(hovering: hovering, activeState: activeState, activeTint: activeTint))
        .onHover { hovering = $0 }
        .help(help)
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

// MARK: - バブル（浮遊モード）

struct BubbleView: View {
    var state: AppState
    var settings: SettingsStore
    var actions: PanelActions

    private var usageWindow: UsageWindow? { state.usage?.window(for: settings.bubbleMetric) }
    private var value: Double { usageWindow?.utilization ?? 0 }

    private var percentText: String {
        state.usage == nil ? "–%" : "\(Int(value.rounded()))%"
    }

    private var metricCaption: String? {
        switch settings.bubbleMetric {
        case .session: return nil
        case .weekly: return "週間"
        case .fable: return state.fableLabel
        }
    }

    private var tint: Color {
        if value >= 95 { return .red }
        if value >= 80 { return .orange }
        return settings.useSystemAccent ? Color(nsColor: .controlAccentColor) : .claudeOrange
    }

    /// 使用量に応じて風船のように膨らむ（10%ごとに+4%、100%で1.4倍）
    private var sizeFactor: CGFloat {
        PanelController.bubbleScaleFactor(for: value)
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                // ヘイズ: 中心にも薄い乳白を敷いて文字の下地を安定させる
                // （どんな背景でも%が読める。縁に向かってCC風の曇りへ繋がる）
                Circle()
                    .fill(EllipticalGradient(
                        gradient: Gradient(stops: [
                            .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.25), location: 0),
                            .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.22), location: 0.4),
                            .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.06), location: 0.65),
                            .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.4), location: 0.88),
                            .init(color: Color(nsColor: .windowBackgroundColor).opacity(0.5), location: 1),
                        ]),
                        center: .center,
                        startRadiusFraction: 0, endRadiusFraction: 0.5
                    ))
                    .blur(radius: 2)
                // 球面の照り（左上光源）— 抑えめにしてガラスの透明感を残す
                Circle()
                    .fill(RadialGradient(
                        colors: [.white.opacity(0.15), .white.opacity(0.04), .clear],
                        center: UnitPoint(x: 0.32, y: 0.28),
                        startRadius: 2, endRadius: 46 * sizeFactor
                    ))
                // 上縁の深度シェーディング — 球の丸みを出す暗がり
                Circle()
                    .trim(from: 0.5, to: 1.0)
                    .stroke(Color.black.opacity(0.15), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .blur(radius: 5)
                // 底に溜まる透過光（コースティクス）— ガラス玉が光を集める表現
                Circle()
                    .trim(from: 0.1, to: 0.4)
                    .stroke(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .blur(radius: 5)
                Circle()
                    .fill(RadialGradient(
                        colors: [.white.opacity(0.35), .clear],
                        center: UnitPoint(x: 0.5, y: 0.9),
                        startRadius: 1, endRadius: 26 * sizeFactor
                    ))
                // ゲージ溝は非表示（進捗アークだけを見せる）
                // ゲージだけ従来の位置（縁から7pt）に留める追加インセット
                Circle().stroke(Color.primary.opacity(0), lineWidth: 4)
                    .padding(4)
                Circle()
                    .trim(from: 0, to: max(0.003, min(value, 100) / 100))
                    .stroke(
                        LinearGradient(
                            colors: [tint.opacity(0.55), tint],
                            startPoint: .leading, endPoint: .trailing
                        ),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .padding(4)
                VStack(spacing: 0) {
                    // 消費中だけClaudeオレンジ、待機中はデフォルトカラー
                    ClaudeLogoView(
                        animating: state.isActive,
                        color: state.isActive ? .claudeOrange : .primary
                    )
                    .frame(width: 14, height: 14)
                    Text(percentText)
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.4), value: percentText)
                    if let metricCaption {
                        Text(metricCaption)
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    // リミットのリセット時刻 — なるべく目立たない極小・淡色
                    if let resets = usageWindow?.resetsAt {
                        Text("↺ \(UsageGaugeView.resetText(resets))")
                            .font(.system(size: 8))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                            .padding(.top, 1)
                    }
                }
                .rotationEffect(.degrees(sin(t * 0.9) * 3))

                // 主ハイライト: 大きく柔らかいブルーム + 小さく鋭いスポット（左上光源）
                Ellipse()
                    .fill(.white.opacity(0.55))
                    .frame(width: 24 * sizeFactor, height: 14 * sizeFactor)
                    .rotationEffect(.degrees(-35))
                    .offset(x: -13 * sizeFactor, y: -17 * sizeFactor)
                    .blur(radius: 4)
                Circle()
                    .fill(.white.opacity(0.95))
                    .frame(width: 6 * sizeFactor, height: 6 * sizeFactor)
                    .offset(x: -19 * sizeFactor, y: -13 * sizeFactor)
                    .blur(radius: 0.6)
                // 対向の小さなグリント
                Circle()
                    .fill(.white.opacity(0.28))
                    .frame(width: 5 * sizeFactor, height: 5 * sizeFactor)
                    .offset(x: 15 * sizeFactor, y: 19 * sizeFactor)
                    .blur(radius: 0.8)
            }
            .padding(3)
        }
        // フレームだけ拡大し、リングの太さと中身（ロゴ/%）は固定サイズを保つ
        .frame(width: 76 * sizeFactor, height: 76 * sizeFactor)
        .animation(.bouncy(duration: 0.4), value: sizeFactor)
        // 素のLiquid Glass（.clear = 透明度の高いガラス玉。旧OSはすりガラスにフォールバック）
        .modifier(AdaptiveBubbleGlass())
        // 微かなドロップシャドウ（白）— 左上光源に合わせて右下へ落とすグロー
        .background(
            Circle()
                .fill(Color.white.opacity(0.25))
                .blur(radius: 7)
                .offset(x: 4, y: 5)
        )
        .overlay(
            ZStack {
                // 内側へにじむ虹色フリンジ
                Circle()
                    .strokeBorder(
                        AngularGradient(colors: [
                            .cyan.opacity(0.3), .purple.opacity(0.24), .pink.opacity(0.28),
                            .orange.opacity(0.22), .mint.opacity(0.26), .cyan.opacity(0.3),
                        ], center: .center),
                        lineWidth: 4
                    )
                    .blur(radius: 3)
                    .opacity(0.7)
                IridescentRim(shape: Circle())
            }
            .allowsHitTesting(false)
        )
        .contentShape(Circle())
        .contextMenu {
            Button("パネルに展開") { actions.expand() }
            Button("バブルを閉じる") { actions.toBubble() }
            Divider()
            Button("設定…") { actions.settings() }
            Button("終了") { actions.quit() }
        }
        .onChange(of: value) { _, newValue in
            if newValue >= 100 { actions.pop() }
        }
        .task {
            // すでに100%の状態でバブルにした場合も少し置いてから割れる
            try? await Task.sleep(for: .seconds(1.2))
            if value >= 100 { actions.pop() }
        }
        .help("クリックでポヨン・3連打で破裂・ドラッグで移動・パネルはメニューバーから")
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
