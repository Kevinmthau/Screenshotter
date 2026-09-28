import AppKit
import RenamerCore

private struct ReviewSuggestion: Codable {
    var original: String
    var proposed: String
    var detail: String
    var date: Date
}

private struct SavedSettings: Codable {
    var folderBookmark: Data?
    var executablePath: String?
    var enabled = false
    var paused = false
    var previewCompleted = false
    var previewSamples: [ReviewSuggestion]?
    var ledger: CaptureLedger?
    var suggestions: [ReviewSuggestion] = []
}

@MainActor final class AppController {
    private var ui: AppUI!
    private var settings = SavedSettings()
    private let support: URL
    private let settingsURL: URL
    private var renamer: CaptureFileService.State?
    private let files = CaptureFileService()
    private var queuePolicy = CaptureQueuePolicy()
    private var activeCapture: PendingCapture?
    private var mutationAuthorization: FileMutationAuthorization?
    private lazy var scans = CaptureScanScheduler(scan: { [files] in try await files.observations(in: $0) },
                                                  receive: { [weak self] in self?.receivedScan($0) })
    private var maintenance: Task<Void, Never>?
    private var initialization: Task<Void, Never>?
    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    private var folder: URL?
    private var folderScope = false
    private var work: Task<Void, Never>?
    private var busy = false
    private let connectionCheck = CodexConnectionCheck()
    private var checking: Bool { connectionCheck.isChecking }
    private var available = false
    private var attention: String?
    private var codexStatus = "Checking saved Codex login…"
    private var generation = 0
    private var overflow = false
    private var fatalPersistenceError = false
    private var isQuitting = false
    private var transientDetail: String?
    private var previews: [UIPreviewItem] = []
    private var wakeObserver: NSObjectProtocol?
    private var lastPruned = Date.distantPast
    private var lastRendered: UIState?
    private var lastHistoryEntries: [RenameJournalEntry] = []
    private var historyPresentation: [UIHistoryItem] = []

    init() {
        support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenshot Renamer", isDirectory: true)
        settingsURL = support.appendingPathComponent("settings.json")
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                settings = try JSONDecoder().decode(SavedSettings.self, from: Data(contentsOf: settingsURL))
            }
            previews = (settings.previewSamples ?? []).filter { Date().timeIntervalSince($0.date) < 30 * 86400 }
                .map { UIPreviewItem(original: $0.original, proposed: $0.proposed, details: $0.detail) }
            settings.ledger?.prunePending(before: Date().addingTimeInterval(-30 * 86400))
            settings.ledger?.recoverAfterRestart()
            if let bookmark = settings.folderBookmark {
                do {
                    var stale = false
                    let resolved = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
                    folder = resolved; folderScope = resolved.startAccessingSecurityScopedResource()
                    if stale { settings.folderBookmark = try resolved.bookmarkData(options: [.withSecurityScope]) }
                } catch {
                    attention = "Folder access could not be restored. Choose the Desktop folder again."
                }
            }
            // Folder scope is restored before the background service recovers the journal.
        } catch {
            fatalPersistenceError = true
            attention = "Saved state or folder access could not be restored. Quit and check the local data folder before retrying."
        }
        ui = AppUI(actions: UIActions(
            chooseFolder: { [weak self] in self?.chooseFolder() },
            preview: { [weak self] in self?.preview() },
            enable: { [weak self] in self?.enable() },
            togglePause: { [weak self] in self?.togglePause() },
            retry: { [weak self] in self?.retry() },
            undo: { [weak self] id in self?.undo(id) },
            clearHistory: { [weak self] in self?.clearHistory() },
            checkCodex: { [weak self] in self?.checkCodex() },
            chooseCodex: { [weak self] in self?.chooseCodex() },
            quit: { [weak self] in self?.quit() }
        ))
        initialization = Task { [weak self] in
            guard let self else { return }
            defer { self.initialization = nil }
            do {
                self.updateFileState(try await self.files.open(journalURL: self.support.appendingPathComponent("history.json")))
                guard !self.isQuitting else { return }
                if self.settings.enabled, self.folder != nil, !self.fatalPersistenceError { self.startWatching() }
                self.tick()
            } catch {
                self.fatalPersistenceError = true
                self.attention = "Rename history could not be restored. Restore folder access and restart; the history has been preserved."
                self.render()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        render()
        if !settings.enabled || attention != nil { ui.showWindow() }
        checkCodex()
    }

    func showWindow() { ui.showWindow() }
    private var analyzer: CodexAnalyzer {
        CodexAnalyzer(executableOverride: settings.executablePath.map { URL(fileURLWithPath: $0) })
    }

    private func chooseFolder() {
        guard !busy, initialization == nil, !fatalPersistenceError else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Your Desktop Folder"
        panel.message = "Grant access to the Desktop folder where macOS saves screenshots. Existing files will be left alone."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            let bookmark = try selected.bookmarkData(options: [.withSecurityScope])
            generation += 1; mutationAuthorization?.cancel(); work?.cancel(); scans.invalidate(); watcher?.stop(); watcher = nil
            let previousFolder = folder, previousScope = folderScope
            Task { [files] in
                await files.drain()
                if previousScope { previousFolder?.stopAccessingSecurityScopedResource() }
            }
            folder = selected; folderScope = selected.startAccessingSecurityScopedResource()
            settings.folderBookmark = bookmark
            settings.enabled = false; settings.paused = false; settings.ledger = nil
            attention = nil
            _ = persist(); render()
        } catch { attention = "Folder access was not granted. Choose the folder again."; render() }
    }

    private func chooseCodex() {
        guard !busy, !isQuitting else { return }
        let panel = NSOpenPanel(); panel.title = "Locate the Codex CLI"
        panel.message = "Choose the codex executable. The app otherwise checks standard install locations and installed Codex or ChatGPT apps."
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url, !busy, !isQuitting else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            attention = "Choose an executable Codex CLI file."; render(); return
        }
        settings.executablePath = url.path; available = false; settings.previewCompleted = false
        _ = persist(); checkCodex(replacingCurrent: true)
    }

    private func checkCodex(replacingCurrent: Bool = false) {
        guard (!checking || replacingCurrent), !busy, !isQuitting else { return }
        codexStatus = "Checking saved Codex login…"
        let client = analyzer
        connectionCheck.start(check: { await client.checkAvailability() }) { [weak self] result in
            guard let self, !self.isQuitting else { return }
            switch result {
            case .available:
                self.available = true; self.codexStatus = "Codex is available · saved login verified"
                if !self.fatalPersistenceError && (self.folder != nil || !self.settings.enabled) { self.attention = nil }
            case .unavailable(let error):
                self.available = false; self.codexStatus = error.localizedDescription
            }
            self.render(); self.tick()
        }
        render()
    }

    /// Preview always uses synthetic images, never existing Desktop files.
    private func preview() {
        guard available, !busy, !fatalPersistenceError, !isQuitting else { return }
        busy = true; previews = []; transientDetail = "Naming three generated samples. Their files will not be renamed."
        let client = analyzer
        render()
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.work = nil; self.transientDetail = nil; self.render(); self.pump() }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ScreenshotRenamer-Preview-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                let samples = try SampleScreenshots.create(in: directory)
                for sample in samples {
                    try Task.checkCancellation()
                    let started = Date()
                    let result = try await client.analyze(sample)
                    let elapsed = Date().timeIntervalSince(started)
                    let proposed = result.useful ? try FilenamePolicy.filename(title: result.title, captureDate: Date(), originalExtension: sample.pathExtension) : "Keep original filename"
                    self.previews.append(UIPreviewItem(original: sample.lastPathComponent, proposed: proposed,
                                                       details: String(format: "Generated sample · %.1f seconds · %@", elapsed, result.useful ? "Useful description" : "Review suggested")))
                    self.render()
                }
                self.settings.previewCompleted = true
                self.settings.previewSamples = self.previews.map {
                    ReviewSuggestion(original: $0.original, proposed: $0.proposed, detail: $0.details, date: Date())
                }
                self.attention = nil; _ = self.persist()
            } catch is CancellationError {
                self.attention = "Preview stopped. Run it again when ready."
            } catch {
                self.attention = (error as? CodexAnalysisError)?.localizedDescription ?? "The sample preview could not finish. Retry the preview."
            }
        }
    }

    private func enable() {
        guard settings.previewCompleted, available, let folder, !busy, renamer != nil, !fatalPersistenceError else { return }
        busy = true; render()
        let submittedGeneration = generation
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.work = nil; self.render() }
            do {
                let baseline = try await self.files.observations(in: folder)
                guard !Task.isCancelled, !self.isQuitting, self.generation == submittedGeneration else { return }
                self.scans.invalidate()
                self.settings.ledger = CaptureLedger(baseline: baseline.files, activatedAt: Date())
                self.settings.enabled = true; self.settings.paused = false; self.attention = nil
                guard self.persist() else { return }
                self.startWatching(); self.tick()
            } catch { self.attention = "Cannot read the selected folder. Choose it again to restore access." }
        }
    }

    private func startWatching() {
        guard let folder else { return }
        watcher?.stop()
        do { watcher = try DirectoryWatcher(url: folder) { [weak self] in self?.tick() } }
        catch { attention = "Filesystem notifications could not start. Folder reconciliation will continue every two seconds." }
    }

    private func togglePause() {
        guard settings.enabled else { return }
        settings.paused.toggle(); generation += 1
        if settings.paused { mutationAuthorization?.cancel(); work?.cancel() }
        _ = persist(); render()
        if !settings.paused { tick() }
    }

    private func retry() {
        guard !fatalPersistenceError, !isQuitting else { return }
        settings.ledger?.retryFailures(); attention = nil; _ = persist()
        if available { tick() } else { checkCodex() }
    }

    private func tick() {
        guard !fatalPersistenceError, !isQuitting, renamer != nil else { return }
        if Date().timeIntervalSince(lastPruned) > 3600, maintenance == nil {
            maintenance = Task { [weak self] in
                guard let self else { return }
                defer { self.maintenance = nil }
                do { self.updateFileState(try await self.files.pruneHistory()); self.lastPruned = Date() }
                catch { self.persistenceFailed(); return }
                guard !self.isQuitting else { return }
                self.settings.suggestions.removeAll { Date().timeIntervalSince($0.date) > 30 * 86400 }
                self.settings.previewSamples?.removeAll { Date().timeIntervalSince($0.date) > 30 * 86400 }
                self.settings.ledger?.prunePending(before: Date().addingTimeInterval(-30 * 86400))
                _ = self.persist(); self.render()
            }
        }
        guard settings.enabled, let folder, settings.ledger != nil else { render(); return }
        scans.request(folder)
    }

    private func receivedScan(_ result: Result<CaptureObservationBatch, Error>) {
        guard !fatalPersistenceError, !isQuitting, settings.enabled, settings.ledger != nil else { return }
        switch result {
        case .success(let observations):
            guard reconcile(observations) else { return }
            pump(reconciled: true); render()
        case .failure:
            attention = "Cannot read the watched folder. Restore Desktop access or choose the folder again."
            render()
        }
    }

    @discardableResult private func reconcile(_ batch: CaptureObservationBatch) -> Bool {
        guard settings.ledger != nil, !fatalPersistenceError, !isQuitting else { return false }
        let before = settings.ledger
        guard let result = queuePolicy.reconcile(batch, ledger: &settings.ledger!, active: activeCapture,
                                                authorization: mutationAuthorization) else { return false }
        overflow = result.overflow
        if result.invalidatedActiveCapture { work?.cancel() }
        return before == settings.ledger || persist()
    }

    private func pump(reconciled: Bool = false) {
        guard settings.enabled, !settings.paused, available, !busy, !fatalPersistenceError, !isQuitting,
              let folder else { return }
        // Completion and Resume request a fresh scan. A tick passes its existing
        // observations through to dispatch, without a second directory traversal.
        guard reconciled else { scans.request(folder); return }
        guard settings.ledger != nil, let job = queuePolicy.claim(from: &settings.ledger!) else { return }
        let source = folder.appendingPathComponent(job.name)
        guard persist() else { return }
        busy = true; transientDetail = "Naming a screenshot…"; render()
        let submittedGeneration = generation
        let client = analyzer
        let authorization = FileMutationAuthorization()
        mutationAuthorization = authorization
        activeCapture = job
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.mutationAuthorization = nil
                self.activeCapture = nil
                self.busy = false; self.work = nil; self.transientDetail = nil; self.render(); self.pump()
            }
            do {
                let pipeline = CaptureAnalysisPipeline(analyzer: client, snapshot: { [files = self.files] in
                    try await files.snapshot(at: $0)
                })
                let (snapshot, result) = try await pipeline.analyze(source, for: job) { [weak self] in
                    guard let self else { return false }
                    return submittedGeneration == self.generation && !self.settings.paused && !self.isQuitting &&
                        self.settings.ledger?.capture(job.id)?.identity == job.identity &&
                        self.settings.ledger?.capture(job.id)?.revision == job.revision
                }
                // Reconcile before applying so moves, replacements and paused/resumed sessions
                // invalidate outstanding submissions even if an old path exists again.
                let observations = try await self.files.observations(in: folder)
                self.reconcile(observations)
                guard !Task.isCancelled, submittedGeneration == self.generation, !self.settings.paused else {
                    self.resetForLater(job.id); return
                }
                let matches = try await self.files.matches(snapshot)
                guard !Task.isCancelled, submittedGeneration == self.generation,
                      let current = self.settings.ledger?.capture(job.id), current.identity == job.identity,
                      current.revision == job.revision, matches else {
                    self.resetForLater(job.id); return
                }
                if result.useful {
                    self.updateFileState(try await self.files.rename(snapshot, title: result.title, job: job, authorization: authorization))
                } else {
                    let title = (try? FilenamePolicy.validatedTitle(result.title)) ?? "No useful description"
                    self.settings.suggestions.append(ReviewSuggestion(original: job.name, proposed: title,
                        detail: "Original preserved · image needs review", date: Date()))
                    self.settings.suggestions = Array(self.settings.suggestions.suffix(100))
                }
                self.settings.ledger?.finish(job.id)
                self.attention = nil; _ = self.persist()
            } catch {
                // A post-rename journal failure must still stop processing if Pause
                // arrived while the background transaction was completing.
                if let state = try? await self.files.state() { self.updateFileState(state) }
                if self.isJournalFailure(error) { self.persistenceFailed(); return }
                if error is CancellationError || Task.isCancelled || submittedGeneration != self.generation {
                    self.resetForLater(job.id); return
                }
                if let observations = try? await self.files.observations(in: folder) { self.reconcile(observations) }
                if Task.isCancelled || submittedGeneration != self.generation { self.resetForLater(job.id); return }
                guard var current = self.settings.ledger?.capture(job.id) else { _ = self.persist(); return }
                if current.identity != job.identity || current.revision != job.revision {
                    // A failed request for the old version must not fail a fresh editor save.
                    if let error = error as? CodexAnalysisError,
                       error == .authenticationRequired || error == .quotaExceeded || error == .unavailable {
                        self.available = false; self.codexStatus = error.localizedDescription
                    }
                    _ = self.persist(); return
                }
                if let error = error as? CodexAnalysisError {
                    if self.queuePolicy.fail(&current, with: error) {
                        self.attention = "\(error.localizedDescription) A bounded retry is pending."
                    } else {
                        current.state = .failed; self.attention = "\(error.localizedDescription) Use Retry Pending when ready."
                        // Stop all further submissions when account availability needs attention.
                        if error == .authenticationRequired || error == .quotaExceeded || error == .unavailable {
                            self.available = false; self.codexStatus = error.localizedDescription
                        }
                    }
                } else {
                    current.state = .failed
                    self.attention = "The file changed, or a safe rename could not be completed. Check the file and History before retrying."
                }
                self.settings.ledger?.update(current); _ = self.persist()
            }
        }
    }

    private func resetForLater(_ id: UUID) {
        if settings.ledger != nil { queuePolicy.reset(id, in: &settings.ledger!) }
        _ = persist()
    }

    private func undo(_ id: UUID) {
        guard !busy, !fatalPersistenceError, !isQuitting else { return }
        busy = true; render()
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.work = nil; self.render(); self.pump() }
            do { self.updateFileState(try await self.files.undo(id)); self.attention = nil }
            catch {
                if let state = try? await self.files.state() { self.updateFileState(state) }
                if self.isJournalFailure(error) { self.persistenceFailed(); return }
                self.attention = "Undo could not safely restore this file. It may have been moved or edited, or its original name is occupied."
            }
        }
    }

    private func clearHistory() {
        guard !busy, !fatalPersistenceError, !isQuitting else { return }
        busy = true; render()
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.work = nil; self.render(); self.pump() }
            do {
                self.updateFileState(try await self.files.clearHistory())
                self.settings.suggestions = []; self.settings.previewSamples = nil; self.previews = []
                _ = self.persist()
            } catch { self.persistenceFailed() }
        }
    }

    @discardableResult private func persist() -> Bool {
        guard !fatalPersistenceError else { return false }
        do {
            let data = try JSONEncoder().encode(settings)
            try data.write(to: settingsURL, options: [.atomic, .completeFileProtectionUnlessOpen])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            return true
        } catch { persistenceFailed(); return false }
    }
    private func persistenceFailed() {
        fatalPersistenceError = true; generation += 1; mutationAuthorization?.cancel(); work?.cancel(); scans.invalidate()
        attention = "Local state could not be saved. Naming has stopped to protect your files. Check available disk space and restart the app."
        render()
    }

    private func updateFileState(_ state: CaptureFileService.State) {
        // Background completions can be delivered to the main actor out of order.
        guard state.revision >= (renamer?.revision ?? 0) else { return }
        renamer = state
    }

    private func isJournalFailure(_ error: Error) -> Bool {
        if renamer?.requiresRecovery == true { return true }
        if let fileError = error as? SafeFileError {
            switch fileError { case .journal, .recoveryRequired: return true; default: break }
        }
        return false
    }

    private func render() {
        guard ui != nil else { return }
        let failedCount = settings.ledger?.pending.filter { $0.state == .failed }.count ?? 0
        let status: String
        if fatalPersistenceError || (settings.enabled && folder == nil) { status = "Needs attention" }
        else if settings.enabled && settings.paused { status = "Paused" }
        else if busy { status = "Naming" }
        else if attention != nil || (!available && !checking) || overflow || failedCount > 0 { status = "Needs attention" }
        else if settings.enabled { status = "Watching" }
        else { status = "Ready to set up" }
        let pendingCount = settings.ledger?.pending.count ?? 0
        let detail = attention ?? transientDetail ?? (overflow ? "Queue is full (64 captures). Additional captures will be picked up as space becomes available." :
            settings.paused ? "No new images will be submitted or renamed. An image already submitted cannot be recalled." :
            failedCount > 0 ? "\(failedCount) captures need attention. Resolve the issue, then use Retry Pending." :
            settings.enabled ? "Watching for new screenshots · \(pendingCount) pending" : "Choose Desktop, preview generated samples, then enable automatic naming.")
        // Keep the journal snapshot so timer/status renders reuse its presentation.
        let historyEntries = renamer?.history ?? []
        if historyEntries != lastHistoryEntries {
            historyPresentation = historyEntries.sorted { $0.timestamp > $1.timestamp }.map {
                UIHistoryItem(id: $0.id, original: $0.originalURL.lastPathComponent, renamed: $0.newURL.lastPathComponent,
                              date: $0.timestamp, state: $0.state.rawValue, canUndo: $0.state == .renamed)
            }
            lastHistoryEntries = historyEntries
        }
        let history = historyPresentation
        let suggestions = settings.suggestions.reversed().map { UIPreviewItem(original: $0.original, proposed: $0.proposed, details: $0.detail) }
        let state = UIState(status: status, detail: detail, folder: folder?.path, codexStatus: codexStatus,
                          isEnabled: settings.enabled, isPaused: settings.paused, isBusy: busy || checking,
                          canEnable: settings.previewCompleted && available && folder != nil && renamer != nil && !fatalPersistenceError,
                          history: history, previews: previews + suggestions)
        if state != lastRendered { ui.update(state); lastRendered = state }
    }

    private func quit() {
        Task { [weak self] in
            await self?.stop()
            NSApplication.shared.terminate(nil)
        }
    }

    func stop() async {
        isQuitting = true
        generation += 1; mutationAuthorization?.cancel(); work?.cancel(); scans.invalidate(); watcher?.stop(); timer?.invalidate()
        _ = persist()
        // Allow the CLI cancellation handler to terminate its child and clean temporary files.
        await connectionCheck.stop()
        await work?.value
        await initialization?.value
        await maintenance?.value
        await scans.drain()
        await files.drain()
        if folderScope { folder?.stopAccessingSecurityScopedResource(); folderScope = false }
    }
}
