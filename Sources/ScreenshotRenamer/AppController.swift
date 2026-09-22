import AppKit
import CoreServices
import Darwin
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
    private var renamer: SafeFileRenamer?
    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    private var folder: URL?
    private var folderScope = false
    private var work: Task<Void, Never>?
    private var busy = false
    private var checking = false
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
            // Restore folder access before inspecting files for interrupted rename recovery.
            renamer = try SafeFileRenamer(journalURL: support.appendingPathComponent("history.json"))
        } catch {
            fatalPersistenceError = true
            if case SafeFileError.recoveryRequired = error {
                attention = "An interrupted rename could not be checked. Restore access to the screenshot folder and restart the app; rename history has been preserved."
            } else {
                attention = "Saved state or folder access could not be restored. Quit and check the local data folder before retrying."
            }
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
        if settings.enabled, folder != nil, !fatalPersistenceError { startWatching() }
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
        guard !busy, !fatalPersistenceError else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Your Desktop Folder"
        panel.message = "Grant access to the Desktop folder where macOS saves screenshots. Existing files will be left alone."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.prompt = "Use This Folder"
        guard panel.runModal() == .OK, let selected = panel.url else { return }
        do {
            let bookmark = try selected.bookmarkData(options: [.withSecurityScope])
            _ = try FileManager.default.contentsOfDirectory(at: selected, includingPropertiesForKeys: nil)
            generation += 1; work?.cancel(); watcher?.stop(); watcher = nil
            if folderScope { folder?.stopAccessingSecurityScopedResource() }
            folder = selected; folderScope = selected.startAccessingSecurityScopedResource()
            settings.folderBookmark = bookmark; settings.folderPath = selected.path
            settings.enabled = false; settings.paused = false; settings.ledger = nil
            attention = nil
            _ = persist(); render()
        } catch { attention = "Folder access was not granted. Choose the folder again."; render() }
    }

    private func chooseCodex() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "Locate the Codex CLI"
        panel.message = "Choose the codex executable. The app otherwise checks standard install locations and installed Codex or ChatGPT apps."
        panel.canChooseDirectories = false; panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard FileManager.default.isExecutableFile(atPath: url.path) else {
            attention = "Choose an executable Codex CLI file."; render(); return
        }
        settings.executablePath = url.path; available = false; settings.previewCompleted = false
        _ = persist(); checkCodex()
    }

    private func checkCodex() {
        guard !checking, !busy, !isQuitting else { return }
        checking = true; codexStatus = "Checking saved Codex login…"; render()
        let client = analyzer
        Task { [weak self] in
            let result = await client.checkAvailability()
            guard let self else { return }
            self.checking = false
            switch result {
            case .available:
                self.available = true; self.codexStatus = "Codex is available · saved login verified"
                if !self.fatalPersistenceError && (self.folder != nil || !self.settings.enabled) { self.attention = nil }
            case .unavailable(let error):
                self.available = false; self.codexStatus = error.localizedDescription
            }
            self.render(); self.tick()
        }
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
        guard settings.previewCompleted, available, let folder, !busy, !fatalPersistenceError else { return }
        do {
            let baseline = try observations(in: folder)
            settings.ledger = CaptureLedger(baseline: baseline, activatedAt: Date())
            settings.enabled = true; settings.paused = false; attention = nil
            guard persist() else { return }
            startWatching(); tick()
        } catch { attention = "Cannot read the selected folder. Choose it again to restore access."; render() }
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
        if settings.paused { work?.cancel() }
        _ = persist(); render()
        if !settings.paused { tick() }
    }

    private func retry() {
        guard !fatalPersistenceError, !isQuitting else { return }
        settings.ledger?.retryFailures(); attention = nil; _ = persist()
        if available { tick() } else { checkCodex() }
    }

    private func tick() {
        guard !fatalPersistenceError else { return }
        if Date().timeIntervalSince(lastPruned) > 3600 {
            do { try renamer?.pruneHistory(); lastPruned = Date() }
            catch { persistenceFailed(); return }
            settings.suggestions.removeAll { Date().timeIntervalSince($0.date) > 30 * 86400 }
            settings.previewSamples?.removeAll { Date().timeIntervalSince($0.date) > 30 * 86400 }
            settings.ledger?.prunePending(before: Date().addingTimeInterval(-30 * 86400))
            _ = persist()
        }
        guard settings.enabled, let folder, settings.ledger != nil else { render(); return }
        do {
            let files = try observations(in: folder)
            let before = settings.ledger
            overflow = settings.ledger!.reconcile(files)
            if before != settings.ledger { guard persist() else { return } }
            pump(); render()
        } catch { attention = "Cannot read the watched folder. Restore Desktop access or choose the folder again."; render() }
    }

    private func observations(in directory: URL) throws -> [CaptureObservation] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
            let identity = "\(UInt64(UInt32(bitPattern: info.st_dev))):\(info.st_ino)"
            let revision = "\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
            let created = Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1_000_000_000)
            var metadata: Bool?
            if ScreenshotRecognition.isCandidate(name: url.lastPathComponent), let item = MDItemCreate(nil, url.path as CFString) {
                metadata = (MDItemCopyAttribute(item, "kMDItemIsScreenCapture" as CFString) as? NSNumber)?.boolValue
            }
            return CaptureObservation(name: url.lastPathComponent, identity: identity, revision: revision, created: created,
                                      captureDate: ScreenshotRecognition.captureDate(name: url.lastPathComponent, fallback: created),
                                      eligible: ScreenshotRecognition.isCandidate(name: url.lastPathComponent, metadataIsScreenshot: metadata))
        }
    }

    private func pump() {
        guard settings.enabled, !settings.paused, available, !busy, !fatalPersistenceError, !isQuitting,
              let folder else { return }
        // Every submission starts with reconciliation, including launch, Resume and
        // completion-driven queue advancement. Never upload a stale persisted path.
        do {
            let before = settings.ledger
            overflow = settings.ledger?.reconcile(try observations(in: folder)) ?? false
            if before != settings.ledger { guard persist() else { return } }
        } catch {
            attention = "Cannot read the watched folder. Restore folder access before retrying."
            return
        }
        guard var job = settings.ledger?.nextReady() else { return }
        let source = folder.appendingPathComponent(job.name)
        job.state = .analyzing; job.attempts += 1
        settings.ledger?.update(job)
        guard persist() else { return }
        busy = true; transientDetail = "Naming a screenshot…"; render()
        let submittedGeneration = generation
        let client = analyzer
        work = Task { [weak self] in
            guard let self else { return }
            defer { self.busy = false; self.work = nil; self.transientDetail = nil; self.render(); self.pump() }
            do {
                let snapshot = try FileSnapshot.capture(at: source)
                guard "\(snapshot.identity.device):\(snapshot.identity.inode)" == job.identity else {
                    self.resetForLater(job.id); return
                }
                guard job.revision.hasPrefix("\(snapshot.size):\(snapshot.modificationSeconds):\(snapshot.modificationNanoseconds):") else {
                    self.resetForLater(job.id); return
                }
                let result = try await client.analyze(source)
                // Reconcile before applying so moves, replacements and paused/resumed sessions
                // invalidate outstanding submissions even if an old path exists again.
                let files = try self.observations(in: folder)
                self.settings.ledger?.reconcile(files)
                guard !Task.isCancelled, submittedGeneration == self.generation, !self.settings.paused else {
                    self.resetForLater(job.id); return
                }
                guard let current = self.settings.ledger?.capture(job.id), current.identity == job.identity,
                      current.revision == job.revision, try snapshot.matchesCurrentFile() else {
                    self.resetForLater(job.id); return
                }
                if result.useful {
                    guard let renamer = self.renamer else { self.persistenceFailed(); return }
                    _ = try renamer.rename(snapshot, title: result.title, captureDate: job.captureDate, captureDay: job.namingDay)
                } else {
                    let title = (try? FilenamePolicy.validatedTitle(result.title)) ?? "No useful description"
                    self.settings.suggestions.append(ReviewSuggestion(original: job.name, proposed: title,
                        detail: "Original preserved · image needs review", date: Date()))
                    self.settings.suggestions = Array(self.settings.suggestions.suffix(100))
                }
                self.settings.ledger?.finish(job.id)
                self.attention = nil; _ = self.persist()
            } catch is CancellationError {
                self.resetForLater(job.id)
            } catch {
                if Task.isCancelled || submittedGeneration != self.generation { self.resetForLater(job.id); return }
                if self.isJournalFailure(error) { self.persistenceFailed(); return }
                if let files = try? self.observations(in: folder) { self.settings.ledger?.reconcile(files) }
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
                    if error.isRetryable && current.attempts < 3 {
                        current.state = .retry
                        current.nextAttempt = Date().addingTimeInterval(current.attempts == 1 ? 15 : 60)
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
        if var job = settings.ledger?.capture(id) {
            job.state = .waiting; job.stableSince = Date(); job.nextAttempt = .distantPast
            settings.ledger?.update(job)
        }
        _ = persist()
    }

    private func undo(_ id: UUID) {
        guard !fatalPersistenceError else { return }
        do { _ = try renamer?.undo(entryID: id); attention = nil }
        catch {
            if isJournalFailure(error) { persistenceFailed(); return }
            attention = "Undo could not safely restore this file. It may have been moved or edited, or its original name is occupied."
        }
        render()
    }
    private func clearHistory() {
        guard !busy, !fatalPersistenceError else { return }
        do {
            try renamer?.clearHistory(); settings.suggestions = []; settings.previewSamples = nil; previews = []
            _ = persist(); render()
        } catch { persistenceFailed() }
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
        fatalPersistenceError = true; generation += 1; work?.cancel()
        attention = "Local state could not be saved. Naming has stopped to protect your files. Check available disk space and restart the app."
        render()
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
        let history = (renamer?.history ?? []).sorted { $0.timestamp > $1.timestamp }.map {
            UIHistoryItem(id: $0.id, original: $0.originalURL.lastPathComponent, renamed: $0.newURL.lastPathComponent,
                          date: $0.timestamp, state: $0.state.rawValue, canUndo: $0.state == .renamed)
        }
        let suggestions = settings.suggestions.reversed().map { UIPreviewItem(original: $0.original, proposed: $0.proposed, details: $0.detail) }
        let state = UIState(status: status, detail: detail, folder: folder?.path, codexStatus: codexStatus,
                          isEnabled: settings.enabled, isPaused: settings.paused, isBusy: busy || checking,
                          canEnable: settings.previewCompleted && available && folder != nil && !fatalPersistenceError,
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
        generation += 1; work?.cancel(); watcher?.stop(); timer?.invalidate()
        _ = persist()
        // Allow the CLI cancellation handler to terminate its child and clean temporary files.
        await work?.value
        if folderScope { folder?.stopAccessingSecurityScopedResource(); folderScope = false }
    }
}
