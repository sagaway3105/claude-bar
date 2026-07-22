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

    /// 内容の色は通常のまま（純正の展開ピルは淡いオーバーレイで、文字色は反転しない）
    private var contentColor: Color {
        tint ?? .primary
    }

    /// 純正メニューバーと同じフォント（サイズ・ウェイト・アクセシビリティ追従）
    private static let menuBarFont: Font =
        Font(NSFont.menuBarFont(ofSize: 0) as CTFont).monospacedDigit()

    var body: some View {
        HStack(spacing: 3) {
            Text(state.sessionPercentText)
                .font(Self.menuBarFont)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.4), value: state.sessionPercentText)
            // 消費中（回転中）はClaudeオレンジ
            ClaudeLogoView(
                animating: state.isActive,
                color: state.isActive ? .claudeOrange : contentColor
            )
            .frame(width: 15, height: 15)
        }
        .foregroundStyle(contentColor)
        // Tahoeはシステム側がNSStatusItemSelectionPaddingで外側余白を付与するため、
        // 自前の余白は控えめに（二重の余白でアイテムが間延びしない範囲でピルの内余白を確保）
        .padding(.horizontal, 6)
        // 縦をメニューバーいっぱいに広げてからピルを敷く（Apple純正のフルハイトピル）
        .frame(maxHeight: .infinity)
        .background(
            // 純正の展開ピル: 外観追従の淡い半透明オーバーレイ（拡大実測 約22%）。
            // Tahoeのボタンは16ptしかなく30ptのバーの中央に置かれるため、
            // 負のパディングでボタン枠を超えて純正サイズ(約24pt)まで拡張する
            Capsule()
                .fill(Color.primary.opacity(state.menuHighlighted ? 0.22 : 0))
                .padding(.vertical, -4)
        )
        .fixedSize(horizontal: true, vertical: false)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            onWidthChange(width)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
