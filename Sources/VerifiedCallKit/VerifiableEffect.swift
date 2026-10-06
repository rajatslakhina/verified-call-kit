/// One attempt at an effect, as the effect and its probe see it.
public struct AttemptContext: Sendable, Hashable {
    /// The logical operation's key, the same on every attempt. Send it to services that
    /// deduplicate by key, and look the effect up by it in the probe, so that an earlier attempt's
    /// effect is found as well as this one's.
    public let key: String
    /// 1-based. A plan's pre-probe uses 0, because it looks for an effect left by an earlier run.
    public let attempt: Int
    /// The verification clock's reading when this attempt was dispatched.
    public let dispatchedAt: Duration

    public init(key: String, attempt: Int, dispatchedAt: Duration) {
        self.key = key
        self.attempt = attempt
        self.dispatchedAt = dispatchedAt
    }
}

/// A side effect that can be performed, and looked for without being performed.
public protocol VerifiableEffect: Sendable {
    associatedtype Output: Sendable

    /// Identifies the logical operation across attempts and across runs.
    var key: String { get }

    /// Performs the effect once.
    func perform(_ context: AttemptContext) async throws -> Output

    /// Looks for the effect by `context.key`. It must not have side effects of its own.
    ///
    /// Look up by key, not by attempt: a ``ProbeReading/absent`` reading after the settle window
    /// is taken to mean that no attempt under this key took effect.
    func probe(_ context: AttemptContext) async throws -> ProbeReading<Output>
}

/// A ``VerifiableEffect`` built from two closures.
public struct ClosureEffect<Output: Sendable>: VerifiableEffect {
    public let key: String
    private let performBody: @Sendable (AttemptContext) async throws -> Output
    private let probeBody: @Sendable (AttemptContext) async throws -> ProbeReading<Output>

    public init(
        key: String,
        perform: @escaping @Sendable (AttemptContext) async throws -> Output,
        probe: @escaping @Sendable (AttemptContext) async throws -> ProbeReading<Output>
    ) {
        self.key = key
        self.performBody = perform
        self.probeBody = probe
    }

    public func perform(_ context: AttemptContext) async throws -> Output {
        try await performBody(context)
    }

    public func probe(_ context: AttemptContext) async throws -> ProbeReading<Output> {
        try await probeBody(context)
    }
}
