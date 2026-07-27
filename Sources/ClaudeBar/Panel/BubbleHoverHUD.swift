import AppKit
import SwiftUI

// MARK: - バブルのホバーHUD（マウスオーバーで全メトリクスを一覧表示）

/// 表示制御。バブルの横に出るクリック透過の小窓で、
/// 出し入れは trackMouse（ホバー検知）とバブルのマウス操作から呼ばれる。
extension PanelController {

    /// ホバーが少し続いたらHUDを出す（かすめただけ・ポヨンだけでは出さない）
    func scheduleHoverHUD() {
        guard hoverHUDWindow == nil else { return }
        hoverHUDShowTask?.cancel()
        hoverHUDShowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.45))
            guard let self, !Task.isCancelled else { return }
            // 発火時点でまだバブルの上にいる時だけ表示
            guard let frame = self.bubbleScreenFrame?.insetBy(dx: -6, dy: -6),
                  frame.contains(NSEvent.mouseLocation) else { return }
            self.showHoverHUD()
        }
    }

    func showHoverHUD() {
        guard state.bubbleActive, !isPopping, !dragActive, hoverHUDWindow == nil,
              let bubbleFrame = bubbleScreenFrame else { return }
        let hosting = NSHostingView(
            rootView: BubbleHoverHUDView(state: state, settings: settings)
        )
        let size = hosting.fittingSize
        guard size.width > 10, size.height > 10 else { return }

        // バブルの右横・縦中央（バブルは漂うが、HUDは出た位置に固定して読みやすさ優先）。
        // 右に入らなければ左横へ。最後に画面内へクランプ
        let gap: CGFloat = 12
        var origin = NSPoint(x: bubbleFrame.maxX + gap, y: bubbleFrame.midY - size.height / 2)
        if let vf = (bubblePanel?.screen ?? NSScreen.main)?.visibleFrame {
            if origin.x + size.width > vf.maxX - 8 {
                origin.x = bubbleFrame.minX - gap - size.width
            }
            origin.x = max(origin.x, vf.minX + 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }

        let w = NSWindow(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true // クリック透過: ポヨン/破裂/ドラッグと干渉しない
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        w.contentView = hosting
        w.alphaValue = 0
        w.orderFrontRegardless()
        hoverHUDWindow = w
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
        }
    }

    func hideHoverHUD() {
        hoverHUDShowTask?.cancel()
        hoverHUDShowTask = nil
        guard let w = hoverHUDWindow else { return }
        hoverHUDWindow = nil
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            w.animator().alphaValue = 0
        }
        // フェード後に片付ける（この間に再表示されても新しいウィンドウなので競合しない）
        Task { [weak w] in
            try? await Task.sleep(for: .seconds(0.15))
            w?.orderOut(nil)
        }
    }
}

/// バブルにマウスを載せた時に出る使用量一覧（読み取り専用・クリック透過）。
/// パネルと同じ書式（メトリクス名 / ↺リセット時刻 / %）を1行ずつコンパクトに並べる
struct BubbleHoverHUDView: View {
    var state: AppState
    var settings: SettingsStore

    private var baseTint: Color {
        settings.useSystemAccent ? Color(nsColor: .controlAccentColor) : .claudeOrange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("現在のセッション", state.usage?.session, current: settings.bubbleMetric == .session)
            row("週間 すべてのモデル", state.usage?.weeklyAll, current: settings.bubbleMetric == .weekly)
            row("週間 \(state.fableLabel)", state.usage?.weeklyFable, current: settings.bubbleMetric == .fable)
            if let extra = state.usage?.extra, extra.isEnabled {
                HStack(spacing: 6) {
                    Circle().fill(Color.clear).frame(width: 4, height: 4)
                    ExtraUsageRow(extra: extra)
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .fixedSize()
        .modifier(AdaptiveHUDGlass())
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private func row(_ title: String, _ window: UsageWindow?, current: Bool) -> some View {
        HStack(spacing: 6) {
            // バブルが表示中のメトリクスに印
            Circle()
                .fill(current ? baseTint : Color.clear)
                .frame(width: 4, height: 4)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(current ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Spacer(minLength: 14)
            if let resets = window?.resetsAt {
                Text("↺ \(UsageGaugeView.resetText(resets))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Text(window.map { "\(Int($0.utilization.rounded()))%" } ?? "–%")
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(valueStyle(window))
                .frame(minWidth: 32, alignment: .trailing)
        }
    }

    /// %の色はパネルのゲージと同じ段階（80%橙・95%赤）
    private func valueStyle(_ window: UsageWindow?) -> AnyShapeStyle {
        guard let v = window?.utilization else { return AnyShapeStyle(.secondary) }
        if v >= 95 { return AnyShapeStyle(Color.red) }
        if v >= 80 { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(.primary)
    }
}

/// HUDのガラス: AdaptivePanelGlassの小型版（角丸12）。
/// 26はLiquid Glass、旧OSはultraThinMaterial+ティント
struct AdaptiveHUDGlass: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let tint = Color(nsColor: .windowBackgroundColor).opacity(scheme == .dark ? 0 : 0.45)
        if #available(macOS 26.0, *), !forceLegacyUI {
            content.glassEffect(.regular.tint(tint), in: RoundedRectangle(cornerRadius: 12))
        } else {
            content.background(
                ZStack {
                    RoundedRectangle(cornerRadius: 12).fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 12).fill(tint)
                }
            )
        }
    }
}
