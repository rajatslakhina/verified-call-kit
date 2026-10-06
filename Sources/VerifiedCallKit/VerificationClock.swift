/// The time source for settle windows, probe intervals and retry delays.
///
/// A protocol rather than `ContinuousClock` so that tests and demos can run a 30-second
/// visibility window in no time and get the same answer every run.
public protocol VerificationClock: Sendable {
    /// Time elapsed since the clock's own origin.
    func now() async -> Duration
    /// Waits, or throws `CancellationError` if the task is cancelled.
    func sleep(for duration: Duration) async throws
}

/// Wall-clock time, measured with `ContinuousClock`.
public struct SystemVerificationClock: VerificationClock {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        origin = clock.now
    }

    public func now() async -> Duration {
        origin.duration(to: clock.now)
    }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

/// Virtual time: `sleep` moves the clock forward at once instead of waiting.
public actor ManualVerificationClock: VerificationClock {
    private var elapsed: Duration

    public init(start: Duration = .zero) {
        elapsed = start
    }

    public func now() -> Duration {
        elapsed
    }

    public func sleep(for duration: Duration) async throws {
        try Task.checkCancellation()
        elapsed += max(duration, .zero)
    }

    /// Moves the clock forward without anyone sleeping, as time passing between two runs would.
    public func advance(by duration: Duration) {
        elapsed += max(duration, .zero)
    }
}
