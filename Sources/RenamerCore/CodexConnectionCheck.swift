import Foundation

/// Owns the connection-check task so replacement and shutdown wait for CLI cleanup.
@MainActor
public final class CodexConnectionCheck {
    private var task: Task<Void, Never>?
    private var stopped = false

    public init() {}

    public var isChecking: Bool { task != nil }

    public func start(check: @escaping @MainActor () async -> CodexAvailability,
                      receive: @escaping @MainActor (CodexAvailability) -> Void) {
        guard !stopped else { return }
        let previous = task
        previous?.cancel()
        task = Task { [weak self] in
            // Retain and drain canceled checks, including their subprocesses and
            // temporary directories, before starting the replacement.
            await previous?.value
            guard !Task.isCancelled else { return }
            let result = await check()
            guard !Task.isCancelled, let self else { return }
            self.task = nil
            receive(result)
        }
    }

    /// Permanently stops checks and waits for all outstanding cleanup.
    public func stop() async {
        stopped = true
        task?.cancel()
        await task?.value
        task = nil
    }
}
