import Foundation

/// Proves that a visual endpoint probe can be reversed through at least the
/// same measured distance. The caller still owns endpoint evidence and target
/// identity; this helper does not turn a delivered wheel into scroll proof.
enum CaptureEndpointContinuity {
    struct Movement: Equatable {
        let rows: Int
        let verifiedContentRect: CGRect
    }

    /// Measure one leg with the production stitcher's unique, textured, dense
    /// overlap checks. The caller retains the result so the GUI does not need to
    /// repeat the forward proof when it later validates the return leg.
    static func measure(from first: ScrollCaptureFrame,
                        to second: ScrollCaptureFrame,
                        captureUpward: Bool) -> Movement? {
        observe(from: first, to: second, captureUpward: captureUpward).movement
    }

    /// Keep the production matcher's rejection details for endpoint diagnostics;
    /// an unsuccessful observation grants no movement or endpoint evidence.
    static func observe(from first: ScrollCaptureFrame, to second: ScrollCaptureFrame,
                        captureUpward: Bool) -> (movement: Movement?, diagnostic: [String: String]) {
        let witness = ScrollingImageStitcher(captureUpward: captureUpward)
        guard witness.append(first) == .first else { return (nil, ["result": "seed_failed"]) }
        let result = witness.append(second)
        var diagnostic = witness.lastAlignment
        diagnostic["result"] = String(describing: result)
        guard case .appended(let rows) = result, rows > 0,
              let rect = witness.verifiedContentRect else { return (nil, diagnostic) }
        return (Movement(rows: rows, verifiedContentRect: rect), diagnostic)
    }

    /// Scan every RGB channel while seeking the starting boundary, allowing one
    /// quantization level of rendering noise. Export uses the stricter stitcher;
    /// stationarity still requires the measured away-and-return endpoint proof.
    static func stationary(from first: ScrollCaptureFrame,
                           to second: ScrollCaptureFrame) -> Bool {
        guard first.width == second.width, first.height == second.height else { return false }
        for pixel in stride(from: 0, to: first.pixels.count, by: 4) {
            for channel in 0..<3 {
                if abs(Int(first.pixels[pixel + channel]) - Int(second.pixels[pixel + channel])) > 1 {
                    return false
                }
            }
        }
        return true
    }
}
