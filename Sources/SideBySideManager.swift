import AppKit

/// Up to three browser windows placed side-by-side without resizing existing ones.
final class SideBySideManager {
    static let shared = SideBySideManager()
    static let maxWindows = 3

    private struct WeakWindow {
        weak var controller: BrowserWindowController?
    }

    private var groups: [UUID: [WeakWindow]] = [:]
    private var controllerToGroup: [ObjectIdentifier: UUID] = [:]

    private init() {}

    /// Place `newController` to the right of the group (same size as `source`). Returns false when full.
    @discardableResult
    func attachSideBySide(source: BrowserWindowController, new newController: BrowserWindowController) -> Bool {
        let sourceID = ObjectIdentifier(source)
        var groupID = controllerToGroup[sourceID]

        if groupID == nil {
            groupID = UUID()
            groups[groupID!] = [WeakWindow(controller: source)]
            controllerToGroup[sourceID] = groupID
        }

        guard let gid = groupID else { return false }
        var members = liveMembers(of: gid)

        if !members.contains(where: { $0 === source }) {
            members.append(source)
            controllerToGroup[sourceID] = gid
        }

        if members.contains(where: { $0 === newController }) {
            return true
        }

        guard members.count < Self.maxWindows else {
            NSSound.beep()
            return false
        }

        guard let sourceWindow = source.window, let newWindow = newController.window else { return false }

        members.append(newController)
        controllerToGroup[ObjectIdentifier(newController)] = gid
        groups[gid] = members.map { WeakWindow(controller: $0) }

        placeNewWindow(newWindow, beside: members.filter { $0 !== newController }, template: sourceWindow.frame)
        return true
    }

    func windowWillClose(_ controller: BrowserWindowController) {
        let oid = ObjectIdentifier(controller)
        guard let groupID = controllerToGroup.removeValue(forKey: oid) else { return }

        let members = liveMembers(of: groupID).filter { $0 !== controller }
        members.forEach { controllerToGroup[ObjectIdentifier($0)] = groupID }

        if members.count <= 1 {
            if let last = members.first {
                controllerToGroup.removeValue(forKey: ObjectIdentifier(last))
            }
            groups.removeValue(forKey: groupID)
            return
        }

        groups[groupID] = members.map { WeakWindow(controller: $0) }
    }

    private func liveMembers(of groupID: UUID) -> [BrowserWindowController] {
        let stored = groups[groupID]?.compactMap(\.controller) ?? []
        if !stored.isEmpty {
            return stored.sorted { lhs, rhs in
                (lhs.window?.frame.origin.x ?? 0) < (rhs.window?.frame.origin.x ?? 0)
            }
        }

        return controllerToGroup.compactMap { entry -> BrowserWindowController? in
            guard entry.value == groupID else { return nil }
            return AppDelegate.shared.browserWindowsForStatusBar().first { ObjectIdentifier($0) == entry.key }
        }
        .sorted { lhs, rhs in
            (lhs.window?.frame.origin.x ?? 0) < (rhs.window?.frame.origin.x ?? 0)
        }
    }

    /// Same width/height as the source window; origin just to the right of the rightmost sibling.
    private func placeNewWindow(_ newWindow: NSWindow, beside siblings: [BrowserWindowController], template: NSRect) {
        let anchor = siblings.compactMap(\.window).max(by: { $0.frame.maxX < $1.frame.maxX })

        var frame = template
        if let anchor {
            frame.origin.x = anchor.frame.maxX
            frame.origin.y = anchor.frame.origin.y
        }

        if let screen = anchor?.screen ?? newWindow.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            if frame.maxX > visible.maxX {
                frame.origin.x = visible.maxX - frame.width
            }
            frame.origin.x = max(frame.origin.x, visible.minX)
            frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        }

        let applyFrame = {
            if newWindow.isMiniaturized {
                newWindow.deminiaturize(nil)
            }
            newWindow.collectionBehavior.insert(.moveToActiveSpace)
            newWindow.setFrame(frame, display: true)
            newWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        applyFrame()
        // Re-apply after showWindow / layout so the frame is not overridden.
        DispatchQueue.main.async(execute: applyFrame)
    }
}
