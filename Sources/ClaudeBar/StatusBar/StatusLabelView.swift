import SwiftUI

/// メニューバーに表示される「42% ✳」ラベル
struct StatusLabelView: View {
    var state: AppState
    var onWidthChange: (CGFloat) -> Void = { _ in }

    private var tint: Color? {
        guard let u = state.sessionUtilization else { return nil }
        if u >= 95 { return .red }
        if u >= 80 { return .orange }
        return nil
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(state.sessionPercentText)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.4), value: state.sessionPercentText)
            // 消費中（回転中）はClaudeオレンジ
            ClaudeLogoView(
                animating: state.isActive,
                color: state.isActive ? .claudeOrange : (tint ?? .primary)
            )
            .frame(width: 14, height: 14)
        }
        .foregroundStyle(tint ?? .primary)
        .padding(.horizontal, 5)
        // Apple純正メニュー展開時と同じ、薄い半透明カプセルのハイライト
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.primary.opacity(state.menuHighlighted ? 0.14 : 0))
                .padding(.vertical, 2.5)
        )
        .fixedSize()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            onWidthChange(width)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
