import AppKit
import Network
import RenamerCore

private struct ReviewSuggestion: Codable {
    var original: String
    var proposed: String
    var detail: String
    var date: Date
}

private struct SavedSettings: Codable {
    var folderBookmark: Data?
    var folderPath: String?
    var executablePath: String?
    var enabled = false
    var paused = false
    var ledger: CaptureLedger?
    var suggestions: [ReviewSuggestion] = []

    init() {}

    private enum CodingKeys: String, CodingKey {
        case folderBookmark, folderPath, executablePath, enabled, paused, ledger, suggestions
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        folderBookmark = try values.decodeIfPresent(Data.self, forKey: .folderBookmark)
        folderPath = try values.decodeIfPresent(String.self, forKey: .folderPath)
        executablePath = try values.decodeIfPresent(String.self, forKey: .executablePath)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        let savedPause = try values.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        paused = enabled && savedPause
        ledger = try values.decodeIfPresent(CaptureLedger.self, forKey: .ledger)
        suggestions = try values.decodeIfPresent([ReviewSuggestion].self, forKey: .suggestions) ?? []
    }
}

@MainActor final class AppController {
    private var ui: AppUI!
    private let updater: AppUpdater?
    private var settings = SavedSettings()
    private let support: URL
    private let settingsURL: URL
    private let codexExecutable: URL?
    private var renamer: CaptureFileService.State?
    private let files = CaptureFileService()
    private var queuePolicy = CaptureQueuePolicy()
    private var activeCapture: PendingCapture?
    private var mutationAuthorization: FileMutationAuthorization?
    private lazy var scans = CaptureScanScheduler(scan: { [weak self, files] in
        try await files.observations(in: $0, freshMetadata: self?.pendingNames ?? [])
    }, receive: { [weak self] in self?.receivedScan($0) })
    private var maintenance: Task<Void, Never>?
    private var initialization: Task<Void, Never>?
    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    private var periodicScans = PeriodicScanPolicy()
    private var folder: URL?
    private var folderScope = false
    private var choosingFolder = false
    private var work: Task<Void, Never>?
    private var busy = false
    private let connectionCheck = CodexConnectionCheck()
    private var checking: Bool { connectionCheck.isChecking }
    private var available = false
    private var attention: String?
    private var folderUnreadable = false
    private var codexStatus = "Checking saved Codex login…"
    // Set while Codex is unavailable. Checks are local and never submit an image.
    private var connectionIssue: CodexAnalysisError?
    // A check cannot confirm a problem reported by naming (a revoked login, a missing
    // model, a usage limit) is resolved; only a successful naming can.
    private var connectionIssueFromNaming = false
    private var connectionFailures = 0
    private var nextConnectionCheck: Date?
    private let network = NWPathMonitor()
    private var networkReachable = true
    private var generation = 0
    private var overflow = false
    private var fatalPersistenceError = false
    private var isQuitting = false
    private var transientDetail: String?
    private var loginNotice: String?
    private var wakeObserver: NSObjectProtocol?
    private var lastPruned = Date.distantPast
    private var lastRendered: UIState?
    private var lastHistoryEntries: [RenameJournalEntry] = []
    private var historyPresentation: [UIHistoryItem] = []

    init(updater: AppUpdater? = nil, supportDirectory: URL? = nil, defaultFolder: URL? = nil,
         registerLoginItem: Bool = true, codexExecutable: URL? = nil, monitorNetwork: Bool = true) {
        self.updater = updater
        self.codexExecutable = codexExecutable
        support = supportDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Screenshot Renamer", isDirectory: true)
        settingsURL = support.appendingPathComponent("settings.json")
        do {
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            if FileManager.default.fileExists(atPath: settingsURL.path) {
                settings = try JSONDecoder().decode(SavedSettings.self, from: Data(contentsOf: settingsURL))
            }
            settings.ledger?.prunePending(before: Date().addingTimeInterval(-30 * 86400))
            settings.ledger?.recoverAfterRestart()
            if let bookmark = settings.folderBookmark {
                var stale = false
                if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale) {
                    folder = resolved; folderScope = resolved.startAccessingSecurityScopedResource()
                    settings.folderPath = resolved.path
                    if stale, let refreshed = try? resolved.bookmarkData(options: [.withSecurityScope]) { settings.folderBookmark = refreshed }
                } else if let saved = AppController.savedFolder(atPath: settings.folderPath) {
                    // Each ad hoc build has a new code signature, which can invalidate a security-scoped
                    // bookmark. The app is not sandboxed, so the folder the person chose is still usable.
                    folder = saved
                    if let refreshed = try? saved.bookmarkData(options: [.withSecurityScope]) { settings.folderBookmark = refreshed }
                } else {
                    attention = "Folder access could not be restored. Choose the Desktop folder again."
                }
            } else {
                // An installed app starts on Desktop without a setup wizard. Reading
                // the folder still uses the normal macOS Desktop permission prompt.
                folder = settings.folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                    ?? defaultFolder
                    ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
                if let folder {
                    settings.folderPath = folder.path
                    folderScope = folder.startAccessingSecurityScopedResource()
                    settings.folderBookmark = try? folder.bookmarkData(options: [.withSecurityScope])
                } else {
                    attention = "Desktop could not be found. Choose a screenshot folder in Settings."
                }
            }
            // Folder scope is restored before the background service recovers the journal.
        } catch {
            fatalPersistenceError = true
            attention = "Saved state or folder access could not be restored. Quit and check the local data folder before retrying."
        }
        ui = AppUI(actions: UIActions(
            chooseFolder: { [weak self] in self?.chooseFolder() },
            togglePause: { [weak self] in self?.togglePause() },
            retry: { [weak self] in self?.retry() },
            undo: { [weak self] id in self?.undo(id) },
            clearHistory: { [weak self] in self?.clearHistory() },
            checkCodex: { [weak self] in self?.checkCodex() },
            chooseCodex: { [weak self] in self?.chooseCodex() },
            checkForUpdates: { [weak updater] in updater?.checkForUpdates() },
            toggleAutomaticUpdates: { [weak updater] in updater?.toggleAutomaticChecks() },
            quit: { [weak self] in self?.quit() }
        ))
        updater?.stateChanged = { [weak self] _ in self?.render() }
        if registerLoginItem { loginNotice = ui.enableLoginAtStartup() }
        initialization = Task { [weak self] in
            guard let self else { return }
            defer { self.initialization = nil }
            do {
                self.updateFileState(try await self.files.open(journalURL: self.support.appendingPathComponent("history.json")))
                guard !self.isQuitting else { return }
                self.startAutomaticNaming()
            } catch {
                guard !self.isQuitting else { return }
                self.fatalPersistenceError = true
                self.attention = "Rename history could not be restored. Restore folder access and restart; the history has been preserved."
                self.render(); self.ui.showWindow()
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick(periodic: true) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        // At login and after wake the network can arrive after the app. Offline captures wait
        // for it instead of using up their attempts.
        network.pathUpdateHandler = { [weak self] path in
            MainActor.assumeIsolated { self?.networkChanged(path.status != .unsatisfied) }
        }
        if monitorNetwork { network.start(queue: .main) }
        render()
        if attention != nil { ui.showWindow() }
        checkCodex()
    }

    func showWindow() { ui.showWindow() }
    private var analyzer: CodexAnalyzer {
        CodexAnalyzer(executableOverride: codexExecutable ?? settings.executablePath.map { URL(fileURLWithPath: $0) })
    }

    private static func savedFolder(atPath path: String?) -> URL? {
        guard let path else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Late Spotlight rejection can still cancel these, so their answers are never reused.
    private var pendingNames: Set<String> { Set(settings.ledger?.pending.map(\.name) ?? []) }

    private func chooseFolder() {
        guard !busy, !choosingFolder, initialization == nil, !fatalPersistenceError, !isQuitting else { return }
        // The folder picker runs a nested event loop. Keep scanning, but defer
        // model dispatch until it closes so changing folders cannot race a job.
        choosingFolder = true
        defer { choosingFolder = false; pump() }
        let panel = NSOpenPanel()
        panel.title = "Choose Your Desktop Folder"
        panel.message = "Grant access to the Desktop folder where macOS saves screenshots. Existing files will be left alone."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let selected = panel.url, !isQuitting else { return }
        do {
            let bookmark = try selected.bookmarkData(options: [.withSecurityScope])
            generation += 1; mutationAuthorization?.cancel(); work?.cancel(); scans.invalidate(); watcher?.stop(); watcher = nil
            let previousFolder = folder, previousScope = folderScope
            Task { [files] in
                await files.drain()
                if previousScope { previousFolder?.stopAccessingSecurityScopedResource() }
            }
            folder = selected; folderScope = selected.startAccessingSecurityScopedResource()
            settings.folderBookmark = bookmark; settings.folderPath = selected.path
            settings.enabled = false; settings.paused = false; settings.ledger = nil
            attention = nil; folderUnreadable = false
            guard persist() else { return }
            startAutomaticNaming()
        } catch { attention = "Folder access was not granted. Choose the folder again."; render() }
    }

    private func chooseCodex() {
        guard !busy, !isQuitting else { return }
        let panel = NSOpenPanel(); panel.title = "Locate the Codex CLI"
        panel.message = "Choose the codex executable, Codex.app, or ChatGPT.app."
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url, !busy, !isQuitting else { return }
        guard let executable = try? CodexAnalyzer(executableOverride: url).resolveExecutable() else {
            attention = "Choose a Codex CLI executable or a Codex or ChatGPT app containing it."; render(); return
        }
        settings.executablePath = executable.path; available = false; attention = nil
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
                if !self.connectionIssueFromNaming { self.connectionFailures = 0 }
                self.connectionIssue = nil; self.nextConnectionCheck = nil
                if !self.fatalPersistenceError, !self.folderUnreadable, self.folder != nil, self.settings.enabled { self.attention = nil }
            case .unavailable(let error):
                self.connectionLost(error, duringNaming: false)
            }
            self.render(); self.tick()
        }
        render()
    }

    /// Stops new submissions and schedules a connection check: within seconds after a slow or
    /// failed response, minutes for sign-in and CLI problems, and within the hour for usage limits.
    private func connectionLost(_ error: CodexAnalysisError, duringNaming: Bool) {
        available = false
        connectionIssue = error
        // A later failed check (for example a timeout) does not settle a naming problem.
        if duringNaming { connectionIssueFromNaming = true }
        codexStatus = error.isRetryable ? "Codex did not respond. Checking again automatically." : error.localizedDescription
        connectionFailures += 1
        nextConnectionCheck = Date().addingTimeInterval(
            CaptureQueuePolicy.connectionCheckDelay(after: error, consecutiveFailures: connectionFailures))
    }

    private func networkChanged(_ reachable: Bool) {
        guard reachable != networkReachable else { return }
        networkReachable = reachable
        render()
        if reachable { tick() }
    }

    private func startAutomaticNaming() {
        guard !busy, !fatalPersistenceError, !isQuitting, renamer != nil, let folder else { render(); return }
        if settings.ledger != nil {
            if !settings.enabled {
                settings.enabled = true
                guard persist() else { return }
            }
            startWatching(); tick(); return
        }
        busy = true; transientDetail = "Starting automatic naming…"; render()
        let submittedGeneration = generation
        work = Task { [weak self] in
            guard let self else { return }
            defer {
                self.busy = false; self.work = nil; self.transientDetail = nil
                self.render(); self.tick()
            }
            do {
                // Establish the baseline even while Codex is unavailable, so an
                // existing screenshot never becomes eligible after reconnecting.
                let baseline = try await self.files.observations(in: folder)
                guard !Task.isCancelled, !self.isQuitting, self.generation == submittedGeneration else { return }
                self.scans.invalidate()
                self.settings.ledger = CaptureLedger(baseline: baseline.files, activatedAt: Date())
                self.settings.enabled = true; self.settings.paused = false; self.attention = nil; self.folderUnreadable = false
                guard self.persist() else { return }
                self.startWatching()
            } catch {
                guard !Task.isCancelled, !self.isQuitting, self.generation == submittedGeneration else { return }
                if !self.folderUnreadable { self.ui.showWindow() }
                self.folderUnreadable = true
                self.attention = "Allow Desktop access when macOS asks. If access was denied, restore it in System Settings or choose the folder here."
            }
        }
    }

    private func startWatching() {
        guard let folder else { return }
        // A watcher that failed to restart must read as missing, keeping two-second reconciliation.
        watcher?.stop(); watcher = nil
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
        settings.ledger?.retryFailures(); attention = nil; connectionFailures = 0; connectionIssueFromNaming = false
        _ = persist()
        if !available { checkCodex() }
        if !settings.enabled || settings.ledger == nil { startAutomaticNaming() }
        else { tick() }
    }

    private func tick(periodic: Bool = false) {
        guard !fatalPersistenceError, !isQuitting, renamer != nil else { return }
        if Date().timeIntervalSince(lastPruned) > 3600, maintenance == nil {
            maintenance = Task { [weak self] in
                guard let self else { return }
                defer { self.maintenance = nil }
                do { self.updateFileState(try await self.files.pruneHistory()); self.lastPruned = Date() }
                catch { self.persistenceFailed(); return }
                guard !self.isQuitting else { return }
                self.settings.suggestions.removeAll { Date().timeIntervalSince($0.date) > 30 * 86400 }
                self.settings.ledger?.prunePending(before: Date().addingTimeInterval(-30 * 86400))
                _ = self.persist(); self.render()
            }
        }
        // Checks are local and submit nothing, so they also run during startup and while paused.
        if !available, !checking, !busy, let due = nextConnectionCheck, Date() >= due {
            nextConnectionCheck = nil
            checkCodex()
        }
        guard settings.enabled, let folder, let ledger = settings.ledger else {
            if periodic, folderUnreadable, !choosingFolder { startAutomaticNaming() }
            else { render() }
            return
        }
        // Maintenance and connection checks above run on every tick; only the timer's own scan
        // backs off while idle. An unreadable folder recovers on its next successful scan, so it
        // keeps the two-second cadence; each failed scan is cheap.
        guard periodicScans.shouldScan(periodic: periodic, watching: watcher != nil && !folderUnreadable,
                                       pending: !ledger.pending.isEmpty) else { return }
        scans.request(folder)
    }

    private func receivedScan(_ result: Result<CaptureObservationBatch, Error>) {
        guard !fatalPersistenceError, !isQuitting, settings.enabled, settings.ledger != nil else { return }
        switch result {
        case .success(let observations):
            // A folder that was briefly unreadable (for example during login) recovers here.
            if folderUnreadable { folderUnreadable = false; render() }
            guard reconcile(observations) else { return }
            pump(reconciled: true); render()
        case .failure:
            folderUnreadable = true
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
        // Naming waits for a running check, so an older check result cannot hide a newer failure.
        guard settings.enabled, !settings.paused, available, !checking, networkReachable, !busy, !choosingFolder, !fatalPersistenceError,
              !isQuitting, let folder else { return }
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
                let observations = try await self.files.observations(in: folder, freshMetadata: self.pendingNames)
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
                // A title that cannot form a safe filename (for example, too long) is treated like an
                // image without a useful description, rather than as a failed capture.
                let usable = result.useful && (try? FilenamePolicy.filename(title: result.title, captureDate: job.captureDate,
                    originalExtension: source.pathExtension, captureDay: job.namingDay)) != nil
                if usable {
                    self.updateFileState(try await self.files.rename(snapshot, title: result.title, job: job, authorization: authorization))
                } else if result.useful {
                    self.recordForReview(job, proposed: result.title, reason: "suggested name could not be used")
                } else {
                    self.recordForReview(job, proposed: (try? FilenamePolicy.validatedTitle(result.title)) ?? "No useful description",
                                         reason: "image needs review")
                }
                self.settings.ledger?.finish(job.id)
                self.attention = nil; self.connectionFailures = 0; self.connectionIssueFromNaming = false
                _ = self.persist()
            } catch {
                // A post-rename journal failure must still stop processing if Pause
                // arrived while the background transaction was completing.
                if let state = try? await self.files.state() { self.updateFileState(state) }
                if self.isJournalFailure(error) { self.persistenceFailed(); return }
                if error is CancellationError || Task.isCancelled || submittedGeneration != self.generation {
                    self.resetForLater(job.id); return
                }
                if let observations = try? await self.files.observations(in: folder, freshMetadata: self.pendingNames) {
                    self.reconcile(observations)
                }
                if Task.isCancelled || submittedGeneration != self.generation { self.resetForLater(job.id); return }
                guard var current = self.settings.ledger?.capture(job.id) else { _ = self.persist(); return }
                if current.identity != job.identity || current.revision != job.revision {
                    // A failed request for the old version must not fail a fresh editor save.
                    if let error = error as? CodexAnalysisError,
                       error == .authenticationRequired || error == .quotaExceeded || error == .unavailable {
                        self.connectionLost(error, duringNaming: true)
                    }
                    _ = self.persist(); return
                }
                if let error = error as? CodexAnalysisError {
                    switch self.queuePolicy.fail(&current, with: error) {
                    case .retryScheduled:
                        break
                    case .awaitingConnection:
                        // Stop all further submissions until a connection check succeeds. Other
                        // captures go first then, in case this failure is specific to this image.
                        self.connectionLost(error, duringNaming: true)
                        self.settings.ledger?.moveToBack(current.id)
                    case .keepOriginal:
                        self.recordForReview(job, proposed: "No usable name", reason: error.localizedDescription)
                        self.settings.ledger?.finish(job.id)
                        _ = self.persist(); return
                    case .failed:
                        self.attention = "\(error.localizedDescription) Use Retry Pending when ready."
                        // Sign-in, usage and CLI problems still stop further submissions.
                        if !error.isRetryable { self.connectionLost(error, duringNaming: true) }
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

    /// The screenshot keeps its original name and the outcome is listed under Needs review in Settings.
    private func recordForReview(_ job: PendingCapture, proposed: String, reason: String) {
        settings.suggestions.append(ReviewSuggestion(original: job.name, proposed: proposed,
                                                     detail: "Original preserved · \(reason)", date: Date()))
        settings.suggestions = Array(settings.suggestions.suffix(100))
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
                self.settings.suggestions = []
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
        let pending = settings.ledger?.pending ?? []
        let failedCount = pending.filter { $0.state == .failed }.count
        let retryingCount = pending.filter { $0.state == .retry }.count
        // A known problem stays reported while an automatic check runs. A slow or failed
        // connection check is retried automatically and needs the person only if it persists.
        let codexProblem = !available && (!checking || connectionIssue != nil)
        let reconnecting = codexProblem && connectionIssue?.isRetryable == true && connectionFailures < 5
        let codexNeedsAttention = codexProblem && !reconnecting
        // A slow or failed check describes the check, not a naming request.
        let codexMessage = connectionIssue.map { $0.isRetryable ? "Codex did not respond." : $0.localizedDescription } ?? codexStatus
        let status: String
        if fatalPersistenceError || (settings.enabled && folder == nil) { status = "Needs attention" }
        else if settings.enabled && settings.paused { status = "Paused" }
        else if busy { status = settings.enabled ? "Naming" : "Starting" }
        else if attention != nil || folderUnreadable || codexNeedsAttention || overflow || failedCount > 0 { status = "Needs attention" }
        else if !settings.enabled || (checking && connectionIssue == nil) { status = "Starting" }
        else { status = "Watching" }
        let activity: String
        if let message = attention ?? transientDetail { activity = message }
        else if settings.enabled && folder == nil { activity = "Folder access could not be restored. Choose the Desktop folder again." }
        else if folderUnreadable { activity = "Cannot read the watched folder. Restore Desktop access or choose the folder again." }
        else if overflow { activity = "Queue is full (64 captures). Additional captures will be picked up as space becomes available." }
        else if settings.paused { activity = "No new images will be submitted or renamed. An image already submitted cannot be recalled." }
        else if failedCount > 0 { activity = "\(failedCount) captures need attention. Resolve the issue, then use Retry Pending." }
        else if codexNeedsAttention {
            activity = settings.enabled ? "\(codexMessage) Naming resumes automatically once Codex is available." : codexMessage
        }
        else if !settings.enabled { activity = "Starting automatic naming…" }
        else if checking && connectionIssue == nil { activity = "Checking Codex before naming new screenshots…" }
        else if reconnecting { activity = "Codex did not respond. Retrying automatically · \(pending.count) pending" }
        else if !networkReachable && !pending.isEmpty { activity = "Waiting for a network connection · \(pending.count) pending" }
        else if retryingCount > 0 { activity = "Watching for new screenshots · \(pending.count) pending, \(retryingCount) retrying automatically" }
        else { activity = "Watching for new screenshots · \(pending.count) pending" }
        let detail = loginNotice.map { "\(activity) \($0)" } ?? activity
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
        let suggestions = settings.suggestions.reversed().map { UICaptureSuggestion(original: $0.original, proposed: $0.proposed, details: $0.detail) }
        // Automatic rechecks of a known problem run in the background without disabling controls.
        let state = UIState(status: status, detail: detail, folder: folder?.path, codexStatus: codexStatus,
                          isEnabled: settings.enabled, isPaused: settings.paused, isBusy: busy || (checking && connectionIssue == nil),
                          history: history, suggestions: suggestions, updates: updater?.state ?? UIUpdateState())
        if state != lastRendered { ui.update(state); lastRendered = state }
    }

    private func quit() {
        NSApplication.shared.terminate(nil)
    }

    func stop() async {
        isQuitting = true
        generation += 1; mutationAuthorization?.cancel(); work?.cancel(); scans.invalidate(); watcher?.stop(); timer?.invalidate()
        network.cancel()
        _ = persist()
        // Allow the CLI cancellation handler to terminate its child and clean temporary files.
        await connectionCheck.stop()
        await work?.value
        await initialization?.value
        await maintenance?.value
        await scans.drain()
        await files.drain()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if folderScope { folder?.stopAccessingSecurityScopedResource(); folderScope = false }
    }
}
