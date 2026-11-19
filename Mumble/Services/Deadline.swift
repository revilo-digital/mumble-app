import Synchronization

/// Waits for `work` until `limit`, then gives up on it (and cancels it). nil means it ran out of time.
/// Doesn't wait for the work to stop, so a model that ignores cancellation can't hold things up.
func result<T: Sendable>(of work: Task<T, Error>, within limit: Duration) async -> Result<T, Error>? {
    let once = ResumeOnceLocked<Result<T, Error>?>()
    return await withCheckedContinuation { continuation in
        once.start(continuation)
        Task { once.resume(await work.result) }
        Task {
            try? await Task.sleep(for: limit)
            work.cancel()
            once.resume(nil)
        }
    }
}

/// Resumes a continuation once, whichever of the racing tasks gets there first.
private final class ResumeOnceLocked<Value: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<Value, Never>?>(nil)

    func start(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(_ value: Value) {
        continuation.withLock { continuation in
            continuation?.resume(returning: value)
            continuation = nil
        }
    }
}
