/// What happened on one attempt.
public enum AttemptVerdict: Sendable, Hashable, CustomStringConvertible {
    /// The service reported success, and no confirmation was asked for.
    case succeeded
    /// The service reported success, and a probe saw the effect.
    case succeededAndSeen(probes: Int)
    /// The service reported success, but no probe saw the effect. `conclusive` is true when the
    /// settle window passed with the effect absent: a lost write.
    case succeededNotSeen(probes: Int, conclusive: Bool)
    /// The attempt failed before taking effect, and another attempt followed or was allowed.
    case retryable(String)
    /// The attempt failed before taking effect, and trying again would not help.
    case rejected(String)
    /// The attempt failed in doubt and a probe found its effect. `late` is true when an earlier
    /// probe in the same reconciliation had read it as absent.
    case inDoubtApplied(probes: Int, late: Bool)
    /// The attempt failed in doubt and the effect was still absent once the settle window passed.
    case inDoubtAbsent(probes: Int)
    /// The attempt failed in doubt and the probes could not settle it.
    case inDoubtUnresolved(probes: Int, reason: String)
    /// The task was cancelled while the attempt ran.
    case cancelled

    /// Probes spent on this attempt.
    public var probes: Int {
        switch self {
        case .succeededAndSeen(let probes), .succeededNotSeen(let probes, _),
             .inDoubtApplied(let probes, _), .inDoubtAbsent(let probes),
             .inDoubtUnresolved(let probes, _):
            return probes
        case .succeeded, .retryable, .rejected, .cancelled:
            return 0
        }
    }

    public var description: String {
        switch self {
        case .succeeded:
            return "succeeded"
        case .succeededAndSeen(let probes):
            return "succeeded, confirmed by probe \(probes)"
        case .succeededNotSeen(let probes, let conclusive):
            return conclusive
                ? "reported success, absent after \(probes) probe(s): lost write"
                : "reported success, not confirmed after \(probes) probe(s)"
        case .retryable(let reason):
            return "retryable: \(reason)"
        case .rejected(let reason):
            return "rejected: \(reason)"
        case .inDoubtApplied(let probes, let late):
            return "in doubt -> applied at probe \(probes)" + (late ? " (read absent first)" : "")
        case .inDoubtAbsent(let probes):
            return "in doubt -> absent after the settle window (\(probes) probe(s))"
        case .inDoubtUnresolved(let probes, let reason):
            return "in doubt -> unresolved after \(probes) probe(s): \(reason)"
        case .cancelled:
            return "cancelled"
        }
    }
}

/// One attempt and its verdict.
public struct AttemptRecord: Sendable, Hashable {
    public let attempt: Int
    public let verdict: AttemptVerdict
}

/// How many attempts were performed again after an in-doubt attempt, and on what grounds.
public struct RedoCounts: Sendable, Hashable {
    /// After a probe confirmed the effect absent.
    public internal(set) var safe = 0
    /// Without confirmation, relying on the service to deduplicate by key.
    public internal(set) var keyed = 0
    /// Without confirmation or deduplication.
    public internal(set) var risked = 0

    public init() {}
}

/// How one effect ended.
public enum Resolution<Output: Sendable>: Sendable {
    /// An attempt reported success (and was seen, if confirmation was asked for).
    case succeeded(Output)
    /// An attempt failed in doubt and a probe found its result. It was not performed again.
    case recovered(Output)
    /// An attempt reported success, but no probe could see the effect.
    case unconfirmed(Output, reason: String)
    /// No attempt took effect.
    case failed(reason: String)
    /// The effect may or may not have happened. Someone has to decide.
    case unresolved(reason: String)

    /// The result, when one exists.
    public var output: Output? {
        switch self {
        case .succeeded(let output), .recovered(let output), .unconfirmed(let output, _):
            return output
        case .failed, .unresolved:
            return nil
        }
    }

    /// Whether the effect happened: `true`, `false`, or `nil` when that is not known.
    public var effectApplied: Bool? {
        switch self {
        case .succeeded, .recovered: return true
        case .failed: return false
        case .unconfirmed, .unresolved: return nil
        }
    }

    public var label: String {
        switch self {
        case .succeeded: return "succeeded"
        case .recovered: return "recovered"
        case .unconfirmed: return "unconfirmed"
        case .failed: return "failed"
        case .unresolved: return "unresolved"
        }
    }

    /// The reason given, for the cases that carry one.
    public var reason: String? {
        switch self {
        case .unconfirmed(_, let reason), .failed(let reason), .unresolved(let reason):
            return reason
        case .succeeded, .recovered:
            return nil
        }
    }
}

/// Everything ``VerifiedCaller/execute(_:)`` learned about one effect.
public struct VerifiedOutcome<Output: Sendable>: Sendable {
    public let key: String
    public let resolution: Resolution<Output>
    public let attempts: [AttemptRecord]
    public let redos: RedoCounts

    /// Times the effect was performed.
    public var performs: Int { attempts.count }

    /// Probes spent across all attempts.
    public var probes: Int { attempts.reduce(0) { $0 + $1.verdict.probes } }
}
