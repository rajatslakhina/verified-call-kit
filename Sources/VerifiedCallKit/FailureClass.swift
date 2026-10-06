/// What a failed attempt says about its own effect.
///
/// The package turns on telling these apart. A retry policy that treats every failure as
/// `.retryable` repeats effects that already happened. One that treats every failure as final
/// gives up on calls the service never received.
public enum FailureClass: String, Sendable, Hashable, CaseIterable {
    /// The call did not take effect, and trying again may work: a 429, or a 503 returned before
    /// the request reached the service.
    case retryable
    /// The call did not take effect, and trying again would fail the same way: a 400, a 401.
    case rejected
    /// The call may have taken effect: a timeout after the request left, or a connection that
    /// dropped while the response was arriving. Only a probe can say which.
    case inDoubt
}

/// Maps an error thrown by an attempt to a ``FailureClass``.
///
/// `CancellationError` never reaches the rule. The caller handles it first, because a cancelled
/// attempt must not be retried or probed.
public struct FailureClassifier: Sendable {
    private let rule: @Sendable (any Error) -> FailureClass

    public init(_ rule: @escaping @Sendable (any Error) -> FailureClass) {
        self.rule = rule
    }

    public func classify(_ error: any Error) -> FailureClass {
        rule(error)
    }

    /// Treats every error as in doubt. This is the safe default when you cannot tell: nothing is
    /// repeated without looking first, at the price of a probe on failures that were harmless.
    public static let conservative = FailureClassifier { _ in .inDoubt }
}
