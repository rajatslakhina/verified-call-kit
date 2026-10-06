import XCTest
@testable import VerifiedCallKit

final class AttemptTests: XCTestCase {
    func testSuccessOnFirstAttempt() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.succeed], clock: clock)
        let outcome = await makeCaller(clock).execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "succeeded")
        XCTAssertEqual(outcome.resolution.output, "receipt-k")
        XCTAssertEqual(outcome.key, "k")
        XCTAssertEqual(outcome.performs, 1)
        XCTAssertEqual(outcome.probes, 0)
        XCTAssertEqual(verdicts(outcome), [.succeeded])
        XCTAssertEqual(outcome.attempts.first?.attempt, 1)
    }

    func testRetryableFailureIsRetriedWithoutProbing() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failBefore("429 slow down"), .succeed], clock: clock)
        let outcome = await makeCaller(clock).execute(service.effect("k"))
        XCTAssertEqual(verdicts(outcome), [.retryable("429 slow down"), .succeeded])
        XCTAssertEqual(outcome.probes, 0)
        let commits = await service.commitCount("k")
        XCTAssertEqual(commits, 1)
    }

    func testRejectionFailsAtOnce() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failBefore("400 bad amount")], clock: clock)
        let outcome = await makeCaller(clock).execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "failed")
        XCTAssertEqual(outcome.resolution.reason, "attempt 1 was rejected: 400 bad amount")
        XCTAssertEqual(outcome.resolution.effectApplied, false)
        XCTAssertEqual(outcome.performs, 1)
    }

    func testInDoubtAttemptFoundAppliedIsRecoveredNotRepeated() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failAfterCommit("timeout")], clock: clock)
        let caller = makeCaller(clock)
        let outcome = await caller.execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "recovered")
        XCTAssertEqual(outcome.resolution.output, "receipt-k")
        XCTAssertEqual(verdicts(outcome), [.inDoubtApplied(probes: 1, late: false)])
        let commits = await service.commitCount("k")
        XCTAssertEqual(commits, 1)
        let report = await caller.report()
        XCTAssertEqual(report.duplicatesAvoided, 1)
        XCTAssertEqual(report.lateAppearances, 0)
        XCTAssertEqual(report.probesPerDuplicateAvoided, 1)
    }

    func testBlindRetryOfTheSameFailureDuplicates() async {
        // The control: classify the timeout as retryable and the effect commits twice.
        let clock = ManualVerificationClock()
        let service = FakeService([.failAfterCommit("timeout"), .succeed], clock: clock)
        let blind = makeCaller(clock, classifier: FailureClassifier { _ in .retryable })
        let outcome = await blind.execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "succeeded")
        let commits = await service.commitCount("k")
        XCTAssertEqual(commits, 2)
    }

    func testInDoubtAttemptConfirmedAbsentIsRedoneSafely() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failBefore("timeout"), .succeed], clock: clock)
        let caller = makeCaller(clock)
        let outcome = await caller.execute(service.effect("k"))
        XCTAssertEqual(verdicts(outcome), [.inDoubtAbsent(probes: 1), .succeeded])
        XCTAssertEqual(outcome.redos.safe, 1)
        let commits = await service.commitCount("k")
        XCTAssertEqual(commits, 1)
        let report = await caller.report()
        XCTAssertEqual(report.safeRedos, 1)
    }

    func testRunningOutOfRetryableAttemptsFails() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failBefore("429"), .failBefore("429"), .failBefore("429")], clock: clock)
        let outcome = await makeCaller(clock).execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "failed")
        XCTAssertEqual(outcome.resolution.reason, "ran out of attempts after 3")
        XCTAssertEqual(outcome.performs, 3)
    }

    func testRetryDelayUsesTheClock() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failBefore("429"), .failBefore("429"), .succeed], clock: clock)
        let outcome = await makeCaller(clock, retryDelay: .seconds(2)).execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.label, "succeeded")
        let now = await clock.now()
        XCTAssertEqual(now, .seconds(4))
    }

    func testCancellationDuringAnAttemptIsUnresolved() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.cancel], clock: clock)
        let outcome = await makeCaller(clock).execute(service.effect("k"))
        XCTAssertEqual(outcome.resolution.reason, "cancelled during attempt 1; its effect is unknown")
        XCTAssertNil(outcome.resolution.effectApplied)
        XCTAssertEqual(verdicts(outcome), [.cancelled])
    }

    func testCancellationBeforeTheNextAttemptFails() async {
        let clock = ManualVerificationClock()
        let effect = ClosureEffect<String>(
            key: "k",
            perform: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw TestError("429")
            },
            probe: { _ in .absent }
        )
        let caller = makeCaller(clock, retryDelay: .seconds(1))
        let outcome = await Task { await caller.execute(effect) }.value
        XCTAssertEqual(outcome.resolution.label, "failed")
        XCTAssertEqual(outcome.resolution.reason, "cancelled before attempt 2")
    }

    func testDefaultCallerUsesTheSystemClockAndConservativeClassifier() async {
        let effect = ClosureEffect<Int>(key: "d", perform: { $0.attempt }, probe: { _ in .absent })
        let caller = VerifiedCaller()
        let outcome = await caller.execute(effect)
        XCTAssertEqual(outcome.resolution.output, 1)
        XCTAssertEqual(caller.policy.maxAttempts, 3)
        XCTAssertEqual(FailureClassifier.conservative.classify(TestError("x")), .inDoubt)
    }

    func testConcurrentEffectsAreAllCounted() async {
        let clock = ManualVerificationClock()
        let service = FakeService([], clock: clock)
        let caller = makeCaller(clock)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask { _ = await caller.execute(service.effect("k\(index)")) }
            }
        }
        let report = await caller.report()
        XCTAssertEqual(report.calls, 100)
        XCTAssertEqual(report.succeeded, 100)
        XCTAssertEqual(report.performs, 100)
        let commits = await service.commits.count
        XCTAssertEqual(commits, 100)
    }
}
