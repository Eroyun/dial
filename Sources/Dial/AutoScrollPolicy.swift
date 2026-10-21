import Foundation

/// Pure decision policy for automatic whole-page capture. The caller performs
/// scrolling and capture, then feeds the resulting stitcher observation back.
struct AutoScrollPolicy {
    enum StitchOutcome: Equatable {
        case first
        case appended
        case unchanged
        case rejected(String)
        case limitReached
    }

    enum Event {
        /// Start only after the owner has positioned and settled at the chosen starting boundary.
        case start(viewportHeight: Int)
        /// One capture after a requested traversal movement (or a stability check).
        case observation(StitchOutcome, outputPixels: Int, scrollbarPosition: Double?)
        case stop
        case focusLost
        case tick(elapsed: TimeInterval)
    }

    enum FinishReason: Equatable {
        case reachedEnd
        case userStopped
        case timeLimit
        case frameLimit
        case pixelLimit
        case pageDidNotAdvance
        case unverifiedEnd
        case inferredEnd
        case unstableContent(String)
    }

    enum Decision: Equatable {
        case captureFirstFrame
        case scrollDown(pixels: Int, settle: TimeInterval)
        /// Roll back the rejected movement, then retry downward at a smaller step.
        case recoverAndScrollDown(rollbackPixels: Int, pixels: Int, settle: TimeInterval)
        /// Capture again after a fresh posted scroll request to confirm stability.
        case checkEnd(pixels: Int, settle: TimeInterval)
        case continueCapture
        case finish(FinishReason, completePage: Bool)
        case abort
    }

    static let maximumDuration: TimeInterval = 120
    static let maximumFrames = 200
    static let maximumPixels = 40_000_000
    struct Limits {
        let duration: TimeInterval
        let frames: Int
        let pixels: Int
        static let standard = Limits(duration: 120, frames: 200, pixels: 40_000_000)
        // Whole-page mode stores accepted rows on disk. These are explicit
        // output/session bounds, independent of the short endpoint-seek budget.
        static let wholePage = Limits(duration: 600, frames: 4_000, pixels: 512_000_000)
    }
    private let limits: Limits
    static let maximumViewportHeight = 16_384
    static let maximumScrollStep = 2_000
    static let settleInterval: TimeInterval = 0.2
    private static let maximumRetries = 2
    private static let stableChecksRequired = 3

    private(set) var viewportHeight = 0
    private(set) var acceptedFrames = 0
    private(set) var unchangedEndChecks = 0
    private(set) var phase: Phase = .idle

    enum Phase: Equatable { case idle, awaitingFirstFrame, scrolling, finished, aborted }

    private var requestedStep = 0
    private var retryCount = 0
    private var hasAdvanced = false
    private var lastElapsed: TimeInterval = 0

    init(limits: Limits = .standard) { self.limits = limits }

    /// Native input adapters may cap a requested step. Retries and rollback must
    /// use that issued magnitude rather than repeatedly halving a larger nominal step.
    mutating func recordEffectiveScrollStep(_ pixels: Int) {
        guard phase == .scrolling, pixels > 0, pixels <= requestedStep else { return }
        requestedStep = pixels
    }

    mutating func decide(_ event: Event) -> Decision {
        switch event {
        case .start(let height):
            guard phase == .idle, height > 0, height <= Self.maximumViewportHeight else { return .abort }
            viewportHeight = height
            requestedStep = min(Self.maximumScrollStep, max(1, height * 45 / 100))
            phase = .awaitingFirstFrame
            return .captureFirstFrame

        case .observation(let outcome, let outputPixels, let scrollbarPosition):
            guard phase == .awaitingFirstFrame || phase == .scrolling else { return .abort }
            guard outputPixels >= 0 else { return finish(.pixelLimit, complete: false) }
            if phase == .awaitingFirstFrame {
                guard outcome == .first else {
                    if case .limitReached = outcome { return finish(.pixelLimit, complete: false) }
                    if case .rejected(let reason) = outcome { return finish(.unstableContent(reason), complete: false) }
                    return .captureFirstFrame
                }
                acceptedFrames = 1
                if outputPixels >= limits.pixels { return finish(.pixelLimit, complete: false) }
                phase = .scrolling
                requestedStep = min(Self.maximumScrollStep, max(1, viewportHeight * 45 / 100))
                return .scrollDown(pixels: requestedStep, settle: Self.settleInterval)
            }

            switch outcome {
            case .first, .appended:
                if outcome == .appended { hasAdvanced = true }
                acceptedFrames += 1
                unchangedEndChecks = 0
                retryCount = 0
                if acceptedFrames >= limits.frames { return finish(.frameLimit, complete: false) }
                if outputPixels >= limits.pixels { return finish(.pixelLimit, complete: false) }
                // The scrollbar is a useful hint, but a stable capture after a
                // further posted scroll is still required before full completion.
                requestedStep = min(Self.maximumScrollStep, max(1, viewportHeight * 45 / 100))
                if scrollbarPosition.map({ $0 >= 0.99 }) == true {
                    return .checkEnd(pixels: requestedStep, settle: Self.settleInterval)
                }
                return .scrollDown(pixels: requestedStep, settle: Self.settleInterval)

            case .unchanged:
                unchangedEndChecks += 1
                if let scrollbarPosition, scrollbarPosition < 0.99 {
                    if unchangedEndChecks >= Self.stableChecksRequired {
                        return finish(.pageDidNotAdvance, complete: false)
                    }
                    return .checkEnd(pixels: requestedStep, settle: Self.settleInterval)
                }
                if (scrollbarPosition.map({ $0 >= 0.99 }) == true && unchangedEndChecks >= 1) ||
                    (scrollbarPosition == nil && unchangedEndChecks >= Self.stableChecksRequired) {
                    if scrollbarPosition == nil {
                        return finish(hasAdvanced ? .inferredEnd : .unverifiedEnd, complete: false)
                    }
                    return finish(.reachedEnd, complete: true)
                }
                return .checkEnd(pixels: requestedStep, settle: Self.settleInterval)

            case .rejected(let reason):
                guard retryCount < Self.maximumRetries else {
                    return finish(.unstableContent(reason), complete: false)
                }
                retryCount += 1
                let smaller = max(1, requestedStep / 2)
                let rollback = requestedStep
                requestedStep = smaller
                unchangedEndChecks = 0
                return .recoverAndScrollDown(rollbackPixels: rollback, pixels: smaller, settle: Self.settleInterval)

            case .limitReached:
                return finish(.pixelLimit, complete: false)
            }

        case .stop:
            guard phase != .finished && phase != .aborted else { return .abort }
            return finish(.userStopped, complete: false)

        case .focusLost:
            phase = .aborted
            return .abort

        case .tick(let elapsed):
            guard elapsed.isFinite, elapsed >= lastElapsed else { phase = .aborted; return .abort }
            lastElapsed = elapsed
            if elapsed >= limits.duration, phase != .finished, phase != .aborted {
                return finish(.timeLimit, complete: false)
            }
            return .continueCapture
        }
    }

    private mutating func finish(_ reason: FinishReason, complete: Bool) -> Decision {
        phase = .finished
        return .finish(reason, completePage: complete)
    }
}
