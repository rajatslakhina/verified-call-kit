/// Running totals across every effect a ``VerifiedCaller`` has executed.
public struct VerificationReport: Sendable, Hashable {
    public internal(set) var calls = 0
    public internal(set) var performs = 0
    public internal(set) var probes = 0

    public internal(set) var succeeded = 0
    public internal(set) var recovered = 0
    public internal(set) var unconfirmed = 0
    public internal(set) var failed = 0
    public internal(set) var unresolved = 0

    /// In-doubt attempts a probe found applied. A blind retry would have repeated each of them.
    public internal(set) var duplicatesAvoided = 0
    /// Of those, the ones an earlier probe had read as absent. A single immediate probe would have
    /// called them absent and repeated them.
    public internal(set) var lateAppearances = 0
    /// Reported successes whose effect was still absent after the settle window.
    public internal(set) var lostWrites = 0
    /// Plan steps a pre-probe found already done by an earlier run, so they were not performed.
    public internal(set) var alreadyApplied = 0

    public internal(set) var safeRedos = 0
    public internal(set) var keyedRedos = 0
    public internal(set) var riskedRedos = 0

    public init() {}

    /// Probes spent for each duplicate avoided, or nil before the first one.
    public var probesPerDuplicateAvoided: Double? {
        guard duplicatesAvoided > 0 else { return nil }
        return Double(probes) / Double(duplicatesAvoided)
    }

    mutating func absorb<Output>(_ outcome: VerifiedOutcome<Output>) {
        calls += 1
        performs += outcome.performs
        probes += outcome.probes
        switch outcome.resolution {
        case .succeeded: succeeded += 1
        case .recovered: recovered += 1
        case .unconfirmed: unconfirmed += 1
        case .failed: failed += 1
        case .unresolved: unresolved += 1
        }
        for record in outcome.attempts {
            switch record.verdict {
            case .inDoubtApplied(_, let late):
                duplicatesAvoided += 1
                if late { lateAppearances += 1 }
            case .succeededNotSeen(_, conclusive: true):
                lostWrites += 1
            default:
                break
            }
        }
        safeRedos += outcome.redos.safe
        keyedRedos += outcome.redos.keyed
        riskedRedos += outcome.redos.risked
    }
}
