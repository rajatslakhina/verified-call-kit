import VerifiedCallKit

// MARK: - A transfer API with injected non-atomic failures

enum APIError: Error, Equatable, CustomStringConvertible {
    case timeout, rateLimited, badRequest, lookupUnavailable

    var description: String {
        switch self {
        case .timeout: return "timeout after 30s"
        case .rateLimited: return "429 rate limited"
        case .badRequest: return "400 bad request"
        case .lookupUnavailable: return "503 lookup unavailable"
        }
    }
}

enum Fault: String, Sendable {
    case none
    case timeoutBeforeCommit = "timeout before commit"
    case timeoutAfterCommit = "timeout after commit"
    case rateLimited = "429, then ok"
    case lostWrite = "200 OK, write lost"
}

/// Each fault fires once, on the first request for its key. Writes become visible to `lookup`
/// `visibilityDelay` after they commit, as on a read replica that lags the primary.
actor TransferAPI {
    private struct Row { let key: String; let cents: Int; let at: Duration }

    private var faults: [String: Fault]
    private var rows: [Row] = []
    private var lookupUp = true
    private let clock: ManualVerificationClock
    private let visibilityDelay: Duration
    private let dedupByKey: Bool
    private(set) var lookupLog: [String] = []

    init(
        faults: [String: Fault] = [:],
        clock: ManualVerificationClock,
        visibilityDelay: Duration = .zero,
        dedupByKey: Bool = false
    ) {
        self.faults = faults
        self.clock = clock
        self.visibilityDelay = visibilityDelay
        self.dedupByKey = dedupByKey
    }

    func setLookup(up: Bool) { lookupUp = up }
    func charges(_ key: String) -> Int { rows.filter { $0.key == key }.count }
    var chargeCount: Int { rows.count }
    var chargedCents: Int { rows.reduce(0) { $0 + $1.cents } }

    func post(key: String, cents: Int) async throws -> String {
        let fault = faults.removeValue(forKey: key) ?? .none
        switch fault {
        case .timeoutBeforeCommit: throw APIError.timeout
        case .rateLimited: throw APIError.rateLimited
        case .lostWrite: return receipt(key, cents)
        case .none, .timeoutAfterCommit: break
        }
        if !(dedupByKey && rows.contains { $0.key == key }) {
            rows.append(Row(key: key, cents: cents, at: await clock.now()))
        }
        if fault == .timeoutAfterCommit { throw APIError.timeout }
        return receipt(key, cents)
    }

    func lookup(key: String) async throws -> ProbeReading<String> {
        let now = await clock.now()
        guard lookupUp else {
            lookupLog.append("t=\(seconds(now))  503")
            throw APIError.lookupUnavailable
        }
        guard let row = rows.first(where: { $0.key == key }), now - row.at >= visibilityDelay else {
            lookupLog.append("t=\(seconds(now))  absent")
            return .absent
        }
        lookupLog.append("t=\(seconds(now))  found \(receipt(row.key, row.cents))")
        return .applied(receipt(row.key, row.cents))
    }

    private func receipt(_ key: String, _ cents: Int) -> String { "rcpt:\(key):\(dollars(cents))" }

    nonisolated func transfer(_ key: String, cents: Int) -> ClosureEffect<String> {
        ClosureEffect(
            key: key,
            perform: { _ in try await self.post(key: key, cents: cents) },
            probe: { _ in try await self.lookup(key: key) }
        )
    }
}

func dollars(_ cents: Int) -> String {
    let rest = cents % 100
    return "$\(cents / 100).\(rest < 10 ? "0" : "")\(rest)"
}

func seconds(_ duration: Duration) -> String {
    let parts = duration.components
    return "\(Double(parts.seconds) + Double(parts.attoseconds) / 1e18)s"
}

func pad(_ text: String, _ width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func header(_ title: String) {
    print("\n=== \(title) ===")
}

/// What the service's own errors say: a 429 never took effect, a 400 never will, a timeout may have.
let classifier = FailureClassifier { error in
    switch error as? APIError {
    case .rateLimited?: return .retryable
    case .badRequest?: return .rejected
    default: return .inDoubt
    }
}

/// What a plain retry loop assumes: anything but a 400 is worth sending again.
let blindClassifier = FailureClassifier { error in
    (error as? APIError) == .badRequest ? .rejected : .retryable
}

let replicaWindow = VisibilityWindow(settle: .seconds(2), interval: .milliseconds(500), maxProbes: 8)

// MARK: - 1. Blind retry vs verify-before-retry

func blindVersusVerified() async -> VerificationReport {
    header("1. Twenty transfers, six injected faults: blind retry vs verify-before-retry")
    let faults: [String: Fault] = [
        "t03": .timeoutAfterCommit, "t07": .timeoutBeforeCommit, "t09": .rateLimited,
        "t12": .timeoutAfterCommit, "t15": .timeoutAfterCommit, "t18": .timeoutBeforeCommit
    ]
    let transfers = (1...20).map { index in ("t" + (index < 10 ? "0" : "") + "\(index)", 1_000 + index * 725) }
    let clock = ManualVerificationClock()
    let blindAPI = TransferAPI(faults: faults, clock: clock)
    let verifiedAPI = TransferAPI(faults: faults, clock: clock)
    let blind = VerifiedCaller(policy: VerificationPolicy(), classifier: blindClassifier, clock: clock)
    let verified = VerifiedCaller(
        policy: VerificationPolicy(window: replicaWindow),
        classifier: classifier,
        clock: clock
    )
    print("key  fault                    blind retry          verify-before-retry")
    for (key, cents) in transfers {
        _ = await blind.execute(blindAPI.transfer(key, cents: cents))
        let outcome = await verified.execute(verifiedAPI.transfer(key, cents: cents))
        guard let fault = faults[key] else { continue }
        let blindCharges = await blindAPI.charges(key)
        let verifiedCharges = await verifiedAPI.charges(key)
        let verdict = outcome.attempts.map(\.verdict.description).joined(separator: "; ")
        print("\(key)  \(pad(fault.rawValue, 23))  \(pad("charged \(blindCharges)x", 19))  "
            + "charged \(verifiedCharges)x, \(outcome.resolution.label) (\(verdict))")
    }
    let owed = transfers.reduce(0) { $0 + $1.1 }
    for (name, api) in [("blind retry", blindAPI), ("verified   ", verifiedAPI)] {
        let count = await api.chargeCount
        let charged = await api.chargedCents
        print("\(name): \(count) charges for 20 transfers, \(dollars(charged - owed)) overcharged")
    }
    let report = await verified.report()
    print("verified cost: \(report.probes) probes; \(report.duplicatesAvoided) duplicates avoided, "
        + "\(report.safeRedos) safe redos, \(report.performs) performs")
    return report
}

// MARK: - 2. Delayed visibility

func delayedVisibility() async {
    header("2. The write lands on a replica 1.5s late")
    let windows = [("one immediate probe", VisibilityWindow.immediate), ("2s settle window   ", replicaWindow)]
    for (name, window) in windows {
        let clock = ManualVerificationClock()
        let lag = Duration.milliseconds(1_500)
        let api = TransferAPI(faults: ["late": .timeoutAfterCommit], clock: clock, visibilityDelay: lag)
        let policy = VerificationPolicy(window: window)
        let caller = VerifiedCaller(policy: policy, classifier: classifier, clock: clock)
        let outcome = await caller.execute(api.transfer("late", cents: 4_200))
        let charges = await api.charges("late")
        let log = await api.lookupLog.joined(separator: ", ")
        print("\(name): \(outcome.resolution.label), charged \(charges)x  lookups: \(log)")
    }
    print("An absence read before the settle window has passed is not evidence. The window costs")
    print("4 lookups and 1.5s here; believing the first lookup cost a second $42.00 charge.")
}

// MARK: - 3. When the lookup cannot answer

func unresolvedPolicies() async {
    header("3. The lookup endpoint is down: what each UnresolvedPolicy does")
    for policy in UnresolvedPolicy.allCases {
        let clock = ManualVerificationClock()
        let api = TransferAPI(faults: ["down": .timeoutAfterCommit], clock: clock, dedupByKey: policy == .redoWithKey)
        await api.setLookup(up: false)
        let caller = VerifiedCaller(
            policy: VerificationPolicy(window: replicaWindow, onUnresolved: policy),
            classifier: classifier,
            clock: clock
        )
        let outcome = await caller.execute(api.transfer("down", cents: 9_900))
        let charges = await api.charges("down")
        let server = policy == .redoWithKey ? "dedups by key" : "no dedup     "
        let redo = outcome.redos.keyed > 0 ? "keyed" : "risked"
        let detail = outcome.resolution.reason ?? "\(outcome.probes) lookups failed, then a \(redo) redo"
        print("\(pad(policy.rawValue, 11)) server \(server)  -> \(pad(outcome.resolution.label, 10)) "
            + "charged \(charges)x  \(detail)")
    }
}

// MARK: - 4. A plan interrupted halfway

func interruptedPlan() async {
    header("4. reserve -> charge -> receipt, interrupted at the charge")
    let clock = ManualVerificationClock()
    let steps = [("reserve", 0), ("charge", 12_000), ("receipt", 0)]
    let verifiedAPI = TransferAPI(faults: ["charge": .timeoutAfterCommit], clock: clock)
    let blindAPI = TransferAPI(faults: ["charge": .timeoutAfterCommit], clock: clock)
    let caller = VerifiedCaller(policy: VerificationPolicy(window: replicaWindow), classifier: classifier, clock: clock)

    // Run 1 on both: reserve succeeds; the charge commits, its response is lost, and the lookup
    // goes down with it, so nothing can say whether the card was charged.
    let interrupted = await caller.execute(plan: firstRunPlan(verifiedAPI, steps))
    await verifiedAPI.setLookup(up: true)
    await performBlind(blindAPI, steps)
    let stoppedAt = interrupted.stoppedAt.map { "\($0 + 1)" } ?? "-"
    print("run 1: stopped at step \(stoppedAt), done so far: \(interrupted.completed.map(\.key))")
    print("       \(interrupted.stop?.resolution.reason ?? "")")

    // Run 2, thirty seconds later: a plain rerun starts from the top; the plan probes each step.
    await clock.advance(by: .seconds(30))
    await performBlind(blindAPI, steps)
    let resumed = await caller.execute(
        plan: EffectPlan(name: "order-17", steps: steps.map { verifiedAPI.transfer($0.0, cents: $0.1) })
    )
    let marks = resumed.completed.map { "\($0.key) \($0.alreadyApplied ? "(already done)" : "(performed)")" }
    print("run 2: complete=\(resumed.isComplete); \(marks.joined(separator: ", "))")
    for (name, api) in [("plain rerun   ", blindAPI), ("verified rerun", verifiedAPI)] {
        var counts: [String] = []
        for (key, _) in steps { counts.append("\(key) \(await api.charges(key))x") }
        print("\(name): \(counts.joined(separator: ", "))")
    }
}

func firstRunPlan(_ api: TransferAPI, _ steps: [(String, Int)]) -> EffectPlan<ClosureEffect<String>> {
    let charge = api.transfer(steps[1].0, cents: steps[1].1)
    let chargeThenLookupDown = ClosureEffect<String>(
        key: charge.key,
        perform: { context in
            await api.setLookup(up: false)
            return try await charge.perform(context)
        },
        probe: { try await charge.probe($0) }
    )
    return EffectPlan(name: "order-17", steps: [
        api.transfer(steps[0].0, cents: steps[0].1),
        chargeThenLookupDown,
        api.transfer(steps[2].0, cents: steps[2].1)
    ])
}

/// A plain sequential run: perform each step, stop at the first error.
func performBlind(_ api: TransferAPI, _ steps: [(String, Int)]) async {
    for (key, cents) in steps {
        do { _ = try await api.post(key: key, cents: cents) } catch { return }
    }
}

// MARK: - 5. Acknowledged, then lost

func lostWrite() async {
    header("5. The service answers 200 OK and drops the write")
    for confirm in [false, true] {
        let clock = ManualVerificationClock()
        let api = TransferAPI(faults: ["lost": .lostWrite], clock: clock)
        let caller = VerifiedCaller(
            policy: VerificationPolicy(window: replicaWindow, confirmSuccess: confirm),
            classifier: classifier,
            clock: clock
        )
        let outcome = await caller.execute(api.transfer("lost", cents: 2_500))
        let charges = await api.charges("lost")
        let lost = await caller.report().lostWrites
        print("confirmSuccess=\(pad("\(confirm)", 5)) -> \(pad(outcome.resolution.label, 11)) "
            + "receipt \(outcome.resolution.output ?? "-"), charged \(charges)x, lostWrites=\(lost)")
    }
}

// MARK: - Run

print("VerifiedCallKit demo: verify before you retry")
let report = await blindVersusVerified()
await delayedVisibility()
await unresolvedPolicies()
await interruptedPlan()
await lostWrite()
header("Report for scenario 1's verified caller")
print("calls \(report.calls), performs \(report.performs), probes \(report.probes)")
print("succeeded \(report.succeeded), recovered \(report.recovered), failed \(report.failed), "
    + "unresolved \(report.unresolved)")
print("duplicates avoided \(report.duplicatesAvoided), late appearances \(report.lateAppearances), "
    + "safe redos \(report.safeRedos)")
let perDuplicate = report.probesPerDuplicateAvoided.map { "\(($0 * 100).rounded() / 100)" } ?? "-"
print("probes per duplicate avoided: \(perDuplicate)")
