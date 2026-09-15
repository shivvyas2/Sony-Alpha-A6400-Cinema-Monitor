import SwiftUI
import AppKit

/// Transparent view that reports scroll-wheel steps (+1 / -1) to SwiftUI.
struct ScrollWheelCatcher: NSViewRepresentable {
    var onStep: (Int) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.onStep = onStep
        return v
    }
    func updateNSView(_ nsView: CatcherView, context: Context) { nsView.onStep = onStep }

    final class CatcherView: NSView {
        var onStep: ((Int) -> Void)?
        private var accumulated: CGFloat = 0
        override var acceptsFirstResponder: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // let clicks pass through to SwiftUI
        override func scrollWheel(with event: NSEvent) {
            accumulated += event.scrollingDeltaY
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 12 : 1
            while accumulated >= threshold { accumulated -= threshold; onStep?(-1) }
            while accumulated <= -threshold { accumulated += threshold; onStep?(1) }
        }
    }
}

/// Wraps content so scroll events over it produce steps even though the catcher is not hit-testable.
struct ScrollStepper<Content: View>: View {
    var onStep: (Int) -> Void
    @ViewBuilder var content: Content
    var body: some View {
        content.background(ScrollWheelCatcherHost(onStep: onStep))
    }
}

private struct ScrollWheelCatcherHost: NSViewRepresentable {
    var onStep: (Int) -> Void
    func makeNSView(context: Context) -> HostView { let v = HostView(); v.onStep = onStep; return v }
    func updateNSView(_ nsView: HostView, context: Context) { nsView.onStep = onStep }

    final class HostView: NSView {
        var onStep: ((Int) -> Void)?
        private var accumulated: CGFloat = 0
        override func scrollWheel(with event: NSEvent) {
            accumulated += event.scrollingDeltaY
            let threshold: CGFloat = event.hasPreciseScrollingDeltas ? 14 : 1
            while accumulated >= threshold { accumulated -= threshold; onStep?(-1) }
            while accumulated <= -threshold { accumulated += threshold; onStep?(1) }
        }
    }
}
