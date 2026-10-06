import XCTest
@testable import VerifiedCallKit

struct TestError: Error, CustomStringConvertible, Equatable {
    let label: String
    init(_ label: String) { self.label = label }
    var description: String { label }
}

/// "429…" is retryable, "400…" is rejected, anything else is in doubt.
let testClassifier = FailureClassifier { error in
    guard let error = error as? TestError else { return .inDoubt }
    if error.label.hasPrefix("429") { return .retryable }
    if error.label.hasPrefix("400") { return .rejected }
    return .inDoubt
}

/// A service whose next perform does whatever the script says, and whose writes become visible to
/// the probe `visibilityDelay` after they commit.
actor FakeService {
    enum Step: Sendable {
        case succeed
        case failBefore(String)
        case failAfterCommit(String)
        case lostWrite
        case cancel
    }

    enum ProbeMode: Sendable {
        case normal
        case failing
        case failOnce
    }

    private var script: [Step]
    private var committedAt: [String: Duration] = [:]
    private(set) var performs = 0
    private(set) var commits: [String] = []
    private var probeMode: ProbeMode
    let visibilityDelay: Duration
    let dedupByKey: Bool
    let clock: ManualVerificationClock

    init(
        _ script: [Step],
        clock: ManualVerificationClock,
        visibilityDelay: Duration = .zero,
        dedupByKey: Bool = false,
        probeMode: ProbeMode = .normal
    ) {
        self.script = script
        self.clock = clock
        self.visibilityDelay = visibilityDelay
        self.dedupByKey = dedupByKey
        self.probeMode = probeMode
    }

    func setProbeMode(_ mode: ProbeMode) { probeMode = mode }

    func commitCount(_ key: String) -> Int { commits.filter { $0 == key }.count }

    func perform(_ context: AttemptContext) async throws -> String {
        performs += 1
        let step = script.isEmpty ? .succeed : script.removeFirst()
        switch step {
        case .succeed:
            await commit(context.key)
            return "receipt-\(context.key)"
        case .failBefore(let label):
            throw TestError(label)
        case .failAfterCommit(let label):
            await commit(context.key)
            throw TestError(label)
        case .lostWrite:
            return "receipt-\(context.key)"
        case .cancel:
            throw CancellationError()
        }
    }

    func probe(_ context: AttemptContext) async throws -> ProbeReading<String> {
        switch probeMode {
        case .failing:
            throw TestError("probe down")
        case .failOnce:
            probeMode = .normal
            throw TestError("probe blip")
        case .normal:
            break
        }
        guard let at = committedAt[context.key] else { return .absent }
        return await clock.now() - at >= visibilityDelay ? .applied("receipt-\(context.key)") : .absent
    }

    private func commit(_ key: String) async {
        if dedupByKey, committedAt[key] != nil { return }
        commits.append(key)
        if committedAt[key] == nil { committedAt[key] = await clock.now() }
    }

    nonisolated func effect(_ key: String) -> ClosureEffect<String> {
        ClosureEffect(key: key, perform: { try await self.perform($0) }, probe: { try await self.probe($0) })
    }
}

func makeCaller(
    _ clock: ManualVerificationClock,
    maxAttempts: Int = 3,
    window: VisibilityWindow = .immediate,
    onUnresolved: UnresolvedPolicy = .escalate,
    confirmSuccess: Bool = false,
    retryDelay: Duration = .zero,
    classifier: FailureClassifier = testClassifier
) -> VerifiedCaller {
    VerifiedCaller(
        policy: VerificationPolicy(
            maxAttempts: maxAttempts,
            window: window,
            onUnresolved: onUnresolved,
            confirmSuccess: confirmSuccess,
            retryDelay: retryDelay
        ),
        classifier: classifier,
        clock: clock
    )
}

func verdicts<Output>(_ outcome: VerifiedOutcome<Output>) -> [AttemptVerdict] {
    outcome.attempts.map(\.verdict)
}
