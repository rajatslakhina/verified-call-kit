import XCTest
@testable import VerifiedCallKit

final class WindowAndPolicyTests: XCTestCase {
    func testImmediateWindowRepeatsAWriteThatIsNotVisibleYet() async {
        // The trap the settle window exists for: one probe, believed at once, on a store that shows
        // writes two seconds late.
        let clock = ManualVerificationClock()
        let service = FakeService([.failAfterCommit("timeout"), .succeed], clock: clock, visibilityDelay: .seconds(2))
        let outcome = await makeCaller(clock, window: .immediate).execute(service.effect("k"))
        XCTAssertEqual(verdicts(outcome), [.inDoubtAbsent(probes: 1), .succeeded])
        let commits = await service.commitCount("k")
        XCTAssertEqual(commits, 2)
    }

    func testSettleWindowWaitsForADelayedWrite() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failAfterCommit("timeout")], clock: clock, visibilityDelay: .seconds(2))
        let window = VisibilityWindow(settle: .seconds(5), interval: .seconds(1), maxProbes: 10)
        let caller = makeCaller(clock, window: window)
        let outcome = await caller.execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "recovered")
        XCTAssertEqual(verdicts(outcome), [.inDoubtApplied(probes: 3, late: true)])
        let commits = await service.commitCount("k")
        XCTAssertEqual(commits, 1)
        let now = await clock.now()
        XCTAssertEqual(now, .seconds(2))
        let report = await caller.report()
        XCTAssertEqual(report.lateAppearances, 1)
    }

    func testAbsenceAfterTheSettleWindowIsConclusive() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failBefore("timeout"), .succeed], clock: clock)
        let window = VisibilityWindow(settle: .seconds(2), interval: .seconds(1), maxProbes: 10)
        let outcome = await makeCaller(clock, window: window).execute(service.effect("k"))
        XCTAssertEqual(verdicts(outcome), [.inDoubtAbsent(probes: 3), .succeeded])
        XCTAssertEqual(outcome.probes, 3)
    }

    func testProbesRunningOutInsideTheWindowEscalates() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failBefore("timeout")], clock: clock)
        let window = VisibilityWindow(settle: .seconds(10), interval: .seconds(1), maxProbes: 3)
        let outcome = await makeCaller(clock, window: window).execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.reason, "attempt 1 is in doubt: still absent inside the settle window")
        XCTAssertEqual(outcome.probes, 3)
        XCTAssertEqual(outcome.performs, 1)
    }

    func testProbeFailureEscalatesWithoutPerformingAgain() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failAfterCommit("timeout")], clock: clock, probeMode: .failing)
        let caller = makeCaller(clock)
        let outcome = await caller.execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.reason, "attempt 1 is in doubt: probe failed: probe down")
        XCTAssertNil(outcome.resolution.effectApplied)
        XCTAssertNil(outcome.resolution.output)
        XCTAssertEqual(outcome.performs, 1)
        let report = await caller.report()
        XCTAssertEqual(report.unresolved, 1)
    }

    func testProbeBlipThenAppliedIsRecovered() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failAfterCommit("timeout")], clock: clock, probeMode: .failOnce)
        let window = VisibilityWindow(settle: .zero, interval: .seconds(1), maxProbes: 3)
        let outcome = await makeCaller(clock, window: window).execute(service.effect("k"))
        XCTAssertEqual(verdicts(outcome), [.inDoubtApplied(probes: 2, late: false)])
    }

    func testAReadingAfterAProbeFailureReplacesItsReason() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failBefore("timeout")], clock: clock, probeMode: .failOnce)
        let window = VisibilityWindow(settle: .seconds(10), interval: .seconds(1), maxProbes: 2)
        let outcome = await makeCaller(clock, window: window).execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.reason, "attempt 1 is in doubt: still absent inside the settle window")
    }

    func testRedoWithKeyReliesOnTheServiceToDeduplicate() async {
        let clock = ManualVerificationClock()
        let service = FakeService(
            [.failAfterCommit("timeout"), .succeed],
            clock: clock,
            dedupByKey: true,
            probeMode: .failing
        )
        let caller = makeCaller(clock, onUnresolved: .redoWithKey)
        let outcome = await caller.execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "succeeded")
        XCTAssertEqual(outcome.redos.keyed, 1)
        let commits = await service.commitCount("k")
        XCTAssertEqual(commits, 1)
        let report = await caller.report()
        XCTAssertEqual(report.keyedRedos, 1)
    }

    func testRedoRisksADuplicateAndCountsIt() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failAfterCommit("timeout"), .succeed], clock: clock, probeMode: .failing)
        let caller = makeCaller(clock, onUnresolved: .redo)
        let outcome = await caller.execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "succeeded")
        XCTAssertEqual(outcome.redos.risked, 1)
        let commits = await service.commitCount("k")
        XCTAssertEqual(commits, 2)
        let report = await caller.report()
        XCTAssertEqual(report.riskedRedos, 1)
    }

    func testRunningOutOfAttemptsWithDoubtCarriedIsUnresolved() async {
        let clock = ManualVerificationClock()
        let service = FakeService(
            [.failAfterCommit("timeout"), .failAfterCommit("timeout")],
            clock: clock,
            probeMode: .failing
        )
        let outcome = await makeCaller(clock, maxAttempts: 2, onUnresolved: .redo).execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.reason, "ran out of attempts after 2; attempt 2 is still in doubt")
        XCTAssertEqual(outcome.redos.risked, 1)
    }

    func testRejectionAfterAnUnsettledAttemptStaysUnresolved() async {
        let clock = ManualVerificationClock()
        let service = FakeService(
            [.failAfterCommit("timeout"), .failBefore("400 bad")],
            clock: clock,
            probeMode: .failing
        )
        let outcome = await makeCaller(clock, onUnresolved: .redo).execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.reason, "attempt 2 was rejected: 400 bad; attempt 1 is still in doubt")
    }

    func testConfirmedAbsenceClearsAnEarlierDoubt() async {
        let clock = ManualVerificationClock()
        let service = FakeService(
            [.failBefore("timeout"), .failBefore("timeout"), .failBefore("400 bad")],
            clock: clock,
            probeMode: .failOnce
        )
        let outcome = await makeCaller(clock, onUnresolved: .redo).execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "failed")
        XCTAssertEqual(outcome.resolution.reason, "attempt 3 was rejected: 400 bad")
        XCTAssertEqual(outcome.redos.risked, 1)
        XCTAssertEqual(outcome.redos.safe, 1)
    }

    func testCancellationWhileProbingIsUnresolved() async {
        let clock = ManualVerificationClock()
        let effect = ClosureEffect<String>(
            key: "k",
            perform: { _ in throw TestError("timeout") },
            probe: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                return .absent
            }
        )
        let window = VisibilityWindow(settle: .seconds(5), interval: .seconds(1), maxProbes: 5)
        let caller = makeCaller(clock, window: window)
        let outcome = await Task { await caller.execute(effect) }.value
        XCTAssertEqual(outcome.resolution.reason, "attempt 1 is in doubt: cancelled while probing")
    }

    func testConfirmedSuccessIsSeenByAProbe() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.succeed], clock: clock)
        let outcome = await makeCaller(clock, confirmSuccess: true).execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "succeeded")
        XCTAssertEqual(verdicts(outcome), [.succeededAndSeen(probes: 1)])
    }

    func testAcknowledgedButLostWriteIsUnconfirmed() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.lostWrite], clock: clock)
        let caller = makeCaller(clock, confirmSuccess: true)
        let outcome = await caller.execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "unconfirmed")
        XCTAssertEqual(outcome.resolution.output, "receipt-k")
        XCTAssertNil(outcome.resolution.effectApplied)
        XCTAssertEqual(
            outcome.resolution.reason,
            "reported success, but the effect was absent after the settle window"
        )
        XCTAssertEqual(verdicts(outcome), [.succeededNotSeen(probes: 1, conclusive: true)])
        let report = await caller.report()
        XCTAssertEqual(report.lostWrites, 1)
        XCTAssertEqual(report.unconfirmed, 1)
    }

    func testSuccessThatCannotBeCheckedIsUnconfirmed() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.succeed], clock: clock, probeMode: .failing)
        let caller = makeCaller(clock, confirmSuccess: true)
        let outcome = await caller.execute(service.effect("k"))
        XCTAssertEqual(
            outcome.resolution.reason,
            "reported success, but it could not be confirmed: probe failed: probe down"
        )
        XCTAssertEqual(verdicts(outcome), [.succeededNotSeen(probes: 1, conclusive: false)])
        let report = await caller.report()
        XCTAssertEqual(report.lostWrites, 0)
    }

    func testPolicyAndWindowClampTheirInputs() {
        let window = VisibilityWindow(settle: .seconds(-1), interval: .seconds(-2), maxProbes: 0)
        XCTAssertEqual(window, VisibilityWindow(settle: .zero, interval: .zero, maxProbes: 1))
        XCTAssertEqual(window, .immediate)
        let policy = VerificationPolicy(maxAttempts: 0, retryDelay: .seconds(-3))
        XCTAssertEqual(policy.maxAttempts, 1)
        XCTAssertEqual(policy.retryDelay, .zero)
        XCTAssertEqual(policy.onUnresolved, .escalate)
        XCTAssertFalse(policy.confirmSuccess)
        XCTAssertEqual(FailureClass.allCases, [.retryable, .rejected, .inDoubt])
        XCTAssertEqual(UnresolvedPolicy.allCases, [.escalate, .redoWithKey, .redo])
    }
}
