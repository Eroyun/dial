import Foundation
import CoreGraphics

@main enum CaptureRollbackContinuityTests {
    static func frame(at offset: Int) throws -> ScrollCaptureFrame {
        var pixels: [UInt8] = []
        for y in 0..<160 {
            for x in 0..<120 {
                let v = UInt32(truncatingIfNeeded: (y + offset) * 7919 + x * 1031)
                pixels += [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), 255]
            }
        }
        return try ScrollCaptureFrame(width: 120, height: 160, pixels: pixels)
    }

    static func main() async throws {
        let reference = try frame(at: 0)
        // A requested 180 wheel moved this document 237. A 180 upward wheel
        // returned only 150: the second down must not run at the wrong position.
        var position = 237, downwardEffects = 0
        let failed = try await CaptureRollbackContinuity.resumeIfRestored(reference: reference,
            rollback: { position -= 150; return true },
            observe: { try frame(at: position) },
            resume: { downwardEffects += 1; return true })
        precondition(!failed && position == 87 && downwardEffects == 0)

        position = 237
        let restored = try await CaptureRollbackContinuity.resumeIfRestored(reference: reference,
            rollback: { position = 0; return true },
            observe: { try frame(at: position) },
            resume: { downwardEffects += 1; return true })
        precondition(restored && downwardEffects == 1)

        var reads = 0
        let stopped = try await CaptureRollbackContinuity.resumeIfRestored(reference: reference,
            rollback: { false }, observe: { reads += 1; return reference },
            resume: { downwardEffects += 1; return true })
        precondition(!stopped && reads == 0 && downwardEffects == 1)
        var changed = reference.pixels
        // Changes between the former every-seventh-pixel samples cannot evade
        // this full pixel check, even when the sampled pixels all remain equal.
        for pixel in stride(from: 1, to: changed.count / 4, by: 7) { changed[pixel * 4] ^= 255 }
        let corrupted = try ScrollCaptureFrame(width: reference.width, height: reference.height, pixels: changed)
        precondition(!CaptureRollbackContinuity.matchesReference(reference, corrupted))
        let body = CGRect(x: 20, y: 24, width: 80, height: 110)
        var furniture = reference.pixels
        furniture[(2 * 120 + 2) * 4] ^= 255
        let outsideChange = try ScrollCaptureFrame(width: 120, height: 160, pixels: furniture)
        precondition(CaptureRollbackContinuity.matchesContent(reference, outsideChange, rect: body))
        furniture[(80 * 120 + 50) * 4] ^= 255
        let insideChange = try ScrollCaptureFrame(width: 120, height: 160, pixels: furniture)
        precondition(!CaptureRollbackContinuity.matchesContent(reference, insideChange, rect: body), "One changed document pixel must still reject the return")
        var rerendered = reference.pixels
        for pixel in 0..<(reference.width * reference.height) {
            let index = pixel * 4
            if rerendered[index] < 255 { rerendered[index] += 1 }
        }
        let samePosition = try ScrollCaptureFrame(width: reference.width, height: reference.height, pixels: rerendered)
        precondition(!CaptureRollbackContinuity.matchesContent(reference, samePosition, rect: body))
        precondition(CaptureRollbackContinuity.matchesPosition(reference, samePosition, rect: body),
            "A dense unique zero-position match must survive small rendering changes")
        for offset in [-12, 12, 87] {
            let displaced = try frame(at: offset)
            precondition(!CaptureRollbackContinuity.matchesPosition(reference, displaced, rect: body),
                "Actual page displacement must not authorize the recovery wheel")
        }
        precondition(!CaptureRollbackContinuity.matchesPosition(reference, corrupted, rect: body),
            "Rendering tolerance must not admit dense corruption")
        var noisyResume = 0
        let noisyRestored = try await CaptureRollbackContinuity.resumeIfRestored(reference: reference, contentRect: body,
            rollback: { true }, observe: { samePosition }, resume: { noisyResume += 1; return true })
        precondition(noisyRestored && noisyResume == 1)
        precondition(!CaptureRollbackContinuity.matchesContent(reference, reference, rect: CGRect(x: 0, y: 0, width: 10, height: 160)))
        precondition(!CaptureRollbackContinuity.matchesContent(reference, reference, rect: CGRect(x: 20.5, y: 24, width: 80, height: 110)))
        var sparsePixels = [UInt8](repeating: 255, count: reference.pixels.count)
        for x in 20..<28 { for channel in 0..<3 { sparsePixels[(80 * 120 + x) * 4 + channel] = 0 } }
        let sparseReference = try ScrollCaptureFrame(width: 120, height: 160, pixels: sparsePixels)
        var sparseShift = [UInt8](repeating: 255, count: reference.pixels.count)
        for x in 20..<28 { for channel in 0..<3 { sparseShift[(81 * 120 + x) * 4 + channel] = 0 } }
        let sparseWrongPosition = try ScrollCaptureFrame(width: 120, height: 160, pixels: sparseShift)
        var sparseDownward = 0
        let sparseRejected = try await CaptureRollbackContinuity.resumeIfRestored(reference: sparseReference,
            rollback: { true }, observe: { sparseWrongPosition }, resume: { sparseDownward += 1; return true })
        precondition(!sparseRejected && sparseDownward == 0, "Sparse content one row off must not resume")
        print("Rollback continuity: asymmetric movement blocks the second wheel; restored pixels resume; stop and dense corruption gates passed")
    }
}
