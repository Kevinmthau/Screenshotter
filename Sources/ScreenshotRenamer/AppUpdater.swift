import AppKit
import Sparkle

/// Sparkle owns update scheduling, preference persistence, verification and installation.
/// Keeping this adapter separate lets the UI harness run without starting an updater.
@MainActor
final class AppUpdater: NSObject, @preconcurrency SPUStandardUserDriverDelegate {
    var stateChanged: ((UIUpdateState) -> Void)?
    private var controller: SPUStandardUpdaterController!
    private var observations: [NSKeyValueObservation] = []
    private var started = false
    private var availableVersion: String?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: self)
        observations = [
            controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.publishState() }
            },
            controller.updater.observe(\.automaticallyChecksForUpdates, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.publishState() }
            }
        ]
    }

    var state: UIUpdateState {
        UIUpdateState(isAvailable: started, canCheck: started && controller.updater.canCheckForUpdates,
                      automaticallyChecks: controller.updater.automaticallyChecksForUpdates,
                      availableVersion: availableVersion)
    }

    func start() {
        guard !started else { return }
        started = true
        controller.startUpdater()
        publishState()
    }

    func checkForUpdates() {
        guard state.canCheck else { return }
        controller.checkForUpdates(nil)
        publishState()
    }

    func toggleAutomaticChecks() {
        guard started else { return }
        // Set only in response to the user's action; Sparkle saves this preference.
        controller.updater.automaticallyChecksForUpdates.toggle()
        publishState()
    }

    // A menu-bar app can stay in the background for days. Keep a visible reminder
    // in its menu instead of putting a scheduled update window behind other apps.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
        publishState()
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        availableVersion = nil
        publishState()
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
        publishState()
    }

    private func publishState() { stateChanged?(state) }
}
