import Foundation

/// Bounded endpoint preparation for automatic page capture. Limit/stopped
/// results retain a caller-validated frame for diagnostics, never as permission
/// to start a capture. Observed and visually inferred endpoints stay distinct.
@MainActor
enum CaptureTopPreparation {
    static let maximumAttempts = 48
    static let maximumDuration: TimeInterval = 15
    static let stableFramesRequired = 3

    enum Evidence: Equatable {
        case observed
        case inferred
        case verifiedVisual
        case limit
        case stopped
    }

    struct Result<Frame> {
        let frame: Frame
        let evidence: Evidence
        let attempts: Int

        var confirmed: Bool { evidence == .observed }
    }

    static func prepare<Frame>(initial: Frame,
                               shouldStop: () -> Bool,
                               elapsed: () -> TimeInterval,
                               advance: () async throws -> Frame?,
                               atBoundary: () -> Bool,
                               stable: (Frame, Frame) async -> Bool) async throws -> Result<Frame> {
        let started = elapsed()
        var latest = initial
        var stableCount = 0
        try Task.checkCancellation()
        if shouldStop() { return Result(frame: latest, evidence: .stopped, attempts: 0) }
        if atBoundary() { return Result(frame: latest, evidence: .observed, attempts: 0) }

        for attempt in 0..<maximumAttempts {
            try Task.checkCancellation()
            if shouldStop() {
                return Result(frame: latest, evidence: .stopped, attempts: attempt)
            }
            guard elapsed() - started < maximumDuration else {
                return Result(frame: latest, evidence: .limit, attempts: attempt)
            }

            guard let next = try await advance() else {
                return Result(frame: latest, evidence: .stopped, attempts: attempt + 1)
            }
            try Task.checkCancellation()
            let unchanged = await stable(latest, next)
            try Task.checkCancellation()
            latest = next
            let attempts = attempt + 1

            if atBoundary() {
                return Result(frame: latest, evidence: .observed, attempts: attempts)
            }
            stableCount = unchanged ? stableCount + 1 : 0
            if stableCount >= stableFramesRequired {
                return Result(frame: latest, evidence: .inferred, attempts: attempts)
            }
        }

        return Result(frame: latest, evidence: .limit, attempts: maximumAttempts)
    }
}
