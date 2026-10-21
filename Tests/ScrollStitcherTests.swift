import Foundation
import CoreGraphics
import CoreText

@main
struct ScrollStitcherTests {
    private static func check(_ value: Bool, _ message: String = "Check failed", file: StaticString = #file, line: UInt = #line) {
        precondition(value, message, file: file, line: line)
    }

    static func main() throws {
        let width = 64
        let viewport = 128
        let page = makePage(width: width, height: 2_048)
        func view(_ offset: Int, source: [UInt8]? = nil) throws -> ScrollCaptureFrame {
            let bytes = source ?? page
            let start = offset * width * 4
            return try ScrollCaptureFrame(width: width, height: viewport,
                                          pixels: Array(bytes[start..<(start + viewport * width * 4)]))
        }
        func expectRejected(_ result: ScrollStitcher.AppendResult,
                            file: StaticString = #file, line: UInt = #line) {
            guard case .rejected(let guidance) = result else {
                preconditionFailure("Expected rejection, received \(result)", file: file, line: line)
            }
            check(!guidance.isEmpty)
        }
        func assertImage(_ stitcher: ScrollStitcher, source: [UInt8], rows: Int, expectedWidth: Int = 64) {
            let image = stitcher.image()!
            check(image.width == expectedWidth && image.height == rows)
            check(image.bytesPerRow == expectedWidth * 4)
            let data = image.dataProvider!.data! as Data
            check(Array(data) == Array(source.prefix(rows * expectedWidth * 4)), "Accepted strips must be pixel-exact and preserve row orientation")
        }

        let stitcher = ScrollStitcher()
        check(stitcher.image() == nil)
        check(stitcher.append(try view(0)) == .first)
        assertImage(stitcher, source: page, rows: viewport)
        var offset = 0
        for next in [17, 52, 90, 125, 180, 239] {
            check(stitcher.append(try view(next)) == .appended(rows: next - offset))
            offset = next
            assertImage(stitcher, source: page, rows: viewport + offset)
        }
        check(stitcher.width == width && stitcher.height == viewport + offset && stitcher.frameCount == 7)
        check(stitcher.append(try view(offset)) == .unchanged)
        check(stitcher.frameCount == 7)

        // Upward observations and unrelated captures cannot change the accepted reference.
        expectRejected(stitcher.append(try view(offset - 23)))
        let otherPage = makePage(width: width, height: 2_048, seed: 998)
        expectRejected(stitcher.append(try view(offset + 16, source: otherPage)))
        let resized = try ScrollCaptureFrame(width: width + 1, height: viewport,
                                             pixels: Array(repeating: 255, count: (width + 1) * viewport * 4))
        expectRejected(stitcher.append(resized))
        check(stitcher.append(try view(offset + 16)) == .appended(rows: 16))
        offset += 16
        assertImage(stitcher, source: page, rows: viewport + offset)

        // One-row capture jitter and bounded RGB rounding noise are unchanged;
        // a subsequent deliberate scroll is measured against the original reference.
        let jitter = ScrollStitcher()
        check(jitter.append(try view(0)) == .first)
        check(jitter.append(try view(1)) == .unchanged)
        var noise = try view(0).pixels
        for i in noise.indices where i % 4 != 3 { noise[i] = noise[i] == 255 ? 254 : noise[i] + 1 }
        check(jitter.append(try ScrollCaptureFrame(width: width, height: viewport, pixels: noise)) == .unchanged)
        check(jitter.append(try view(20)) == .appended(rows: 20))
        assertImage(jitter, source: page, rows: viewport + 20)

        // An almost uniform gradient can have an exact alignment but no reliable
        // texture. Repeated panels offer multiple valid shifts and must not append.
        let smooth = (0..<(512 * width)).flatMap { index -> [UInt8] in
            let value = UInt8((index / width) / 4)
            return [value, value, value, 255]
        }
        let lowDetail = ScrollStitcher()
        check(lowDetail.append(try view(0, source: smooth)) == .first)
        let lowDetailResult = lowDetail.append(try view(50, source: smooth))
        expectRejected(lowDetailResult)
        check(lowDetail.height == viewport)
        let panel = makePage(width: width, height: 24)
        let repeating = Array(repeating: panel, count: 32).flatMap { $0 }
        let repeated = ScrollStitcher()
        check(repeated.append(try view(0, source: repeating)) == .first)
        expectRejected(repeated.append(try view(11, source: repeating)))
        check(repeated.frameCount == 1)

        // A fixed header and sideways movement invalidate a vertical overlap.
        var headerOld = try view(0).pixels
        var headerNew = try view(30).pixels
        headerOld.replaceSubrange(0..<(16 * width * 4), with: panel.prefix(16 * width * 4))
        headerNew.replaceSubrange(0..<(16 * width * 4), with: panel.prefix(16 * width * 4))
        let header = ScrollStitcher()
        check(header.append(try ScrollCaptureFrame(width: width, height: viewport, pixels: headerOld)) == .first)
        expectRejected(header.append(try ScrollCaptureFrame(width: width, height: viewport, pixels: headerNew)))

        // Automatic mode may recognize fixed top and bottom chrome only when
        // the moving body supplies a unique, textured, downward overlap.
        let fixedViewport = 320
        let topRows = 32
        let bottomRows = 24
        let bodyRows = fixedViewport - topRows - bottomRows
        let rowBytes = width * 4
        let fixedHeader = Array(makePage(width: width, height: topRows, seed: 111).prefix(topRows * rowBytes))
        let fixedFooter = Array(makePage(width: width, height: bottomRows, seed: 222).prefix(bottomRows * rowBytes))
        let movingPage = makePage(width: width, height: 1_024, seed: 333)
        func fixedView(_ offset: Int, body: [UInt8]? = nil,
                       top: [UInt8]? = nil, bottom: [UInt8]? = nil) throws -> ScrollCaptureFrame {
            let source = body ?? movingPage
            let start = offset * rowBytes
            return try ScrollCaptureFrame(width: width, height: fixedViewport,
                                          pixels: (top ?? fixedHeader) + Array(source[start..<(start + bodyRows * rowBytes)]) + (bottom ?? fixedFooter))
        }
        func assertFixedImage(_ stitcher: ScrollStitcher, offset: Int) {
            let image = stitcher.image()!
            let bytes = image.dataProvider!.data! as Data
            let expected = fixedHeader + Array(movingPage.prefix((bodyRows + offset) * rowBytes)) + fixedFooter
            check(image.width == width && image.height == fixedViewport + offset)
            check(Array(bytes) == expected, "Header, accepted body, and footer must appear once in exact row order")
        }
        let automatic = ScrollStitcher(allowFixedEdges: true)
        check(automatic.append(try fixedView(0)) == .first)
        check(!automatic.fixedEdgesApplied && automatic.fixedEdgesDescription == nil)
        check(automatic.append(try fixedView(45)) == .appended(rows: 45))
        check(automatic.fixedEdgesApplied && automatic.fixedTopRows == topRows && automatic.fixedBottomRows == bottomRows)
        check(automatic.fixedEdgesDescription?.contains("32 fixed top rows") == true)
        assertFixedImage(automatic, offset: 45)
        check(automatic.append(try fixedView(45)) == .unchanged)
        expectRejected(automatic.append(try fixedView(20)))
        var changedHeader = fixedHeader
        changedHeader[0] ^= 0xff
        expectRejected(automatic.append(try fixedView(45, top: changedHeader)))
        expectRejected(automatic.append(try fixedView(80, top: changedHeader)))
        var changedFooter = fixedFooter
        changedFooter[0] ^= 0xff
        expectRejected(automatic.append(try fixedView(45, bottom: changedFooter)))
        expectRejected(automatic.append(try fixedView(80, bottom: changedFooter)))
        check(automatic.frameCount == 2 && automatic.height == fixedViewport + 45)
        check(automatic.append(try fixedView(80)) == .appended(rows: 35))
        assertFixedImage(automatic, offset: 80)
        automatic.reset()
        check(!automatic.fixedEdgesApplied && automatic.fixedEdgesDescription == nil)
        check(automatic.image() == nil)

        let changedAtStart = ScrollStitcher(allowFixedEdges: true)
        check(changedAtStart.append(try fixedView(0)) == .first)
        // Successive observations at one scroll position may first return the
        // old frame, then a transient header, before the final exact viewport.
        // Neither stale nor rejected samples may commit pixels or fixed edges.
        check(changedAtStart.append(try fixedView(0)) == .unchanged)
        expectRejected(changedAtStart.append(try fixedView(45, top: changedHeader)))
        check(changedAtStart.frameCount == 1 && changedAtStart.height == fixedViewport && !changedAtStart.fixedEdgesApplied)
        check(changedAtStart.append(try fixedView(45)) == .appended(rows: 45))
        assertFixedImage(changedAtStart, offset: 45)

        let repeatedBody = Array(repeating: panel, count: 48).flatMap { $0 }
        let ambiguous = ScrollStitcher(allowFixedEdges: true)
        check(ambiguous.append(try fixedView(0, body: repeatedBody)) == .first)
        expectRejected(ambiguous.append(try fixedView(11, body: repeatedBody)))
        check(!ambiguous.fixedEdgesApplied && ambiguous.frameCount == 1)
        let blankBody = [UInt8](repeating: 255, count: 1_024 * rowBytes)
        let blank = ScrollStitcher(allowFixedEdges: true)
        check(blank.append(try fixedView(0, body: blankBody)) == .first)
        check(blank.append(try fixedView(45, body: blankBody)) == .unchanged)
        check(!blank.fixedEdgesApplied && blank.frameCount == 1)
        let smoothBody = (0..<(1_024 * width)).flatMap { index -> [UInt8] in
            let value = UInt8((index / width) / 4)
            return [value, value, value, 255]
        }
        let lowDetailFixed = ScrollStitcher(allowFixedEdges: true)
        check(lowDetailFixed.append(try fixedView(0, body: smoothBody)) == .first)
        expectRejected(lowDetailFixed.append(try fixedView(45, body: smoothBody)))
        check(!lowDetailFixed.fixedEdgesApplied)

        let fixedHeightLimit = ScrollStitcher(maximumHeight: fixedViewport + 30, allowFixedEdges: true)
        check(fixedHeightLimit.append(try fixedView(0)) == .first)
        check(fixedHeightLimit.append(try fixedView(45)) == .limitReached)
        check(!fixedHeightLimit.fixedEdgesApplied && fixedHeightLimit.frameCount == 1)
        check(fixedHeightLimit.append(try fixedView(20)) == .appended(rows: 20))
        assertFixedImage(fixedHeightLimit, offset: 20)
        let fixedFrameLimit = ScrollStitcher(maximumFrames: 2, allowFixedEdges: true)
        check(fixedFrameLimit.append(try fixedView(0)) == .first)
        check(fixedFrameLimit.append(try fixedView(20)) == .appended(rows: 20))
        check(fixedFrameLimit.append(try fixedView(45)) == .limitReached)
        assertFixedImage(fixedFrameLimit, offset: 20)
        let fixedPixelLimit = ScrollStitcher(maximumPixels: width * (fixedViewport + 30), allowFixedEdges: true)
        check(fixedPixelLimit.append(try fixedView(0)) == .first)
        check(fixedPixelLimit.append(try fixedView(45)) == .limitReached)
        check(!fixedPixelLimit.fixedEdgesApplied && fixedPixelLimit.frameCount == 1)
        check(fixedPixelLimit.append(try fixedView(20)) == .appended(rows: 20))
        assertFixedImage(fixedPixelLimit, offset: 20)

        func singleEdgeView(_ offset: Int, top: Bool) throws -> ScrollCaptureFrame {
            let edgeRows = top ? topRows : bottomRows
            let bodyLength = fixedViewport - edgeRows
            let start = offset * rowBytes
            let body = Array(movingPage[start..<(start + bodyLength * rowBytes)])
            return try ScrollCaptureFrame(width: width, height: fixedViewport,
                                          pixels: top ? fixedHeader + body : body + fixedFooter)
        }
        for top in [true, false] {
            let oneEdge = ScrollStitcher(allowFixedEdges: true)
            check(oneEdge.append(try singleEdgeView(0, top: top)) == .first)
            check(oneEdge.append(try singleEdgeView(40, top: top)) == .appended(rows: 40))
            check(oneEdge.fixedTopRows == (top ? topRows : 0))
            check(oneEdge.fixedBottomRows == (top ? 0 : bottomRows))
            let bodyLength = fixedViewport - (top ? topRows : bottomRows)
            let expected = (top ? fixedHeader : []) + Array(movingPage.prefix((bodyLength + 40) * rowBytes)) + (top ? [] : fixedFooter)
            let output = oneEdge.image()!.dataProvider!.data! as Data
            check(Array(output) == expected)
        }

        var sideways = try view(20).pixels
        for y in 0..<viewport {
            let row = Array(sideways[(y * width * 4)..<((y + 1) * width * 4)])
            sideways.replaceSubrange((y * width * 4)..<((y + 1) * width * 4), with: Array(row.dropFirst(4)) + Array(row.prefix(4)))
        }
        let shifted = ScrollStitcher()
        check(shifted.append(try view(0)) == .first)
        expectRejected(shifted.append(try ScrollCaptureFrame(width: width, height: viewport, pixels: sideways)))
        check(shifted.append(try view(20)) == .appended(rows: 20))

        // A jump with insufficient overlap leaves the image recoverable.
        let fast = ScrollStitcher()
        check(fast.append(try view(0)) == .first)
        expectRejected(fast.append(try view(100)))
        check(fast.append(try view(30)) == .appended(rows: 30))

        let heightLimit = ScrollStitcher(maximumHeight: viewport + 10)
        check(heightLimit.append(try view(0)) == .first)
        check(heightLimit.append(try view(20)) == .limitReached)
        check(heightLimit.append(try view(8)) == .appended(rows: 8))
        assertImage(heightLimit, source: page, rows: viewport + 8)
        let pixelLimit = ScrollStitcher(maximumPixels: width * (viewport + 10))
        check(pixelLimit.append(try view(0)) == .first)
        check(pixelLimit.append(try view(20)) == .limitReached)
        check(pixelLimit.height == viewport && pixelLimit.frameCount == 1)
        let frameLimit = ScrollStitcher(maximumFrames: 2)
        check(frameLimit.append(try view(0)) == .first)
        check(frameLimit.append(try view(8)) == .appended(rows: 8))
        check(frameLimit.append(try view(16)) == .limitReached)
        check(frameLimit.append(try view(8)) == .unchanged)
        let productionFrameLimit = ScrollStitcher()
        check(productionFrameLimit.append(try view(0)) == .first)
        for index in 1..<200 { check(productionFrameLimit.append(try view(index * 3)) == .appended(rows: 3)) }
        check(productionFrameLimit.frameCount == 200)
        check(productionFrameLimit.append(try view(600)) == .limitReached)
        assertImage(productionFrameLimit, source: page, rows: viewport + 597)
        let firstLimit = ScrollStitcher(maximumPixels: 16)
        check(firstLimit.append(try view(0)) == .limitReached)
        check(firstLimit.image() == nil && firstLimit.frameCount == 0)
        stitcher.reset()
        check(stitcher.width == 0 && stitcher.height == 0 && stitcher.frameCount == 0 && stitcher.image() == nil)
        check(stitcher.append(try view(0)) == .first)

        // Mostly white document content exercises alignment without the high
        // texture of the noise fixture above. Glyphs and line lengths vary.
        let documentWidth = 320
        let documentHeight = 768
        let documentViewport = 180
        var document = [UInt8](repeating: 255, count: documentWidth * documentHeight * 4)
        for y in 0..<documentHeight where y % 24 < 10 {
            let line = y / 24
            let end = 190 + (line * 47) % 105
            for x in 16..<end where x % 8 < 5 {
                let glyph = x / 8
                let seed = UInt64(line * 379 + glyph * 79 + (y % 24) * 13 + (x % 8) * 3)
                let ink = (seed &* 0x9e3779b97f4a7c15) >> 61
                if ink < 4 {
                    let index = (y * documentWidth + x) * 4
                    document[index] = 28; document[index + 1] = 28; document[index + 2] = 28
                }
            }
        }
        func documentView(_ offset: Int) throws -> ScrollCaptureFrame {
            let start = offset * documentWidth * 4
            return try ScrollCaptureFrame(width: documentWidth, height: documentViewport,
                                          pixels: Array(document[start..<(start + documentViewport * documentWidth * 4)]))
        }
        let text = ScrollStitcher()
        check(text.append(try documentView(0)) == .first)
        var documentOffset = 0
        for next in [27, 74, 133, 187] {
            check(text.append(try documentView(next)) == .appended(rows: next - documentOffset))
            documentOffset = next
            assertImage(text, source: document, rows: documentViewport + next, expectedWidth: documentWidth)
        }

        // Native rasterized small text with regular 40px line spacing previously
        // caused uniform coarse samples to land entirely in whitespace, losing
        // the real overlap from the shortlist at the 120-row offset.
        let nativeWidth = 800
        let nativeHeight = 4_000
        let nativeViewport = 1_000
        let nativeText = renderedText(width: nativeWidth, height: nativeHeight)
        func nativeView(_ offset: Int) throws -> ScrollCaptureFrame {
            let start = offset * nativeWidth * 4
            return try ScrollCaptureFrame(width: nativeWidth, height: nativeViewport,
                                          pixels: Array(nativeText[start..<(start + nativeViewport * nativeWidth * 4)]))
        }
        let native = ScrollStitcher()
        check(native.append(try nativeView(0)) == .first)
        var nativeOffset = 0
        for next in [120, 300, 510, 690] {
            check(native.append(try nativeView(next)) == .appended(rows: next - nativeOffset))
            nativeOffset = next
            assertImage(native, source: nativeText, rows: nativeViewport + next, expectedWidth: nativeWidth)
        }

        // A smooth embedded-image field plus low-contrast text can make the
        // exact offset and its one-row neighbors satisfy existing pixel
        // budgets. The exact full-pixel match must win within that local
        // cluster, while the exported rows remain an exact document oracle.
        let imageWidth = 256
        let imageHeight = 720
        let imageViewport = 240
        var smoothImageText = [UInt8](repeating: 255, count: imageWidth * imageHeight * 4)
        for y in 0..<imageHeight {
            // This gentle, unwrapped luminance ramp has sub-threshold adjacent
            // row differences across the true overlap, but a two-row offset
            // exceeds the existing mean RGB error budget.
            let ramp = UInt8(min(255, max(0, (y - 90) * 255 / 150)))
            for x in 0..<imageWidth {
                // Alternating broad bands provide image texture without
                // making a one-row alignment error look like a different page.
                let imageBand = (x / 8) % 2 == 0 ? 0 : 16
                var value = UInt8(min(255, Int(ramp) + imageBand))
                // Fine low-contrast glyph strokes give the image field text
                // detail while keeping neighboring-row differences bounded.
                if y % 31 >= 8 && y % 31 < 18
                    && x >= 18 && x < 140 && ((x / 3 + y / 2) % 7) < 2 {
                    value = value >= 4 ? value - 4 : 0
                }
                let index = (y * imageWidth + x) * 4
                smoothImageText[index] = value
                smoothImageText[index + 1] = value
                smoothImageText[index + 2] = value
                smoothImageText[index + 3] = 255
            }
        }
        func smoothImageView(_ offset: Int) throws -> ScrollCaptureFrame {
            let start = offset * imageWidth * 4
            return try ScrollCaptureFrame(width: imageWidth, height: imageViewport,
                pixels: Array(smoothImageText[start..<(start + imageViewport * imageWidth * 4)]))
        }
        let localCluster = ScrollStitcher()
        check(localCluster.append(try smoothImageView(0)) == .first)
        let localClusterResult = localCluster.append(try smoothImageView(90))
        check(localClusterResult == .appended(rows: 90),
              "A decisive full-pixel winner in a compact positive-shift cluster should preserve the actual movement; result=\(localClusterResult), \(localCluster.alignmentDiagnostic ?? "no diagnostic")")
        check(localCluster.alignmentDiagnostic?.contains("89:") == true
              && localCluster.alignmentDiagnostic?.contains("91:") == true,
              "The fixture must exercise one-row neighboring full-pixel candidates")
        check(localCluster.alignmentDiagnostic?.contains("selected=90") == true,
              "The numeric alignment diagnostic should identify the selected exact offset")
        assertImage(localCluster, source: smoothImageText, rows: imageViewport + 90, expectedWidth: imageWidth)

        // A 160-row native text document occupies only the left ~350 pixels
        // of a 1920-pixel viewport. White margins must not dilute mismatched
        // numbered rows into plausible overlaps at several offsets.
        let wideWidth = 1_920
        let wideHeight = 5_840
        let wideViewport = 900
        let wideText = renderedNarrowNumberedText(width: wideWidth, height: wideHeight)
        func wideView(_ offset: Int) throws -> ScrollCaptureFrame {
            let start = offset * wideWidth * 4
            return try ScrollCaptureFrame(width: wideWidth, height: wideViewport,
                                          pixels: Array(wideText[start..<(start + wideViewport * wideWidth * 4)]))
        }
        let wide = ScrollStitcher(allowFixedEdges: true)
        check(wide.append(try wideView(0)) == .first)
        var wideOffset = 0
        for next in [120, 278, 443, 607] {
            check(wide.append(try wideView(next)) == .appended(rows: next - wideOffset),
                  "Sparse text must choose the actual downward row offset")
            wideOffset = next
            assertImage(wide, source: wideText, rows: wideViewport + next, expectedWidth: wideWidth)
        }
        expectRejected(wide.append(try wideView(wideOffset - 72)))
        check(wide.frameCount == 5 && !wide.fixedEdgesApplied)
        check(wide.append(try wideView(wideOffset + 36)) == .appended(rows: 36))
        assertImage(wide, source: wideText, rows: wideViewport + wideOffset + 36, expectedWidth: wideWidth)

        // Every coarse and dense probe misses these narrow, moving ink columns,
        // so more than eight offsets have the same sampled score. Whole-row RGB
        // sums still rule out the wrong offsets without assuming their pixels
        // match; the only verified overlap must preserve exact output rows.
        let hiddenWidth = 256
        let hiddenViewport = 128
        let hiddenHeight = 512
        let probePositions = Set([20, 48].flatMap { count in
            (0..<count).map { $0 * (hiddenWidth - 1) / (count - 1) }
        })
        let hiddenColumns = Array((1..<hiddenWidth / 2).filter { !probePositions.contains($0) }.prefix(16))
        check(hiddenColumns.count == 16, "Fixture requires sixteen unseen ink columns")
        func hiddenPage(repeating: Bool) -> [UInt8] {
            var pixels = [UInt8](repeating: 255, count: hiddenWidth * hiddenHeight * 4)
            for y in 0..<hiddenHeight {
                var state = UInt64(y + 1) &* 0x9e3779b97f4a7c15
                state = (state ^ (state >> 30)) &* 0xbf58476d1ce4e5b9
                state = (state ^ (state >> 27)) &* 0x94d049bb133111eb
                let dark = repeating ? y % 16 < 8 : (state ^ (state >> 31)) & 1 == 0
                if dark {
                    for x in hiddenColumns {
                        let index = (y * hiddenWidth + x) * 4
                        pixels[index] = 0; pixels[index + 1] = 0; pixels[index + 2] = 0
                    }
                }
            }
            return pixels
        }
        func hiddenView(_ offset: Int, source: [UInt8]) throws -> ScrollCaptureFrame {
            let start = offset * hiddenWidth * 4
            return try ScrollCaptureFrame(width: hiddenWidth, height: hiddenViewport,
                                          pixels: Array(source[start..<(start + hiddenViewport * hiddenWidth * 4)]))
        }
        let uniqueHiddenPage = hiddenPage(repeating: false)
        let hidden = ScrollStitcher()
        check(hidden.append(try hiddenView(0, source: uniqueHiddenPage)) == .first)
        check(hidden.append(try hiddenView(20, source: uniqueHiddenPage)) == .appended(rows: 20))
        assertImage(hidden, source: uniqueHiddenPage, rows: hiddenViewport + 20, expectedWidth: hiddenWidth)
        expectRejected(hidden.append(try hiddenView(10, source: uniqueHiddenPage)))
        check(hidden.append(try hiddenView(45, source: uniqueHiddenPage)) == .appended(rows: 25))
        assertImage(hidden, source: uniqueHiddenPage, rows: hiddenViewport + 45, expectedWidth: hiddenWidth)

        let repeatedHiddenPage = hiddenPage(repeating: true)
        let repeatedHidden = ScrollStitcher()
        check(repeatedHidden.append(try hiddenView(0, source: repeatedHiddenPage)) == .first)
        expectRejected(repeatedHidden.append(try hiddenView(8, source: repeatedHiddenPage)))
        // A near-zero match alongside periodic larger shifts is ambiguous.
        expectRejected(repeatedHidden.append(try hiddenView(1, source: repeatedHiddenPage)))
        check(repeatedHidden.frameCount == 1 && repeatedHidden.height == hiddenViewport)

        // A one-column mark moves twenty rows. Its changed pixels fit the
        // whole-frame zero-shift tolerance, so an early approximate duplicate
        // would silently omit the scroll even though a positive overlap exists.
        var tinyPage = [UInt8](repeating: 255, count: hiddenWidth * hiddenHeight * 4)
        for y in 0..<hiddenHeight where uniqueHiddenPage[(y * hiddenWidth + hiddenColumns[0]) * 4] == 0 {
            let index = (y * hiddenWidth + hiddenColumns[0]) * 4
            tinyPage[index] = 0; tinyPage[index + 1] = 0; tinyPage[index + 2] = 0
        }
        let tiny = ScrollStitcher()
        check(tiny.append(try hiddenView(0, source: tinyPage)) == .first)
        let tinyResult = tiny.append(try hiddenView(20, source: tinyPage))
        check(tinyResult != .unchanged, "Moving under-budget ink must not be called unchanged")
        if case .rejected = tinyResult {
            check(tiny.frameCount == 1 && tiny.height == hiddenViewport)
        } else {
            check(tinyResult == .appended(rows: 20))
            assertImage(tiny, source: tinyPage, rows: hiddenViewport + 20, expectedWidth: hiddenWidth)
        }

        // Moving pixels with identical RGB sums on every row cannot be ruled
        // out by the sound lower bound. The candidate cap must reject instead
        // of guessing among an incomplete set of full-image verifications.
        let alternateColumns = Array((1..<hiddenWidth / 2).filter {
            !probePositions.contains($0) && !hiddenColumns.contains($0)
        }.prefix(16))
        check(alternateColumns.count == 16, "Fixture requires two unseen column groups")
        var equalSumPage = [UInt8](repeating: 255, count: hiddenWidth * hiddenHeight * 4)
        for y in 0..<hiddenHeight {
            let group = (y * 73 + y / 7) % 11 < 5 ? hiddenColumns : alternateColumns
            for x in group {
                let index = (y * hiddenWidth + x) * 4
                equalSumPage[index] = 0; equalSumPage[index + 1] = 0; equalSumPage[index + 2] = 0
            }
        }
        let crowded = ScrollStitcher()
        check(crowded.append(try hiddenView(0, source: equalSumPage)) == .first)
        expectRejected(crowded.append(try hiddenView(20, source: equalSumPage)))
        check(crowded.frameCount == 1 && crowded.height == hiddenViewport)

        for (w, h, bytes) in [(0, 2, []), (-1, 2, []), (2, 0, []), (Int.max, 2, []), (Int.max / 2, 1, []), (2, 2, [UInt8](repeating: 0, count: 15))] {
            do { _ = try ScrollCaptureFrame(width: w, height: h, pixels: bytes); preconditionFailure("Invalid frame accepted") }
            catch is ScrollCaptureFrame.Invalid { }
        }
        print("Scroll stitching: exact strips, orientation, duplicate/jitter, rejection recovery, ambiguity, texture, and allocation limits passed")
    }

    private static func renderedText(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let words = ["capture", "selected", "background", "operating", "screen", "application", "independent", "manual",
                     "gesture", "keyboard", "position", "verified", "source", "permission", "memory", "image",
                     "model", "completed", "results", "overlay", "navigation", "stitching", "reference", "calendar",
                     "setting", "preview", "capture", "original", "control", "content", "display", "evidence"]
        let font = CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            for y in stride(from: 20, to: height, by: 40) {
                var state = UInt64(y)
                let line = (0..<8).map { _ -> String in
                    state = state &* 1_664_525 &+ 1_013_904_223
                    return words[Int((state >> 16) % 32)]
                }.joined(separator: " ")
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                ]
                let attributed = NSAttributedString(string: line, attributes: attributes)
                context.textPosition = CGPoint(x: 35, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
        }
        return pixels
    }

    private static func renderedNarrowNumberedText(width: Int, height: Int) -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let words = ["capture", "screen", "window", "scroll", "document", "content", "position", "sample"]
        pixels.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            for row in 0..<160 {
                let first = words[(row * 5 + row / 7) % words.count]
                let second = words[(row * 3 + row / 11) % words.count]
                let line = String(format: "%03d  %@ %@  %04X", row + 1, first, second, row * 137 + 29)
                let attributes: [NSAttributedString.Key: Any] = [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
                ]
                context.textPosition = CGPoint(x: 24, y: 28 + row * 36)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: attributes)), context)
            }
        }
        return pixels
    }

    private static func makePage(width: Int, height: Int, seed: UInt64 = 123) -> [UInt8] {
        var pixels: [UInt8] = []
        pixels.reserveCapacity(width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                var state = UInt64(y) &* 0x9e3779b97f4a7c15 &+ UInt64(x) &* 0xbf58476d1ce4e5b9 &+ seed
                state = (state ^ (state >> 30)) &* 0xbf58476d1ce4e5b9
                state = (state ^ (state >> 27)) &* 0x94d049bb133111eb
                state ^= state >> 31
                pixels.append(contentsOf: [UInt8(truncatingIfNeeded: state), UInt8(truncatingIfNeeded: state >> 8), UInt8(truncatingIfNeeded: state >> 16), 255])
            }
        }
        return pixels
    }
}
