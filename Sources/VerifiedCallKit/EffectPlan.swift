/// An ordered set of effects that together make one operation: reserve, charge, notify.
///
/// A plan interrupted after step 2 of 3 has applied part of its effect. Running it again from the
/// top repeats steps 1 and 2. ``VerifiedCaller/execute(plan:)`` probes each step first and skips
/// the ones an earlier run already did, so a rerun resumes at the first missing step.
public struct EffectPlan<Step: VerifiableEffect>: Sendable {
    public let name: String
    public let steps: [Step]

    public init(name: String, steps: [Step]) {
        self.name = name
        self.steps = steps
    }
}

/// One plan step that is done, in this run or an earlier one.
public struct PlanStepRecord<Output: Sendable>: Sendable {
    public let index: Int
    public let key: String
    public let output: Output
    /// True when a pre-probe found the step done by an earlier run, so it was not performed.
    public let alreadyApplied: Bool
}

/// How far a plan got.
public struct PlanOutcome<Output: Sendable>: Sendable {
    public let name: String
    public let completed: [PlanStepRecord<Output>]
    /// The index of the step that stopped the plan, or nil when every step is done.
    public let stoppedAt: Int?
    /// The outcome of the step that stopped the plan.
    public let stop: VerifiedOutcome<Output>?

    public var isComplete: Bool { stoppedAt == nil }

    /// Steps skipped because an earlier run had already done them.
    public var alreadyApplied: Int { completed.filter(\.alreadyApplied).count }
}

extension VerifiedCaller {
    /// Runs the steps in order, skipping any an earlier run already applied, and stops at the
    /// first step that does not end ``Resolution/succeeded(_:)`` or ``Resolution/recovered(_:)``.
    ///
    /// Nothing is rolled back: the steps before a stop stay done, and a later run resumes after
    /// them. Resume only once the settle window has passed since the interrupted run, or a
    /// pre-probe may miss a step whose effect is not visible yet.
    public func execute<Step: VerifiableEffect>(plan: EffectPlan<Step>) async -> PlanOutcome<Step.Output> {
        var completed: [PlanStepRecord<Step.Output>] = []
        for (index, step) in plan.steps.enumerated() {
            let context = AttemptContext(key: step.key, attempt: 0, dispatchedAt: await currentTime())
            let earlier: ProbeReading<Step.Output>
            do {
                earlier = try await step.probe(context)
            } catch {
                notePreProbe(alreadyApplied: false)
                let stop = VerifiedOutcome<Step.Output>(
                    key: step.key,
                    resolution: .unresolved(
                        reason: "could not check whether an earlier run already did this step: \(error)"
                    ),
                    attempts: [],
                    redos: RedoCounts()
                )
                absorb(stop)
                return PlanOutcome(name: plan.name, completed: completed, stoppedAt: index, stop: stop)
            }
            if case .applied(let output) = earlier {
                notePreProbe(alreadyApplied: true)
                completed.append(PlanStepRecord(index: index, key: step.key, output: output, alreadyApplied: true))
                continue
            }
            notePreProbe(alreadyApplied: false)
            let outcome = await execute(step)
            switch outcome.resolution {
            case .succeeded(let output), .recovered(let output):
                completed.append(PlanStepRecord(index: index, key: step.key, output: output, alreadyApplied: false))
            case .unconfirmed, .failed, .unresolved:
                return PlanOutcome(name: plan.name, completed: completed, stoppedAt: index, stop: outcome)
            }
        }
        return PlanOutcome(name: plan.name, completed: completed, stoppedAt: nil, stop: nil)
    }
}
