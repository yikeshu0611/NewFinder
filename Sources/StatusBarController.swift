import AppKit

/// Menu-bar (status item) entry when NewFinder stays out of the Dock / system menu bar.
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private weak var zoomMenuItem: NSMenuItem?
    private var helpers: [AnyObject] = []

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: "NewFinder")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "NewFinder"
        }

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
        rebuildMenu(menu)
    }

    func refreshZoomTitle(_ percent: Int? = nil) {
        let value = percent ?? AppSettings.shared.uiZoomPercent
        zoomMenuItem?.title = "缩放（\(value)%）"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    private func rebuildMenu(_ menu: NSMenu) {
        helpers = AppDelegate.shared.populateChromeMenu(menu, includeQuit: true)
        // Keep a weak handle to the zoom title for live updates while the menu is open.
        zoomMenuItem = menu.items.first { $0.title.hasPrefix("缩放") }
    }
}
