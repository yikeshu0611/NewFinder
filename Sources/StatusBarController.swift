import AppKit

/// Menu-bar (status item) entry when NewFinder stays out of the Dock / system menu bar.
final class StatusBarController: NSObject, NSMenuDelegate {
    static let shared = StatusBarController()

    private var statusItem: NSStatusItem?
    private var statusMenu = NSMenu()
    private weak var zoomMenuItem: NSMenuItem?
    private var helpers: [AnyObject] = []

    func install() {
        // 用户要求：顶部右上角不再展示 NF 图标。
        // 之前这里会创建一个 NSStatusItem（文件夹图标），现在改为不创建；
        // 如果之前已经创建过（比如热更新），顺手移除掉。
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
        return
    }

    func refreshZoomTitle(_ percent: Int? = nil) {
        let value = percent ?? AppSettings.shared.uiZoomPercent
        zoomMenuItem?.title = "缩放（\(value)%）"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }

    @objc private func statusItemClicked(_ sender: Any?) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true {
            guard let button = statusItem?.button else { return }
            // Attach menu only for this popup so left-click stays a direct show.
            statusItem?.menu = statusMenu
            statusMenu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 2), in: button)
            statusItem?.menu = nil
            return
        }
        AppDelegate.shared.userRequestedShowUI()
    }

    private func rebuildMenu(_ menu: NSMenu) {
        helpers = AppDelegate.shared.populateChromeMenu(menu, includeQuit: true)
        // Keep a weak handle to the zoom title for live updates while the menu is open.
        zoomMenuItem = menu.items.first { $0.title.hasPrefix("缩放") }
    }
}
