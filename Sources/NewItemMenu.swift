import AppKit

/// Builds the「新建」submenu that is shared by the list view and the column
/// view context menus.
///
/// The listed types come from the user's settings (Settings → 新建类型), so the
/// menu always mirrors what the toolbar's New button offers.
enum NewItemMenu {
    /// Identifiers for the two separators that frame the archive section of the
    /// list-view context menu. Referencing them by identifier keeps the menu
    /// robust when items are inserted or removed.
    static let archiveLeadingSeparatorID = NSUserInterfaceItemIdentifier("nf.menu.archive.leading")
    static let archiveTrailingSeparatorID = NSUserInterfaceItemIdentifier("nf.menu.archive.trailing")

    /// Builds the submenu listing every enabled New type.
    ///
    /// - Parameters:
    ///   - action: selector fired when a type is picked.
    ///   - target: receiver of `action`.
    ///   - tag: value stored in the menu item's `tag` (used by the column view
    ///     to remember which column the menu belongs to).
    /// - Returns: a submenu whose items carry the raw type in `representedObject`
    ///   (`"dir"` means a folder).
    static func makeSubmenu(action: Selector, target: AnyObject, tag: Int = 0) -> NSMenu {
        let submenu = NSMenu()
        submenu.autoenablesItems = false

        let types = AppSettings.shared.newItemTypes
        let fixedCount = AppSettings.shared.enabledFixedNewItemTypes.count
        for (index, type) in types.enumerated() {
            let item = NSMenuItem(
                title: AppSettings.displayName(forNewItemType: type),
                action: action,
                keyEquivalent: ""
            )
            item.target = target
            item.tag = tag
            item.isEnabled = true
            item.representedObject = type
            submenu.addItem(item)

            // A separator between the built-in types and the user's own ones.
            if fixedCount > 0, index == fixedCount - 1, fixedCount < types.count {
                submenu.addItem(.separator())
            }
        }
        return submenu
    }

    /// The extension to create for a picked type (`nil` means a folder).
    static func extensionName(forType type: String) -> String? {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.lowercased() == "dir" ? nil : trimmed
    }
}
