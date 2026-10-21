import Foundation
import CoreGraphics

@main
enum AutomaticCapturePipelineTests {
    static let width = 72, viewport = 240, header = 26, footer = 14, document = 1377

    static func pixel(_ row: Int, _ column: Int, _ section: Int) -> [UInt8] {
        [UInt8((row * 17 + column * 13 + section * 31) & 255),
         UInt8(((row >> 8) * 73 + column * 7 + row * column % 19 + section * 53) & 255),
         UInt8((row * 29 + column * 3 + section * 79) & 255), 255]
    }
    static func rows(_ count: Int, offset: Int, section: Int) -> [UInt8] {
        (0..<count).flatMap { y in (0..<width).flatMap { x in pixel(offset + y, x, section) } }
    }
    static func frame(_ offset: Int) throws -> ScrollCaptureFrame {
        try ScrollCaptureFrame(width: width, height: viewport,
            pixels: rows(header, offset: 0, section: 1) + rows(viewport - header - footer, offset: offset, section: 0) + rows(footer, offset: 0, section: 2))
    }
    static func observation(_ result: ScrollStitcher.AppendResult) -> AutoScrollPolicy.StitchOutcome {
        switch result {
        case .first: .first
        case .appended: .appended
        case .unchanged: .unchanged
        case .rejected(let reason): .rejected(reason)
        case .limitReached: .limitReached
        }
    }
    static func main() throws {
        var policy = AutoScrollPolicy()
        let stitcher = ScrollStitcher(allowFixedEdges: true)
        var decision = policy.decide(.start(viewportHeight: viewport))
        var offset = 0, requests = 0, completed = false
        let end = document - (viewport - header - footer)
        for _ in 0..<100 {
            switch decision {
            case .captureFirstFrame: break
            case .scrollDown(let amount, _), .checkEnd(let amount, _): offset = min(end, offset + amount); requests += 1
            case .recoverAndScrollDown(let rollback, let amount, _): offset = max(0, offset - rollback); offset = min(end, offset + amount); requests += 2
            case .finish(let reason, let complete):
                precondition(reason == .reachedEnd && complete)
                completed = true
            default: preconditionFailure("Unexpected pipeline decision")
            }
            if completed { break }
            let result = stitcher.append(try frame(offset))
            decision = policy.decide(.observation(observation(result), outputPixels: stitcher.width * stitcher.height, scrollbarPosition: Double(offset) / Double(end)))
        }
        precondition(completed && requests > 1 && requests < 30, "Finite page finishes without a Done event")
        precondition(stitcher.fixedEdgesApplied && stitcher.fixedTopRows == header && stitcher.fixedBottomRows == footer)
        let expected = rows(header, offset: 0, section: 1) + rows(document, offset: 0, section: 0) + rows(footer, offset: 0, section: 2)
        let image = stitcher.image()!
        precondition(image.height == header + document + footer)
        precondition(Array(image.dataProvider!.data! as Data) == expected, "Policy and stitcher preserve every document row and only one fixed header/footer")

        var stopped = AutoScrollPolicy()
        _ = stopped.decide(.start(viewportHeight: viewport))
        _ = stopped.decide(.observation(.first, outputPixels: width * viewport, scrollbarPosition: 0))
        _ = stopped.decide(.observation(.appended, outputPixels: width * (viewport + 108), scrollbarPosition: 0.1))
        precondition(stopped.decide(.stop) == .finish(.userStopped, completePage: false))
        print("Automatic capture pipeline: finite page, exact fixed edges, bounded pace and early Stop passed")
    }
}
