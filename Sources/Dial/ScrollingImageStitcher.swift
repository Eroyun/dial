// SwiftShot image-stitching engine reused under the MIT License.
// Copyright (c) 2026 Ahmad Faraz.
// Upstream: pirzada-ahmadfaraz/swiftshot-mac
// Revision: 0066e07095c51b224447067d5eb89401642e1d5f
// Source: Sources/CleanShotClone/Capture/ImageStitcher.swift
// License and adaptation details: Resources/ThirdParty/SwiftShot-LICENSE.txt
// and Resources/ThirdParty/SwiftShot-NOTICE.md.

import CoreGraphics
import Foundation

protocol ScrollImageAssembler: AnyObject {
    var width: Int { get }
    var height: Int { get }
    var frameCount: Int { get }
    func image() -> CGImage?
}

extension ScrollStitcher: ScrollImageAssembler {}

/// Serial adapter around SwiftShot's reused matcher and pixel compositor.
/// It tolerates some fixed/animated pixels when finding a moving region, but
/// can trim densely stationary side columns from an automatic page selection.
/// No unmatched full-frame fallback is permitted. An accepted match is image
/// alignment evidence, not proof of the page's top, bottom, or completeness.
final class ScrollingImageStitcher: ScrollImageAssembler {
    typealias AppendResult = ScrollStitcher.AppendResult

    private(set) var width = 0
    /// Export height, including any deferred footer rows.
    private(set) var height = 0
    private(set) var frameCount = 0
    /// Original input coordinates of the full-pixel, texture-verified overlap
    /// body from the last accepted movement. Absent before positive movement.
    private(set) var verifiedContentRect: CGRect?
    private(set) var lastAlignment: [String: String] = [:]
    private var rowStore: CaptureRowStore?
    private var previous: CGImage?
    private var previousFrame: ScrollCaptureFrame?
    private var bottomExclude = 0
    private let captureUpward: Bool
    private let trimStationaryColumns: Bool
    private var movingColumns: Range<Int>?
    private let maximumPixels: Int
    private let maximumHeight: Int
    private let maximumFrames: Int
    private let maximumFramePixels = 8_000_000

    init(maximumPixels: Int = 40_000_000, maximumHeight: Int = 20_000,
         maximumFrames: Int = 200, captureUpward: Bool = false,
         trimStationaryColumns: Bool = false) {
        precondition(maximumPixels > 0 && maximumPixels <= 512_000_000)
        precondition(maximumHeight > 0 && maximumHeight <= 1_000_000)
        precondition(maximumFrames > 0 && maximumFrames <= 4_000)
        self.captureUpward = captureUpward
        self.trimStationaryColumns = trimStationaryColumns
        self.maximumPixels = maximumPixels
        self.maximumHeight = maximumHeight
        self.maximumFrames = maximumFrames
    }

    /// Rejected, stationary, and capped observations leave all state unchanged.
    func append(_ frame: ScrollCaptureFrame) -> AppendResult {
        // Check the incoming allocation bound before making an upward copy.
        guard frame.width <= maximumFramePixels / frame.height else { return .limitReached }
        guard captureUpward else { return appendNormalized(frame) }
        var pixels = [UInt8](repeating: 0, count: frame.pixels.count)
        let rowBytes = frame.width * 4
        pixels.withUnsafeMutableBytes { destination in
            frame.pixels.withUnsafeBytes { source in
                for row in 0..<frame.height {
                    memcpy(destination.baseAddress!.advanced(by: row * rowBytes),
                           source.baseAddress!.advanced(by: (frame.height - 1 - row) * rowBytes), rowBytes)
                }
            }
        }
        guard let flipped = try? ScrollCaptureFrame(width: frame.width, height: frame.height, pixels: pixels) else {
            return .rejected("The capture image could not be read.")
        }
        return appendNormalized(flipped)
    }

    /// Upward input is normalized to downward motion; every matcher, witness,
    /// compositor and commit guard below is shared by both traversal directions.
    private func appendNormalized(_ frame: ScrollCaptureFrame) -> AppendResult {
        lastAlignment = [:]
        guard frame.width <= maximumFramePixels / frame.height else { return .limitReached }
        if let previous {
            guard frame.width == width && frame.height == previous.height else {
                return .rejected("The capture size changed. Start again with a fixed content selection.")
            }
        } else {
            guard frame.height <= maximumHeight,
                  frame.width <= maximumPixels / frame.height else { return .limitReached }
        }
        guard let next = Self.image(from: frame) else {
            return .rejected("The capture image could not be read.")
        }
        guard let previous, let rowStore else {
            width = frame.width
            height = frame.height
            frameCount = 1
            self.previous = next
            previousFrame = frame
            guard let store = try? CaptureRowStore(width: frame.width, maximumPixels: maximumPixels),
                  store.seed(frame: frame) else {
                width = 0; height = 0; frameCount = 0; self.previous = nil; previousFrame = nil
                return .rejected("The capture could not be stored locally. Check available disk space.")
            }
            self.rowStore = store
            return .first
        }
        guard let previousFrame else { return .rejected("The scrolling reference is unavailable.") }
        let region = Self.movingRegion(previousFrame, frame)
        var proposal = SwiftShotImageStitcher.detectScroll(previous: previous, next: next)
        lastAlignment["upstream"] = String(describing: proposal)
        var denseAlignment: DenseAlignment?
        switch proposal {
        case .stationary:
            guard region.meaningfullyChanged else { return .unchanged }
            proposal = Self.croppedProposal(previous: previousFrame, next: frame, region: region)
        case .noMatch:
            proposal = Self.croppedProposal(previous: previousFrame, next: frame, region: region)
        case .scrolled: break
        }
        denseAlignment = Self.denseOffset(previousFrame, frame, region: region,
                                          bottomRows: region.fixedBottomRows, captureUpward: captureUpward,
                                          diagnostic: &lastAlignment)
        if denseAlignment == nil {
            // One expanded, direction-aware witness can use document texture
            // near the safe ROI edge while still excluding floating controls.
            // It is a second exact dense proof, never a relaxed score fallback.
            denseAlignment = Self.expandedDenseOffset(previousFrame, frame, region: region,
                                                       captureUpward: captureUpward,
                                                       diagnostic: &lastAlignment)
        }
        if let denseAlignment {
            // The sampled proposal is a hint. A different uniquely verified
            // dense displacement is authoritative, including large embedded
            // pictures and clamped final movements. Do not reject that valid
            // overlap merely because the fast matcher proposed another offset.
            proposal = .scrolled(.init(scrollPixels: denseAlignment.rows,
                                       fixedBottomRows: denseAlignment.deferredBottomRows))
        }
        switch proposal {
        case .stationary:
            // Dense changes must not disappear because upstream samples missed
            // a narrow moving pane or corrupt, unsampled columns.
            return region.meaningfullyChanged
                ? .rejected("The moving content could not be aligned reliably.") : .unchanged
        case .noMatch:
            return .rejected("No reliable scrolling overlap. Wait for the page to settle or select its moving content.")
        case .scrolled(let match):
            let rows = match.scrollPixels
            guard rows > 0, frameCount < maximumFrames,
                  rows <= maximumHeight - height,
                  height + rows <= maximumPixels / width else { return .limitReached }
            // Keep an overlap tail out of every intermediate strip. Floating
            // controls and fades can cover moving text without making an entire
            // row stationary, so a fixed-row detector alone cannot exclude them.
            // Restore the tail exactly once from the final accepted viewport.
            guard let denseAlignment, denseAlignment.rows == rows else {
                return .rejected("The proposed overlap did not match the moving content's full pixels.")
            }
            let nextBottom = max(bottomExclude, denseAlignment.deferredBottomRows)
            let trim = max(0, nextBottom - bottomExclude)
            let endRow = frame.height - nextBottom
            let startRow = max(0, endRow - rows)
            guard endRow > startRow, endRow - startRow == rows, trim < rowStore.height,
                  rowStore.height - trim + rows + nextBottom == height + rows,
                  rowStore.append(frame: frame, rows: startRow..<endRow, trimming: trim) else {
                return .rejected("The scrolling image could not be stored without losing rows. Check available disk space.")
            }
            // Commit only after the bounded row write succeeds completely.
            self.previous = next
            self.previousFrame = frame
            bottomExclude = nextBottom
            height += rows
            frameCount += 1
            verifiedContentRect = denseAlignment.verifiedContentRect
            if trimStationaryColumns {
                // Alignment uses a safe central body, but export must also keep
                // moving pictures or text visible only near a viewport edge.
                let verifiedColumns = region.exportColumns
                if let previousColumns = movingColumns {
                    movingColumns = min(previousColumns.lowerBound, verifiedColumns.lowerBound)..<max(previousColumns.upperBound, verifiedColumns.upperBound)
                } else { movingColumns = verifiedColumns }
            }
            return .appended(rows: rows)
        }
    }

    /// Footer restoration and upward row order are read-only exports. Accepted
    /// rows live in an owned temporary file, rather than copying an ever larger
    /// bitmap after each scroll. The returned image retains its own snapshot.
    func image() -> CGImage? {
        guard let rowStore, let previousFrame,
              let result = rowStore.image(footer: previousFrame, footerRows: bottomExclude,
                                          verticallyFlipped: captureUpward),
              result.width == width, result.height == height else { return nil }
        guard let columns = movingColumns, columns.count < width else { return result }
        return result.cropping(to: CGRect(x: columns.lowerBound, y: 0,
                                          width: columns.count, height: result.height))
    }

    private struct MovingRegion {
        let columns: Range<Int>
        let exportColumns: Range<Int>
        let topRows: Int
        let fixedBottomRows: Int
        let meaningfullyChanged: Bool
    }

    private struct DenseAlignment {
        let rows: Int
        /// Rectangle in original, unnormalized capture coordinates.
        let verifiedContentRect: CGRect
        /// Tail rows that must be withheld from intermediate strips.
        let deferredBottomRows: Int
    }

    /// Only contiguous edge columns equal at zero shift over every body pixel
    /// can be excluded. Interior columns are never masked, even when stationary.
    private static func movingRegion(_ old: ScrollCaptureFrame, _ new: ScrollCaptureFrame) -> MovingRegion {
        // Match the safe central half in either traversal direction. Upward
        // capture flips the viewport, so either edge can contain floating UI.
        // Only the tail is deferred in composition; the complete first frame's
        // leading rows remain intact and the final tail is exported once.
        let top = old.height / 4
        let footer = old.height / 4
        let bottom = old.height - footer
        var unchanged = [Bool](repeating: true, count: old.width)
        var exportUnchanged = unchanged
        var changed = false
        // Top/footer exclusions apply only to alignment. Stationarity must
        // account for meaningful movement anywhere in the captured frame.
        for y in 0..<old.height {
            for x in 0..<old.width {
                let i = (y * old.width + x) * 4
                for channel in 0..<3 {
                    let delta = abs(Int(old.pixels[i + channel]) - Int(new.pixels[i + channel]))
                    if delta != 0 {
                        changed = true
                        exportUnchanged[x] = false
                        if y >= top, y < bottom { unchanged[x] = false }
                    }
                }
            }
        }
        var left = 0, right = old.width
        while left < right && unchanged[left] { left += 1 }
        while right > left && unchanged[right - 1] { right -= 1 }
        var exportLeft = 0, exportRight = old.width
        while exportLeft < exportRight && exportUnchanged[exportLeft] { exportLeft += 1 }
        while exportRight > exportLeft && exportUnchanged[exportRight - 1] { exportRight -= 1 }
        return MovingRegion(columns: left..<right, exportColumns: exportLeft..<exportRight, topRows: top,
                            fixedBottomRows: footer, meaningfullyChanged: changed)
    }

    private static func croppedProposal(previous: ScrollCaptureFrame, next: ScrollCaptureFrame,
                                        region: MovingRegion) -> SwiftShotImageStitcher.DetectResult {
        let minimumWidth = max(32, (previous.width + 4) / 5)
        guard region.columns.count >= minimumWidth,
              region.columns.count < previous.width else { return .noMatch }
        // Repack the ROI: the reused engine reads providers directly, so a lazy
        // CGImage crop's provider/stride must not be mistaken for packed pixels.
        guard let oldFrame = crop(previous, columns: region.columns, top: 0, bottom: 0),
              let newFrame = crop(next, columns: region.columns, top: 0, bottom: 0),
              let old = image(from: oldFrame), let new = image(from: newFrame) else { return .noMatch }
        return SwiftShotImageStitcher.detectScroll(previous: old, next: new)
    }

    /// Reuse Dial's existing dense, textured, unambiguous full-overlap checks as
    /// an independent witness of the upstream proposal. This includes every
    /// pixel column in the moving span, not just upstream's sampled columns.
    private static func denseOffset(_ old: ScrollCaptureFrame, _ new: ScrollCaptureFrame,
                                    region: MovingRegion, bottomRows: Int, captureUpward: Bool,
                                    diagnostic: inout [String: String]) -> DenseAlignment? {
        guard region.columns.count >= max(32, (old.width + 4) / 5),
              let oldBody = crop(old, columns: region.columns, top: region.topRows, bottom: bottomRows),
              let newBody = crop(new, columns: region.columns, top: region.topRows, bottom: bottomRows),
              oldBody.height >= 64 else { diagnostic["dense"] = "invalid_body"; return nil }
        let witness = ScrollStitcher()
        guard witness.append(oldBody) == .first else { diagnostic["dense"] = "seed_failed"; return nil }
        let result = witness.append(newBody)
        diagnostic["dense"] = String(describing: result)
        if let candidates = witness.alignmentDiagnostic { diagnostic["candidates"] = candidates }
        guard case .appended(let rows) = result, rows > 0 else { return nil }
        let normalizedRect = CGRect(x: region.columns.lowerBound, y: region.topRows,
                                    width: region.columns.count,
                                    height: old.height - region.topRows - bottomRows)
        return DenseAlignment(rows: rows,
                              verifiedContentRect: captureRect(normalizedRect, height: old.height,
                                                               captureUpward: captureUpward),
                              deferredBottomRows: bottomRows)
    }

    private static func expandedDenseOffset(_ old: ScrollCaptureFrame, _ new: ScrollCaptureFrame,
                                            region: MovingRegion, captureUpward: Bool,
                                            diagnostic: inout [String: String]) -> DenseAlignment? {
        let cropTop = captureUpward ? old.height / 4 : 0
        let cropBottom = captureUpward ? 0 : old.height / 4
        let minimumWidth = max(32, (old.width + 4) / 5)
        // A blank central alignment band can make movingRegion report no
        // columns even when the expanded edge contains real document texture.
        // In that case the one-shot fallback verifies the full viewport width;
        // the dense matcher still has to prove a unique, directional overlap.
        let columns = region.columns.count >= minimumWidth ? region.columns : 0..<old.width
        guard columns.count >= minimumWidth,
              let oldBody = crop(old, columns: columns, top: cropTop, bottom: cropBottom),
              let newBody = crop(new, columns: columns, top: cropTop, bottom: cropBottom),
              oldBody.height >= 64 else { diagnostic["expanded"] = "invalid_body"; return nil }
        let witness = ScrollStitcher(allowFixedEdges: true)
        guard witness.append(oldBody) == .first else { diagnostic["expanded"] = "seed_failed"; return nil }
        let result = witness.append(newBody)
        diagnostic["expanded"] = String(describing: result)
        if let candidates = witness.alignmentDiagnostic { diagnostic["expandedCandidates"] = candidates }
        guard case .appended(let rows) = result, rows > 0 else { return nil }

        let top = cropTop + witness.fixedTopRows
        let bottom = cropBottom + witness.fixedBottomRows
        let normalizedRect = CGRect(x: columns.lowerBound, y: top,
                                    width: columns.count,
                                    height: old.height - top - bottom)
        guard normalizedRect.height >= 64 else { diagnostic["expanded"] = "invalid_verified_body"; return nil }
        return DenseAlignment(rows: rows,
                              verifiedContentRect: captureRect(normalizedRect, height: old.height,
                                                               captureUpward: captureUpward),
                              deferredBottomRows: max(old.height / 4, cropBottom + witness.fixedBottomRows))
    }

    private static func captureRect(_ normalizedRect: CGRect, height: Int,
                                    captureUpward: Bool) -> CGRect {
        guard captureUpward else { return normalizedRect }
        return CGRect(x: normalizedRect.minX,
                      y: CGFloat(height) - normalizedRect.maxY,
                      width: normalizedRect.width, height: normalizedRect.height)
    }

    private static func crop(_ frame: ScrollCaptureFrame, columns: Range<Int>,
                             top: Int, bottom: Int) -> ScrollCaptureFrame? {
        let bodyHeight = frame.height - top - bottom
        guard !columns.isEmpty, columns.lowerBound >= 0, columns.upperBound <= frame.width,
              top >= 0, bottom >= 0, bodyHeight > 0 else { return nil }
        var pixels: [UInt8] = []
        pixels.reserveCapacity(columns.count * bodyHeight * 4)
        for y in top..<(frame.height - bottom) {
            let start = (y * frame.width + columns.lowerBound) * 4
            pixels.append(contentsOf: frame.pixels[start..<(start + columns.count * 4)])
        }
        return try? ScrollCaptureFrame(width: columns.count, height: bodyHeight, pixels: pixels)
    }

    private static func image(from frame: ScrollCaptureFrame) -> CGImage? {
        let data = Data(frame.pixels)
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: frame.width, height: frame.height,
                       bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
                           .union(.byteOrder32Big),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Stitches vertically-scrolling screenshot frames at full pixel resolution.
///
/// Detection: every frame is reduced to per-row signature vectors — mean luminance
/// over `segmentCount` horizontal segments. Consecutive frames are aligned by
/// scanning vertical shifts over a center band of rows (dodging sticky headers and
/// footers). All accept thresholds are *relative*: the winning shift must clearly
/// beat the median score across all candidate shifts (what a wrong alignment costs
/// on THIS content) and the zero shift, so detection self-calibrates to dark,
/// low-contrast, or busy content instead of relying on absolute luminance numbers.
/// The worst segments are dropped from every comparison, which ignores animated
/// columns (avatars, GIFs, spinners). Ambiguous matches (periodic chat layouts) and
/// upward scrolls are rejected rather than guessed.
///
/// Composition: newly scrolled-in rows are appended below the stitched image with a
/// raw pixel copy — the accumulated image is never re-rendered. Rows pinned to the
/// bottom of the viewport (chat inputs, toolbars) are detected, withheld from every
/// append, and flushed exactly once when the session ends; the bookkeeping is
/// continuity-preserving even when the fixed-row estimate is wrong.
private enum SwiftShotImageStitcher {

    struct ScrollMatch {
        /// How many pixels the content scrolled down between the two frames.
        let scrollPixels: Int
        /// Rows at the bottom of the viewport that did not move with the content.
        let fixedBottomRows: Int
    }

    enum DetectResult {
        /// The viewport did not move (animation-only changes count as stationary).
        case stationary
        /// The frames differ but no confident alignment exists — wait, don't guess.
        case noMatch
        case scrolled(ScrollMatch)
    }

    // MARK: - Tuning

    /// Signature vector width per row.
    private static let segmentCount = 12
    /// Worst-matching segments ignored per comparison (dodges animated columns).
    private static let droppedSegments = 2
    private static let minScroll = 4

    // MARK: - Public API

    /// Align `next` against `previous` and report how far the content scrolled down.
    static func detectScroll(previous: CGImage, next: CGImage) -> DetectResult {
        guard previous.width == next.width, previous.height == next.height else { return .noMatch }
        let w = previous.width
        let h = previous.height
        guard h > 80 else { return .noMatch }

        guard let prevPix = rawPixels(previous), let nextPix = rawPixels(next),
              let prevSig = segmentSignatures(prevPix, width: w, height: h),
              let nextSig = segmentSignatures(nextPix, width: w, height: h) else { return .noMatch }

        let K = segmentCount

        // Texture prefix sums for `next`: a comparison window that is flat
        // background in both frames scores a vacuous, evidence-free 0 — such
        // windows may neither claim a match nor contest one as a rival.
        var deltaPrefix = [Double](repeating: 0, count: h + 1)
        for y in 0..<h {
            var d = 0.0
            if y < h - 2 {
                for k in 0..<K { d += abs(nextSig[y * K + k] - nextSig[(y + 2) * K + k]) }
                d /= Double(K)
            }
            deltaPrefix[y + 1] = deltaPrefix[y] + d
        }
        let minTexture = 0.5

        // Fixed rows at the bottom of the viewport (footers, chat inputs) are
        // identical between the frames regardless of scroll, so they can be
        // measured BEFORE alignment — and must be: prev-side comparison windows
        // that reach into a fixed footer poison the true alignment's score.
        //
        // Two estimates with different jobs: the liberal identical-row streak is
        // used for append deferral (safe by construction, flushed at Done), but
        // flat background rows that merely *coincide* between frames would crush
        // the scan range. The distinction is binary: a streak containing ANY
        // texture is a real fixed footer (borders, buttons, input pills) and the
        // whole streak limits alignment; a textureless streak is coincidental
        // background and scrolls with the content — it limits nothing.
        let fixedBottom = fixedBottomRows(prevPix, nextPix, width: w, height: h)
        var certainFixedBottom = 0
        for y in (h - fixedBottom)..<h {
            if deltaPrefix[y + 1] - deltaPrefix[y] >= minTexture {
                certainFixedBottom = fixedBottom
                break
            }
        }
        let hEff = h - certainFixedBottom

        // Compare a center band: skips sticky headers (top) and sticky footers /
        // chat inputs (bottom) that stay fixed while the content scrolls.
        let bandStart = h / 4
        let bandEnd = min((h * 3) / 4, hEff)
        // Tiny tail windows produce statistically meaningless scores — require a
        // meaningful slice of the band to overlap for a shift to be considered.
        let minRows = max(24, (bandEnd - bandStart) / 6)
        let maxScroll = hEff - bandStart - minRows
        guard maxScroll > minScroll, bandEnd - bandStart >= minRows else { return .noMatch }

        /// Trimmed L1 distance between band signatures at shift `s`
        /// (`s` > 0 = content moved up by `s` px, i.e. the user scrolled down).
        func score(_ s: Int) -> Double {
            let yStart = max(bandStart, -s)
            let yEnd = min(bandEnd, hEff - s)
            guard yEnd - yStart >= minRows else { return .infinity }
            var segSum = [Double](repeating: 0, count: K)
            var rows = 0
            var y = yStart
            while y < yEnd {
                let p = (y + s) * K
                let q = y * K
                for k in 0..<K {
                    segSum[k] += abs(prevSig[p + k] - nextSig[q + k])
                }
                rows += 1
                y += 2
            }
            guard rows > 0 else { return .infinity }
            segSum.sort()
            var total = 0.0
            for k in 0..<(K - droppedSegments) { total += segSum[k] }
            return total / Double((K - droppedSegments) * rows)
        }

        func textured(_ s: Int) -> Bool {
            let yStart = max(bandStart, -s)
            let yEnd = min(min(bandEnd, hEff - s), h - 2)
            guard yEnd > yStart else { return false }
            return (deltaPrefix[yEnd] - deltaPrefix[yStart]) / Double(yEnd - yStart) >= minTexture
        }

        // Stationary check is animation-tolerant: the trimmed score ignores the
        // worst segments, so a blinking GIF or hover highlight no longer turns an
        // idle viewport into a fake "scroll" hunt.
        let staticScore = score(0)
        if staticScore < 0.35 { return .stationary }

        var candidates: [(s: Int, score: Double)] = []
        var s = minScroll
        while s <= maxScroll {
            let sc = score(s)
            if sc.isFinite, textured(s) { candidates.append((s, sc)) }
            s += 2
        }
        guard candidates.count >= 8,
              var best = candidates.min(by: { $0.score < $1.score }) else { return .noMatch }

        // Refine ±2 around the coarse winner (scan stepped by 2).
        for cand in max(minScroll, best.s - 2)...min(maxScroll, best.s + 2) where cand != best.s {
            let sc = score(cand)
            if sc < best.score { best = (cand, sc) }
        }

        // Chance baseline: what a wrong alignment scores on this content. The
        // winner must clearly beat both chance and "didn't scroll" — relative
        // gates that hold on dark Discord themes and bright documents alike.
        let sortedScores = candidates.map(\.score).sorted()
        let baseline = sortedScores[sortedScores.count / 2]
        guard best.score < baseline * 0.45, best.score < staticScore * 0.5 else { return .noMatch }

        // Unambiguous: no rival minimum away from the winner (periodic layouts —
        // repeated chat rows, table stripes — produce several near-equal minima).
        // The segment metric can be blind to thin differences its trimming dropped,
        // so a rival only vetoes the winner if it is also pixel-real: a genuinely
        // periodic layout still vetoes, a trim-blind phantom does not.
        if let rival = candidates
            .filter({ abs($0.s - best.s) >= 12 })
            .min(by: { $0.score < $1.score }),
           rival.score < best.score * 1.25 + 0.05,
           verifyAlignment(prevPix, nextPix, width: w, effectiveHeight: hEff, height: h, shift: rival.s) {
            return .noMatch
        }

        // Upward scroll must not be mistaken for a downward one — wait it out.
        // Same rule: a negative shift only vetoes if it is pixel-real.
        var negBest: (s: Int, score: Double) = (0, .infinity)
        var neg = -minScroll
        while neg >= -(h / 2) {
            if textured(neg) {
                let sc = score(neg)
                if sc < negBest.score { negBest = (neg, sc) }
            }
            neg -= 4
        }
        if negBest.score < best.score * 1.15 + 0.02,
           verifyAlignment(prevPix, nextPix, width: w, effectiveHeight: hEff, height: h, shift: negBest.s) {
            return .noMatch
        }

        // Pixel-level verification of the winning alignment.
        guard verifyAlignment(prevPix, nextPix, width: w, effectiveHeight: hEff, height: h, shift: best.s) else {
            return .noMatch
        }

        return .scrolled(ScrollMatch(scrollPixels: best.s, fixedBottomRows: fixedBottom))
    }

    /// Append the newly scrolled-in rows of `newFrame` below `stitched`.
    ///
    /// The bottom `bottomExclude` rows of the viewport (fixed footers) are withheld
    /// from the append; when the estimate grows, the difference is trimmed off the
    /// stitched bottom so the seam stays continuous. Withheld rows are restored by
    /// `flushBottom` when the session ends.
    static func appendScroll(
        stitched: CGImage, newFrame: CGImage, scrollPixels: Int,
        previousBottomExclude: Int, bottomExclude: Int
    ) -> CGImage? {
        let h = newFrame.height
        let trim = max(0, bottomExclude - previousBottomExclude)
        let srcEnd = h - bottomExclude
        let srcStart = max(0, srcEnd - scrollPixels)
        guard srcEnd > srcStart, scrollPixels > 0, trim < stitched.height else { return nil }
        return verticalConcat(stitched, newFrame, topRows: stitched.height - trim,
                              srcStart: srcStart, srcCount: srcEnd - srcStart)
    }

    /// Restore the withheld fixed-bottom rows (footer/chat input) exactly once.
    static func flushBottom(stitched: CGImage, lastFrame: CGImage, bottomExclude: Int) -> CGImage? {
        guard bottomExclude > 0 else { return stitched }
        let h = lastFrame.height
        guard bottomExclude < h else { return stitched }
        return verticalConcat(stitched, lastFrame, topRows: stitched.height,
                              srcStart: h - bottomExclude, srcCount: bottomExclude) ?? stitched
    }

    /// Cheap sameness test used to decide when a viewport has settled after sync
    /// was lost. Compares two sampled bands; animation keeps this false.
    static func framesRoughlyEqual(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        let h = a.height
        guard h > 80, let aPix = rawPixels(a), let bPix = rawPixels(b) else { return false }
        let rows = min(32, h / 4)
        let d1 = sampledDiff(aPix, bPix, aRow: h / 4, bRow: h / 4, rows: rows,
                             width: a.width, aHeight: h, bHeight: h)
        let d2 = sampledDiff(aPix, bPix, aRow: (h * 5) / 8, bRow: (h * 5) / 8, rows: rows,
                             width: a.width, aHeight: h, bHeight: h)
        return d1 < 1.2 && d2 < 1.2
    }

    /// A copy in the canonical RGBA layout the stitcher composes in.
    static func canonicalCopy(_ image: CGImage) -> CGImage? {
        if isCanonical(image) { return image }
        return redrawCanonical(image)
    }

    /// Downsample for live preview only — never used for the final export.
    static func previewImage(from image: CGImage, maxWidth: Int, maxHeight: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let scale = min(Double(maxWidth) / Double(w), Double(maxHeight) / Double(h), 1.0)
        let tw = max(1, Int(Double(w) * scale)), th = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        return ctx.makeImage()
    }

    // MARK: - Signatures (scroll detection)

    /// Per-row signature: mean luminance over `segmentCount` horizontal segments,
    /// flattened to `height * segmentCount` values. Channel order doesn't matter
    /// because all three color channels are summed symmetrically.
    private static func segmentSignatures(_ pix: PixelBuffer, width w: Int, height h: Int) -> [Double]? {
        let K = segmentCount
        let bpr = pix.bytesPerRow
        let rowLen = w * 4

        // Sample every 8th pixel; map each sample to a horizontal segment.
        var xs: [Int] = []
        var x = 0
        while x + 2 < rowLen {
            xs.append(x)
            x += 32
        }
        let n = xs.count
        guard n > 0 else { return nil }
        let segOf = (0..<n).map { min(K - 1, $0 * K / n) }
        var segWeight = [Double](repeating: 0, count: K)
        for i in 0..<n { segWeight[segOf[i]] += 3 }

        var sig = [Double](repeating: 0, count: h * K)
        pix.bytes.withUnsafeBytes { raw in
            guard let p = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            for y in 0..<h {
                let rowOff = y * bpr
                guard rowOff + rowLen <= raw.count else { continue }
                let base = y * K
                for i in 0..<n {
                    let off = rowOff + xs[i]
                    sig[base + segOf[i]] += Double(Int(p[off]) + Int(p[off + 1]) + Int(p[off + 2]))
                }
            }
        }
        for y in 0..<h {
            let base = y * K
            for k in 0..<K where segWeight[k] > 0 {
                sig[base + k] /= segWeight[k]
            }
        }
        return sig
    }

    // MARK: - Pixel verification

    /// Verify the winning shift against raw pixels in up to three bands spread
    /// across the overlap. Each band is judged *relative* to a deliberately wrong
    /// control shift — absolute pixel-diff thresholds are meaningless on dark
    /// themes where most pixels match by coincidence. A 2-of-3 vote tolerates one
    /// band being covered by animation.
    private static func verifyAlignment(
        _ prevPix: PixelBuffer, _ nextPix: PixelBuffer,
        width: Int, effectiveHeight hEff: Int, height h: Int, shift s: Int
    ) -> Bool {
        let headerSkip = h / 8
        let available = (hEff - s) - headerSkip
        guard available >= 12 else { return false }
        let bandRows = min(28, available)

        var bandStarts = [headerSkip]
        if available > bandRows {
            let span = available - bandRows
            bandStarts.append(headerSkip + span / 2)
            bandStarts.append(headerSkip + span)
        }
        var seen = Set<Int>()
        bandStarts = bandStarts.filter { seen.insert($0).inserted }

        var passes = 0
        for y0 in bandStarts {
            let match = sampledDiff(prevPix, nextPix, aRow: y0 + s, bRow: y0,
                                    rows: bandRows, width: width, aHeight: h, bHeight: h)
            let controlShift = (y0 + s + 17 + bandRows <= hEff) ? s + 17 : s - 17
            let control = sampledDiff(prevPix, nextPix, aRow: y0 + controlShift, bRow: y0,
                                      rows: bandRows, width: width, aHeight: h, bHeight: h)
            if match < 1.6 {
                passes += 1
            } else if control.isFinite, control > 0, match < control * 0.4 {
                passes += 1
            }
        }
        return passes * 3 >= bandStarts.count * 2
    }

    /// Rows at the bottom of the viewport identical between the two frames even
    /// though the content scrolled — fixed footers, chat inputs, toolbars. Flat
    /// background rows can count too; that's safe, the append bookkeeping only
    /// defers them to the end of the session.
    private static func fixedBottomRows(
        _ prevPix: PixelBuffer, _ nextPix: PixelBuffer, width: Int, height h: Int
    ) -> Int {
        let cap = h / 4
        var n = 0
        while n < cap {
            let y = h - 1 - n
            let d = sampledDiff(prevPix, nextPix, aRow: y, bRow: y, rows: 1,
                                width: width, aHeight: h, bHeight: h)
            guard d < 2.0 else { break }
            n += 1
        }
        return n
    }

    /// Mean absolute per-channel difference over sampled pixels of two row ranges.
    private static func sampledDiff(
        _ a: PixelBuffer, _ b: PixelBuffer,
        aRow: Int, bRow: Int, rows: Int,
        width: Int, aHeight: Int, bHeight: Int
    ) -> Double {
        var sum = 0.0
        var count = 0.0
        a.bytes.withUnsafeBytes { aRaw in
            b.bytes.withUnsafeBytes { bRaw in
                guard let ap = aRaw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let bp = bRaw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                for r in 0..<rows {
                    let ay = aRow + r, by = bRow + r
                    guard ay >= 0, ay < aHeight, by >= 0, by < bHeight else { continue }
                    let aOff = ay * a.bytesPerRow, bOff = by * b.bytesPerRow
                    guard aOff + width * 4 <= aRaw.count, bOff + width * 4 <= bRaw.count else { continue }
                    var x = 0
                    while x + 2 < width * 4 {
                        for c in 0..<3 {
                            sum += Double(abs(Int(ap[aOff + x + c]) - Int(bp[bOff + x + c])))
                            count += 1
                        }
                        x += 16 // every 4th pixel
                    }
                }
            }
        }
        return count > 0 ? sum / count : .infinity
    }

    // MARK: - Compose (append rows — never re-draw the accumulated image)

    private struct PixelBuffer {
        let bytes: Data
        let bytesPerRow: Int
    }

    /// Copy `topRows` rows of `top`, then rows `[srcStart, srcStart+srcCount)` of
    /// `bottom`, into a fresh canonical image.
    private static func verticalConcat(
        _ top: CGImage, _ bottom: CGImage,
        topRows: Int, srcStart: Int, srcCount: Int
    ) -> CGImage? {
        guard topRows > 0, topRows <= top.height,
              srcCount > 0, srcStart >= 0, srcStart + srcCount <= bottom.height,
              top.width == bottom.width else { return nil }

        // Top is always canonical (built by us); the new frame may need a layout conversion.
        guard let topPix = rawPixels(top),
              let bottomPix = canonicalPixels(bottom) else { return nil }

        let w = top.width
        let totalH = topRows + srcCount
        let destBPR = alignedBytesPerRow(width: w)
        var dest = Data(count: destBPR * totalH)

        let rowBytes = w * 4
        let copied = dest.withUnsafeMutableBytes { raw -> Bool in
            guard let dst = raw.baseAddress else { return false }
            return copyRows(from: topPix.bytes, srcBPR: topPix.bytesPerRow, srcStart: 0, count: topRows,
                            into: dst, dstBPR: destBPR, dstStart: 0, rowBytes: rowBytes)
                && copyRows(from: bottomPix.bytes, srcBPR: bottomPix.bytesPerRow, srcStart: srcStart, count: srcCount,
                            into: dst, dstBPR: destBPR, dstStart: topRows, rowBytes: rowBytes)
        }
        guard copied else { return nil }

        return makeImage(pixels: PixelBuffer(bytes: dest, bytesPerRow: destBPR),
                         width: w, height: totalH, colorSpace: top.colorSpace)
    }

    // MARK: - Pixel access & layout

    private static func rawPixels(_ image: CGImage) -> PixelBuffer? {
        guard let data = image.dataProvider?.data, CFDataGetLength(data) > 0,
              let ptr = CFDataGetBytePtr(data) else { return nil }
        return PixelBuffer(bytes: Data(bytes: ptr, count: CFDataGetLength(data)), bytesPerRow: image.bytesPerRow)
    }

    private static func canonicalPixels(_ image: CGImage) -> PixelBuffer? {
        if isCanonical(image), let direct = rawPixels(image) { return direct }
        guard let redrawn = redrawCanonical(image) else { return nil }
        return rawPixels(redrawn)
    }

    /// Canonical layout: 32-bit RGBA, alpha last, big/default byte order.
    private static func isCanonical(_ image: CGImage) -> Bool {
        guard image.bitsPerPixel == 32, image.bitsPerComponent == 8 else { return false }
        let alpha = image.alphaInfo
        let alphaOK = alpha == .premultipliedLast || alpha == .noneSkipLast || alpha == .last
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        let orderOK = order.rawValue == 0 || order == .byteOrder32Big
        return alphaOK && orderOK
    }

    /// Redraw into canonical RGBA with identity transform (row 0 = visual top).
    private static func redrawCanonical(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .none
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    private static func makeImage(pixels: PixelBuffer, width: Int, height: Int, colorSpace: CGColorSpace?) -> CGImage? {
        let space = colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: pixels.bytes as CFData) else { return nil }
        return CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels.bytesPerRow,
            space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    private static func alignedBytesPerRow(width: Int) -> Int {
        ((width * 4 + 15) / 16) * 16
    }

    private static func copyRows(
        from src: Data, srcBPR: Int, srcStart: Int, count: Int,
        into dst: UnsafeMutableRawPointer, dstBPR: Int, dstStart: Int, rowBytes: Int
    ) -> Bool {
        guard srcStart >= 0, count >= 0 else { return false }
        return src.withUnsafeBytes { raw -> Bool in
            guard let srcBase = raw.baseAddress else { return false }
            for row in 0..<count {
                let sOff = (srcStart + row) * srcBPR
                let dOff = (dstStart + row) * dstBPR
                guard sOff + rowBytes <= raw.count else { return false }
                memcpy(dst.advanced(by: dOff), srcBase.advanced(by: sOff), rowBytes)
            }
            return true
        }
    }
}
