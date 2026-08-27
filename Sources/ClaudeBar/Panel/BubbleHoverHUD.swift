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
            // 発火時点でまだバブル（3つ表示は塊の外接）の上にいる時だけ表示
            guard let frame = self.bubbleHoverZone,
                  frame.contains(NSEvent.mouseLocation) else { return }
            self.showHoverHUD()
        }
    }

    func showHoverHUD() {
        guard state.bubbleActive, !isPopping, !dragActive, hoverHUDWindow == nil,
              let p = bubblePanel, let bubbleAssembly else { return }
        // 位置の基準は漂いの中心（モデル座標）。presentation（見た目の位置）を使うと
        // 表示した瞬間の漂いオフセットが焼き込まれ、タイミングによって上下にズレる。
        // 3つ表示はアセンブリ枠（ウィンドウ全体）ではなく見えている球の外接矩形を基準にする
        let bubbleFrame = p.convertToScreen(bubbleAssembly.frame)
        let anchor = settings.isTripleBubble
            ? (tripleClusterScreenBounds(in: p) ?? bubbleFrame)
            : bubbleFrame
        let hosting = NSHostingView(
            rootView: BubbleHoverHUDView(state: state, settings: settings)
        )
        let size = hosting.fittingSize
        guard size.width > 10, size.height > 10 else { return }

        // バブルの右横・縦中央。右に入らなければ左横へ。最後に画面内へクランプ
        let gap: CGFloat = 12
        var origin = NSPoint(x: anchor.maxX + gap, y: anchor.midY - size.height / 2)
        if let vf = (bubblePanel?.screen ?? NSScreen.main)?.visibleFrame {
            if origin.x + size.width > vf.maxX - 8 {
                origin.x = anchor.minX - gap - size.width
            }
            origin.x = max(origin.x, vf.minX + 8)
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        }

        // バブルと同じ構造: ウィンドウは固定で、内側のアセンブリだけが漂う
        // （浮遊振幅 x±8.5 / y±9.5pt を包める余白を持たせる）
        let margin: CGFloat = 12
        let w = NSWindow(
            contentRect: NSRect(x: origin.x - margin, y: origin.y - margin,
                                width: size.width + margin * 2, height: size.height + margin * 2),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        w.backgroundColor = .clear
        w.isOpaque = false
        w.hasShadow = false
        w.ignoresMouseEvents = true // クリック透過: ポヨン/破裂/ドラッグと干渉しない
        w.level = .floating
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false

        let container = NSView(frame: NSRect(origin: .zero, size: w.frame.size))
        container.wantsLayer = true
        let assembly = NSView(frame: NSRect(x: margin, y: margin, width: size.width, height: size.height))
        assembly.wantsLayer = true
        hosting.frame = assembly.bounds
        hosting.autoresizingMask = []
        assembly.addSubview(hosting)
        container.addSubview(assembly)
        w.contentView = container

        w.alphaValue = 0
        w.orderFrontRegardless()
        hoverHUDWindow = w
        syncHUDFloating(with: assembly)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            w.animator().alphaValue = 1
        }
    }

    /// 表示中に内容の幅が変わったら（起動直後の初回取得・ラベル変化）、実測し直して欠けを防ぐ。
    /// %のnumericText遷移（0.4秒）が終わってから測る。途中で測ると幅が数px足りない
    func refitHoverHUD() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            guard let self,
                  let w = self.hoverHUDWindow,
                  let assembly = w.contentView?.subviews.first,
                  let hosting = assembly.subviews.first else { return }
            let size = hosting.fittingSize
            guard size.width > 10, size.height > 10,
                  abs(size.width - assembly.frame.width) > 0.5
                    || abs(size.height - assembly.frame.height) > 0.5 else { return }
            let margin: CGFloat = 12
            var frame = w.frame
            let newSize = NSSize(width: size.width + margin * 2, height: size.height + margin * 2)
            frame.origin.y -= (newSize.height - frame.height) / 2 // 縦中央を保つ
            // バブルの左側に配置されている場合は左へ伸ばす（右へ伸ばすとバブルに食い込む）
            if let bubbleMidX = self.bubblePanel?.frame.midX, frame.midX < bubbleMidX {
                frame.origin.x -= newSize.width - frame.width
            }
            frame.size = newSize
            if let vf = w.screen?.visibleFrame {
                frame.origin.x = min(max(frame.origin.x, vf.minX), vf.maxX - frame.width)
                frame.origin.y = min(max(frame.origin.y, vf.minY), vf.maxY - frame.height)
            }
            w.setFrame(frame, display: true)
            assembly.frame = NSRect(x: margin, y: margin, width: size.width, height: size.height)
            hosting.frame = assembly.bounds
        }
    }

    /// バブルの浮遊アニメーションを同位相でHUDへコピーし、バブルと一緒に漂わせる。
    /// animation(forKey:)のコピーにはbeginTimeが解決済みで入っているため、
    /// そのまま追加するだけで位相が揃う（両レイヤーとも標準タイムスペース）
    private func syncHUDFloating(with view: NSView) {
        guard let bubbleLayer = bubbleAssembly?.layer, let layer = view.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in ["float-x1", "float-x2", "float-y1", "float-y2"] {
            guard let source = bubbleLayer.animation(forKey: key),
                  let copy = source.copy() as? CAAnimation else { continue }
            layer.add(copy, forKey: key)
        }
        CATransaction.commit()
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
            row(L("hud.currentSession"), state.usage?.session, current: settings.bubbleMetric == .session)
            row(L("hud.weeklyAllModels"), state.usage?.weeklyAll, current: settings.bubbleMetric == .weekly)
            row(L("hud.weeklyModel", state.fableLabel), state.usage?.weeklyFable, current: settings.bubbleMetric == .fable)
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
                .font(.system(size: 12, weight: .medium))
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
