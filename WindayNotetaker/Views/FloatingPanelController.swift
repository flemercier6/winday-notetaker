import AppKit
import SwiftUI

/// Manages a floating panel that hosts a SwiftUI view, anchored to a screen
/// corner. The panel auto-sizes to its content. A `topCenter` panel with an
/// autosave name is draggable and remembers its position; a transient panel
/// (no autosave) is re-anchored on every show.
@MainActor
final class FloatingPanelController {
    enum Anchor { case topCenter, bottomTrailing }

    private var panel: FloatingPanel?
    private let anchor: Anchor
    private let autosaveName: String?
    private let movable: Bool
    private var didInitialPlacement = false

    init(anchor: Anchor, autosaveName: String? = nil, movable: Bool = true) {
        self.anchor = anchor
        self.autosaveName = autosaveName
        self.movable = movable
    }

    func configure(_ rootView: some View) {
        let hosting = NSHostingController(rootView: rootView)
        let panel = FloatingPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80), movable: movable)
        panel.contentViewController = hosting
        if let autosaveName { panel.setFrameAutosaveName(autosaveName) }
        self.panel = panel
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        guard let panel else { return }
        panel.layoutIfNeeded()
        if let autosaveName {
            // Sticky: place once (first launch), then respect user drags.
            if !didInitialPlacement {
                didInitialPlacement = true
                if UserDefaults.standard.object(forKey: "NSWindow Frame \(autosaveName)") == nil {
                    reposition()
                }
            }
        } else {
            reposition()   // transient: always re-anchor
        }
        panel.orderFrontRegardless()
    }

    func hide() { panel?.orderOut(nil) }

    private func reposition() {
        guard let panel, let screen = NSScreen.main else { return }
        let size = panel.frame.size
        let vf = screen.visibleFrame
        let origin: NSPoint
        switch anchor {
        case .topCenter:
            origin = NSPoint(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 8)
        case .bottomTrailing:
            origin = NSPoint(x: vf.maxX - size.width - 16, y: vf.minY + 16)
        }
        panel.setFrameOrigin(origin)
    }
}

/// A borderless, non-activating, always-on-top panel that can still take key
/// focus (so the sign-in fields work).
final class FloatingPanel: NSPanel {
    init(contentRect: NSRect, movable: Bool = true) {
        super.init(contentRect: contentRect,
                   styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = movable
        self.isMovable = movable
        standardWindowButton(.closeButton)?.isHidden = true
        standardWindowButton(.miniaturizeButton)?.isHidden = true
        standardWindowButton(.zoomButton)?.isHidden = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
