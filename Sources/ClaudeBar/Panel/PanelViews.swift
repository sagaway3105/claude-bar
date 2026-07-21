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
                UsagePanelView(state: state, actions: actions)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        actions.contentHeightChanged(height)
                    }
            }
        }
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

struct PanelSheen: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            IridescentRim(shape: RoundedRectangle(cornerRadius: 24))
            // 上部のスペキュラハイライト
            Ellipse()
                .fill(.white.opacity(0.09))
                .frame(width: 170, height: 44)
                .blur(radius: 10)
                .offset(x: 16, y: -14)
        }
        .allowsHitTesting(false)
        .clipShape(RoundedRectangle(cornerRadius: 24))
    }
}

// MARK: - 展開パネル

struct UsagePanelView: View {
    var state: AppState
    var actions: PanelActions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Capsule().fill(.tertiary).frame(width: 36, height: 5)
                Spacer()
            }
            .padding(.top, 9)
            .contentShape(Rectangle())
            .gesture(WindowDragGesture())

            HStack(spacing: 6) {
                ClaudeLogoView(animating: state.isActive, color: .claudeOrange)
                    .frame(width: 15, height: 15)
                Text("Claude 使用量")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if state.mode == .floating {
                    IconButton(systemName: "xmark.circle.fill", help: "メニューバーへ戻す") {
                        actions.backToMenuBar()
                    }
                }
            }

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
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }

            UsageGaugeView(title: "現在のセッション", window: state.usage?.session, prominent: true)

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 10) {
                Text("週間制限")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                UsageGaugeView(title: "すべてのモデル", window: state.usage?.weeklyAll)
                UsageGaugeView(title: state.fableLabel, window: state.usage?.weeklyFable)

                if let forecast = state.weeklyForecast {
                    ForecastRow(forecast: forecast)
                }
                if let extra = state.usage?.extra, extra.isEnabled {
                    ExtraUsageRow(extra: extra)
                }
            }

            HStack(spacing: 8) {
                Text(updatedText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                IconButton(systemName: "arrow.clockwise", help: "今すぐ更新") { actions.refresh() }
                IconButton(systemName: "bubbles.and.sparkles.fill", help: "浮遊モード（バブル）") { actions.toBubble() }
                IconButton(systemName: "gearshape.fill", help: "設定") { actions.settings() }
                IconButton(systemName: "power", help: "終了") { actions.quit() }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .frame(width: 240)
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
    let forecast: WeeklyForecast

    var body: some View {
        HStack(spacing: 5) {
            switch forecast {
            case .safe:
                Image(systemName: "checkmark.circle")
                Text("このペースならリセットまで持ちそうです")
            case .willHit(let date):
                Image(systemName: "exclamationmark.triangle.fill")
                Text("このペースだと \(Self.format(date)) 頃に週間上限")
            }
        }
        .font(.caption2)
        .foregroundStyle(color)
    }

    private var color: Color {
        if case .willHit = forecast { return .orange }
        return .secondary
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
        return .claudeOrange
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().stroke(.quaternary, lineWidth: 4)
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
                    ClaudeLogoView(animating: state.isActive, color: .claudeOrange)
                        .frame(width: 14, height: 14)
                    Text(percentText)
                        .font(.system(size: 11.5, weight: .bold))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .animation(.snappy(duration: 0.4), value: percentText)
                    if let metricCaption {
                        Text(metricCaption)
                            .font(.system(size: 6.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .rotationEffect(.degrees(sin(t * 0.9) * 3))

                // シャボン玉のハイライト
                Ellipse()
                    .fill(.white.opacity(0.35))
                    .frame(width: 18, height: 9)
                    .rotationEffect(.degrees(-32))
                    .offset(x: -15, y: -19)
                    .blur(radius: 1)
            }
            .padding(7)
        }
        .frame(width: 76, height: 76)
        .overlay(IridescentRim(shape: Circle()))
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
        .help("クリックで展開・ドラッグで移動・メニューバーへ持っていくと戻る")
    }
}

// MARK: - 割れる演出（衝撃波 + 飛沫）

struct PopBurstView: View {
    @State private var expand = false

    // 不揃いな飛沫（角度オフセット・距離・サイズを決め打ちで散らす）
    private static let droplets: [(angle: Double, distance: CGFloat, size: CGFloat, opacity: Double)] = {
        let count = 14
        var result: [(Double, CGFloat, CGFloat, Double)] = []
        let distances: [CGFloat] = [88, 62, 76, 54, 92, 68, 80, 58, 86, 64, 74, 96, 60, 82]
        let sizes: [CGFloat] = [8, 5, 6, 4, 9, 5, 7, 4, 6, 5, 8, 4, 6, 5]
        let jitters: [Double] = [0.1, -0.15, 0.05, 0.2, -0.08, 0.12, -0.2, 0.07, -0.05, 0.18, -0.12, 0.03, 0.15, -0.1]
        for i in 0..<count {
            let angle = Double(i) / Double(count) * 2 * .pi + jitters[i]
            result.append((angle, distances[i], sizes[i], i.isMultiple(of: 3) ? 0.9 : 0.6))
        }
        return result
    }()

    var body: some View {
        ZStack {
            // 衝撃波リング
            Circle()
                .stroke(.white.opacity(expand ? 0 : 0.55), lineWidth: 2.5)
                .frame(width: 64, height: 64)
                .scaleEffect(expand ? 2.8 : 0.9)

            ForEach(Array(Self.droplets.enumerated()), id: \.offset) { _, d in
                Circle()
                    .fill(Color.claudeOrange.opacity(d.opacity))
                    .frame(width: d.size, height: d.size)
                    .offset(
                        x: expand ? cos(d.angle) * d.distance : 0,
                        y: expand ? sin(d.angle) * d.distance : 0
                    )
                    .opacity(expand ? 0 : 1)
                    .scaleEffect(expand ? 0.3 : 1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.65)) { expand = true }
        }
    }
}
