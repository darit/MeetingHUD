import AppKit

/// A floating, non-activating, transparent panel used as the HUD overlay.
/// Sits above all windows and workspaces without stealing focus.
@MainActor
final class OverlayPanel: NSPanel {

    static func create() -> OverlayPanel {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 380),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )

        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false

        panel.minSize = NSSize(width: 600, height: 280)
        panel.maxSize = NSSize(width: 1600, height: 900)

        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
        ]

        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - panel.frame.width / 2
            let y = screenFrame.minY + 24
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        return panel
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Perform a live resize from a SwiftUI drag gesture.
    func resizeBy(dx: CGFloat, dy: CGFloat, edge: ResizeEdgeSwiftUI) {
        var f = frame
        switch edge {
        case .bottomRight:
            f.size.width += dx
            f.origin.y -= dy
            f.size.height += dy
        case .bottomLeft:
            f.origin.x += dx
            f.size.width -= dx
            f.origin.y -= dy
            f.size.height += dy
        case .topRight:
            f.size.width += dx
            f.size.height += dy
        case .topLeft:
            f.origin.x += dx
            f.size.width -= dx
            f.size.height += dy
        }
        f.size.width = max(minSize.width, min(maxSize.width, f.size.width))
        f.size.height = max(minSize.height, min(maxSize.height, f.size.height))
        setFrame(f, display: true)
    }

    enum ResizeEdgeSwiftUI {
        case bottomRight, bottomLeft, topRight, topLeft
    }
}

/// An AppKit view that handles resize dragging directly, bypassing
/// isMovableByWindowBackground. Embedded in the overlay via NSViewRepresentable.
class ResizeGripNSView: NSView {
    private var dragOrigin: NSPoint = .zero
    private var originalFrame: NSRect = .zero

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Draw 3 diagonal dots as resize indicator
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.25).cgColor)
        let dotSize: CGFloat = 2
        let offsets: [(CGFloat, CGFloat)] = [(12, 4), (8, 8), (4, 12), (12, 8), (8, 12), (12, 12)]
        for (x, y) in offsets {
            ctx.fillEllipse(in: CGRect(x: x, y: y, width: dotSize, height: dotSize))
        }
    }

    override func mouseDown(with event: NSEvent) {
        // Capture start state — do NOT call super (prevents window move)
        dragOrigin = NSEvent.mouseLocation
        originalFrame = window?.frame ?? .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let panel = window as? OverlayPanel else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - dragOrigin.x
        let dy = current.y - dragOrigin.y

        var f = originalFrame
        // Top-right resize: width grows right, height grows up
        f.size.width += dx
        f.size.height += dy

        f.size.width = max(panel.minSize.width, min(panel.maxSize.width, f.size.width))
        f.size.height = max(panel.minSize.height, min(panel.maxSize.height, f.size.height))
        panel.setFrame(f, display: true)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }
}

