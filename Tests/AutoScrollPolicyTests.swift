import Foundation

@main enum AutoScrollPolicyTests {
    static func check(_ condition: Bool, _ message: String = "Check failed", file: StaticString = #file, line: UInt = #line) {
        precondition(condition, message, file: file, line: line)
    }

    static func main() {
        // The owner resolves top first. The first capture precedes downward input.
        var atTop = AutoScrollPolicy()
        check(atTop.decide(.start(viewportHeight: 1_000)) == .captureFirstFrame)
        check(atTop.phase == .awaitingFirstFrame)

        var noBar = AutoScrollPolicy()
        check(noBar.decide(.start(viewportHeight: 400)) == .captureFirstFrame)

        // The first accepted frame must precede any downward movement.
        check(noBar.decide(.observation(.first, outputPixels: 2_000_000, scrollbarPosition: nil)) == .scrollDown(pixels: 180, settle: 0.2))
        check(noBar.acceptedFrames == 1)
        check(noBar.decide(.observation(.appended, outputPixels: 2_400_000, scrollbarPosition: nil)) == .scrollDown(pixels: 180, settle: 0.2))

        // Prior movement plus stationary frames can infer an end, but later input
        // may have been ignored mid-document. Without a native signal it is unconfirmed.
        check(noBar.decide(.observation(.unchanged, outputPixels: 2_400_000, scrollbarPosition: nil)) == .checkEnd(pixels: 180, settle: 0.2))
        check(noBar.decide(.observation(.unchanged, outputPixels: 2_400_000, scrollbarPosition: nil)) == .checkEnd(pixels: 180, settle: 0.2))
        check(noBar.decide(.observation(.unchanged, outputPixels: 2_400_000, scrollbarPosition: nil)) == .finish(.inferredEnd, completePage: false))

        var ignoredInput = AutoScrollPolicy()
        _ = ignoredInput.decide(.start(viewportHeight: 400))
        _ = ignoredInput.decide(.observation(.first, outputPixels: 100, scrollbarPosition: nil))
        _ = ignoredInput.decide(.observation(.unchanged, outputPixels: 100, scrollbarPosition: nil))
        _ = ignoredInput.decide(.observation(.unchanged, outputPixels: 100, scrollbarPosition: nil))
        check(ignoredInput.decide(.observation(.unchanged, outputPixels: 100, scrollbarPosition: nil)) == .finish(.unverifiedEnd, completePage: false), "Ignored scrolling cannot prove whole-page completion")

        // A known non-end position can be temporarily stationary while the
        // page animates. Require three separate posted-scroll observations.
        var transient = AutoScrollPolicy()
        _ = transient.decide(.start(viewportHeight: 300))
        _ = transient.decide(.observation(.first, outputPixels: 100, scrollbarPosition: 0.4))
        check(transient.decide(.observation(.unchanged, outputPixels: 100, scrollbarPosition: 0.4)) == .checkEnd(pixels: 135, settle: 0.2))
        check(transient.decide(.observation(.unchanged, outputPixels: 100, scrollbarPosition: 0.4)) == .checkEnd(pixels: 135, settle: 0.2))
        check(transient.decide(.observation(.unchanged, outputPixels: 100, scrollbarPosition: 0.4)) == .finish(.pageDidNotAdvance, completePage: false))

        var retry = AutoScrollPolicy()
        _ = retry.decide(.start(viewportHeight: 200))
        _ = retry.decide(.observation(.first, outputPixels: 1_000, scrollbarPosition: nil))
        check(retry.decide(.observation(.rejected("overlap"), outputPixels: 1_000, scrollbarPosition: nil)) ==
              .recoverAndScrollDown(rollbackPixels: 90, pixels: 45, settle: 0.2))
        check(retry.decide(.observation(.rejected("still moving"), outputPixels: 1_000, scrollbarPosition: nil)) ==
              .recoverAndScrollDown(rollbackPixels: 45, pixels: 22, settle: 0.2))
        check(retry.decide(.observation(.rejected("animated content"), outputPixels: 1_000, scrollbarPosition: nil)) ==
              .finish(.unstableContent("animated content"), completePage: false))

        var capped = AutoScrollPolicy()
        _ = capped.decide(.start(viewportHeight: 10_000))
        _ = capped.decide(.observation(.first, outputPixels: 100, scrollbarPosition: nil))
        capped.recordEffectiveScrollStep(180)
        check(capped.decide(.observation(.rejected("overlap"), outputPixels: 100, scrollbarPosition: nil)) ==
              .recoverAndScrollDown(rollbackPixels: 180, pixels: 90, settle: 0.2))
        capped.recordEffectiveScrollStep(90)
        check(capped.decide(.observation(.rejected("overlap"), outputPixels: 100, scrollbarPosition: nil)) ==
              .recoverAndScrollDown(rollbackPixels: 90, pixels: 45, settle: 0.2))

        var stopTop = AutoScrollPolicy()
        _ = stopTop.decide(.start(viewportHeight: 700))
        check(stopTop.decide(.stop) == .finish(.userStopped, completePage: false))
        check(stopTop.phase == .finished)

        var lostFocus = AutoScrollPolicy()
        _ = lostFocus.decide(.start(viewportHeight: 700))
        check(lostFocus.decide(.focusLost) == .abort)
        check(lostFocus.phase == .aborted)
        check(lostFocus.decide(.stop) == .abort)

        var deadline = AutoScrollPolicy()
        _ = deadline.decide(.start(viewportHeight: 500))
        check(deadline.decide(.tick(elapsed: 119.9)) == .continueCapture)
        check(deadline.decide(.tick(elapsed: 120)) == .finish(.timeLimit, completePage: false))

        var bounded = AutoScrollPolicy()
        _ = bounded.decide(.start(viewportHeight: 100))
        _ = bounded.decide(.observation(.first, outputPixels: 10, scrollbarPosition: nil))
        var decision: AutoScrollPolicy.Decision = .continueCapture
        for frame in 2...AutoScrollPolicy.maximumFrames {
            decision = bounded.decide(.observation(.appended, outputPixels: frame * 10, scrollbarPosition: nil))
        }
        check(decision == .finish(.frameLimit, completePage: false))

        var pixelLimited = AutoScrollPolicy()
        _ = pixelLimited.decide(.start(viewportHeight: 100))
        check(pixelLimited.decide(.observation(.first, outputPixels: AutoScrollPolicy.maximumPixels,
                                               scrollbarPosition: nil)) == .finish(.pixelLimit, completePage: false))

        // Disk-backed whole-page capture must cross the old output/frame/time
        // ceilings, and still stop honestly at its own explicit bounds.
        var longPage = AutoScrollPolicy(limits: .wholePage)
        _ = longPage.decide(.start(viewportHeight: 400))
        check(longPage.decide(.observation(.first, outputPixels: 41_000_000,
                                          scrollbarPosition: nil)) == .scrollDown(pixels: 180, settle: 0.2))
        check(longPage.decide(.tick(elapsed: 120)) == .continueCapture)
        for _ in 2...201 {
            check(longPage.decide(.observation(.appended, outputPixels: 42_000_000,
                                              scrollbarPosition: nil)) == .scrollDown(pixels: 180, settle: 0.2))
        }
        check(longPage.decide(.observation(.appended, outputPixels: AutoScrollPolicy.Limits.wholePage.pixels,
                                          scrollbarPosition: nil)) == .finish(.pixelLimit, completePage: false))
        var longDeadline = AutoScrollPolicy(limits: .wholePage)
        _ = longDeadline.decide(.start(viewportHeight: 400))
        check(longDeadline.decide(.tick(elapsed: 600)) == .finish(.timeLimit, completePage: false))

        var invalid = AutoScrollPolicy()
        check(invalid.decide(.start(viewportHeight: 0)) == .abort)
        check(invalid.decide(.start(viewportHeight: 20)) == .captureFirstFrame)
        var tall = AutoScrollPolicy()
        check(tall.decide(.start(viewportHeight: 16_000)) == .captureFirstFrame)
        check(tall.decide(.observation(.first, outputPixels: 10, scrollbarPosition: nil)) == .scrollDown(pixels: 2_000, settle: 0.2))
        var impossibleHeight = AutoScrollPolicy()
        check(impossibleHeight.decide(.start(viewportHeight: 16_385)) == .abort)

        var noAdvance = AutoScrollPolicy()
        _ = noAdvance.decide(.start(viewportHeight: 300))
        _ = noAdvance.decide(.observation(.first, outputPixels: 100, scrollbarPosition: 0.2))
        check(noAdvance.decide(.observation(.unchanged, outputPixels: 100, scrollbarPosition: 0.2)) == .checkEnd(pixels: 135, settle: 0.2))
        check(noAdvance.decide(.observation(.unchanged, outputPixels: 100, scrollbarPosition: 0.2)) == .checkEnd(pixels: 135, settle: 0.2))
        check(noAdvance.decide(.observation(.unchanged, outputPixels: 100, scrollbarPosition: 0.2)) ==
              .finish(.pageDidNotAdvance, completePage: false))

        print("Automatic scroll policy: top preparation, first-frame order, stable end, retries, stop/focus loss, and bounds passed")
    }
}
