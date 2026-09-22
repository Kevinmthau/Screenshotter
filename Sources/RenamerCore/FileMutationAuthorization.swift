import Foundation

/// Pause and shutdown revoke pending mutations synchronously. The lock covers only
/// the final rename syscall, never image hashing, journal writes or synchronization.
public final class FileMutationAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var allowed = true
    public init() {}
    public func cancel() { lock.lock(); allowed = false; lock.unlock() }
    func perform<T>(_ mutation: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard allowed else { throw CancellationError() }
        return try mutation()
    }
}
