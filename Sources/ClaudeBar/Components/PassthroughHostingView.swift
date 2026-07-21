import AppKit
import SwiftUI

/// 自分自身への클リックを無視するコンテナ（バブルウィンドウの透明マージン用）
final class PassthroughContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
    }
}

/// クリックを下のビュー（NSStatusBarButtonなど）へ通すNSHostingView
final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    required init(rootView: Content) {
        super.init(rootView: rootView)
    }

    @MainActor @preconcurrency required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
