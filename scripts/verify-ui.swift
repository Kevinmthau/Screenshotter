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

    func run() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let ui = AppUI(actions: UIActions(chooseFolder: {}, preview: {}, enable: {}, togglePause: {}, retry: {},
                                          undo: { [weak self] in self?.undone = $0 }, clearHistory: {},
                                          checkCodex: {}, chooseCodex: {}, quit: {}))
        // Read the view references without adding a test-only API to AppUI.
        let window: NSWindow = try stored("window", in: ui)
        let history: NSStackView = try stored("historyRows", in: ui)
        let previews: NSStackView = try stored("previewRows", in: ui)
        let segments: NSSegmentedControl = try stored("segments", in: ui)
        let statusItem: NSStatusItem = try stored("statusItem", in: ui)
        defer { window.orderOut(nil); NSStatusBar.system.removeStatusItem(statusItem) }
        var state = UIState(status: "Watching", isEnabled: true)
        state.history = (0..<200).map { index in
            UIHistoryItem(id: UUID(), original: "Screenshot \(index).png", renamed: "Generated Name \(index).png",
                          date: Date(timeIntervalSince1970: Double(1_750_000_000 - index)), state: "renamed", canUndo: true)
        }
        state.previews = [UIPreviewItem(original: "Sample.png", proposed: "Sample Preview.png", details: "Generated sample")]
        ui.update(state)
        try check(history.arrangedSubviews.isEmpty && previews.arrangedSubviews.isEmpty,
                  "closed window defers row construction")

        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        ui.update(state)
        try check(previews.arrangedSubviews.count == 1 && history.arrangedSubviews.isEmpty,
                  "opening Setup renders previews and leaves History deferred")
        let previewRow = previews.arrangedSubviews[0]
        let menu = statusItem.menu
        state.detail = "An unrelated status detail"
        ui.update(state)
        try check(previews.arrangedSubviews[0] === previewRow && statusItem.menu === menu,
                  "detail updates preserve preview rows and the menu")

        segments.selectedSegment = 1
        segments.sendAction(segments.action!, to: segments.target)
        try check(history.arrangedSubviews.count == state.history.count, "History renders on selection")
        let originalRows = history.arrangedSubviews
        let originalButtons = try history.arrangedSubviews.map { try undoButton(in: $0) }
        let originalConstraints = history.constraints.count
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

        state.previews[0].proposed = "Changed while hidden.png"
        ui.update(state)
        try check(previews.arrangedSubviews[0] === previewRow, "hidden Preview defers changed content")
        segments.selectedSegment = 0
        segments.sendAction(segments.action!, to: segments.target)
        try check(previews.arrangedSubviews[0] !== previewRow &&
                  descendants(of: previews).contains { ($0 as? NSTextField)?.stringValue == "Changed while hidden.png" },
                  "selecting Preview applies its latest content")
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
