import Foundation
import CoreGraphics

/// Premultiplied RGBA8 pixels in display order: the first row is the top of the selected region.
struct ScrollCaptureFrame {
    enum Invalid: Error, LocalizedError {
        case dimensions, buffer
        var errorDescription: String? {
            switch self {
            case .dimensions: return "The capture dimensions are invalid."
            case .buffer: return "The capture pixel buffer does not match its dimensions."
            }
        }
    }

    let width: Int
    let height: Int
    let pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) throws {
        guard width > 0, height > 0 else { throw Invalid.dimensions }
        let (count, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = count.multipliedReportingOverflow(by: 4)
        guard !overflow, !byteOverflow else { throw Invalid.dimensions }
        guard pixels.count == bytes else { throw Invalid.buffer }
        self.width = width
        self.height = height
        self.pixels = pixels
    }
}

/// Call serially. Rejected observations never move the alignment reference.
final class ScrollStitcher {
    enum AppendResult: Equatable {
        case first
        case appended(rows: Int)
        case unchanged
        case rejected(String)
        case limitReached
    }

    private(set) var width = 0
    private(set) var height = 0
    private(set) var frameCount = 0
    /// Bounded numeric matcher evidence for the most recent append; contains no pixels.
    private(set) var alignmentDiagnostic: String?
    private var strips: [[UInt8]] = []
    private var previous: ScrollCaptureFrame?
    private let allowFixedEdges: Bool
    private var fixedEdges: FixedEdges?
    private var fixedFooter: [UInt8] = []
    var fixedEdgesApplied: Bool { fixedEdges != nil }
    var fixedTopRows: Int { fixedEdges?.top ?? 0 }
    var fixedBottomRows: Int { fixedEdges?.bottom ?? 0 }
    var fixedEdgesDescription: String? {
        guard let fixedEdges else { return nil }
        return "Stitched scrolling content while keeping \(fixedEdges.top) fixed top rows and \(fixedEdges.bottom) fixed bottom rows once."
    }
    private let maximumPixels: Int
    private let maximumHeight: Int
    private let maximumFrames: Int
    private let maximumFramePixels = 8_000_000

    // Smaller budgets are useful for deterministic limit tests. These cannot raise
    // production caps: output <= 160 MB, reference viewport <= 32 MB. Strips
    // avoid geometric growth of a large array. image() materializes at most
    // 160 MB of provider data (bridging may make another copy). Callers own inputs.
    init(maximumPixels: Int = 40_000_000, maximumHeight: Int = 20_000, maximumFrames: Int = 200,
         allowFixedEdges: Bool = false) {
        precondition(maximumPixels > 0 && maximumPixels <= 40_000_000)
        precondition(maximumHeight > 0 && maximumHeight <= 20_000)
        precondition(maximumFrames > 0 && maximumFrames <= 200)
        self.maximumPixels = maximumPixels
        self.maximumHeight = maximumHeight
        self.maximumFrames = maximumFrames
        self.allowFixedEdges = allowFixedEdges
    }

    func append(_ frame: ScrollCaptureFrame) -> AppendResult {
        alignmentDiagnostic = nil
        guard frame.width <= maximumFramePixels / frame.height else { return .limitReached }
        guard let previous else {
            guard frame.height <= maximumHeight,
                  frame.width <= maximumPixels / frame.height else { return .limitReached }
            width = frame.width
            height = frame.height
            strips = [frame.pixels]
            self.previous = frame
            frameCount = 1
            return .first
        }
        guard frame.width == width && frame.height == previous.height else {
            return .rejected("The capture size changed. Start again with a fixed content selection.")
        }
        if let fixedEdges, !fixedBandsMatch(previous, frame, edges: fixedEdges) {
            return .rejected("The fixed header or footer changed. Return to the last captured position or start again.")
        }
        // Only an exact duplicate can bypass offset search. A sparse moving
        // page may satisfy the tolerant zero-shift budget while also having a
        // real positive overlap; both must participate in ambiguity checks.
        if previous.pixels == frame.pixels { return .unchanged }
        guard frameCount < maximumFrames else { return .limitReached }
        guard width >= 16, frame.height >= 64 else {
            return .rejected("Select a larger content area, then scroll slowly downward.")
        }

        if let fixedEdges {
            return accept(alignment(previous, frame, edges: fixedEdges), frame: frame, activating: nil)
        }
        let normal = alignment(previous, frame, edges: FixedEdges(top: 0, bottom: 0))
        // Activate only on the first transition: later strips may already
        // contain chrome and cannot be reclassified without changing pixels.
        if case .rejected = normal, allowFixedEdges, frameCount == 1,
           let edges = detectFixedEdges(previous, frame) {
            let cropped = alignment(previous, frame, edges: edges)
            if case .shifted = cropped {
                return accept(cropped, frame: frame, activating: edges)
            }
        }
        return accept(normal, frame: frame, activating: nil)
    }

    private struct FixedEdges { let top: Int; let bottom: Int }
    private enum Alignment {
        case unchanged, shifted(Int), rejected(String)
    }

    private func alignment(_ old: ScrollCaptureFrame, _ new: ScrollCaptureFrame,
                           edges: FixedEdges) -> Alignment {
        let bodyHeight = old.height - edges.top - edges.bottom
        // Keep at least 40% overlap of the moving body. Sparse scoring searches
        // every integer shift in both directions; dense scoring refines a shortlist.
        let minimumOverlap = max(32, (bodyHeight * 2 + 4) / 5)
        let maximumShift = bodyHeight - minimumOverlap
        guard maximumShift > 0 else {
            return .rejected("The moving content area is too small to verify an overlap.")
        }
        let coarseColumns = sampledColumns(old, edges: edges, count: 20)
        let denseColumns = sampledColumns(old, edges: edges, count: 48)
        // For a narrow document in a wide viewport, blank margins dilute both
        // the score and the full-frame error budget. Keep the full verification
        // and additionally enforce its limits on columns carrying content.
        let contentColumns = sparseColumns(denseColumns)
        var exhaustiveWasPerformed = false
        var candidates = (-maximumShift...maximumShift).map {
            Candidate(shift: $0, score: sampledScore(old, new, shift: $0, rows: 64, columns: coarseColumns, edges: edges))
        }
        candidates.sort { $0.score == $1.score ? abs($0.shift) < abs($1.shift) : $0.score < $1.score }
        candidates = Array(candidates.prefix(32)).map {
            Candidate(shift: $0.shift, score: sampledScore(old, new, shift: $0.shift, rows: 128, columns: denseColumns, edges: edges))
        }
        candidates.sort { $0.score < $1.score }
        let plausible = candidates.filter { $0.score <= 4.0 }
        guard !plausible.isEmpty else { return .rejected("No reliable overlap. Return to the last captured position and scroll more slowly; keep toolbars outside the selection.") }
        var shifts = plausible.map(\.shift)
        let approximateZero = verifies(old, new, shift: 0, edges: edges,
                                       informativeColumns: contentColumns).matches
        if plausible.count > 8 || approximateZero {
            // Sparse sampling can make many different article rows look alike.
            // An approximate zero match also needs the complete ambiguity scan:
            // it must not hide a genuine, textured positive alignment.
            // A row's RGB sums give a sound lower bound on its pixel difference
            // (triangle inequality). Check every offset, in both directions,
            // then fully verify every survivor only when the work is bounded.
            guard let exhaustive = exhaustiveCandidateShifts(old, new, edges: edges,
                                                              maximumShift: maximumShift,
                                                              informativeColumns: contentColumns) else {
                return .rejected("This content is too repetitive or lacks detail. Select an area with distinctive content.")
            }
            exhaustiveWasPerformed = true
            guard !exhaustive.isEmpty else {
                return .rejected("The content changed or moved sideways. Settle the view and scroll slowly downward.")
            }
            shifts = exhaustive
        }
        // Zero is always tested against the same full-image/content budgets as
        // other candidates, even if sparse sampling omitted it from a shortlist.
        if !shifts.contains(0) { shifts.append(0) }
        var matches: [(shift: Int, textured: Bool, meanRGBError: Double)] = []
        for shift in shifts {
            let verification = verifies(old, new, shift: shift, edges: edges,
                                        informativeColumns: contentColumns)
            if verification.matches {
                matches.append((shift, verification.textured, verification.meanRGBError))
            }
        }
        // Local-cluster disambiguation is safe only after excluding distinct
        // alignments that sparse scoring may have omitted. Reuse the existing
        // bounded exhaustive scan and its fail-closed work limits.
        if matches.count > 1 && !exhaustiveWasPerformed {
            guard let exhaustive = exhaustiveCandidateShifts(old, new, edges: edges,
                                                              maximumShift: maximumShift,
                                                              informativeColumns: contentColumns) else {
                alignmentDiagnostic = "verified-shift-rgb-mean=[\(matches.map { String($0.shift) }.sorted().joined(separator: ",") )]; exhaustive=budget-exceeded"
                return .rejected("This content is too repetitive or lacks detail. Select an area with distinctive content.")
            }
            guard !exhaustive.isEmpty else {
                alignmentDiagnostic = "verified-shift-rgb-mean=[]; exhaustive=no-candidates"
                return .rejected("The content changed or moved sideways. Settle the view and scroll slowly downward.")
            }
            matches.removeAll(keepingCapacity: true)
            for shift in exhaustive {
                let verification = verifies(old, new, shift: shift, edges: edges,
                                            informativeColumns: contentColumns)
                if verification.matches {
                    matches.append((shift, verification.textured, verification.meanRGBError))
                }
            }
        }
        let numericMatches = matches.sorted { $0.shift < $1.shift }
            .map { "\($0.shift):\(String(format: "%.8g", $0.meanRGBError))" }
            .joined(separator: ",")
        alignmentDiagnostic = "verified-shift-rgb-mean=[\(numericMatches)]"
        guard !matches.isEmpty else {
            return .rejected("The content changed or moved sideways. Settle the view and scroll slowly downward.")
        }
        // One or two rows are capture jitter only when no distinct larger
        // alignment also matches. Never hide an ambiguous seam as a duplicate.
        if matches.contains(where: { abs($0.shift) <= 2 }) {
            guard matches.allSatisfy({ abs($0.shift) <= 2 }) else {
                return .rejected("Multiple overlaps look alike. Select more distinctive content and scroll in smaller steps.")
            }
            return .unchanged
        }
        var selectedMatches = matches
        if matches.count > 1,
           matches.allSatisfy({ $0.shift > 2 }),
           let minimumShift = matches.map(\.shift).min(),
           let maximumShift = matches.map(\.shift).max(),
           maximumShift - minimumShift <= 2 {
            let ranked = matches.sorted { $0.meanRGBError < $1.meanRGBError }
            if ranked.count >= 2 {
                let best = ranked[0].meanRGBError
                let second = ranked[1].meanRGBError
                let tied = ranked.dropFirst().contains { $0.meanRGBError == best }
                let decisive = !tied && ((best == 0) || (second > 0 && best <= second / 2))
                if decisive {
                    selectedMatches = [ranked[0]]
                }
            }
        }
        guard selectedMatches.count == 1 else {
            return .rejected("Multiple overlaps look alike. Select more distinctive content and scroll in smaller steps.")
        }
        let match = selectedMatches[0]
        alignmentDiagnostic = "verified-shift-rgb-mean=[\(numericMatches)]; selected=\(match.shift)"
        guard match.shift > 0 else {
            return .rejected("Scroll downward. Return to the last captured position before continuing.")
        }
        guard match.textured else {
            return .rejected("The overlap lacks enough detail. Select distinctive content and scroll in smaller steps.")
        }
        return .shifted(match.shift)
    }

    private func accept(_ alignment: Alignment, frame: ScrollCaptureFrame,
                        activating edges: FixedEdges?) -> AppendResult {
        switch alignment {
        case .unchanged: return .unchanged
        case .rejected(let guidance): return .rejected(guidance)
        case .shifted(let rows):
            let activeEdges = edges ?? fixedEdges ?? FixedEdges(top: 0, bottom: 0)
            let bodyEnd = frame.height - activeEdges.bottom
            guard rows <= maximumHeight - height,
                  height + rows <= maximumPixels / width else { return .limitReached }
            if let edges {
                // The first viewport supplied the sole copy of the fixed footer.
                // Keep it after every accepted moving-body strip in image().
                if edges.bottom > 0 {
                    let footerBytes = edges.bottom * width * 4
                    let original = strips.removeLast()
                    fixedFooter = Array(original.suffix(footerBytes))
                    strips.append(Array(original.dropLast(footerBytes)))
                }
                fixedEdges = edges
            }
            let firstByte = (bodyEnd - rows) * width * 4
            let endByte = bodyEnd * width * 4
            strips.append(Array(frame.pixels[firstByte..<endByte]))
            height += rows
            frameCount += 1
            previous = frame
            return .appended(rows: rows)
        }
    }

    private func detectFixedEdges(_ old: ScrollCaptureFrame, _ new: ScrollCaptureFrame) -> FixedEdges? {
        let maxTop = old.height / 4
        let maxBottom = old.height / 5
        var top = 0
        while top < maxTop && rowMatches(old, new, row: top) { top += 1 }
        var bottom = 0
        while bottom < maxBottom && rowMatches(old, new, row: old.height - bottom - 1) { bottom += 1 }
        // A few incidental equal rows are not enough to identify fixed chrome.
        if top < 4 { top = 0 }
        if bottom < 4 { bottom = 0 }
        guard top + bottom > 0,
              old.height - top - bottom >= old.height / 2 + 64 else { return nil }
        return FixedEdges(top: top, bottom: bottom)
    }

    private func rowMatches(_ old: ScrollCaptureFrame, _ new: ScrollCaptureFrame, row: Int) -> Bool {
        let start = row * width * 4
        let end = start + width * 4
        return old.pixels[start..<end].elementsEqual(new.pixels[start..<end])
    }

    private func fixedBandsMatch(_ old: ScrollCaptureFrame, _ new: ScrollCaptureFrame,
                                 edges: FixedEdges) -> Bool {
        for row in 0..<edges.top where !rowMatches(old, new, row: row) { return false }
        for row in (old.height - edges.bottom)..<old.height where !rowMatches(old, new, row: row) { return false }
        return true
    }

    func image() -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        // The same cap is checked before constructing a contiguous export buffer.
        guard height <= maximumPixels / width else { return nil }
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) in
            var offset = 0
            for strip in strips {
                strip.withUnsafeBytes { source in
                    destination.baseAddress!.advanced(by: offset).copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
                offset += strip.count
            }
            fixedFooter.withUnsafeBytes { source in
                if source.count > 0 {
                    destination.baseAddress!.advanced(by: offset).copyMemory(from: source.baseAddress!, byteCount: source.count)
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        // The provider preserves top-to-bottom rows without a CGContext draw.
        // When drawing into a y-up CGContext, the caller must flip its transform.
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                           .union(.byteOrder32Big), provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }

    func reset() {
        width = 0
        height = 0
        frameCount = 0
        strips = []
        previous = nil
        fixedEdges = nil
        fixedFooter = []
    }

    private struct Candidate { let shift: Int; let score: Double }

    private struct RowRGBSums {
        let red: Int
        let green: Int
        let blue: Int

        func difference(from other: RowRGBSums) -> Int {
            abs(red - other.red) + abs(green - other.green) + abs(blue - other.blue)
        }
    }

    /// Returns nil when exhaustive full verification would exceed its budget.
    /// A discarded shift must violate an existing RGB-difference limit; bad
    /// pixels, texture, direction, and uniqueness remain full-verification work.
    private func exhaustiveCandidateShifts(_ old: ScrollCaptureFrame, _ new: ScrollCaptureFrame,
                                           edges: FixedEdges, maximumShift: Int,
                                           informativeColumns: [Int]?) -> [Int]? {
        let bodyHeight = old.height - edges.top - edges.bottom
        let oldGlobal = rowRGBSums(old, rows: edges.top..<(edges.top + bodyHeight), columns: 0..<width)
        let newGlobal = rowRGBSums(new, rows: edges.top..<(edges.top + bodyHeight), columns: 0..<width)
        let content = informativeRange(informativeColumns)
        let oldContent = content.map { rowRGBSums(old, rows: edges.top..<(edges.top + bodyHeight), columns: $0) }
        let newContent = content.map { rowRGBSums(new, rows: edges.top..<(edges.top + bodyHeight), columns: $0) }
        let maximumCandidates = 32
        let maximumVerificationPixels = 64_000_000
        let maximumRowComparisons = 8_000_000
        var shifts: [Int] = []
        var verificationPixels = 0
        var rowComparisons = 0

        for shift in -maximumShift...maximumShift {
            let overlap = bodyHeight - abs(shift)
            let oldStart = max(shift, 0)
            let newStart = max(-shift, 0)
            let globalLimit = overlap * width * 3 * 3
            let contentLimit = content.map { overlap * $0.count * 3 * 3 }
            var globalLowerBound = 0
            var contentLowerBound = 0
            var possible = true
            for row in 0..<overlap {
                guard rowComparisons < maximumRowComparisons else { return nil }
                rowComparisons += 1
                globalLowerBound += oldGlobal[oldStart + row].difference(from: newGlobal[newStart + row])
                if globalLowerBound > globalLimit { possible = false; break }
                if let oldContent, let newContent, let contentLimit {
                    contentLowerBound += oldContent[oldStart + row].difference(from: newContent[newStart + row])
                    if contentLowerBound > contentLimit { possible = false; break }
                }
            }
            guard possible else { continue }
            let pixels = overlap * width
            guard shifts.count < maximumCandidates,
                  pixels <= maximumVerificationPixels - verificationPixels else { return nil }
            shifts.append(shift)
            verificationPixels += pixels
        }
        return shifts
    }

    private func rowRGBSums(_ frame: ScrollCaptureFrame, rows: Range<Int>,
                            columns: Range<Int>) -> [RowRGBSums] {
        var sums: [RowRGBSums] = []
        sums.reserveCapacity(rows.count)
        for row in rows {
            var red = 0, green = 0, blue = 0
            for column in columns {
                let index = (row * width + column) * 4
                red += Int(frame.pixels[index])
                green += Int(frame.pixels[index + 1])
                blue += Int(frame.pixels[index + 2])
            }
            sums.append(RowRGBSums(red: red, green: green, blue: blue))
        }
        return sums
    }

    private func informativeRange(_ columns: [Int]?) -> Range<Int>? {
        guard let columns, let first = columns.first, let last = columns.last else { return nil }
        let columnStep = max(1, (width - 1) / max(1, min(48, width) - 1))
        return max(0, first - columnStep)..<min(width, last + columnStep + 1)
    }

    private func sparseColumns(_ columns: [Int]) -> [Int]? {
        let sampledCount = min(48, width)
        return columns.count >= 3 && columns.count * 4 < sampledCount * 3 ? columns : nil
    }

    private func sampledColumns(_ frame: ScrollCaptureFrame, edges: FixedEdges,
                                count: Int) -> [Int] {
        let columnCount = min(count, width)
        let bodyHeight = frame.height - edges.top - edges.bottom
        let rowCount = min(128, bodyHeight)
        let positions = (0..<columnCount).map { $0 * (width - 1) / max(1, columnCount - 1) }
        var informative: [Int] = []
        for x in positions {
            var darkest = 255
            var lightest = 0
            for r in 0..<rowCount {
                let start = r * bodyHeight / rowCount
                let end = (r + 1) * bodyHeight / rowCount
                let hash = UInt64(r + 1) &* 0x9e3779b97f4a7c15
                let y = edges.top + start + Int((hash ^ (hash >> 32)) % UInt64(max(1, end - start)))
                let index = (y * width + x) * 4
                let tone = (Int(frame.pixels[index]) + Int(frame.pixels[index + 1]) + Int(frame.pixels[index + 2])) / 3
                darkest = min(darkest, tone)
                lightest = max(lightest, tone)
            }
            if lightest - darkest >= 24 { informative.append(x) }
        }
        // A tiny or blank selection has no trustworthy location evidence.
        // Retain the original uniform scoring and ambiguity behavior there.
        return informative.count >= 3 ? informative : positions
    }

    private func sampledScore(_ old: ScrollCaptureFrame, _ new: ScrollCaptureFrame,
                              shift: Int, rows: Int, columns: [Int], edges: FixedEdges) -> Double {
        let overlap = old.height - edges.top - edges.bottom - abs(shift)
        let oldStart = edges.top + max(shift, 0)
        let newStart = edges.top + max(-shift, 0)
        let rowCount = min(rows, overlap)
        var difference = 0
        for r in 0..<rowCount {
            // Regular row spacing can sample only the white gaps between text
            // lines. A deterministic offset within each stratum avoids that alias.
            let start = r * overlap / rowCount
            let end = (r + 1) * overlap / rowCount
            let hash = UInt64(r + 1) &* 0x9e3779b97f4a7c15
            let y = start + Int((hash ^ (hash >> 32)) % UInt64(max(1, end - start)))
            for x in columns {
                let a = ((oldStart + y) * width + x) * 4
                let b = ((newStart + y) * width + x) * 4
                for channel in 0..<3 { difference += abs(Int(old.pixels[a + channel]) - Int(new.pixels[b + channel])) }
            }
        }
        return Double(difference) / Double(rowCount * columns.count * 3)
    }

    private func verifies(_ old: ScrollCaptureFrame, _ new: ScrollCaptureFrame,
                          shift: Int, edges: FixedEdges = FixedEdges(top: 0, bottom: 0),
                          informativeColumns: [Int]? = nil) -> (matches: Bool, textured: Bool, meanRGBError: Double) {
        let overlap = old.height - edges.top - edges.bottom - abs(shift)
        let oldStart = edges.top + max(shift, 0)
        let newStart = edges.top + max(-shift, 0)
        let pixelCount = overlap * width
        let allowedDifference = pixelCount * 3 * 3
        let allowedBadPixels = max(1, pixelCount * 15 / 1000)
        let content = informativeRange(informativeColumns)
        let selectedStart = content?.lowerBound ?? 0
        let selectedEnd = content?.upperBound ?? 0
        let selectedPixelCount = overlap * (selectedEnd - selectedStart)
        let selectedDifferenceLimit = selectedPixelCount * 3 * 3
        let selectedBadPixelLimit = max(1, selectedPixelCount * 15 / 1000)
        var difference = 0
        var badPixels = 0
        var selectedDifference = 0
        var selectedBadPixels = 0
        var edges = 0
        var detailedRows = 0
        for y in 0..<overlap {
            var rowEdges = 0
            for x in 0..<width {
                let inContent = informativeColumns != nil && x >= selectedStart && x < selectedEnd
                let a = ((oldStart + y) * width + x) * 4
                let b = ((newStart + y) * width + x) * 4
                var maximumDifference = 0
                var edge = 0
                for channel in 0..<4 {
                    let delta = abs(Int(old.pixels[a + channel]) - Int(new.pixels[b + channel]))
                    maximumDifference = max(maximumDifference, delta)
                    if channel < 3 {
                        difference += delta
                        if inContent { selectedDifference += delta }
                        if x > 0 { edge += abs(Int(old.pixels[a + channel]) - Int(old.pixels[a - 4 + channel])) }
                        if y > 0 { edge += abs(Int(old.pixels[a + channel]) - Int(old.pixels[a - width * 4 + channel])) }
                    }
                }
                if maximumDifference > 18 {
                    badPixels += 1
                    if inContent { selectedBadPixels += 1 }
                }
                if edge > 36 { edges += 1; rowEdges += 1 }
                // A mismatch can only grow, so stop early on a clear failure.
                if difference > allowedDifference || badPixels > allowedBadPixels ||
                    (informativeColumns != nil &&
                     (selectedDifference > selectedDifferenceLimit || selectedBadPixels > selectedBadPixelLimit)) {
                    return (false, false, .infinity)
                }
            }
            if rowEdges >= max(2, width / 200) { detailedRows += 1 }
        }
        let textured = edges >= max(16, pixelCount / 500) && detailedRows >= max(6, overlap / 16)
        return (true, textured, Double(difference) / Double(pixelCount * 3))
    }
}
