import AppKit

/// Exercises the production AppKit UI with synthetic state only. It never creates
/// AppController, accesses user settings, submits images, or changes login items.
/// The window is ordered offscreen without activating this process.
private struct VerificationFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private final class UIVerification {
    private var checks = 0
    private var undone: UUID?
    private var updateChecks = 0
    private var updateToggles = 0

    func run() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let ui = AppUI(actions: UIActions(chooseFolder: {}, togglePause: {}, retry: {},
                                          undo: { [weak self] in self?.undone = $0 }, clearHistory: {},
                                          checkCodex: {}, chooseCodex: {},
                                          checkForUpdates: { [weak self] in self?.updateChecks += 1 },
                                          toggleAutomaticUpdates: { [weak self] in self?.updateToggles += 1 }, quit: {}))
        // Read the view references without adding a test-only API to AppUI.
        let window: NSWindow = try stored("window", in: ui)
        let history: NSStackView = try stored("historyRows", in: ui)
        let suggestions: NSStackView = try stored("suggestionRows", in: ui)
        let segments: NSSegmentedControl = try stored("segments", in: ui)
        let statusItem: NSStatusItem = try stored("statusItem", in: ui)
        let updateButton: NSButton = try stored("updateButton", in: ui)
        defer { window.orderOut(nil); NSStatusBar.system.removeStatusItem(statusItem) }
        let controls = descendants(of: window.contentView!).compactMap { $0 as? NSButton }
        try check(!controls.contains { button in
            let title = button.title.lowercased()
            return title.contains("preview") || title.contains("enable automatic") || title.contains("i understand")
        }, "Settings has no preview, enable, or consent controls")
        try check(segments.label(forSegment: 0) == "Settings", "Settings replaces the setup workflow")
        try check(statusItem.menu?.items.contains { $0.title == "Settings…" } == true &&
                  statusItem.menu?.items.contains { $0.title.lowercased().contains("preview") } == false,
                  "menu opens Settings without a preview step")
        try check(descendants(of: window.contentView!).contains {
            ($0 as? NSTextField)?.stringValue.contains("sent to OpenAI through Codex using your saved login") == true
        }, "Settings explains automatic screenshot sharing")
        let retry: NSButton = try stored("retryButton", in: ui)
        var startupFailure = UIState(status: "Needs attention", detail: "Desktop access needs to be restored.")
        ui.update(startupFailure)
        try check(retry.isEnabled && retry.title == "Retry" &&
                  statusItem.menu?.items.contains { $0.title == "Retry Automatic Naming" && $0.isEnabled } == true,
                  "startup failure can retry automatic naming before a baseline exists")
        try check(statusItem.menu?.item(withTitle: startupFailure.detail)?.toolTip == startupFailure.detail,
                  "Needs attention explains the startup failure directly in the menu")
        startupFailure.detail = "Desktop access was denied. Restore it in System Settings, then retry automatic naming to start watching new screenshots."
        ui.update(startupFailure)
        try check(statusItem.menu?.item(withTitle: "Desktop access was denied.")?.toolTip == startupFailure.detail,
                  "changed attention details refresh the shortened menu explanation and full tooltip")
        startupFailure.isBusy = true
        ui.update(startupFailure)
        try check(!retry.isEnabled &&
                  statusItem.menu?.items.contains { $0.title == "Retry Automatic Naming" && !$0.isEnabled } == true,
                  "startup retry stays disabled during work or connection checking")
        startupFailure.isBusy = false
        startupFailure.isPaused = true
        ui.update(startupFailure)
        try check(!retry.isEnabled, "paused startup state cannot retry")
        var state = UIState(status: "Watching", isEnabled: true)
        state.history = (0..<200).map { index in
            UIHistoryItem(id: UUID(), original: "Screenshot \(index).png", renamed: "Generated Name \(index).png",
                          date: Date(timeIntervalSince1970: Double(1_750_000_000 - index)), state: "renamed", canUndo: true)
        }
        state.suggestions = [UICaptureSuggestion(original: "Screenshot.png", proposed: "Review Name.png", details: "Needs review")]
        ui.update(state)
        try check(history.arrangedSubviews.isEmpty && suggestions.arrangedSubviews.isEmpty,
                  "closed window defers row construction")

        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        ui.update(state)
        try check(suggestions.arrangedSubviews.count == 1 && history.arrangedSubviews.isEmpty,
                  "opening Settings renders suggestions and leaves History deferred")
        let suggestionRow = suggestions.arrangedSubviews[0]
        let menu = statusItem.menu
        state.detail = "An unrelated status detail"
        ui.update(state)
        try check(suggestions.arrangedSubviews[0] === suggestionRow && statusItem.menu === menu,
                  "detail updates preserve suggestion rows and the menu")

        try check(statusItem.menu?.item(withTitle: "Check for Updates…")?.isEnabled == false && !updateButton.isEnabled,
                  "updater controls stay disabled when no updater is running")
        state.updates = UIUpdateState(isAvailable: true, canCheck: true, automaticallyChecks: true)
        ui.update(state)
        try check(statusItem.menu?.item(withTitle: "Check for Updates…")?.isEnabled == true &&
                  statusItem.menu?.item(withTitle: "Automatically Check for Updates")?.state == .on,
                  "updater-only changes refresh menu enablement and automatic-check preference")
        if let updateMenu = statusItem.menu, let item = updateMenu.item(withTitle: "Check for Updates…") {
            updateMenu.performActionForItem(at: updateMenu.index(of: item))
        }
        if let updateMenu = statusItem.menu, let item = updateMenu.item(withTitle: "Automatically Check for Updates") {
            updateMenu.performActionForItem(at: updateMenu.index(of: item))
        }
        try check(updateChecks == 1 && updateToggles == 1, "updater menu actions reach their injected handlers")
        updateButton.performClick(nil)
        try check(updateButton.isEnabled && updateChecks == 2, "the window's update button invokes the same updater")
        state.updates.canCheck = false
        state.updates.automaticallyChecks = false
        ui.update(state)
        try check(statusItem.menu?.item(withTitle: "Check for Updates…")?.isEnabled == false && !updateButton.isEnabled &&
                  statusItem.menu?.item(withTitle: "Automatically Check for Updates")?.state == .off,
                  "an active update check disables rechecking without stale menu state")
        state.updates.canCheck = true
        state.updates.availableVersion = "1.1.0"
        ui.update(state)
        try check(statusItem.menu?.item(withTitle: "Update Available (1.1.0)…")?.isEnabled == true,
                  "a scheduled update remains discoverable in the menu")
        state.updates.availableVersion = nil
        ui.update(state)
        try check(statusItem.menu?.item(withTitle: "Check for Updates…") != nil,
                  "finishing an update restores the normal check action")

        segments.selectedSegment = 1
        segments.sendAction(segments.action!, to: segments.target)
        try check(history.arrangedSubviews.count == state.history.count, "History renders on selection")
        let originalRows = history.arrangedSubviews
        let originalButtons = try history.arrangedSubviews.map { try undoButton(in: $0) }
        let originalConstraints = history.constraints.count
        let formatter: DateFormatter = try stored("historyDateFormatter", in: ui)
        let expectedFormatter = DateFormatter()
        expectedFormatter.dateStyle = .medium
        expectedFormatter.timeStyle = .short
        expectedFormatter.locale = .current
        expectedFormatter.calendar = .current
        expectedFormatter.timeZone = .current
        // Simulate stale cached formatting without changing macOS or user preferences.
        formatter.timeZone = TimeZone(secondsFromGMT: TimeZone.current.secondsFromGMT() == 0 ? 43200 : 0)
        state.history[0].date.addTimeInterval(60)
        ui.update(state)
        let detail = try historyDetail(in: originalRows[0])
        let expectedDate = "\(expectedFormatter.string(from: state.history[0].date)) · \(state.history[0].state)"
        try check(detail.stringValue != expectedDate, "timezone fixture starts with stale cached date text")
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        try check(detail.stringValue == expectedDate && history.arrangedSubviews[0] === originalRows[0],
                  "timezone changes refresh visible dates without replacing rows")
        formatter.locale = Locale(identifier: Locale.current.language.languageCode?.identifier == "fr" ? "en_US" : "fr_FR")
        state.history[0].date.addTimeInterval(60)
        ui.update(state)
        let hiddenDate = detail.stringValue
        try check(hiddenDate != "\(expectedFormatter.string(from: state.history[0].date)) · \(state.history[0].state)",
                  "locale fixture starts with stale cached date text")
        segments.selectedSegment = 0
        segments.sendAction(segments.action!, to: segments.target)
        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        try check(detail.stringValue == hiddenDate, "locale changes defer hidden History date updates")
        segments.selectedSegment = 1
        segments.sendAction(segments.action!, to: segments.target)
        try check(detail.stringValue == "\(expectedFormatter.string(from: state.history[0].date)) · \(state.history[0].state)" &&
                  history.arrangedSubviews[0] === originalRows[0],
                  "selecting History applies current locale to reused rows")
        try check(suggestions.arrangedSubviews[0] === suggestionRow, "date-format changes preserve unrelated suggestion rows")
        for index in 0..<20 {
            state.isBusy = index.isMultiple(of: 2)
            state.detail = "Naming state \(index)"
            ui.update(state)
        }
        try check(zip(history.arrangedSubviews, originalRows).allSatisfy { $0 === $1 },
                  "busy/detail updates retain all 200 row objects")
        try check(history.constraints.count == originalConstraints, "repeated updates do not accumulate constraints")
        state.isBusy = true
        ui.update(state)
        try check(originalButtons.allSatisfy { !$0.isEnabled }, "busy state disables existing Undo buttons")
        state.isBusy = false
        ui.update(state)
        try check(originalButtons.allSatisfy(\.isEnabled), "idle state re-enables eligible Undo buttons")

        let added = UIHistoryItem(id: UUID(), original: "Newest.png", renamed: "Newest Named.png", date: Date(),
                                  state: "renamed", canUndo: true)
        state.history.insert(added, at: 0)
        ui.update(state)
        try check(history.arrangedSubviews.count == 201 && zip(history.arrangedSubviews.dropFirst(), originalRows).allSatisfy { $0 === $1 },
                  "prepending a rename reuses all existing rows")
        let addedRow = history.arrangedSubviews[0]
        let addedUndo = try undoButton(in: addedRow)
        addedUndo.performClick(nil)
        try check(undone == added.id, "reused row action targets its history ID")
        state.history[0].state = "undone"
        state.history[0].canUndo = false
        state.history[0].renamed = "Updated Name.png"
        ui.update(state)
        try check(history.arrangedSubviews[0] === addedRow && !addedUndo.isEnabled &&
                  descendants(of: addedRow).contains { ($0 as? NSTextField)?.stringValue == "Updated Name.png" },
                  "changed history content and Undo state update in place")
        state.history.swapAt(0, 1)
        ui.update(state)
        try check(history.arrangedSubviews[0] === originalRows[0] && history.arrangedSubviews[1] === addedRow,
                  "history reordering preserves row identity")
        try check(history.arrangedSubviews.allSatisfy { row in
            history.constraints.contains { ($0.firstItem as? NSView) === row && $0.firstAttribute == .width &&
                ($0.secondItem as? NSView) === history }
        }, "reordering retains row width constraints")
        state.history.remove(at: 1)
        ui.update(state)
        try check(history.arrangedSubviews.count == 200 && addedRow.superview == nil,
                  "removed history detaches only its row")

        state.suggestions[0].proposed = "Changed while hidden.png"
        ui.update(state)
        try check(suggestions.arrangedSubviews[0] === suggestionRow, "hidden Settings defers changed content")
        segments.selectedSegment = 0
        segments.sendAction(segments.action!, to: segments.target)
        try check(suggestions.arrangedSubviews[0] !== suggestionRow &&
                  descendants(of: suggestions).contains { ($0 as? NSTextField)?.stringValue == "Changed while hidden.png" },
                  "selecting Settings applies its latest content")
        state.suggestions.removeAll()
        ui.update(state)
        try check(suggestions.arrangedSubviews.count == 1 && descendants(of: suggestions).contains {
            ($0 as? NSTextField)?.stringValue.contains("Screenshots that need your review") == true
        }, "Settings explains the empty review state")
        state.history.removeAll()
        ui.update(state)
        try check(history.arrangedSubviews.count == 200, "hidden History defers removal")
        segments.selectedSegment = 1
        segments.sendAction(segments.action!, to: segments.target)
        try check(history.arrangedSubviews.count == 1 && (history.arrangedSubviews[0] as? NSTextField) != nil,
                  "selecting History applies an empty state")
        let empty = history.arrangedSubviews[0]
        state.detail = "Still empty"
        ui.update(state)
        try check(history.arrangedSubviews[0] === empty, "unchanged empty state is reused")
        window.orderOut(nil)
        state.history = [added]
        ui.update(state)
        try check(history.arrangedSubviews[0] === empty, "closed window defers new history")
        window.orderFront(nil)
        window.delegate?.windowDidBecomeKey?(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        try check(try undoButton(in: history.arrangedSubviews[0]).identifier?.rawValue == added.id.uuidString,
                  "reopening the window applies the latest history")
        window.contentView?.layoutSubtreeIfNeeded()
        print("UI verification passed: \(checks) checks; synthetic state, no model calls or user settings.")
    }

    private func check(_ condition: Bool, _ description: String) throws {
        guard condition else { throw VerificationFailure(description: description) }
        checks += 1
        print("PASS \(description)")
    }

    private func stored<T>(_ name: String, in ui: AppUI) throws -> T {
        guard let value = Mirror(reflecting: ui).children.first(where: { $0.label == name })?.value as? T else {
            throw VerificationFailure(description: "Missing AppUI field \(name)")
        }
        return value
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }

    private func historyDetail(in view: NSView) throws -> NSTextField {
        guard let field = descendants(of: view).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue.contains(" · ") }) else {
            throw VerificationFailure(description: "Missing history date label")
        }
        return field
    }

    private func undoButton(in view: NSView) throws -> NSButton {
        guard let button = descendants(of: view).compactMap({ $0 as? NSButton }).first(where: { $0.title == "Undo" }) else {
            throw VerificationFailure(description: "Missing Undo button")
        }
        return button
    }
}

@main
private enum VerifyUI {
    @MainActor static func main() {
        do { try UIVerification().run() }
        catch { fputs("UI verification failed: \(error)\n", stderr); exit(1) }
    }
}
