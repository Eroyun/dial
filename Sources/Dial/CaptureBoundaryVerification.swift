import Foundation

/// Requires positive visual movement away from a candidate boundary and an
/// independently verified visual return before that boundary can authorize
/// page capture. The caller validates position, not necessarily identical pixels.
@MainActor
enum CaptureBoundaryVerification {
    static func verify<Frame>(reference: Frame,
                              shouldStop: () -> Bool,
                              probeAway: () async throws -> Frame?,
                              movementVerified: (Frame, Frame) async -> Bool,
                              returnToBoundary: (Frame) async throws -> Frame?,
                              referenceRestored: (Frame, Frame) async -> Bool) async throws -> Frame? {
        try Task.checkCancellation()
        guard !shouldStop(), let away = try await probeAway() else { return nil }
        try Task.checkCancellation()
        guard !shouldStop(), await movementVerified(reference, away) else { return nil }
        try Task.checkCancellation()
        guard !shouldStop(), let returned = try await returnToBoundary(away) else { return nil }
        try Task.checkCancellation()
        guard !shouldStop(), await referenceRestored(reference, returned) else { return nil }
        try Task.checkCancellation()
        guard !shouldStop() else { return nil }
        return returned
    }
}
