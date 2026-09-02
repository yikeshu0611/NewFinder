import AppKit
import Foundation
import ObjectiveC

enum ArchiveDialogs {
    static func runCompressDialog(
        for urls: [URL],
        relativeTo directory: URL
    ) -> ArchiveCompressOptions? {
        let defaultName: String
        if urls.count == 1 {
            defaultName = urls[0].deletingPathExtension().lastPathComponent + ".zip"
        } else {
            defaultName = "Archive.zip"
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 340),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "压缩"
        panel.isFloatingPanel = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 340))
        panel.contentView = content

        let pathLabel = makeLabel("保存位置")
        let pathField = NSTextField(string: directory.path)
        pathField.isEditable = true
        let browseBtn = NSButton(title: "选择…", target: nil, action: nil)

        let nameLabel = makeLabel("文件名")
        let nameField = NSTextField(string: defaultName)

        let formatLabel = makeLabel("格式")
        let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        formatPopup.addItems(withTitles: ["ZIP（兼容最好）", "TAR.GZ（体积更小）"])

        let splitLabel = makeLabel("分卷")
        let splitPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        splitPopup.addItems(withTitles: [
            "不分卷", "1 MB", "10 MB", "100 MB", "650 MB (CD)", "700 MB", "4092 MB"
        ])

        let encryptCheck = NSButton(checkboxWithTitle: "加密（ZIP）", target: nil, action: nil)
        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = "密码"
        passwordField.isEnabled = false

        let deleteCheck = NSButton(checkboxWithTitle: "压缩后删除原文件", target: nil, action: nil)

        let cancelBtn = NSButton(title: "取消", target: nil, action: nil)
        let okBtn = NSButton(title: "压缩", target: nil, action: nil)
        okBtn.keyEquivalent = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"

        let views: [NSView] = [
            pathLabel, pathField, browseBtn, nameLabel, nameField,
            formatLabel, formatPopup, splitLabel, splitPopup,
            encryptCheck, passwordField, deleteCheck, cancelBtn, okBtn
        ]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            pathLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            pathLabel.widthAnchor.constraint(equalToConstant: 70),

            pathField.leadingAnchor.constraint(equalTo: pathLabel.trailingAnchor, constant: 8),
            pathField.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
            pathField.trailingAnchor.constraint(equalTo: browseBtn.leadingAnchor, constant: -8),

            browseBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            browseBtn.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
            browseBtn.widthAnchor.constraint(equalToConstant: 70),

            nameLabel.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 16),
            nameLabel.widthAnchor.constraint(equalToConstant: 70),
            nameField.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: browseBtn.trailingAnchor),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            formatLabel.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            formatLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 16),
            formatLabel.widthAnchor.constraint(equalToConstant: 70),
            formatPopup.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            formatPopup.centerYAnchor.constraint(equalTo: formatLabel.centerYAnchor),
            formatPopup.widthAnchor.constraint(equalToConstant: 200),

            splitLabel.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            splitLabel.topAnchor.constraint(equalTo: formatLabel.bottomAnchor, constant: 16),
            splitLabel.widthAnchor.constraint(equalToConstant: 70),
            splitPopup.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            splitPopup.centerYAnchor.constraint(equalTo: splitLabel.centerYAnchor),
            splitPopup.widthAnchor.constraint(equalToConstant: 200),

            encryptCheck.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            encryptCheck.topAnchor.constraint(equalTo: splitLabel.bottomAnchor, constant: 16),
            passwordField.leadingAnchor.constraint(equalTo: encryptCheck.trailingAnchor, constant: 12),
            passwordField.centerYAnchor.constraint(equalTo: encryptCheck.centerYAnchor),
            passwordField.trailingAnchor.constraint(equalTo: browseBtn.trailingAnchor),

            deleteCheck.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            deleteCheck.topAnchor.constraint(equalTo: encryptCheck.bottomAnchor, constant: 14),

            cancelBtn.trailingAnchor.constraint(equalTo: okBtn.leadingAnchor, constant: -12),
            cancelBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            okBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            okBtn.bottomAnchor.constraint(equalTo: cancelBtn.bottomAnchor)
        ])

        final class Handler: NSObject {
            var result: ArchiveCompressOptions?
            let panel: NSPanel
            let pathField: NSTextField
            let nameField: NSTextField
            let formatPopup: NSPopUpButton
            let splitPopup: NSPopUpButton
            let encryptCheck: NSButton
            let passwordField: NSSecureTextField
            let deleteCheck: NSButton

            init(
                panel: NSPanel,
                pathField: NSTextField,
                nameField: NSTextField,
                formatPopup: NSPopUpButton,
                splitPopup: NSPopUpButton,
                encryptCheck: NSButton,
                passwordField: NSSecureTextField,
                deleteCheck: NSButton
            ) {
                self.panel = panel
                self.pathField = pathField
                self.nameField = nameField
                self.formatPopup = formatPopup
                self.splitPopup = splitPopup
                self.encryptCheck = encryptCheck
                self.passwordField = passwordField
                self.deleteCheck = deleteCheck
            }

            @objc func browse() {
                let open = NSOpenPanel()
                open.canChooseFiles = false
                open.canChooseDirectories = true
                open.canCreateDirectories = true
                open.prompt = "选择"
                open.directoryURL = URL(fileURLWithPath: pathField.stringValue)
                if open.runModal() == .OK, let url = open.url {
                    pathField.stringValue = url.path
                }
            }

            @objc func toggleEncrypt() {
                passwordField.isEnabled = encryptCheck.state == .on
            }

            @objc func formatChanged() {
                let isZip = formatPopup.indexOfSelectedItem == 0
                splitPopup.isEnabled = isZip
                encryptCheck.isEnabled = isZip
                if !isZip {
                    encryptCheck.state = .off
                    passwordField.isEnabled = false
                    splitPopup.selectItem(at: 0)
                }
            }

            @objc func cancel() {
                result = nil
                NSApp.stopModal(withCode: .cancel)
                panel.orderOut(nil)
            }

            @objc func ok() {
                let format = formatPopup.indexOfSelectedItem == 0 ? "zip" : "tar.gz"
                let splits = ["none", "1m", "10m", "100m", "650m", "700m", "4092m"]
                let split = splits[max(0, min(splitPopup.indexOfSelectedItem, splits.count - 1))]
                let dir = URL(fileURLWithPath: pathField.stringValue).standardizedFileURL
                result = ArchiveCompressOptions(
                    directory: dir,
                    fileName: nameField.stringValue,
                    format: format,
                    split: split,
                    password: encryptCheck.state == .on ? passwordField.stringValue : "",
                    deleteSource: deleteCheck.state == .on
                )
                NSApp.stopModal(withCode: .OK)
                panel.orderOut(nil)
            }
        }

        let handler = Handler(
            panel: panel,
            pathField: pathField,
            nameField: nameField,
            formatPopup: formatPopup,
            splitPopup: splitPopup,
            encryptCheck: encryptCheck,
            passwordField: passwordField,
            deleteCheck: deleteCheck
        )
        browseBtn.target = handler
        browseBtn.action = #selector(Handler.browse)
        encryptCheck.target = handler
        encryptCheck.action = #selector(Handler.toggleEncrypt)
        formatPopup.target = handler
        formatPopup.action = #selector(Handler.formatChanged)
        cancelBtn.target = handler
        cancelBtn.action = #selector(Handler.cancel)
        okBtn.target = handler
        okBtn.action = #selector(Handler.ok)

        // Retain handler for modal session
        objc_setAssociatedObject(panel, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        let code = NSApp.runModal(for: panel)
        return code == .OK ? handler.result : nil
    }

    static func runExtractDialog(
        for archives: [URL],
        relativeTo directory: URL
    ) -> ArchiveExtractOptions? {
        let defaultFolder: String
        if archives.count == 1 {
            defaultFolder = ArchiveSupport.extractFolderName(for: archives[0])
        } else {
            defaultFolder = ""
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 260),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "解压"
        panel.isFloatingPanel = true

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 260))
        panel.contentView = content

        let pathLabel = makeLabel("解压到")
        let pathField = NSTextField(string: directory.path)
        let browseBtn = NSButton(title: "选择…", target: nil, action: nil)

        let nameLabel = makeLabel("文件夹名")
        let nameField = NSTextField(string: defaultFolder)
        nameField.placeholderString = "留空则直接解压到上方目录"

        let passwordLabel = makeLabel("密码")
        let passwordField = NSSecureTextField(string: "")
        passwordField.placeholderString = "如需要"

        let deleteCheck = NSButton(checkboxWithTitle: "解压后删除压缩包", target: nil, action: nil)

        let cancelBtn = NSButton(title: "取消", target: nil, action: nil)
        let okBtn = NSButton(title: "解压", target: nil, action: nil)
        okBtn.keyEquivalent = "\r"
        cancelBtn.keyEquivalent = "\u{1b}"

        [
            pathLabel, pathField, browseBtn, nameLabel, nameField,
            passwordLabel, passwordField, deleteCheck, cancelBtn, okBtn
        ].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview($0)
        }

        NSLayoutConstraint.activate([
            pathLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            pathLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            pathLabel.widthAnchor.constraint(equalToConstant: 70),
            pathField.leadingAnchor.constraint(equalTo: pathLabel.trailingAnchor, constant: 8),
            pathField.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
            pathField.trailingAnchor.constraint(equalTo: browseBtn.leadingAnchor, constant: -8),
            browseBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            browseBtn.centerYAnchor.constraint(equalTo: pathLabel.centerYAnchor),
            browseBtn.widthAnchor.constraint(equalToConstant: 70),

            nameLabel.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            nameLabel.topAnchor.constraint(equalTo: pathLabel.bottomAnchor, constant: 16),
            nameLabel.widthAnchor.constraint(equalToConstant: 70),
            nameField.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: browseBtn.trailingAnchor),
            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),

            passwordLabel.leadingAnchor.constraint(equalTo: pathLabel.leadingAnchor),
            passwordLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 16),
            passwordLabel.widthAnchor.constraint(equalToConstant: 70),
            passwordField.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            passwordField.trailingAnchor.constraint(equalTo: browseBtn.trailingAnchor),
            passwordField.centerYAnchor.constraint(equalTo: passwordLabel.centerYAnchor),

            deleteCheck.leadingAnchor.constraint(equalTo: pathField.leadingAnchor),
            deleteCheck.topAnchor.constraint(equalTo: passwordLabel.bottomAnchor, constant: 16),

            cancelBtn.trailingAnchor.constraint(equalTo: okBtn.leadingAnchor, constant: -12),
            cancelBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            okBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            okBtn.bottomAnchor.constraint(equalTo: cancelBtn.bottomAnchor)
        ])

        final class Handler: NSObject {
            var result: ArchiveExtractOptions?
            let panel: NSPanel
            let pathField: NSTextField
            let nameField: NSTextField
            let passwordField: NSSecureTextField
            let deleteCheck: NSButton

            init(
                panel: NSPanel,
                pathField: NSTextField,
                nameField: NSTextField,
                passwordField: NSSecureTextField,
                deleteCheck: NSButton
            ) {
                self.panel = panel
                self.pathField = pathField
                self.nameField = nameField
                self.passwordField = passwordField
                self.deleteCheck = deleteCheck
            }

            @objc func browse() {
                let open = NSOpenPanel()
                open.canChooseFiles = false
                open.canChooseDirectories = true
                open.canCreateDirectories = true
                open.prompt = "选择"
                open.directoryURL = URL(fileURLWithPath: pathField.stringValue)
                if open.runModal() == .OK, let url = open.url {
                    pathField.stringValue = url.path
                }
            }

            @objc func cancel() {
                result = nil
                NSApp.stopModal(withCode: .cancel)
                panel.orderOut(nil)
            }

            @objc func ok() {
                result = ArchiveExtractOptions(
                    directory: URL(fileURLWithPath: pathField.stringValue).standardizedFileURL,
                    folderName: nameField.stringValue,
                    password: passwordField.stringValue,
                    deleteSource: deleteCheck.state == .on
                )
                NSApp.stopModal(withCode: .OK)
                panel.orderOut(nil)
            }
        }

        let handler = Handler(
            panel: panel,
            pathField: pathField,
            nameField: nameField,
            passwordField: passwordField,
            deleteCheck: deleteCheck
        )
        browseBtn.target = handler
        browseBtn.action = #selector(Handler.browse)
        cancelBtn.target = handler
        cancelBtn.action = #selector(Handler.cancel)
        okBtn.target = handler
        okBtn.action = #selector(Handler.ok)
        objc_setAssociatedObject(panel, "handler", handler, .OBJC_ASSOCIATION_RETAIN)

        let code = NSApp.runModal(for: panel)
        return code == .OK ? handler.result : nil
    }

    private static func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }
}
