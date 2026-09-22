import AppKit
import ServiceManagement

struct UIActions {
    var chooseFolder: () -> Void
    var preview: () -> Void
    var enable: () -> Void
    var togglePause: () -> Void
    var retry: () -> Void
    var undo: (UUID) -> Void
    var clearHistory: () -> Void
    var checkCodex: () -> Void
    var chooseCodex: () -> Void
    var quit: () -> Void
}

struct UIHistoryItem: Equatable {
    var id: UUID
    var original: String
    var renamed: String
    var date: Date
    var state: String
    var canUndo: Bool
}

struct UIPreviewItem: Equatable {
    var original: String
    var proposed: String
    var details: String
}

struct UIState: Equatable {
    var status = "Needs attention"
    var detail = "Choose your Desktop folder, connect Codex, and preview a few names to get started."
    var folder: String?
    var codexStatus = "Codex has not been checked."
    var isEnabled = false
    var isPaused = false
    var isBusy = false
    var canEnable = false
    var history: [UIHistoryItem] = []
    var previews: [UIPreviewItem] = []
}

/// All AppKit and login-item interactions stay on the application's main actor.
@MainActor
final class AppUI: NSObject, NSWindowDelegate, NSMenuDelegate {
    private let actions: UIActions
    private var state = UIState()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var window: NSWindow!
    private let statusLabel = NSTextField(labelWithString: "Needs attention")
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let folderLabel = NSTextField(wrappingLabelWithString: "No folder selected")
    private let codexLabel = NSTextField(wrappingLabelWithString: "Codex has not been checked.")
    private let consent = NSButton(checkboxWithTitle: "I understand that screenshots are sent to OpenAI.", target: nil, action: nil)
    private let previewButton = NSButton(title: "Preview Generated Samples", target: nil, action: nil)
    private let enableButton = NSButton(title: "Enable Automatic Naming", target: nil, action: nil)
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry Pending", target: nil, action: nil)
    private let clearButton = NSButton(title: "Clear History", target: nil, action: nil)
    private let previewRows = NSStackView()
    private let historyRows = NSStackView()
    private var setupPane: NSScrollView!
    private var historyPane: NSView!
    private var segments: NSSegmentedControl!
    private var renderedPreviews: [UIPreviewItem]?
    private var renderedHistory: [UIHistoryItem]?
    private var renderedHistoryBusy: Bool?
    private var historyDatesNeedRefresh = false
    private var dateFormattingObservers: [NSObjectProtocol] = []
    private var historyViews: [UUID: HistoryRow] = [:]
    private var emptyHistoryView: NSView?
    private var renderedMenu: MenuState?
    private var loginMenuItem: NSMenuItem?
    private let historyDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private struct HistoryRow {
        var item: UIHistoryItem
        let view: NSView
        let title: NSTextField
        let original: NSTextField
        let detail: NSTextField
        let undo: NSButton
    }

    private struct MenuState: Equatable {
        let status: String
        let isEnabled: Bool
        let isPaused: Bool
        let isBusy: Bool
        let recent: [UIHistoryItem]
    }

    init(actions: UIActions) {
        self.actions = actions
        super.init()
        buildWindow()
        update(state)
        for name in [NSLocale.currentLocaleDidChangeNotification, NSNotification.Name.NSSystemTimeZoneDidChange] {
            let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.invalidateHistoryDateFormatting() }
            }
            dateFormattingObservers.append(observer)
        }
    }

    deinit {
        for observer in dateFormattingObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func showWindow() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshVisibleRows()
    }

    func windowDidBecomeKey(_ notification: Notification) { refreshVisibleRows() }
    func windowDidDeminiaturize(_ notification: Notification) { refreshVisibleRows() }
    func menuWillOpen(_ menu: NSMenu) {
        loginMenuItem?.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    func update(_ state: UIState) {
        self.state = state
        statusLabel.stringValue = state.status
        statusLabel.textColor = state.status == "Needs attention" ? .systemOrange : .labelColor
        detailLabel.stringValue = state.detail
        folderLabel.stringValue = state.folder ?? "Select the Desktop folder you want to watch."
        codexLabel.stringValue = state.codexStatus
        previewButton.isEnabled = !state.isBusy
        enableButton.title = state.isEnabled ? "Automatic Naming Enabled" : "Enable Automatic Naming"
        refreshEnablement()
        pauseButton.title = state.isPaused ? "Resume" : "Pause"
        pauseButton.isEnabled = state.isEnabled
        retryButton.isEnabled = state.isEnabled && !state.isBusy && !state.isPaused
        clearButton.isEnabled = (!state.history.isEmpty || !state.previews.isEmpty) && !state.isBusy
        refreshVisibleRows()
        let menuState = MenuState(status: state.status, isEnabled: state.isEnabled,
                                  isPaused: state.isPaused, isBusy: state.isBusy,
                                  recent: Array(state.history.prefix(5)))
        if menuState != renderedMenu {
            rebuildMenu()
            renderedMenu = menuState
        }
    }

    /// Row trees are updated only when their pane can be seen. The latest state is
    /// retained while the window is closed or its other pane is selected.
    private func refreshVisibleRows() {
        guard window.isVisible, !window.isMiniaturized else { return }
        if !setupPane.isHidden, renderedPreviews != state.previews {
            rebuildPreviews()
            renderedPreviews = state.previews
        }
        if !historyPane.isHidden {
            if renderedHistory != state.history {
                updateHistory()
                renderedHistory = state.history
                renderedHistoryBusy = state.isBusy
            } else if renderedHistoryBusy != state.isBusy {
                updateUndoEnablement()
                renderedHistoryBusy = state.isBusy
            }
            if historyDatesNeedRefresh {
                for row in historyViews.values { row.detail.stringValue = historyDetail(row.item) }
                historyDatesNeedRefresh = false
            }
        }
    }

    private func invalidateHistoryDateFormatting() {
        historyDateFormatter.locale = .current
        historyDateFormatter.calendar = .current
        historyDateFormatter.timeZone = .current
        historyDatesNeedRefresh = true
        refreshVisibleRows()
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.delegate = self
        window.title = "Screenshot Renamer"
        window.minSize = NSSize(width: 650, height: 580)
        window.isReleasedWhenClosed = false
        window.center()
        let root = WindowBackgroundView()
        window.contentView = root

        let headerIcon = NSImageView(image: NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Screenshot Renamer")!)
        headerIcon.contentTintColor = .controlAccentColor
        headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 34, weight: .medium)
        headerIcon.widthAnchor.constraint(equalToConstant: 48).isActive = true
        headerIcon.heightAnchor.constraint(equalToConstant: 48).isActive = true
        let heading = label("Screenshot Renamer", size: 23, weight: .semibold)
        let subtitle = label("A little order for your Desktop.", size: 13, color: .secondaryLabelColor)
        let brand = vertical([heading, subtitle], spacing: 5)
        let header = horizontal([headerIcon, brand, spacer()], spacing: 14)

        statusLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        detailLabel.font = .systemFont(ofSize: 12)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 3
        let statusText = vertical([statusLabel, detailLabel], spacing: 5)
        statusText.setContentHuggingPriority(.defaultLow, for: .horizontal)
        wire(pauseButton, #selector(togglePause))
        wire(retryButton, #selector(retry))
        let statusActions = horizontal([pauseButton, retryButton], spacing: 8)
        statusActions.setContentHuggingPriority(.required, for: .horizontal)
        let statusRow = horizontal([statusText, statusActions], spacing: 16)
        statusRow.alignment = .centerY
        let statusCard = card(statusRow, inset: 16)

        segments = NSSegmentedControl(labels: ["Setup & Preview", "History"], trackingMode: .selectOne, target: self, action: #selector(changePane))
        segments.selectedSegment = 0
        segments.segmentStyle = .rounded
        let segmentRow = horizontal([segments, spacer()], spacing: 0)

        setupPane = scrollView(document: makeSetup())
        historyPane = makeHistory()
        historyPane.isHidden = true
        let content = NSView()
        for pane in [setupPane!, historyPane!] {
            content.addSubview(pane)
            pin(pane, to: content)
        }

        let footer = label("Only new screenshots. Original image contents preserved. Undo from History.", size: 11, color: .tertiaryLabelColor)
        let layout = vertical([header, statusCard, segmentRow, content, footer], spacing: 18)
        root.addSubview(layout)
        pin(layout, to: root, inset: 24)
        for item in [header, statusCard, segmentRow, content, footer] {
            item.widthAnchor.constraint(equalTo: layout.widthAnchor).isActive = true
        }
        content.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true
    }

    private func makeSetup() -> NSView {
        folderLabel.font = .systemFont(ofSize: 12)
        folderLabel.textColor = .secondaryLabelColor
        folderLabel.lineBreakMode = .byTruncatingMiddle
        folderLabel.maximumNumberOfLines = 2
        folderLabel.isSelectable = true
        let choose = button("Choose Folder…", #selector(chooseFolder))
        let folder = setupStep(number: "1", title: "Choose your Desktop", description: folderLabel, controls: [choose])

        codexLabel.font = .systemFont(ofSize: 12)
        codexLabel.textColor = .secondaryLabelColor
        codexLabel.maximumNumberOfLines = 3
        let codex = setupStep(number: "2", title: "Connect Codex", description: codexLabel,
                              controls: [button("Check Connection", #selector(checkCodex)), button("Locate Codex…", #selector(chooseCodex))])

        let privacy = wrapping("Preview sends three generated sample images to OpenAI through Codex using your existing login. After you enable automatic naming, new screenshots in your selected folder are also sent to OpenAI. Review sensitive screenshots before enabling.")
        let retention = wrapping("Filename history is stored on this Mac for 30 days. You can clear it at any time. Local cleanup does not control OpenAI’s service-side data policies.", size: 11)
        retention.textColor = .secondaryLabelColor
        wire(consent, #selector(consentChanged))
        consent.font = .systemFont(ofSize: 12)
        wire(previewButton, #selector(preview))
        wire(enableButton, #selector(enable))
        enableButton.bezelColor = .controlAccentColor
        let buttons = horizontal([previewButton, enableButton, spacer()], spacing: 10)
        let previewIntro = wrapping("Review proposed names and response times using three generated sample images. The preview does not access or rename your Desktop screenshots.", size: 12)
        previewIntro.textColor = .secondaryLabelColor
        let enableSection = vertical([
            label("3  Preview, then enable", size: 14, weight: .semibold),
            previewIntro, privacy, retention, consent, buttons
        ], spacing: 10)
        fillWidth(enableSection, excluding: [consent])

        previewRows.orientation = .vertical
        previewRows.alignment = .leading
        previewRows.spacing = 12
        let previewSection = vertical([label("PREVIEW", size: 10, weight: .semibold, color: .secondaryLabelColor), previewRows], spacing: 10)
        fillWidth(previewSection)
        let stack = vertical([folder, codex, card(enableSection, inset: 16), previewSection], spacing: 20)
        fillWidth(stack)
        return stack
    }

    private func setupStep(number: String, title: String, description: NSTextField, controls: [NSView]) -> NSView {
        let text = vertical([label("\(number)  \(title)", size: 14, weight: .semibold), description], spacing: 6)
        fillWidth(text)
        let controlsRow = horizontal(controls + [spacer()], spacing: 8)
        let stack = vertical([text, controlsRow], spacing: 9)
        fillWidth(stack)
        return stack
    }

    private func makeHistory() -> NSView {
        let title = label("Recent filenames", size: 16, weight: .semibold)
        wire(clearButton, #selector(clearHistory))
        let header = horizontal([title, spacer(), clearButton], spacing: 12)
        let explanation = wrapping("Undo restores the original name when the file is unchanged and the original name is available. History is retained for 30 days.", size: 12)
        explanation.textColor = .secondaryLabelColor
        historyRows.orientation = .vertical
        historyRows.alignment = .leading
        historyRows.spacing = 12
        let scroll = scrollView(document: historyRows)
        let stack = vertical([header, explanation, scroll], spacing: 12)
        fillWidth(stack)
        return stack
    }

    private func rebuildPreviews() {
        removeRows(from: previewRows)
        if state.previews.isEmpty {
            let empty = wrapping("Your preview names will appear here. Nothing is renamed until you enable automatic naming.", size: 12)
            empty.textColor = .secondaryLabelColor
            previewRows.addArrangedSubview(empty)
        } else {
            for item in state.previews {
                let original = wrapping(item.original, size: 11)
                original.textColor = .secondaryLabelColor
                let proposed = wrapping(item.proposed, size: 13, weight: .medium)
                let details = wrapping(item.details, size: 11)
                details.textColor = .secondaryLabelColor
                let row = vertical([original, proposed, details], spacing: 5)
                fillWidth(row)
                previewRows.addArrangedSubview(card(row, inset: 12))
            }
        }
        fillWidth(previewRows)
    }

    private func updateHistory() {
        let retainedIDs = Set(state.history.map(\.id))
        for id in Array(historyViews.keys) where !retainedIDs.contains(id) {
            guard let row = historyViews.removeValue(forKey: id) else { continue }
            historyRows.removeArrangedSubview(row.view)
            row.view.removeFromSuperview()
        }
        if state.history.isEmpty {
            if emptyHistoryView == nil {
                let empty = wrapping("No renames yet. Once automatic naming is enabled, recent screenshots and Undo actions appear here.", size: 13)
                empty.textColor = .secondaryLabelColor
                historyRows.addArrangedSubview(empty)
                empty.widthAnchor.constraint(equalTo: historyRows.widthAnchor).isActive = true
                emptyHistoryView = empty
            }
            return
        }
        if let empty = emptyHistoryView {
            historyRows.removeArrangedSubview(empty)
            empty.removeFromSuperview()
            emptyHistoryView = nil
        }
        var currentRows = historyRows.arrangedSubviews
        for (index, item) in state.history.enumerated() {
            var row: HistoryRow
            if let existing = historyViews[item.id] {
                row = existing
                if row.item != item {
                    row.title.stringValue = item.renamed
                    row.original.stringValue = item.original
                    row.detail.stringValue = historyDetail(item)
                    row.item = item
                }
            } else {
                row = makeHistoryRow(item)
                historyRows.insertArrangedSubview(row.view, at: index)
                row.view.widthAnchor.constraint(equalTo: historyRows.widthAnchor).isActive = true
                currentRows.insert(row.view, at: index)
            }
            row.undo.isEnabled = item.canUndo && !state.isBusy
            if currentRows[index] !== row.view {
                historyRows.removeArrangedSubview(row.view)
                historyRows.insertArrangedSubview(row.view, at: index)
                currentRows.removeAll { $0 === row.view }
                currentRows.insert(row.view, at: index)
            }
            historyViews[item.id] = row
        }
    }

    private func makeHistoryRow(_ item: UIHistoryItem) -> HistoryRow {
        let title = wrapping(item.renamed, size: 13, weight: .medium)
        let original = wrapping(item.original, size: 11)
        original.textColor = .secondaryLabelColor
        let detail = wrapping(historyDetail(item), size: 11)
        detail.textColor = .secondaryLabelColor
        let text = vertical([title, original, detail], spacing: 5)
        fillWidth(text)
        let undo = button("Undo", #selector(undoButton(_:)))
        undo.identifier = NSUserInterfaceItemIdentifier(item.id.uuidString)
        let content = horizontal([text, undo], spacing: 14)
        let view = card(content, inset: 14)
        return HistoryRow(item: item, view: view, title: title, original: original, detail: detail, undo: undo)
    }

    private func historyDetail(_ item: UIHistoryItem) -> String {
        "\(historyDateFormatter.string(from: item.date)) · \(item.state)"
    }

    private func updateUndoEnablement() {
        for row in historyViews.values { row.undo.isEnabled = row.item.canUndo && !state.isBusy }
    }

    private func rebuildMenu() {
        let symbol: String
        switch state.status {
        case "Paused": symbol = "pause.circle"
        case "Naming": symbol = "sparkles"
        case "Needs attention": symbol = "exclamationmark.circle"
        default: symbol = "viewfinder"
        }
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Screenshot Renamer: \(state.status)")
        statusItem.button?.toolTip = "Screenshot Renamer — \(state.status)"
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Screenshot Renamer · \(state.status)", action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)
        menu.addItem(.separator())
        menu.addItem(menuItem("Settings & Preview…", #selector(openSettings), key: ","))
        menu.addItem(menuItem("History…", #selector(openHistory)))
        menu.addItem(menuItem(state.isPaused ? "Resume" : "Pause", #selector(togglePause), enabled: state.isEnabled))
        menu.addItem(menuItem("Retry Pending Captures", #selector(retry), enabled: state.isEnabled && !state.isBusy && !state.isPaused))
        if !state.history.isEmpty {
            menu.addItem(.separator())
            let recent = NSMenuItem(title: "Recent Renames", action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for item in state.history.prefix(5) {
                let entry = NSMenuItem(title: item.renamed, action: nil, keyEquivalent: "")
                let detailMenu = NSMenu()
                detailMenu.autoenablesItems = false
                let original = NSMenuItem(title: "Originally: \(item.original)", action: nil, keyEquivalent: "")
                original.isEnabled = false
                detailMenu.addItem(original)
                let undo = menuItem("Undo Rename", #selector(undoMenu(_:)), enabled: item.canUndo && !state.isBusy)
                undo.representedObject = item.id.uuidString
                detailMenu.addItem(undo)
                entry.submenu = detailMenu
                submenu.addItem(entry)
            }
            recent.submenu = submenu
            menu.addItem(recent)
        }
        menu.addItem(.separator())
        let login = menuItem("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        loginMenuItem = login
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(menuItem("Quit Screenshot Renamer", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func refreshEnablement() {
        enableButton.isEnabled = consent.state == .on && state.canEnable && !state.isBusy && !state.isEnabled
    }

    @objc private func chooseFolder() { actions.chooseFolder() }
    @objc private func preview() { actions.preview() }
    @objc private func enable() { actions.enable() }
    @objc private func togglePause() { actions.togglePause() }
    @objc private func retry() { actions.retry() }
    @objc private func checkCodex() { actions.checkCodex() }
    @objc private func chooseCodex() { actions.chooseCodex() }
    @objc private func quit() { actions.quit() }
    @objc private func clearHistory() { actions.clearHistory() }
    @objc private func consentChanged() { refreshEnablement() }
    @objc private func changePane() {
        setupPane.isHidden = segments.selectedSegment != 0
        historyPane.isHidden = segments.selectedSegment != 1
        refreshVisibleRows()
    }
    @objc private func openSettings() { segments.selectedSegment = 0; changePane(); showWindow() }
    @objc private func openHistory() { segments.selectedSegment = 1; changePane(); showWindow() }
    @objc private func undoButton(_ sender: NSButton) {
        if let raw = sender.identifier?.rawValue, let id = UUID(uuidString: raw) { actions.undo(id) }
    }
    @objc private func undoMenu(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) { actions.undo(id) }
    }
    @objc private func toggleLogin() {
        do {
            switch SMAppService.mainApp.status {
            case .enabled, .requiresApproval:
                try SMAppService.mainApp.unregister()
            default:
                try SMAppService.mainApp.register()
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
            rebuildMenu()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn’t change Open at Login"
            alert.informativeText = "Run Screenshot Renamer from its installed Applications location, then try again. \(error.localizedDescription)"
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func menuItem(_ title: String, _ action: Selector, key: String = "", enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        return item
    }

    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        return field
    }

    private func wrapping(_ text: String, size: CGFloat = 12, weight: NSFont.Weight = .regular) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.isSelectable = true
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    private func wire(_ button: NSButton, _ action: Selector) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        wire(button, action)
        return button
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func horizontal(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        return view
    }

    private func card(_ child: NSView, inset: CGFloat) -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.titlePosition = .noTitle
        box.borderWidth = 1
        box.cornerRadius = 12
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        box.contentView!.addSubview(child)
        pin(child, to: box.contentView!, inset: inset)
        return box
    }

    private func scrollView(document: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let wrapper = FlippedView()
        wrapper.addSubview(document)
        scroll.documentView = wrapper
        wrapper.translatesAutoresizingMaskIntoConstraints = false
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            wrapper.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            wrapper.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            wrapper.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 2),
            document.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 1),
            document.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -14),
            document.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor, constant: -16)
        ])
        return scroll
    }

    private func pin(_ child: NSView, to parent: NSView, inset: CGFloat = 0) {
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: inset),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -inset),
            child.topAnchor.constraint(equalTo: parent.topAnchor, constant: inset),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -inset)
        ])
    }

    private func fillWidth(_ stack: NSStackView, excluding: [NSView] = []) {
        for view in stack.arrangedSubviews where !excluding.contains(where: { $0 === view }) {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func removeRows(from stack: NSStackView) {
        for row in stack.arrangedSubviews { stack.removeArrangedSubview(row); row.removeFromSuperview() }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

private final class WindowBackgroundView: NSView {
    override var isOpaque: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}
