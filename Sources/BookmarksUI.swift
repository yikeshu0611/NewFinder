import AppKit

/// Folder chip or direct bookmark link on the top favorites bar (Chrome-style).
final class BookmarkFolderButton: NSButton {
    var folderName: String = ""
    var bookmarkID: UUID?
    var bookmarkPath: String = ""
    var onClick: (() -> Void)?
    var onRightClick: (() -> Void)?
    var onOrderChanged: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bezelStyle = .inline
        isBordered = false
        font = .systemFont(ofSize: 13)
        contentTintColor = .labelColor
        translatesAutoresizingMaskIntoConstraints = false
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyNormalTitleColor()
    }

    override var title: String {
        get { super.title }
        set {
            super.title = newValue
            applyNormalTitleColor()
        }
    }

    private func applyNormalTitleColor() {
        contentTintColor = .labelColor
        let text = attributedTitle.string.isEmpty ? title : attributedTitle.string
        guard !text.isEmpty else { return }
        attributedTitle = NSAttributedString(string: text, attributes: [
            .font: font ?? .systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let startScreen = NSEvent.mouseLocation
        var dragging = false
        var pushedCursor = false

        while true {
            guard let next = NSApp.nextEvent(
                matching: [.leftMouseDragged, .leftMouseUp],
                until: .distantFuture,
                inMode: .eventTracking,
                dequeue: true
            ) else { break }

            let mouse = NSEvent.mouseLocation

            if next.type == .leftMouseUp {
                if dragging {
                    if pushedCursor { NSCursor.pop() }
                    alphaValue = 1
                    onOrderChanged?()
                } else if isMouseInside(screenPoint: mouse) {
                    onClick?()
                }
                break
            }

            let distance = hypot(mouse.x - startScreen.x, mouse.y - startScreen.y)
            if !dragging {
                guard distance > 4 else { continue }
                dragging = true
                alphaValue = 0.65
                NSCursor.closedHand.push()
                pushedCursor = true
            }

            guard let stack = superview as? NSStackView,
                  let stackWindow = stack.window else { continue }
            let pointInWindow = stackWindow.convertPoint(fromScreen: mouse)
            let location = stack.convert(pointInWindow, from: nil)
            let target = targetIndex(for: location.x, in: stack)
            guard let currentIndex = stack.arrangedSubviews.firstIndex(of: self),
                  target != currentIndex else { continue }
            stack.insertArrangedSubview(self, at: target)
            stack.layoutSubtreeIfNeeded()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }

    private func isMouseInside(screenPoint: NSPoint) -> Bool {
        guard let window else { return false }
        let pointInWindow = window.convertPoint(fromScreen: screenPoint)
        let pointInView = convert(pointInWindow, from: nil)
        return bounds.insetBy(dx: -2, dy: -2).contains(pointInView)
    }

    private func targetIndex(for locationX: CGFloat, in stack: NSStackView) -> Int {
        let views = stack.arrangedSubviews
        guard !views.isEmpty else { return 0 }
        var best = 0
        var bestDist = CGFloat.greatestFiniteMagnitude
        for (index, view) in views.enumerated() {
            let dist = abs(locationX - view.frame.midX)
            if dist < bestDist {
                bestDist = dist
                best = index
            }
        }
        return best
    }
}

/// Simple menu row for custom NSMenuItem views (e.g. New menu). Click opens.
final class BookmarkMenuRowView: NSView {
    var onOpen: (() -> Void)?
    var onEdit: (() -> Void)?

    private let label: NSTextField
    private var trackingAreaRef: NSTrackingArea?

    init(title: String, path: String, font: NSFont, width: CGFloat, bookmarkID: UUID? = nil) {
        self.label = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        toolTip = path
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor

        label.font = font
        label.textColor = .labelColor
        label.alignment = .left
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isEditable = false
        label.isSelectable = false
        label.refusesFirstResponder = true
        label.isEnabled = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 26),
            widthAnchor.constraint(equalToConstant: width)
        ])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        trackingAreaRef = area
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        label.textColor = .white
    }

    override func mouseExited(with event: NSEvent) {
        layer?.backgroundColor = NSColor.clear.cgColor
        label.textColor = .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        // Defer open to mouseUp so the same down doesn't select while the menu is still settling.
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard bounds.contains(point) else { return }
        onOpen?()
    }

    override func rightMouseDown(with event: NSEvent) {
        onEdit?()
    }
}
