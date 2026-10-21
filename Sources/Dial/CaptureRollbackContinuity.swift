import Foundation
import CoreGraphics

/// A requested wheel magnitude is not measured document movement. Never send
/// a recovery step until the actual returned position matches the accepted reference.
enum CaptureRollbackContinuity {
    /// Compare every RGB pixel in a region whose movement and texture were
    /// already independently validated. Stationary window furniture outside
    /// that region is not part of the document-position proof.
    static func matchesContent(_ reference: ScrollCaptureFrame, _ observed: ScrollCaptureFrame,
                               rect: CGRect) -> Bool {
        guard reference.width == observed.width, reference.height == observed.height,
              rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect == rect.integral, rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= CGFloat(reference.width), rect.maxY <= CGFloat(reference.height),
              rect.width >= CGFloat(max(32, (reference.width + 4) / 5)), rect.height >= 64 else { return false }
        for y in Int(rect.minY)..<Int(rect.maxY) {
            for x in Int(rect.minX)..<Int(rect.maxX) {
                let i = (y * reference.width + x) * 4
                if (0..<3).contains(where: { reference.pixels[i + $0] != observed.pixels[i + $0] }) { return false }
            }
        }
        return true
    }

    static func matchesReference(_ reference: ScrollCaptureFrame, _ observed: ScrollCaptureFrame) -> Bool {
        guard reference.width == observed.width, reference.height == observed.height else { return false }
        for index in stride(from: 0, to: reference.pixels.count, by: 4) {
            if (0..<3).contains(where: { reference.pixels[index + $0] != observed.pixels[index + $0] }) { return false }
        }
        return true
    }

    /// A verified document body can rerasterize without changing its position.
    /// Use the compositor's dense zero-offset/ambiguity check on that same body,
    /// never a sparse visual score or the requested wheel distance. The normal
    /// compositor still measures the next forward frame against its unchanged
    /// accepted reference; recovery observations never contribute output rows.
    static func matchesPosition(_ reference: ScrollCaptureFrame, _ observed: ScrollCaptureFrame,
                                rect: CGRect) -> Bool {
        if matchesContent(reference, observed, rect: rect) { return true }
        guard reference.width == observed.width, reference.height == observed.height,
              rect.minX.isFinite, rect.minY.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect == rect.integral, rect.minX >= 0, rect.minY >= 0,
              rect.maxX <= CGFloat(reference.width), rect.maxY <= CGFloat(reference.height),
              rect.width >= CGFloat(max(32, (reference.width + 4) / 5)), rect.height >= 64 else { return false }
        let x = Int(rect.minX), y = Int(rect.minY), width = Int(rect.width), height = Int(rect.height)
        func crop(_ frame: ScrollCaptureFrame) -> ScrollCaptureFrame? {
            var pixels = [UInt8]()
            pixels.reserveCapacity(width * height * 4)
            for row in y..<(y + height) {
                let start = (row * frame.width + x) * 4
                pixels.append(contentsOf: frame.pixels[start..<(start + width * 4)])
            }
            return try? ScrollCaptureFrame(width: width, height: height, pixels: pixels)
        }
        guard let before = crop(reference), let after = crop(observed) else { return false }
        let witness = ScrollStitcher()
        return witness.append(before) == .first && witness.append(after) == .unchanged
    }

    static func resumeIfRestored(reference: ScrollCaptureFrame,
                                 contentRect: CGRect? = nil,
                                 rollback: () async throws -> Bool,
                                 observe: () async throws -> ScrollCaptureFrame,
                                 resume: () async throws -> Bool) async throws -> Bool {
        guard try await rollback() else { return false }
        let returned = try await observe()
        let restored = contentRect.map { matchesPosition(reference, returned, rect: $0) }
            ?? matchesReference(reference, returned)
        guard restored else { return false }
        return try await resume()
    }
}
