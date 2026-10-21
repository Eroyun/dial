import Foundation
import CoreGraphics

@main enum ScrollingImageStitcherTests {
    static let width = 240, viewport = 240, header = 24, footer = 20, document = 1237

    static func color(x: Int, y: Int, section: Int) -> [UInt8] {
        var v = UInt32(truncatingIfNeeded: x * 1_031 + y * 79_919 + section * 29_399 + 1)
        v ^= v << 13; v ^= v >> 17; v ^= v << 5
        return [UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v >> 16), 255]
    }

    static func frame(_ offset: Int, rails: Bool = false, railWidth: Int = 24) throws -> ScrollCaptureFrame {
        var pixels: [UInt8] = []
        for y in 0..<viewport {
            for x in 0..<width {
                let section = y < header ? 1 : y >= viewport - footer ? 2 : rails && (x < railWidth || x >= width - railWidth) ? 3 : 0
                pixels += color(x: x, y: section == 0 ? y - header + offset : y, section: section)
            }
        }
        return try ScrollCaptureFrame(width: width, height: viewport, pixels: pixels)
    }

    static func bytes(_ image: CGImage) -> [UInt8] {
        let data = image.dataProvider!.data!
        let pointer = CFDataGetBytePtr(data)!
        return (0..<image.height).flatMap { y in
            Array(UnsafeBufferPointer(start: pointer + y * image.bytesPerRow, count: image.width * 4))
        }
    }

    static let floatingViewport = 240
    static let floatingDocument = 913
    static let floatingOverlayTop = floatingViewport * 4 / 5
    static let expandedViewport = 240
    static let expandedDocument = 270

    static func expandedPageColor(x: Int, y: Int, fixedFooter: Bool = false) -> [UInt8] {
        // Distinctive moving separators stop the fixed-edge detector at the
        // six-row control strip; the intervening document band stays blank.
        if fixedFooter && (y == 173 || y == 203) { return color(x: x, y: y, section: 12) }
        if y >= 60 && y < 210 { return [132, 136, 140, 255] }
        return color(x: x, y: y, section: 11)
    }

    static func expandedFrame(_ offset: Int, fixedFooter: Bool = false) throws -> ScrollCaptureFrame {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * expandedViewport * 4)
        for y in 0..<expandedViewport {
            for x in 0..<width {
                let pixel: [UInt8]
                if fixedFooter && (174..<180).contains(y) {
                    pixel = x % 12 < 4 ? [32, 38, 48, 255] : [220, 224, 232, 255]
                } else {
                    pixel = expandedPageColor(x: x, y: offset + y, fixedFooter: fixedFooter)
                }
                pixels += pixel
            }
        }
        return try ScrollCaptureFrame(width: width, height: expandedViewport, pixels: pixels)
    }

    static func assertExpandedBodyCapture(upward: Bool, fixedFooter: Bool = false) throws {
        let offsets = upward ? [30, 0] : [0, 30]
        let stitcher = ScrollingImageStitcher(captureUpward: upward, trimStationaryColumns: true)
        let first = try expandedFrame(offsets[0], fixedFooter: fixedFooter)
        precondition(stitcher.append(first) == .first)
        let second = try expandedFrame(offsets[1], fixedFooter: fixedFooter)
        if !upward && !fixedFooter {
            let oldOverlap = first.pixels[(30 * width * 4)..<(180 * width * 4)]
            let newOverlap = second.pixels[0..<(150 * width * 4)]
            for (index, pair) in zip(oldOverlap, newOverlap).enumerated() where pair.0 != pair.1 {
                preconditionFailure("Expanded fixture overlap differs at byte \(index), old=\(pair.0), new=\(pair.1)")
            }
        }
        let moved = stitcher.append(second)
        precondition(moved == .appended(rows: 30),
            "One-shot expanded directional witness should recover the textured edge; \(moved), \(stitcher.lastAlignment)")
        precondition(stitcher.frameCount == 2 && stitcher.height == expandedViewport + 30)
        if fixedFooter {
            precondition(stitcher.lastAlignment["expanded"]?.contains("appended") == true,
                "The expanded witness must accept the fixture after excluding its fixed edge band")
            precondition(abs((stitcher.verifiedContentRect?.maxY ?? 0) - 174) < 0.01,
                "The verified moving-body rectangle must stop above the six-row fixed edge")
        }

        let actual = bytes(stitcher.image()!)
        for y in 0..<expandedDocument {
            for x in 0..<width {
                var expected = expandedPageColor(x: x, y: y, fixedFooter: fixedFooter)
                if fixedFooter && !upward && (204..<210).contains(y) {
                    expected = x % 12 < 4 ? [32, 38, 48, 255] : [220, 224, 232, 255]
                }
                let index = (y * width + x) * 4
                precondition(Array(actual[index..<(index + 4)]) == expected,
                    "Expanded-body composition lost or duplicated source row \(y) (upward: \(upward), fixed footer: \(fixedFooter))")
            }
        }
        precondition((stitcher.verifiedContentRect?.height ?? 0) >= 64,
            "The returned rollback witness must describe the actual verified body")
    }

    static func floatingFrame(_ offset: Int, overlay: Bool, variant: Int) throws -> ScrollCaptureFrame {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * floatingViewport * 4)
        for y in 0..<floatingViewport {
            for x in 0..<width {
                if overlay && y >= floatingOverlayTop {
                    let gradient = min(40, (y - floatingOverlayTop) * 40 / (floatingViewport - floatingOverlayTop))
                    let drift = variant % 4
                    var color: [UInt8] = [UInt8(220 - gradient + drift), UInt8(224 - gradient + drift), UInt8(232 - gradient + drift), 255]

                    // A floating down-arrow near 82% viewport height.
                    let centerX = width / 2
                    let arrowY = floatingViewport * 82 / 100
                    let dy = y - arrowY
                    if dy >= -4 && dy <= 4 && abs(x - centerX) <= max(1, dy + 5) {
                        color = [36, 44, 56, 255]
                    }

                    // A textbox/card and sparse glyph strokes below the arrow.
                    if y >= floatingViewport * 9 / 10 && x >= 24 && x < width - 24 {
                        color = [250, 250, 252, 255]
                        let glyphX = (x - 34) % 13
                        if x < width - 42 && glyphX < 2 && (y + variant) % 7 < 5 {
                            color = [96, 104, 116, 255]
                        }
                    }
                    pixels += color
                } else {
                    pixels += color(x: x, y: offset + y, section: 0)
                }
            }
        }
        return try ScrollCaptureFrame(width: width, height: floatingViewport, pixels: pixels)
    }

    static func floatingOffsets(from start: Int, to end: Int, step: Int) -> [Int] {
        var offsets = [start]
        var current = start
        while current < end {
            current = min(end, current + step)
            offsets.append(current)
        }
        return offsets
    }

    static func assertFloatingOverlayCapture(upward: Bool) throws {
        let bottom = floatingDocument - floatingViewport
        let downOffsets = floatingOffsets(from: 0, to: bottom, step: 40)
        let offsets = upward ? Array(downOffsets.reversed()) : downOffsets
        let stitcher = ScrollingImageStitcher(captureUpward: upward)
        for (index, offset) in offsets.enumerated() {
            // The overlay is absent at the real bottom. Downward capture ends
            // there; upward capture starts there and sees it on later frames.
            let overlay = offset != bottom
            let frame = try floatingFrame(offset, overlay: overlay, variant: index)
            let result = stitcher.append(frame)
            if index == 0 {
                precondition(result == .first)
            } else if case .appended = result {
                // Each source step stays below 20% of the viewport, preserving
                // a large verified overlap after the protected overlay band.
            } else {
                preconditionFailure("Floating-overlay traversal failed at offset \(offset): \(result)")
            }
        }

        let image = stitcher.image()!
        precondition(image.width == width && image.height == floatingDocument,
            "Deferred overlay rows must preserve the complete document height")
        let actual = bytes(image)
        for y in 0..<floatingDocument {
            for x in 0..<width {
                let index = (y * width + x) * 4
                precondition(Array(actual[index..<(index + 4)]) == color(x: x, y: y, section: 0),
                    "Floating UI must neither replace nor duplicate document row \(y)")
            }
        }
    }

    static func main() throws {
        // Exercise the actual policy and reused compositor together. The oracle
        // checks every moving document pixel, including its first and final row.
        var policy = AutoScrollPolicy()
        let stitcher = ScrollingImageStitcher()
        var decision = policy.decide(.start(viewportHeight: viewport))
        var offset = 0, finished = false, requests = 0
        let bottom = document - (viewport - header - footer)
        for _ in 0..<80 {
            switch decision {
            case .captureFirstFrame: break
            case .scrollDown(let pixels, _), .checkEnd(let pixels, _):
                let before = offset
                let effectiveRequest = min(pixels, EndpointNavigation.ordinaryWheelLimit(viewportHeight: CGFloat(viewport)))
                offset = min(bottom, offset + effectiveRequest); requests += 1
                policy.recordEffectiveScrollStep(offset - before)
            case .recoverAndScrollDown(let rollback, let pixels, _):
                offset = max(0, offset - rollback)
                let before = offset
                let effectiveRequest = min(pixels, EndpointNavigation.ordinaryWheelLimit(viewportHeight: CGFloat(viewport)))
                offset = min(bottom, offset + effectiveRequest); requests += 2
                policy.recordEffectiveScrollStep(offset - before)
            case .finish(let reason, let complete):
                precondition(reason == .reachedEnd && complete,
                    "Unexpected finish \(reason), offset \(offset), accepted frames \(stitcher.frameCount), height \(stitcher.height)")
                finished = true
            default: preconditionFailure("Unexpected policy decision")
            }
            if finished { break }
            let outcome: AutoScrollPolicy.StitchOutcome
            switch stitcher.append(try frame(offset, rails: true)) {
            case .first: outcome = .first
            case .appended: outcome = .appended
            case .unchanged: outcome = .unchanged
            case .rejected(let reason): outcome = .rejected(reason)
            case .limitReached: outcome = .limitReached
            }
            decision = policy.decide(.observation(outcome, outputPixels: stitcher.width * stitcher.height,
                scrollbarPosition: Double(offset) / Double(bottom)))
        }
        precondition(finished && requests > 1 && requests < 30)
        let image = stitcher.image()!
        precondition(image.height == header + document + footer)
        let pixels = bytes(image)
        for y in 0..<document {
            for x in 24..<(width - 24) {
                let start = ((header + y) * width + x) * 4
                precondition(Array(pixels[start..<(start + 4)]) == color(x: x, y: y, section: 0), "Document rows must not be lost or duplicated")
            }
        }
        precondition(bytes(stitcher.image()!) == pixels, "Repeated export is inert")

        let beforeHeight = stitcher.height, beforeFrames = stitcher.frameCount
        if case .rejected = stitcher.append(try frame(bottom + 987)) {} else { preconditionFailure("Unrelated frame accepted") }
        precondition(stitcher.height == beforeHeight && stitcher.frameCount == beforeFrames && bytes(stitcher.image()!) == pixels)

        let first = try frame(0), second = try frame(40)
        // Regression from upstream: its sampled verification looked only at
        // every fourth column, accepting a frame with 75% corrupted overlap.
        var corrupted = second.pixels
        let unrelated = try frame(987)
        for y in header..<(viewport - footer) {
            for x in 0..<width where x % 4 != 0 {
                let start = (y * width + x) * 4
                corrupted.replaceSubrange(start..<(start + 4), with: unrelated.pixels[start..<(start + 4)])
            }
        }
        let bad = try ScrollCaptureFrame(width: width, height: viewport, pixels: corrupted)
        let verified = ScrollingImageStitcher()
        precondition(verified.append(first) == .first)
        if case .rejected = verified.append(bad) {} else { preconditionFailure("Corrupted unsampled columns accepted") }
        precondition(verified.frameCount == 1 && bytes(verified.image()!) == first.pixels)
        precondition(verified.append(second) == .appended(rows: 40), "Rejection must preserve the alignment reference")

        let narrow = ScrollingImageStitcher()
        let narrowFirst = try frame(0, rails: true, railWidth: 96)
        let narrowNext = try frame(40, rails: true, railWidth: 96)
        precondition(narrow.append(narrowFirst) == .first)
        precondition(narrow.append(narrowNext) == .appended(rows: 40), "A moving pane must not be discarded as stationary furniture")
        precondition(narrow.height == viewport + 40)

        // An automatically selected page exports only columns that actually
        // moved, so stationary sidebars cannot repeat down the long image.
        let trimmed = ScrollingImageStitcher(trimStationaryColumns: true)
        let trimmedFirst = try frame(0, rails: true), trimmedNext = try frame(40, rails: true)
        precondition(trimmed.append(trimmedFirst) == .first)
        precondition(trimmed.append(trimmedNext) == .appended(rows: 40))
        let trimmedImage = trimmed.image()!
        precondition(trimmedImage.width == width - 48 && trimmedImage.height == viewport + 40)
        let trimmedBytes = bytes(trimmedImage)
        for y in 0..<trimmedImage.height {
            for x in 0..<trimmedImage.width {
                let section = y < header ? 1 : y >= trimmedImage.height - footer ? 2 : 0
                let sourceY = section == 0 ? y - header : section == 2 ? viewport - footer + y - (trimmedImage.height - footer) : y
                let index = (y * trimmedImage.width + x) * 4
                precondition(Array(trimmedBytes[index..<(index + 4)]) == color(x: x + 24, y: sourceY, section: section))
            }
        }

        // A moving strip above the alignment band cannot be treated as a
        // stationary page. That would let successful wheel delivery imply a
        // false end even though visible document pixels changed.
        var topPixels: [[UInt8]] = [[], []]
        for y in 0..<viewport {
            for x in 0..<width {
                for index in 0..<2 {
                    topPixels[index] += color(x: x, y: y < 32 ? y + index * 40 : y,
                                              section: y < 32 ? 0 : 3)
                }
            }
        }
        let topFirst = try ScrollCaptureFrame(width: width, height: viewport, pixels: topPixels[0])
        let topNext = try ScrollCaptureFrame(width: width, height: viewport, pixels: topPixels[1])
        let topOnly = ScrollingImageStitcher()
        precondition(topOnly.append(topFirst) == .first)
        if case .rejected = topOnly.append(topNext) {} else { preconditionFailure("Top-only movement was mistaken for a stationary page") }
        precondition(topOnly.height == viewport && topOnly.frameCount == 1)

        for limited in [ScrollingImageStitcher(maximumHeight: viewport + 20),
                        ScrollingImageStitcher(maximumPixels: width * (viewport + 20)),
                        ScrollingImageStitcher(maximumFrames: 1)] {
            precondition(limited.append(first) == .first)
            precondition(limited.append(second) == .limitReached)
            precondition(limited.height == viewport && limited.frameCount == 1)
            precondition(bytes(limited.image()!) == first.pixels)
        }
        let reversed = ScrollingImageStitcher()
        _ = reversed.append(try frame(80))
        if case .appended = reversed.append(try frame(40)) { preconditionFailure("Upward scroll appended") }
        precondition(reversed.height == viewport && reversed.frameCount == 1)
        // Traverse upward through four asymmetric frames. Export must restore
        // visual top-to-bottom order with every document row and each fixed
        // header/footer exactly once, not just match dimensions or luminance.
        let upward = ScrollingImageStitcher(captureUpward: true)
        let offsets = [bottom, bottom - 40, bottom - 95, bottom - 150]
        let upwardFrames = try offsets.map { try frame($0) }
        precondition(upward.append(upwardFrames[0]) == .first)
        for index in 1..<offsets.count {
            precondition(upward.append(upwardFrames[index]) == .appended(rows: offsets[index - 1] - offsets[index]))
        }
        let upwardHeight = viewport + 150
        var expected: [UInt8] = []
        for y in 0..<upwardHeight {
            for x in 0..<width {
                if y < header { expected += color(x: x, y: y, section: 1) }
                else if y >= upwardHeight - footer {
                    expected += color(x: x, y: viewport - footer + y - (upwardHeight - footer), section: 2)
                } else { expected += color(x: x, y: offsets.last! + y - header, section: 0) }
            }
        }
        precondition(upward.width == width && upward.height == upwardHeight && upward.frameCount == 4)
        precondition(bytes(upward.image()!) == expected, "Upward export must preserve every RGBA pixel in visual order")
        precondition(bytes(upward.image()!) == expected, "Repeated upward export cannot duplicate fixed rows")
        precondition(upward.append(upwardFrames.last!) == .unchanged)
        if case .rejected = upward.append(try frame(bottom + 987)) {} else {
            preconditionFailure("Unrelated upward frame accepted")
        }
        precondition(upward.height == upwardHeight && upward.frameCount == 4 && bytes(upward.image()!) == expected,
                     "Rejected upward observations must leave pixels and reference unchanged")
        let afterRejection = try frame(offsets.last! - 40)
        precondition(upward.append(afterRejection) == .appended(rows: 40),
                     "A rejected upward frame must not replace its alignment reference")

        // A floating arrow and textbox repeatedly cover the bottom quarter of
        // the whole-window crop. That band is clear at the true document bottom.
        try assertFloatingOverlayCapture(upward: false)
        try assertFloatingOverlayCapture(upward: true)

        // When the central half is a flat embedded-image area, one expanded
        // directional witness may use the text at the opposite safe edge.
        // The page still exports every source pixel exactly in both directions.
        try assertExpandedBodyCapture(upward: false)
        try assertExpandedBodyCapture(upward: true)
        // A stationary band discovered at the fallback body's lower edge must
        // grow the deferred tail and appear only once in the final oracle.
        try assertExpandedBodyCapture(upward: false, fixedFooter: true)

        let wrongDirection = ScrollingImageStitcher(captureUpward: true)
        precondition(wrongDirection.append(upwardFrames.last!) == .first)
        if case .appended = wrongDirection.append(upwardFrames[2]) {
            preconditionFailure("A downward scroll cannot append during upward traversal")
        }
        precondition(wrongDirection.height == viewport && wrongDirection.frameCount == 1
            && bytes(wrongDirection.image()!) == upwardFrames.last!.pixels)

        for limited in [ScrollingImageStitcher(maximumHeight: viewport + 20, captureUpward: true),
                        ScrollingImageStitcher(maximumPixels: width * (viewport + 20), captureUpward: true),
                        ScrollingImageStitcher(maximumFrames: 1, captureUpward: true)] {
            let original = try frame(bottom)
            precondition(limited.append(original) == .first)
            let overLimit = try frame(bottom - 40)
            precondition(limited.append(overLimit) == .limitReached)
            precondition(limited.height == viewport && limited.frameCount == 1)
            precondition(bytes(limited.image()!) == original.pixels, "Upward caps leave original orientation and content intact")
        }
        print("Reused scrolling engine: finite page, every moving pixel, fixed rails, inert rejection, limits, reverse checks and exact upward export passed (synthetic)")
    }
}
