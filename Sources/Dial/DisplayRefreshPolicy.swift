/// Decisions made from the cause of a refresh. Keeping these independent of CoreGraphics makes
/// the important distinction testable without connecting a physical monitor.
enum DisplayRefreshReason: CustomStringConvertible {
    case initial
    case modeChange
    case inventory
    case topology
    case wake

    var description: String {
        switch self {
        case .initial: "launch"
        case .modeChange: "mode change"
        case .inventory: "display arrangement"
        case .topology: "reconnect"
        case .wake: "wake"
        }
    }
}

enum DisplayRefreshPolicy {
    /// A finite set of observations, long enough for a display that appears after the first scan.
    static let settleDelays: [Double] = [0.4, 2, 5]

    static func shouldAdoptExternalMode(reason: DisplayRefreshReason, isKnown: Bool, settling: Bool) -> Bool {
        reason == .modeChange && isKnown && !settling
    }

    static func shouldRestore(reason: DisplayRefreshReason, isKnown: Bool, settling: Bool,
                              affectedByReconnect: Bool, externalModeChangeObserved: Bool = false) -> Bool {
        if externalModeChangeObserved { return false }
        if reason == .inventory { return false }
        if !isKnown { return true }
        return settling && (reason == .wake || (reason == .topology && affectedByReconnect))
    }

    static func shouldRebind(reason: DisplayRefreshReason, isKnown: Bool,
                             affectedByReconnect: Bool, alreadyRebound: Bool,
                             ddcResponded: Bool = false) -> Bool {
        guard isKnown, reason == .wake || (reason == .topology && affectedByReconnect) else { return false }
        return !alreadyRebound || !ddcResponded
    }

    /// Gamma belongs to one physical screen. An unrelated display callback must not
    /// rewrite an already-dimmed screen's transfer table.
    static func shouldReapplyDimming(reason: DisplayRefreshReason,
                                     affectedByReconnect: Bool,
                                     modeChangeAffected: Bool) -> Bool {
        reason == .wake || (reason == .topology && affectedByReconnect)
            || modeChangeAffected
    }

    static func mayWrite(captured: DisplayIdentity, current: DisplayIdentity,
                         online: Bool) -> Bool {
        // Some monitors report serial zero. Matching a nonzero vendor/model with
        // serial zero is the strongest CG check available; proxy uniqueness remains
        // a separate requirement when attaching DDC.
        online && captured.vendor > 0 && captured.model > 0 && captured == current
    }
}

/// Captured when a model is created; CG display IDs may later be reused.
struct DisplayIdentity: Equatable {
    let vendor: Int
    let model: Int
    let serial: Int
}
