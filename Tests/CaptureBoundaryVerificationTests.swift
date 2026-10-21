import Foundation

@main
enum CaptureBoundaryVerificationTests {
    static func main() async throws {
        let stationary = try await CaptureBoundaryVerification.verify(reference: 0,
            shouldStop: { false }, probeAway: { 0 },
            movementVerified: { reference, probe in probe != reference },
            returnToBoundary: { _ in 0 },
            referenceRestored: { reference, returned in reference == returned })
        precondition(stationary == nil, "Stationary imagery cannot prove an endpoint")

        let wrongReturn = try await CaptureBoundaryVerification.verify(reference: 10,
            shouldStop: { false }, probeAway: { 20 },
            movementVerified: { reference, probe in probe > reference },
            returnToBoundary: { _ in 11 },
            referenceRestored: { reference, returned in reference == returned })
        precondition(wrongReturn == nil, "A return at another page position must fail closed")

        let verified = try await CaptureBoundaryVerification.verify(reference: 10,
            shouldStop: { false }, probeAway: { 20 },
            movementVerified: { reference, probe in probe > reference },
            returnToBoundary: { away in precondition(away == 20); return 10 },
            referenceRestored: { reference, returned in reference == returned })
        precondition(verified == 10, "Positive movement plus exact return proves the boundary")

        var stopped = false
        let stoppedBeforeProbe = try await CaptureBoundaryVerification.verify(reference: 1,
            shouldStop: { stopped }, probeAway: { stopped = true; return 2 },
            movementVerified: { _, _ in true },
            returnToBoundary: { _ in 1 },
            referenceRestored: { _, _ in true })
        precondition(stoppedBeforeProbe == nil)

        stopped = false
        let stoppedBetweenPhases = try await CaptureBoundaryVerification.verify(reference: 1,
            shouldStop: { stopped }, probeAway: { 2 },
            movementVerified: { _, _ in stopped = true; return true },
            returnToBoundary: { away in precondition(away == 2); return 1 },
            referenceRestored: { _, _ in true })
        precondition(stoppedBetweenPhases == nil)

        stopped = false
        let stoppedDuringFinalVerification = try await CaptureBoundaryVerification.verify(reference: 1,
            shouldStop: { stopped }, probeAway: { 2 },
            movementVerified: { _, _ in true },
            returnToBoundary: { away in precondition(away == 2); return 1 },
            referenceRestored: { _, _ in stopped = true; return true })
        precondition(stoppedDuringFinalVerification == nil,
                     "Stop during exact-return verification must prevent acceptance")

        enum ProbeError: Error { case failed }
        do {
            _ = try await CaptureBoundaryVerification.verify(reference: 1,
                shouldStop: { false }, probeAway: { throw ProbeError.failed },
                movementVerified: { _, _ in true },
                returnToBoundary: { _ in 1 },
                referenceRestored: { _, _ in true })
            preconditionFailure("Probe errors must propagate")
        } catch ProbeError.failed {}

        let cancellationDuringFinalVerification = Task { @MainActor in
            try await CaptureBoundaryVerification.verify(reference: 1,
                shouldStop: { false }, probeAway: { 2 },
                movementVerified: { _, _ in true },
                returnToBoundary: { away in precondition(away == 2); return 1 },
                referenceRestored: { _, _ in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    return true
                })
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        cancellationDuringFinalVerification.cancel()
        do {
            _ = try await cancellationDuringFinalVerification.value
            preconditionFailure("Cancellation during final verification must propagate")
        } catch is CancellationError {}

        let cancelled = Task { @MainActor in
            try await CaptureBoundaryVerification.verify(reference: 1,
                shouldStop: { false }, probeAway: { try await Task.sleep(nanoseconds: 5_000_000); return 2 },
                movementVerified: { _, _ in true },
                returnToBoundary: { _ in 1 },
                referenceRestored: { _, _ in true })
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            preconditionFailure("Task cancellation must propagate")
        } catch is CancellationError {}

        print("Boundary verification requires movement and exact return; stop, cancellation, and errors fail closed")
    }
}
