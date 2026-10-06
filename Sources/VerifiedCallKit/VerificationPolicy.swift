/// How long, and how often, to look for an effect before believing it is not there.
public struct VisibilityWindow: Sendable, Hashable {
    /// How long after dispatch an effect may take to become visible to the probe. An absence seen
    /// before this has elapsed proves nothing, so probing continues.
    public let settle: Duration
    /// The wait between two probes.
    public let interval: Duration
    /// The most probes spent on one reconciliation. Running out inside the settle window leaves
    /// the attempt unresolved.
    public let maxProbes: Int

    public init(settle: Duration, interval: Duration, maxProbes: Int) {
        self.settle = max(settle, .zero)
        self.interval = max(interval, .zero)
        self.maxProbes = max(1, maxProbes)
    }

    /// One probe, believed at once. Right for a store with read-your-writes consistency, and the
    /// setting that turns delayed visibility into duplicates everywhere else.
    public static let immediate = VisibilityWindow(settle: .zero, interval: .zero, maxProbes: 1)
}

/// What to do with an in-doubt attempt the probe could not settle.
public enum UnresolvedPolicy: String, Sendable, Hashable, CaseIterable {
    /// Stop and hand the decision back. Right for money, messages, and anything a person must not
    /// receive twice.
    case escalate
    /// Perform again with the same key. Safe only when the service deduplicates by key.
    case redoWithKey
    /// Perform again, accepting that the effect may now have happened twice. Each one is counted
    /// in the report as a risked redo.
    case redo
}

/// The rules one ``VerifiedCaller`` applies to every effect it runs.
public struct VerificationPolicy: Sendable, Hashable {
    /// Performs allowed per effect, including the first.
    public let maxAttempts: Int
    public let window: VisibilityWindow
    public let onUnresolved: UnresolvedPolicy
    /// Probe after a reported success too, to catch a write the service acknowledged and lost.
    public let confirmSuccess: Bool
    /// The wait before each attempt after the first. Probing time does not count toward it.
    public let retryDelay: Duration

    public init(
        maxAttempts: Int = 3,
        window: VisibilityWindow = .immediate,
        onUnresolved: UnresolvedPolicy = .escalate,
        confirmSuccess: Bool = false,
        retryDelay: Duration = .zero
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.window = window
        self.onUnresolved = onUnresolved
        self.confirmSuccess = confirmSuccess
        self.retryDelay = max(retryDelay, .zero)
    }
}
