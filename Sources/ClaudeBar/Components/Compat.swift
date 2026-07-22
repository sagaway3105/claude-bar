import AppKit
import SwiftUI

// macOS 14互換シム。15+の専用APIを使う箇所はここを経由する。
// （glassEffectの26分岐は PanelViews の AdaptivePanelGlass / AdaptiveBubbleGlass 参照）

/// サイズ監視: 15+は onGeometryChange、14は GeometryReader + PreferenceKey
struct SizeReader: ViewModifier {
    var onChange: (CGSize) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
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
        if #available(macOS 15.0, *) {
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
