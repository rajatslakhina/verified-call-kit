import XCTest
@testable import VerifiedCallKit

final class PlanAndReportTests: XCTestCase {
    func testPlanRunsEveryStep() async {
        let clock = ManualVerificationClock()
        let service = FakeService([], clock: clock)
        let caller = makeCaller(clock)
        let plan = EffectPlan(name: "order", steps: ["reserve", "charge", "notify"].map(service.effect))
        let outcome = await caller.execute(plan: plan)
        XCTAssertTrue(outcome.isComplete)
        XCTAssertEqual(outcome.name, "order")
        XCTAssertEqual(outcome.completed.map(\.key), ["reserve", "charge", "notify"])
        XCTAssertEqual(outcome.completed.map(\.index), [0, 1, 2])
        XCTAssertEqual(outcome.completed.last?.output, "receipt-notify")
        XCTAssertEqual(outcome.alreadyApplied, 0)
        XCTAssertNil(outcome.stop)
        let report = await caller.report()
        XCTAssertEqual(report.probes, 3)
        XCTAssertEqual(report.performs, 3)
    }

    func testRerunResumesWithoutRepeatingDoneSteps() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.succeed, .failAfterCommit("timeout")], clock: clock)
        let caller = makeCaller(clock)
        let plan = EffectPlan(name: "order", steps: ["reserve", "charge", "notify"].map(service.effect))

        // First run: the charge commits, then its response is lost and the probe is down.
        let first = await Task { () -> PlanOutcome<String> in
            let probeDown = FakeServiceProbeSwitch(service: service)
            return await caller.execute(plan: probeDown.plan(plan))
        }.value
        XCTAssertFalse(first.isComplete)
        XCTAssertEqual(first.stoppedAt, 1)
        XCTAssertEqual(first.completed.map(\.key), ["reserve"])
        XCTAssertEqual(first.stop?.resolution.label, "unresolved")

        await clock.advance(by: .seconds(30))
        let second = await caller.execute(plan: plan)
        XCTAssertTrue(second.isComplete)
        XCTAssertEqual(second.completed.map(\.alreadyApplied), [true, true, false])
        XCTAssertEqual(second.alreadyApplied, 2)
        for key in ["reserve", "charge", "notify"] {
            let commits = await service.commitCount(key)
            XCTAssertEqual(commits, 1, key)
        }
        let report = await caller.report()
        XCTAssertEqual(report.alreadyApplied, 2)
    }

    func testPlanStopsWhenAPreProbeFails() async {
        let clock = ManualVerificationClock()
        let service = FakeService([], clock: clock, probeMode: .failing)
        let caller = makeCaller(clock)
        let outcome = await caller.execute(plan: EffectPlan(name: "p", steps: [service.effect("a")]))
        XCTAssertEqual(outcome.stoppedAt, 0)
        XCTAssertEqual(
            outcome.stop?.resolution.reason,
            "could not check whether an earlier run already did this step: probe down"
        )
        XCTAssertEqual(outcome.stop?.attempts.count, 0)
        let performs = await service.performs
        XCTAssertEqual(performs, 0)
        let report = await caller.report()
        XCTAssertEqual(report.unresolved, 1)
        XCTAssertEqual(report.probes, 1)
    }

    func testPlanStopsAtARejectedStep() async {
        let clock = ManualVerificationClock()
        let service = FakeService([.failBefore("400 bad")], clock: clock)
        let outcome = await makeCaller(clock).execute(plan: EffectPlan(name: "p", steps: [service.effect("a")]))
        XCTAssertEqual(outcome.stoppedAt, 0)
        XCTAssertEqual(outcome.stop?.resolution.label, "failed")
    }

    func testReportTotalsAcrossOutcomes() async {
        let clock = ManualVerificationClock()
        let service = FakeService(
            [.succeed, .failAfterCommit("timeout"), .failBefore("400"), .lostWrite],
            clock: clock
        )
        let caller = makeCaller(clock)
        let empty = await caller.report()
        XCTAssertNil(empty.probesPerDuplicateAvoided)
        XCTAssertEqual(empty, VerificationReport())
        _ = await caller.execute(service.effect("a"))
        _ = await caller.execute(service.effect("b"))
        _ = await caller.execute(service.effect("c"))
        let confirming = makeCaller(clock, confirmSuccess: true)
        _ = await confirming.execute(service.effect("d"))
        let report = await caller.report()
        XCTAssertEqual(report.calls, 3)
        XCTAssertEqual(report.succeeded, 1)
        XCTAssertEqual(report.recovered, 1)
        XCTAssertEqual(report.failed, 1)
        XCTAssertEqual(report.duplicatesAvoided, 1)
        XCTAssertEqual(report.probes, 1)
        let lost = await confirming.report()
        XCTAssertEqual(lost.unconfirmed, 1)
    }

    func testVerdictDescriptionsAndProbeCounts() {
        let cases: [(AttemptVerdict, String, Int)] = [
            (.succeeded, "succeeded", 0),
            (.succeededAndSeen(probes: 1), "succeeded, confirmed by probe 1", 1),
            (.succeededNotSeen(probes: 2, conclusive: true), "reported success, absent after 2 probe(s): lost write", 2),
            (.succeededNotSeen(probes: 1, conclusive: false), "reported success, not confirmed after 1 probe(s)", 1),
            (.retryable("429"), "retryable: 429", 0),
            (.rejected("400"), "rejected: 400", 0),
            (.inDoubtApplied(probes: 3, late: true), "in doubt -> applied at probe 3 (read absent first)", 3),
            (.inDoubtApplied(probes: 1, late: false), "in doubt -> applied at probe 1", 1),
            (.inDoubtAbsent(probes: 2), "in doubt -> absent after the settle window (2 probe(s))", 2),
            (.inDoubtUnresolved(probes: 4, reason: "x"), "in doubt -> unresolved after 4 probe(s): x", 4),
            (.cancelled, "cancelled", 0)
        ]
        for (verdict, text, probes) in cases {
            XCTAssertEqual(verdict.description, text)
            XCTAssertEqual(verdict.probes, probes, text)
        }
    }

    func testResolutionAccessors() {
        let all: [Resolution<Int>] = [
            .succeeded(1), .recovered(2), .unconfirmed(3, reason: "u"), .failed(reason: "f"), .unresolved(reason: "r")
        ]
        XCTAssertEqual(all.map(\.label), ["succeeded", "recovered", "unconfirmed", "failed", "unresolved"])
        XCTAssertEqual(all.map(\.output), [1, 2, 3, nil, nil])
        XCTAssertEqual(all.map(\.effectApplied), [true, true, nil, false, nil])
        XCTAssertEqual(all.map(\.reason), [nil, nil, "u", "f", "r"])
    }

    func testManualClockOnlyMovesForward() async throws {
        let clock = ManualVerificationClock(start: .seconds(1))
        await clock.advance(by: .seconds(-5))
        try await clock.sleep(for: .seconds(-5))
        var now = await clock.now()
        XCTAssertEqual(now, .seconds(1))
        await clock.advance(by: .seconds(2))
        try await clock.sleep(for: .seconds(3))
        now = await clock.now()
        XCTAssertEqual(now, .seconds(6))
    }

    func testSystemClockMeasuresElapsedTime() async throws {
        let clock = SystemVerificationClock()
        let before = await clock.now()
        try await clock.sleep(for: .milliseconds(5))
        let after = await clock.now()
        XCTAssertGreaterThanOrEqual(after - before, .milliseconds(5))
    }

    func testAttemptContextKeepsItsFields() {
        let context = AttemptContext(key: "k", attempt: 2, dispatchedAt: .seconds(3))
        XCTAssertEqual(context, AttemptContext(key: "k", attempt: 2, dispatchedAt: .seconds(3)))
        XCTAssertNotEqual(context, AttemptContext(key: "k", attempt: 1, dispatchedAt: .seconds(3)))
    }
}

/// Wraps each step so its probe fails during one run, without changing the shared service.
struct FakeServiceProbeSwitch {
    let service: FakeService

    func plan(_ plan: EffectPlan<ClosureEffect<String>>) -> EffectPlan<ClosureEffect<String>> {
        EffectPlan(name: plan.name, steps: plan.steps.map { step in
            ClosureEffect(
                key: step.key,
                perform: { try await step.perform($0) },
                probe: { context in
                    // Pre-probes (attempt 0) see the real store; probes after a failure are down.
                    guard context.attempt > 0 else { return try await step.probe(context) }
                    throw TestError("probe down")
                }
            )
        })
    }
}
