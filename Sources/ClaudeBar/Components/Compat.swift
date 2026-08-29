import AppKit
import SwiftUI

// macOS 14互換シム。15+の専用APIを使う箇所はここを経由する。
// （glassEffectの26分岐は PanelViews の AdaptivePanelGlass / SingleBubbleGlass 参照。1つ表示と3つ表示で共通）

/// 旧OS分岐の検証用: CLAUDEBAR_FORCE_LEGACY=1 で全ての新API分岐を旧OS側に倒す
/// （新しいmacOS上ではフォールバックが実行されず目視確認できないため）。
/// デバッグビルドでは実行中にも切り替えられる（バブルの右クリックメニュー /
/// デバッグブリッジの `legacy`）。切り替え後はウィンドウを作り直すこと
#if DEBUG
nonisolated(unsafe) var forceLegacyUI = ProcessInfo.processInfo.environment["CLAUDEBAR_FORCE_LEGACY"] == "1"
#else
let forceLegacyUI = ProcessInfo.processInfo.environment["CLAUDEBAR_FORCE_LEGACY"] == "1"
#endif

/// 検証用の環境変数（パーセント指定）を読む共通ヘルパ。
/// **数値でない値が来ても落とさない**（開発者が手で打つものなので、
/// `Double(...)!` にすると `CLAUDEBAR_PLATE_D=70%` のような打ち間違いで即クラッシュする）
func envPercent(_ key: String, default fallback: Double, range: ClosedRange<Double> = 0...300) -> Double {
    guard let raw = ProcessInfo.processInfo.environment[key], let value = Double(raw) else {
        return fallback / 100
    }
    return min(max(value, range.lowerBound), range.upperBound) / 100
}

/// Liquid Glass（macOS 26）の経路を使っているか。
/// 旧OS（14/15）と `forceLegacyUI` のときは false。
/// **旧OSでは背景に応じた light/dark の自動反転が無い**ので、文字の可読性は
/// 自前で担保する必要がある（`BubbleStyle.haloGain` 参照）
@MainActor
var usesLiquidGlass: Bool {
    if #available(macOS 26.0, *), !forceLegacyUI { return true }
    return false
}

/// サイズ監視: 15+は onGeometryChange、14は GeometryReader + PreferenceKey
struct SizeReader: ViewModifier {
    var onChange: (CGSize) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *), !forceLegacyUI {
            content.onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                onChange(size)
            }
        } else {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: SizePreferenceKey.self, value: proxy.size)
                    }
                )
                .onPreferenceChange(SizePreferenceKey.self) { onChange($0) }
        }
    }
}

private struct SizePreferenceKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

extension View {
    /// ビューの実測サイズが変わるたびに通知する（macOS 14対応版 onGeometryChange）
    func measureSize(_ onChange: @escaping (CGSize) -> Void) -> some View {
        modifier(SizeReader(onChange: onChange))
    }
}

/// グリップのウィンドウドラッグ: 15+は WindowDragGesture、
/// 14は mouseDown で NSWindow.performDrag を呼ぶ透明ビュー
/// （SwiftUIのDragGestureは非アクティブ化パネルで不安定なため使わない）
struct GripDrag: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *), !forceLegacyUI {
            content.gesture(WindowDragGesture())
        } else {
            content.overlay(WindowDragHandle())
        }
    }
}

private struct WindowDragHandle: NSViewRepresentable {
    final class HandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> HandleView { HandleView() }
    func updateNSView(_ nsView: HandleView, context: Context) {}
}
