import Foundation

/// Chooses the nearest page endpoint as the traversal start, then reports
/// progress in the selected traversal direction without changing coordinates.
enum CaptureTraversal: String, Codable, Equatable {
    case topToBottom
    case bottomToTop

    enum PreparationDirection: Equatable {
        case towardTop
        case towardBottom
    }

    static func choose(scrollFraction: Double?) -> CaptureTraversal {
        guard let scrollFraction, scrollFraction.isFinite,
              (0...1).contains(scrollFraction) else { return .topToBottom }
        return scrollFraction > 0.5 ? .bottomToTop : .topToBottom
    }

    var startBoundaryFraction: Double {
        self == .topToBottom ? 0 : 1
    }

    var endBoundaryFraction: Double {
        self == .topToBottom ? 1 : 0
    }

    var preparesUp: Bool { self == .topToBottom }
    var capturesUp: Bool { self == .bottomToTop }

    var preparationDirection: PreparationDirection {
        preparesUp ? .towardTop : .towardBottom
    }

    /// Returns directional progress from the chosen start toward the opposite
    /// endpoint. Unknown or invalid native fractions remain unknown.
    func progress(towardEnd nativeFraction: Double?) -> Double? {
        guard let nativeFraction, nativeFraction.isFinite,
              (0...1).contains(nativeFraction) else { return nil }
        return self == .topToBottom ? nativeFraction : 1 - nativeFraction
    }

    /// A capture starts only after a native endpoint observation or a visual
    /// away-and-return probe verified against the same boundary frame.
    /// Stationary imagery and attempt/time limits are not endpoint proof.
    static func startReached(preparationEvidence: CaptureTopPreparation.Evidence) -> Bool {
        preparationEvidence == .observed || preparationEvidence == .verifiedVisual
    }
}
