import SwiftUI

struct PanelActions {
    var refresh: () -> Void = {}
    var quit: () -> Void = {}
    var toBubble: () -> Void = {}
    var expand: () -> Void = {}
    var backToMenuBar: () -> Void = {}
    var pop: () -> Void = {}
    var settings: () -> Void = {}
    var login: () -> Void = {}
    var contentHeightChanged: (CGFloat) -> Void = { _ in }
}

// MARK: - ルート（モード切り替え）
// ※「ぷるんっ/ポヨン」はSwiftUIで行うとガラスの円形マスクで切れるため、
//   PanelController.bounceAssembly()（レイヤー変形）で行う

struct PanelRootView: View {
    var state: AppState
    var settings: SettingsStore
    var actions: PanelActions

    var body: some View {
        ZStack {
            switch state.mode {
            case .bubble:
                BubbleView(state: state, settings: settings, actions: actions)
            case .attached, .floating:
                UsagePanelView(state: state, settings: settings, actions: actions)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        actions.contentHeightChanged(height)
                    }
            }
        }
        // ウィンドウは固定サイズなので、内容（ガラスごと）は上詰めで描く
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            .gesture(WindowDragGesture())

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

            if let message = state.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if state.needsLogin {
                        Button {
                            actions.login()
                        } label: {
                            Label("Claude Codeにログイン", systemImage: "terminal")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                        .tint(.claudeOrange)
                    }
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
                IconButton(systemName: "bubbles.and.sparkles.fill", help: "浮遊モード（バブル）") { actions.toBubble() }
                IconButton(systemName: "gearshape.fill", help: "設定") { actions.settings() }
                IconButton(systemName: "power", help: "終了") { actions.quit() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(width: 300)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.45)), in: RoundedRectangle(cornerRadius: 18))
        .overlay(PanelSheen())
    }

    private var updatedText: String {
        guard let date = state.lastUpdated else { return "未取得" }
        let formatter = DateFormatter()
        formatter.dateFormat = "H:mm 更新"
        return formatter.string(from: date)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
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
                // 球面の照り（左上光源）— シャボン玉の立体感
                Circle()
                    .fill(RadialGradient(
                        colors: [.white.opacity(0.25), .white.opacity(0.06), .clear],
                        center: UnitPoint(x: 0.32, y: 0.28),
                        startRadius: 2, endRadius: 46 * sizeFactor
                    ))
                // ゲージ溝はごく薄く（進捗アークだけが目立つように）
                Circle().stroke(Color.primary.opacity(0.05), lineWidth: 4)
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
                }
                .rotationEffect(.degrees(sin(t * 0.9) * 3))

                // シャボン玉のハイライト（主）— 表面の特徴なのでサイズ追従
                Ellipse()
                    .fill(.white.opacity(0.5))
                    .frame(width: 20 * sizeFactor, height: 9 * sizeFactor)
                    .rotationEffect(.degrees(-32))
                    .offset(x: -15 * sizeFactor, y: -19 * sizeFactor)
                    .blur(radius: 1.5)
                // 対向の小さなグリント
                Circle()
                    .fill(.white.opacity(0.28))
                    .frame(width: 5 * sizeFactor, height: 5 * sizeFactor)
                    .offset(x: 15 * sizeFactor, y: 19 * sizeFactor)
                    .blur(radius: 0.8)
            }
            .padding(7)
        }
        // フレームだけ拡大し、リングの太さと中身（ロゴ/%）は固定サイズを保つ
        .frame(width: 76 * sizeFactor, height: 76 * sizeFactor)
        .animation(.bouncy(duration: 0.4), value: sizeFactor)
        .glassEffect(.regular.tint(Color(nsColor: .windowBackgroundColor).opacity(0.45)), in: Circle())
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
            Button("メニューバーへ戻す") { actions.backToMenuBar() }
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
