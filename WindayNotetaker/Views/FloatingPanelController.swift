import AppKit
import SwiftUI

/// Manages a single floating panel that hosts the recorder popup, pinned to the
/// top-center of the main screen and visible above full-screen apps. The panel
/// auto-sizes to its SwiftUI content (so collapsing shrinks the window).
@MainActor
final class FloatingPanelController {
    private var panel: FloatingPanel?

    /// Build the panel once with the popup view (environment objects injected).
    func configure(_ rootView: some View) {
        let hosting = NSHostingController(rootView: rootView)
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80))
        panel.contentViewController = hosting   // window follows SwiftUI size
        self.panel = panel
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        guard let panel else { return }
        panel.layoutIfNeeded()
        reposition()
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let x = visible.midX - size.width / 2
        let y = visible.maxY - size.height - 8   // just below the menu bar
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

/// A borderless, non-activating, always-on-top panel that can still take key
/// focus (so the sign-in fields work).
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false   // the SwiftUI card draws its own shadow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
