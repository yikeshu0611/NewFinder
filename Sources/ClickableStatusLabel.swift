import AppKit

/// The single font used by every label in the bottom status bar, so the
/// item count, the load time, the system usage readout and the version number
/// all render with the same typeface.
enum StatusBarFont {
    static let size: CGFloat = 11
    /// Digits are monospaced so a changing readout does not shift the layout,
    /// while the rest of the text keeps the regular system typeface.
    static var standard: NSFont { .monospacedDigitSystemFont(ofSize: size, weight: .regular) }
}

/// A read-only text field that behaves like a link: clickable, with a pointing
/// hand cursor and a subtle highlight while the pointer is over it.
final class ClickableStatusLabel: NSTextField {
    /// Invoked when the user clicks the label.
    var onClick: (() -> Void)?
    /// Text color used when the pointer is not over the label.
    var idleColor: NSColor = .secondaryLabelColor

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    /// Convenience initializer producing a label with the given text.
    convenience init(text: String) {
        self.init(frame: .zero)
        stringValue = text
    }

    private func commonInit() {
        isEditable = false
        isSelectable = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
            self.trackingArea = nil
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        textColor = .labelColor
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        textColor = idleColor
        NSCursor.arrow.set()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            textColor = idleColor
        }
    }
}
