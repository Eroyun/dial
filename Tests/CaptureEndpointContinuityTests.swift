import Foundation

@main enum CaptureEndpointContinuityTests {
    static func frame(at offset: Int, width: Int = 128, height: Int = 192,
                      redDelta: Int = 0, period: Int? = nil) throws -> ScrollCaptureFrame {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let row = period.map { (y + offset) % $0 } ?? (y + offset)
                let value = UInt32(truncatingIfNeeded: row &* 7_919 &+ x &* 1_031)
                let red = (Int(UInt8(truncatingIfNeeded: value)) + redDelta) & 0xff
                pixels += [UInt8(red),
                           UInt8(truncatingIfNeeded: value >> 8),
                           UInt8(truncatingIfNeeded: value >> 16), 255]
            }
        }
        return try ScrollCaptureFrame(width: width, height: height, pixels: pixels)
    }

    static func main() throws {
        let still = try frame(at: 0)
        precondition(CaptureEndpointContinuity.stationary(from: still, to: still),
            "Byte-identical frames must use the production unchanged result")

        var onePixelBytes = still.pixels
        onePixelBytes[4 * (still.width * (still.height / 2) + still.width / 2)] ^= 1
        let onePixelChanged = try ScrollCaptureFrame(width: still.width, height: still.height,
                                                    pixels: onePixelBytes)
        precondition(CaptureEndpointContinuity.stationary(from: still, to: onePixelChanged),
            "Insignificant rendering noise is not page movement")

        var footnoteBytes = still.pixels
        for y in (still.height - 5)..<(still.height - 3) { for x in 11..<14 {
            let pixel = (y * still.width + x) * 4
            for channel in 0..<3 { footnoteBytes[pixel + channel] ^= 255 }
        } }
        let footnote = try ScrollCaptureFrame(width: still.width, height: still.height, pixels: footnoteBytes)
        precondition(!CaptureEndpointContinuity.stationary(from: still, to: footnote),
            "Sparse new content must not be mistaken for rendering noise")

        let unchangedObservation = CaptureEndpointContinuity.observe(from: still, to: still, captureUpward: false)
        precondition(unchangedObservation.movement == nil && unchangedObservation.diagnostic["result"] == "unchanged",
            "A swallowed probe must retain its no-movement reason, without authorizing capture")

        let oneRowMoved = try frame(at: 5)
        precondition(!CaptureEndpointContinuity.stationary(from: still, to: oneRowMoved),
            "Measured page movement must not count as endpoint stability")

        var topOnlyPixels = still.pixels
        let rowBytes = still.width * 4
        topOnlyPixels.replaceSubrange(0..<(rowBytes * 16),
            with: oneRowMoved.pixels[0..<(rowBytes * 16)])
        let topOnlyMoved = try ScrollCaptureFrame(width: still.width, height: still.height,
                                                  pixels: topOnlyPixels)
        precondition(!CaptureEndpointContinuity.stationary(from: still, to: topOnlyMoved),
            "Movement confined to a narrow top band must not count as stationary")

        let reference = try frame(at: 0)
        let away = try frame(at: 24, redDelta: 1)
        let returned = try frame(at: 0, redDelta: 2)
        precondition(reference.pixels != returned.pixels,
            "Subtle per-pixel rendering drift must differ from exact RGB")
        let probeMovement = CaptureEndpointContinuity.measure(from: reference, to: away,
            captureUpward: false)
        let returnMovement = CaptureEndpointContinuity.measure(from: away, to: returned,
            captureUpward: true)
        precondition(probeMovement != nil && (returnMovement?.rows ?? 0) >= probeMovement!.rows,
            "Dense forward and reverse witnesses tolerate subtle RGB drift")

        let shortReturn = try frame(at: 8)
        let shortMovement = CaptureEndpointContinuity.measure(from: away, to: shortReturn,
            captureUpward: true)
        precondition(shortMovement == nil || shortMovement!.rows < probeMovement!.rows,
            "Returning fewer rows than the measured probe must fail closed")

        let wrongDirection = try frame(at: 40)
        precondition(CaptureEndpointContinuity.measure(from: away, to: wrongDirection,
            captureUpward: true) == nil,
            "A return frame that continues in the probe direction must fail")

        let repeatedReference = try frame(at: 0, width: 128, height: 192, period: 8)
        let repeatedAway = try frame(at: 16, width: 128, height: 192, period: 8)
        let repeatedReturn = try frame(at: 0, width: 128, height: 192, period: 8)
        precondition(CaptureEndpointContinuity.measure(from: repeatedReference, to: repeatedAway,
            captureUpward: false) == nil &&
            CaptureEndpointContinuity.measure(from: repeatedAway, to: repeatedReturn,
                captureUpward: true) == nil,
            "Repeated content must not authorize an ambiguous endpoint witness")

        let bottom = try frame(at: 320)
        let movedUp = try frame(at: 296)
        let restoredBottom = try frame(at: 320)
        let upwardProbe = CaptureEndpointContinuity.measure(from: bottom, to: movedUp,
            captureUpward: true)
        let downwardReturn = CaptureEndpointContinuity.measure(from: movedUp, to: restoredBottom,
            captureUpward: false)
        precondition(upwardProbe != nil && (downwardReturn?.rows ?? 0) >= upwardProbe!.rows,
            "Upward probes must normalize the reverse leg in the opposite direction")

        print("Endpoint continuity requires unique dense movement in both directions")
    }
}
