/// Performs side effects, and settles every in-doubt failure by looking before retrying.
///
/// A plain retry loop sees a timeout and sends the request again. If the first request had
/// already taken effect, the customer is charged twice. `VerifiedCaller` classifies each failure
/// first. A failure that provably did not take effect is retried. One that may have taken effect
/// is reconciled with the effect's probe, through a ``VisibilityWindow``, before anything is
/// performed again:
///
/// - found applied: the probe's result is returned as ``Resolution/recovered(_:)``, and the
///   effect is not performed again;
/// - absent once the settle window has passed: performing again is safe;
/// - still unsettled: the ``UnresolvedPolicy`` decides.
public actor VerifiedCaller {
    public nonisolated let policy: VerificationPolicy
    private let classifier: FailureClassifier
    private let clock: any VerificationClock
    private var ledger = VerificationReport()

    public init(
        policy: VerificationPolicy = VerificationPolicy(),
        classifier: FailureClassifier = .conservative,
        clock: any VerificationClock = SystemVerificationClock()
    ) {
        self.policy = policy
        self.classifier = classifier
        self.clock = clock
    }

    /// Totals across every effect executed so far.
    public func report() -> VerificationReport {
        ledger
    }

    /// Performs the effect under the policy and reports how it ended.
    public func execute<Effect: VerifiableEffect>(_ effect: Effect) async -> VerifiedOutcome<Effect.Output> {
        var run = Run()
        let resolution = await drive(effect, &run)
        let outcome = VerifiedOutcome(
            key: effect.key,
            resolution: resolution,
            attempts: run.records,
            redos: run.redos
        )
        ledger.absorb(outcome)
        return outcome
    }

    func absorb<Output>(_ outcome: VerifiedOutcome<Output>) {
        ledger.absorb(outcome)
    }

    func notePreProbe(alreadyApplied: Bool) {
        ledger.probes += 1
        if alreadyApplied { ledger.alreadyApplied += 1 }
    }

    func currentTime() async -> Duration {
        await clock.now()
    }

    // MARK: - Attempts

    private func drive<Effect: VerifiableEffect>(
        _ effect: Effect,
        _ run: inout Run
    ) async -> Resolution<Effect.Output> {
        for attempt in 1...policy.maxAttempts {
            if attempt > 1, policy.retryDelay > .zero {
                do {
                    try await clock.sleep(for: policy.retryDelay)
                } catch {
                    return run.concluded("cancelled before attempt \(attempt)")
                }
            }
            run.beginAttempt()
            let context = AttemptContext(key: effect.key, attempt: attempt, dispatchedAt: await clock.now())
            let output: Effect.Output
            do {
                output = try await effect.perform(context)
            } catch {
                if let final = await settleFailure(error, effect, context, &run) { return final }
                continue
            }
            return await settleSuccess(output, effect, context, &run)
        }
        return run.concluded("ran out of attempts after \(policy.maxAttempts)")
    }

    private func settleSuccess<Effect: VerifiableEffect>(
        _ output: Effect.Output,
        _ effect: Effect,
        _ context: AttemptContext,
        _ run: inout Run
    ) async -> Resolution<Effect.Output> {
        guard policy.confirmSuccess else {
            run.record(context, .succeeded)
            return .succeeded(output)
        }
        switch await reconcile(effect, context) {
        case .applied(_, let probes, _):
            run.record(context, .succeededAndSeen(probes: probes))
            return .succeeded(output)
        case .absent(let probes):
            run.record(context, .succeededNotSeen(probes: probes, conclusive: true))
            return .unconfirmed(output, reason: "reported success, but the effect was absent after the settle window")
        case .unresolved(let probes, let reason):
            run.record(context, .succeededNotSeen(probes: probes, conclusive: false))
            return .unconfirmed(output, reason: "reported success, but it could not be confirmed: \(reason)")
        }
    }

    /// Returns the final resolution, or nil when another attempt should follow.
    private func settleFailure<Effect: VerifiableEffect>(
        _ error: any Error,
        _ effect: Effect,
        _ context: AttemptContext,
        _ run: inout Run
    ) async -> Resolution<Effect.Output>? {
        if error is CancellationError {
            run.record(context, .cancelled)
            return .unresolved(reason: "cancelled during attempt \(context.attempt); its effect is unknown")
        }
        switch classifier.classify(error) {
        case .retryable:
            run.record(context, .retryable("\(error)"))
            return nil
        case .rejected:
            run.record(context, .rejected("\(error)"))
            return run.concluded("attempt \(context.attempt) was rejected: \(error)")
        case .inDoubt:
            return await settleDoubt(effect, context, &run)
        }
    }

    private func settleDoubt<Effect: VerifiableEffect>(
        _ effect: Effect,
        _ context: AttemptContext,
        _ run: inout Run
    ) async -> Resolution<Effect.Output>? {
        switch await reconcile(effect, context) {
        case .applied(let output, let probes, let late):
            run.record(context, .inDoubtApplied(probes: probes, late: late))
            return .recovered(output)
        case .absent(let probes):
            run.record(context, .inDoubtAbsent(probes: probes))
            // The probe looks up by key, so absence covers every earlier attempt too.
            run.carriedDoubt = nil
            run.pendingRedo = .safe
            return nil
        case .unresolved(let probes, let reason):
            run.record(context, .inDoubtUnresolved(probes: probes, reason: reason))
            run.carriedDoubt = context.attempt
            switch policy.onUnresolved {
            case .escalate:
                return .unresolved(reason: "attempt \(context.attempt) is in doubt: \(reason)")
            case .redoWithKey:
                run.pendingRedo = .keyed
                return nil
            case .redo:
                run.pendingRedo = .risked
                return nil
            }
        }
    }

    // MARK: - Probing

    private enum Reconciliation<Output: Sendable> {
        case applied(Output, probes: Int, late: Bool)
        case absent(probes: Int)
        case unresolved(probes: Int, reason: String)
    }

    private func reconcile<Effect: VerifiableEffect>(
        _ effect: Effect,
        _ context: AttemptContext
    ) async -> Reconciliation<Effect.Output> {
        let window = policy.window
        var sawAbsence = false
        var probeFailure: String?
        for probe in 1...window.maxProbes {
            if probe > 1 {
                do {
                    try await clock.sleep(for: window.interval)
                } catch {
                    return .unresolved(probes: probe - 1, reason: "cancelled while probing")
                }
            }
            do {
                let reading = try await effect.probe(context)
                probeFailure = nil
                switch reading {
                case .applied(let output):
                    return .applied(output, probes: probe, late: sawAbsence)
                case .absent:
                    sawAbsence = true
                    if await clock.now() - context.dispatchedAt >= window.settle {
                        return .absent(probes: probe)
                    }
                }
            } catch {
                probeFailure = "probe failed: \(error)"
            }
        }
        let reason = probeFailure ?? "still absent inside the settle window"
        return .unresolved(probes: window.maxProbes, reason: reason)
    }
}

/// The mutable state of one ``VerifiedCaller/execute(_:)`` call.
struct Run {
    enum RedoKind { case safe, keyed, risked }

    var records: [AttemptRecord] = []
    var redos = RedoCounts()
    /// The latest attempt that may have taken effect, if any is still unsettled.
    var carriedDoubt: Int?
    var pendingRedo: RedoKind?

    mutating func record(_ context: AttemptContext, _ verdict: AttemptVerdict) {
        records.append(AttemptRecord(attempt: context.attempt, verdict: verdict))
    }

    /// Counts the redo the previous attempt asked for, now that it is happening.
    mutating func beginAttempt() {
        switch pendingRedo {
        case .safe: redos.safe += 1
        case .keyed: redos.keyed += 1
        case .risked: redos.risked += 1
        case nil: break
        }
        pendingRedo = nil
    }

    /// Ends without a result: failed when nothing can have taken effect, unresolved otherwise.
    func concluded<Output>(_ reason: String) -> Resolution<Output> {
        guard let attempt = carriedDoubt else { return .failed(reason: reason) }
        return .unresolved(reason: "\(reason); attempt \(attempt) is still in doubt")
    }
}
