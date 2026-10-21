import Foundation

@main
enum CaptureTopPreparationTests {
    @MainActor
    static func main() async throws {
        var boundedAdvances = 0
        let limited = try await CaptureTopPreparation.prepare(initial: 0, shouldStop: { false },
            elapsed: { 0 }, advance: { boundedAdvances += 1; return boundedAdvances },
            atBoundary: { false }, stable: { _, _ in false })
        precondition(limited.evidence == .limit && limited.attempts == 48 && limited.frame == 48)
        precondition(!limited.confirmed, "Attempt exhaustion never proves the top")
        var elapsedValue: TimeInterval = 0
        var elapsedAdvances = 0
        let timedOut = try await CaptureTopPreparation.prepare(initial: 10, shouldStop: { false },
            elapsed: {
                elapsedValue = elapsedAdvances > 0 ? 15 : 0
                return elapsedValue
            }, advance: {
                elapsedAdvances += 1
                return 11
            }, atBoundary: { false }, stable: { _, _ in false })
        precondition(timedOut.evidence == .limit && timedOut.frame == 11 && timedOut.attempts == 1)
        precondition(elapsedAdvances == 1, "The time limit prevents another advance")

        var stableAdvances = 0
        let inferred = try await CaptureTopPreparation.prepare(initial: 0, shouldStop: { false },
            elapsed: { 0 }, advance: { stableAdvances += 1; return stableAdvances }, atBoundary: { false },
            stable: { _, _ in true })
        precondition(inferred.evidence == .inferred && inferred.attempts == 3 && inferred.frame == 3)
        precondition(!inferred.confirmed, "Stable imagery remains inferred evidence")

        let observed = try await CaptureTopPreparation.prepare(initial: 5, shouldStop: { false },
            elapsed: { 0 }, advance: { 4 }, atBoundary: { true }, stable: { _, _ in false })
        precondition(observed.evidence == .observed && observed.attempts == 0 && observed.confirmed)

        var stoppedAdvances = 0
        let stopped = try await CaptureTopPreparation.prepare(initial: 7, shouldStop: { true },
            elapsed: { 0 }, advance: { stoppedAdvances += 1; return 6 }, atBoundary: { false },
            stable: { _, _ in false })
        precondition(stopped.evidence == .stopped && stopped.frame == 7 && stopped.attempts == 0)
        precondition(stoppedAdvances == 0)
        let alreadyStopped = try await CaptureTopPreparation.prepare(initial: 9, shouldStop: { true },
            elapsed: { 0 }, advance: { 8 }, atBoundary: { true }, stable: { _, _ in false })
        precondition(alreadyStopped.evidence == .stopped && alreadyStopped.frame == 9,
                     "A stop request takes precedence over initial top observation")

        enum ExpectedError: Error { case failure }
        do {
            _ = try await CaptureTopPreparation.prepare(initial: 0, shouldStop: { false },
                elapsed: { 0 }, advance: { throw ExpectedError.failure }, atBoundary: { false },
                stable: { _, _ in false })
            preconditionFailure("Advance errors must propagate")
        } catch ExpectedError.failure { }

        do {
            _ = try await CaptureTopPreparation.prepare(initial: 0, shouldStop: { false },
                elapsed: { 0 }, advance: { throw CancellationError() }, atBoundary: { false },
                stable: { _, _ in false })
            preconditionFailure("Cancellation must propagate")
        } catch is CancellationError { }

        print("Capture top preparation bounds and evidence checks passed")
    }
}
