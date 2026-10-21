import Foundation

@main
enum CaptureTraversalTests {
    static func main() {
        precondition(CaptureTraversal.choose(scrollFraction: 0.25) == .topToBottom)
        precondition(CaptureTraversal.choose(scrollFraction: 0.5) == .topToBottom,
                     "A midpoint tie uses the stable top-to-bottom default")
        precondition(CaptureTraversal.choose(scrollFraction: 0.75) == .bottomToTop)

        let topToBottom = CaptureTraversal.topToBottom
        precondition(topToBottom.startBoundaryFraction == 0 && topToBottom.endBoundaryFraction == 1)
        precondition(topToBottom.preparesUp && !topToBottom.capturesUp)
        precondition(topToBottom.preparationDirection == .towardTop)
        precondition(topToBottom.progress(towardEnd: 0.25) == 0.25)
        precondition(topToBottom.progress(towardEnd: 1) == 1)

        let bottomToTop = CaptureTraversal.bottomToTop
        precondition(bottomToTop.startBoundaryFraction == 1 && bottomToTop.endBoundaryFraction == 0)
        precondition(!bottomToTop.preparesUp && bottomToTop.capturesUp)
        precondition(bottomToTop.preparationDirection == .towardBottom)
        precondition(bottomToTop.progress(towardEnd: 0.75) == 0.25)
        precondition(bottomToTop.progress(towardEnd: 0) == 1)

        for invalid in [Double.nan, Double.infinity, -.infinity, -0.01, 1.01] {
            precondition(CaptureTraversal.choose(scrollFraction: invalid) == .topToBottom)
            precondition(topToBottom.progress(towardEnd: invalid) == nil)
        }
        precondition(CaptureTraversal.choose(scrollFraction: nil) == .topToBottom)
        precondition(bottomToTop.progress(towardEnd: nil) == nil)

        precondition(CaptureTraversal.startReached(preparationEvidence: .observed))
        precondition(!CaptureTraversal.startReached(preparationEvidence: .inferred))
        precondition(CaptureTraversal.startReached(preparationEvidence: .verifiedVisual))
        precondition(!CaptureTraversal.startReached(preparationEvidence: .limit))
        precondition(!CaptureTraversal.startReached(preparationEvidence: .stopped))

        print("Capture traversal direction, progress, and endpoint gates passed")
    }
}
