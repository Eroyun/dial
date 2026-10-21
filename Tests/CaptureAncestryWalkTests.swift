import Foundation

@main
enum CaptureAncestryWalkTests {
    static func main() {
        func walk(from start: Int, target: Int, maximumNodes: Int = CaptureAncestryWalk.maximumNodes,
                  isWithinBudget: () -> Bool = { true }, parent: (Int) -> Int?) -> CaptureAncestryWalk.Result {
            CaptureAncestryWalk.evaluate(from: start, matching: target,
                maximumNodes: maximumNodes, isWithinBudget: isWithinBudget,
                parent: parent, equals: ==)
        }

        let deep = walk(from: 0, target: 30, parent: { $0 < 30 ? $0 + 1 : nil })
        precondition(deep.stop == .matched && deep.containsTarget && deep.visitedNodes == 31,
                     "A deep virtualized accessibility chain remains valid")
        precondition(deep.validationIssue == nil, "A proven ancestor has no failure diagnostic")

        let boundary = walk(from: 0, target: 63, parent: { $0 < 63 ? $0 + 1 : nil })
        precondition(boundary.stop == .matched && boundary.containsTarget && boundary.visitedNodes == 64,
                     "The last node within the bound can match")
        let beyond = walk(from: 0, target: 64, parent: { $0 < 64 ? $0 + 1 : nil })
        precondition(beyond.stop == .depthLimit && !beyond.containsTarget && beyond.visitedNodes == 64,
                     "A target beyond the bound is incomplete and rejected")
        precondition(beyond.validationIssue == "point_ancestry_stop_depth_limit_depth_64")

        let outside = walk(from: 1, target: 9, parent: { $0 == 1 ? 2 : nil })
        precondition(outside.stop == .missingParent && !outside.containsTarget,
                     "A terminated chain outside the selected region is rejected")
        precondition(outside.validationIssue == "point_not_in_content_stop_missing_parent_depth_2")
        let cycle = walk(from: 1, target: 9, parent: { $0 == 1 ? 2 : 1 })
        precondition(cycle.stop == .cycle && !cycle.containsTarget,
                     "A malformed parent cycle is rejected")
        precondition(cycle.validationIssue == "point_not_in_content_stop_cycle_depth_2")

        var budgetChecks = 0
        let budget = walk(from: 0, target: 8, isWithinBudget: {
            budgetChecks += 1
            return budgetChecks <= 3
        }, parent: { $0 + 1 })
        precondition(budget.stop == .budgetExhausted && !budget.containsTarget,
                     "Budget exhaustion never proves containment")
        precondition(budget.validationIssue == "point_ancestry_stop_budget_exhausted_depth_3")

        print("Capture ancestry walk bounds and fail-closed results passed")
    }
}
