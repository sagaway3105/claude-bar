import AppKit
import SwiftUI

/// 自分自身へのクリックを無視するコンテナ（バブルウィンドウの透明マージン用）。
/// パネルモードでは、NSGlassEffectView内部のAuto Layoutがautoresizingとズレて
/// ガラスが縮む問題があるため、レイアウトパスごとに子をboundsへピン留めする。
final class PassthroughContainerView: NSView {
    /// バブルモード中はfalse（assembly/glassのフレームはコントローラが手動管理）
    var pinsChildrenToBounds = true

    override func layout() {
        super.layout()
        guard pinsChildrenToBounds else { return }
        for subview in subviews where subview.frame != bounds {
            subview.frame = bounds
        }
        for subview in subviews {
            for inner in subview.subviews where inner.frame != subview.bounds {
                inner.frame = subview.bounds
            }
        }
    }

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
