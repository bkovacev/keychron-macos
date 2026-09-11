import AppKit

/// A row of buttons inside a menu, which does not dismiss the menu when
/// clicked.
///
/// A normal NSMenuItem closes the menu as soon as its action fires, so cycling
/// through backlight effects would mean reopening the menu for every step. A
/// menu item hosting a custom view keeps the menu up, because dismissal is
/// then the view's decision and this one never asks for it.
///
/// The drawing and hit-testing are done by hand rather than with NSButtons: a
/// menu runs its own event loop, and controls embedded in a menu item view do
/// not track the mouse reliably inside it.
final class ControlStripView: NSView {
    struct Segment {
        let symbol: String
        let title: String
        let enabled: Bool
        let perform: () -> Void
    }

    private let segments: [Segment]
    private var hovered: Int?

    private let rowHeight: CGFloat = 46
    private let inset: CGFloat = 10

    init(width: CGFloat, segments: [Segment]) {
        self.segments = segments
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowHeight))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private var segmentWidth: CGFloat {
        guard !segments.isEmpty else { return 0 }
        return (bounds.width - inset * 2) / CGFloat(segments.count)
    }

    private func rect(for index: Int) -> NSRect {
        NSRect(x: inset + CGFloat(index) * segmentWidth, y: 4,
               width: segmentWidth, height: bounds.height - 8)
    }

    private func index(at point: NSPoint) -> Int? {
        segments.indices.first { rect(for: $0).contains(point) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        for (index, segment) in segments.enumerated() {
            let box = rect(for: index)

            if hovered == index && segment.enabled {
                NSColor.selectedContentBackgroundColor.setFill()
                NSBezierPath(roundedRect: box.insetBy(dx: 2, dy: 0),
                             xRadius: 5, yRadius: 5).fill()
            }

            let tint: NSColor = !segment.enabled ? .tertiaryLabelColor
                              : hovered == index ? .white
                              : .labelColor

            let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            if let image = NSImage(systemSymbolName: segment.symbol,
                                   accessibilityDescription: segment.title)?
                            .withSymbolConfiguration(config) {
                image.isTemplate = true
                let tinted = NSImage(size: image.size, flipped: false) { rect in
                    image.draw(in: rect)
                    tint.set()
                    rect.fill(using: .sourceAtop)
                    return true
                }
                let origin = NSPoint(x: box.midX - image.size.width / 2,
                                     y: box.maxY - image.size.height - 4)
                tinted.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }

            let style = NSMutableParagraphStyle()
            style.alignment = .center
            let label = NSAttributedString(string: segment.title, attributes: [
                .font: NSFont.systemFont(ofSize: 10),
                .foregroundColor: tint,
                .paragraphStyle: style,
            ])
            label.draw(in: NSRect(x: box.minX, y: box.minY + 1,
                                  width: box.width, height: 13))
        }
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited],
            owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let new = index(at: point)
        if new != hovered { hovered = new; needsDisplay = true }
    }

    override func mouseExited(with event: NSEvent) {
        if hovered != nil { hovered = nil; needsDisplay = true }
    }

    /// Acts on mouse-up and, crucially, never calls cancelTracking, so the
    /// menu stays open for the next click.
    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = index(at: point), segments[index].enabled else { return }
        segments[index].perform()
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow it: the default would begin menu-item tracking and dismiss.
    }
}
