import Foundation

extension Notification.Name {
    static let compareWorkspacesDidChange = Notification.Name("NewFinder.compareWorkspacesDidChange")
}

final class CompareDocument {
    let id = UUID()
    var url: URL
    var text: String
    var isDirty = false

    var title: String {
        let name = url.lastPathComponent
        return isDirty ? "• \(name)" : name
    }

    init(url: URL, text: String) {
        self.url = url.standardizedFileURL
        self.text = text
    }
}

struct CompareWorkspace {
    var documents: [CompareDocument] = []
    /// Visible panes in left-to-right order; each pane shows one document.
    var paneDocIDs: [UUID] = []

    func document(id: UUID) -> CompareDocument? {
        documents.first { $0.id == id }
    }

    func summaryTitle(index: Int) -> String {
        let names = paneDocIDs.compactMap { id in documents.first { $0.id == id }?.url.lastPathComponent }
        if names.isEmpty { return "比对\(index)" }
        if names.count == 1 { return "比对\(index)：\(names[0])" }
        if names.count == 2 { return "比对\(index)：\(names[0]) ↔ \(names[1])" }
        return "比对\(index)：\(names[0]) ↔ \(names[1]) +\(names.count - 2)"
    }

    /// Open file and put it in its own pane (appended). Returns document id.
    @discardableResult
    mutating func openFile(_ url: URL) -> UUID? {
        let standardized = url.standardizedFileURL
        if let existing = documents.first(where: { $0.url == standardized }) {
            if !paneDocIDs.contains(existing.id) {
                paneDocIDs.append(existing.id)
            }
            return existing.id
        }
        let text: String
        switch TextDiffEngine.loadText(from: standardized) {
        case .success(let loaded): text = loaded
        case .failure: text = "（无法读取文件）"
        }
        let doc = CompareDocument(url: standardized, text: text)
        documents.append(doc)
        paneDocIDs.append(doc.id)
        return doc.id
    }

    mutating func movePane(documentID id: UUID, toIndex target: Int) {
        guard let from = paneDocIDs.firstIndex(of: id) else { return }
        var dest = min(max(0, target), paneDocIDs.count - 1)
        guard from != dest else { return }
        paneDocIDs.remove(at: from)
        if from < dest { dest -= 1 }
        paneDocIDs.insert(id, at: min(dest, paneDocIDs.count))
    }

    /// Drop document onto another pane: swap their positions.
    mutating func swapPanes(documentID id: UUID, withPaneAt index: Int) {
        guard let from = paneDocIDs.firstIndex(of: id),
              paneDocIDs.indices.contains(index),
              from != index else { return }
        paneDocIDs.swapAt(from, index)
    }

    mutating func closeDocument(_ id: UUID) {
        documents.removeAll { $0.id == id }
        paneDocIDs.removeAll { $0 == id }
    }

    mutating func clearAll() {
        documents.removeAll()
        paneDocIDs.removeAll()
    }
}

/// Ten independent compare workspaces (比对1…比对10).
final class CompareSession {
    static let shared = CompareSession()
    static let workspaceCount = 10

    private(set) var workspaces: [CompareWorkspace] = Array(
        repeating: CompareWorkspace(),
        count: workspaceCount
    )

    private init() {}

    func workspace(at index: Int) -> CompareWorkspace? {
        guard index >= 1, index <= Self.workspaceCount else { return nil }
        return workspaces[index - 1]
    }

    /// Open any number of files; each file gets its own panel.
    @discardableResult
    func open(_ urls: [URL], inWorkspace index: Int) -> Int {
        guard index >= 1, index <= Self.workspaceCount else { return index }
        var seen = Set<URL>()
        let unique = urls.map(\.standardizedFileURL).filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { return index }

        for url in unique {
            _ = workspaces[index - 1].openFile(url)
        }
        notify(index)
        return index
    }

    @discardableResult
    func open(_ url: URL, inWorkspace index: Int) -> Int {
        open([url], inWorkspace: index)
    }

    func updateText(workspace index: Int, documentID: UUID, text: String) {
        guard index >= 1, index <= Self.workspaceCount,
              let i = workspaces[index - 1].documents.firstIndex(where: { $0.id == documentID }) else { return }
        let doc = workspaces[index - 1].documents[i]
        guard doc.text != text else { return }
        workspaces[index - 1].documents[i].text = text
        workspaces[index - 1].documents[i].isDirty = true
    }

    func markSaved(workspace index: Int, documentID: UUID) {
        guard index >= 1, index <= Self.workspaceCount,
              let i = workspaces[index - 1].documents.firstIndex(where: { $0.id == documentID }) else { return }
        workspaces[index - 1].documents[i].isDirty = false
        notify(index)
    }

    func touchWorkspace(_ index: Int) {
        notify(index)
    }

    func swapPanes(workspace index: Int, documentID: UUID, withPaneAt paneIndex: Int) {
        guard index >= 1, index <= Self.workspaceCount else { return }
        workspaces[index - 1].swapPanes(documentID: documentID, withPaneAt: paneIndex)
        notify(index)
    }

    func closeDocument(workspace index: Int, documentID: UUID) {
        guard index >= 1, index <= Self.workspaceCount else { return }
        workspaces[index - 1].closeDocument(documentID)
        notify(index)
    }

    func clearWorkspace(_ index: Int) {
        guard index >= 1, index <= Self.workspaceCount else { return }
        workspaces[index - 1].clearAll()
        notify(index)
    }

    func menuTitle(forWorkspace index: Int) -> String {
        guard let ws = workspace(at: index) else { return "比对\(index)" }
        let title = ws.summaryTitle(index: index)
        if title == "比对\(index)" { return title }
        if let range = title.range(of: "：") {
            return "比对\(index)（\(title[range.upperBound...])）"
        }
        return title
    }

    private func notify(_ index: Int) {
        NotificationCenter.default.post(
            name: .compareWorkspacesDidChange,
            object: self,
            userInfo: ["workspace": index]
        )
    }
}

enum CompareFileSupport {
    static let codeExtensions: Set<String> = [
        "swift", "py", "js", "ts", "jsx", "tsx", "java", "c", "cpp", "cc", "cxx",
        "h", "hpp", "m", "mm", "cs", "go", "rs", "rb", "php", "html", "htm",
        "css", "scss", "less", "json", "xml", "yml", "yaml", "md", "txt",
        "r", "sql", "sh", "zsh", "bash", "plist", "toml", "ini", "cfg",
        "kt", "kts", "scala", "groovy", "lua", "pl", "pm", "vue", "svelte"
    ]

    static func isComparable(_ url: URL, isDirectory: Bool) -> Bool {
        guard !isDirectory else { return false }
        let ext = url.pathExtension.lowercased()
        return codeExtensions.contains(ext)
    }
}
