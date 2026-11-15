import AppKit

/// The look of NewFinder, in one place.
///
/// The windows use the same colours, the same fonts and the same buttons as
/// the file browser, so they all look like they belong to the same app.
enum NFStyle {
    /// The colour of the chrome (the tab bar at the top of the browser).
    static func chromeColor(for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(calibratedWhite: 0.18, alpha: 1)
            : NSColor(calibratedWhite: 0.82, alpha: 1)
    }

    /// The colour of the window body.
    static func bodyColor(for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return dark
            ? NSColor(calibratedWhite: 0.14, alpha: 1)
            : NSColor(calibratedWhite: 0.96, alpha: 1)
    }

    /// The blue NF uses for its active items.
    static let accent = NSColor(calibratedRed: 0.18, green: 0.52, blue: 0.92, alpha: 1)

    /// The font of the status bar, with monospaced digits so a changing
    /// number does not make the line jump around.
    static func statusFont(size: CGFloat = 11, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedDigitSystemFont(ofSize: size, weight: weight)
    }

    /// A button that looks like the ones in NF's title bar: no border, no
    /// focus ring, and the text in the browser's grey.
    static func makeFlatButton(
        title: String,
        target: AnyObject,
        action: Selector,
        fontSize: CGFloat = 12
    ) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.focusRingType = .none
        button.font = .systemFont(ofSize: fontSize)
        button.contentTintColor = NSColor(calibratedWhite: 0.32, alpha: 1)
        button.setButtonType(.momentaryPushIn)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// A button that looks like the ones in NF's title bar, but with a
    /// symbol instead of a word.
    static func makeFlatIconButton(
        symbol: String,
        tip: String,
        target: AnyObject,
        action: Selector,
        pointSize: CGFloat = 12
    ) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .inline
        button.isBordered = false
        button.focusRingType = .none
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .regular)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(config)
        button.image?.isTemplate = true
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.setButtonType(.momentaryPushIn)
        button.target = target
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}
