import Foundation

/// A small, pure bound for walking an accessibility parent chain. Only an
/// exact match proves containment; every incomplete walk remains fail-closed.
enum CaptureAncestryWalk {
    static let maximumNodes = 64

    enum Stop: Equatable {
        case matched
        case missingParent
        case cycle
        case depthLimit
        case budgetExhausted
    }

    struct Result: Equatable {
        let stop: Stop
        let visitedNodes: Int
        var containsTarget: Bool { stop == .matched }

        var validationIssue: String? {
            switch stop {
            case .matched: return nil
            case .missingParent: return "point_not_in_content_stop_missing_parent_depth_\(visitedNodes)"
            case .cycle: return "point_not_in_content_stop_cycle_depth_\(visitedNodes)"
            case .depthLimit: return "point_ancestry_stop_depth_limit_depth_\(visitedNodes)"
            case .budgetExhausted: return "point_ancestry_stop_budget_exhausted_depth_\(visitedNodes)"
            }
        }
    }

    static func evaluate<Node>(from start: Node, matching target: Node,
                               maximumNodes: Int = CaptureAncestryWalk.maximumNodes,
                               isWithinBudget: () -> Bool,
                               parent: (Node) -> Node?,
                               equals: (Node, Node) -> Bool) -> Result {
        guard maximumNodes > 0 else { return Result(stop: .depthLimit, visitedNodes: 0) }
        var current: Node? = start
        var seen: [Node] = []

        for _ in 0..<maximumNodes {
            guard isWithinBudget() else { return Result(stop: .budgetExhausted, visitedNodes: seen.count) }
            guard let node = current else { return Result(stop: .missingParent, visitedNodes: seen.count) }
            if equals(node, target) { return Result(stop: .matched, visitedNodes: seen.count + 1) }
            guard !seen.contains(where: { equals($0, node) }) else {
                return Result(stop: .cycle, visitedNodes: seen.count)
            }
            seen.append(node)
            current = parent(node)
        }

        return Result(stop: .depthLimit, visitedNodes: seen.count)
    }
}
