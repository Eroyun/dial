// swiftc Sources/Dial/DisplayModeSelectionPolicy.swift Tests/DisplayModeSelectionPolicyTests.swift -o /tmp/dial-mode-policy-tests && /tmp/dial-mode-policy-tests
@main
struct DisplayModeSelectionPolicyTests {
    static func main() {
        let variants = [
            DisplayModeDescriptor(key: "1920x1080@2x@160", fingerprint: "first"),
            DisplayModeDescriptor(key: "1920x1080@2x@160", fingerprint: "second"),
            DisplayModeDescriptor(key: "2560x1440@165", fingerprint: "other")
        ]

        // A precise preference selects its variant, not the first same-size mode.
        precondition(DisplayModeSelectionPolicy.restoreIndex(savedKey: variants[0].key,
            savedFingerprint: "second", currentKey: "1280x720@60", candidates: variants) == 1)
        // If the OS is already at the requested size and rate, preserve its actual mode.
        precondition(DisplayModeSelectionPolicy.restoreIndex(savedKey: variants[0].key,
            savedFingerprint: "first", currentKey: variants[0].key, candidates: variants) == nil)
        // An old size/rate-only preference must not choose an arbitrary variant.
        precondition(DisplayModeSelectionPolicy.restoreIndex(savedKey: variants[0].key,
            savedFingerprint: nil, currentKey: "1280x720@60", candidates: variants) == nil)
        precondition(DisplayModeSelectionPolicy.restoreIndex(savedKey: variants[0].key,
            savedFingerprint: "unavailable", currentKey: "1280x720@60", candidates: variants) == nil)
        // A sole available mode still restores legacy 160/165 Hz preferences.
        precondition(DisplayModeSelectionPolicy.restoreIndex(savedKey: "2560x1440@165",
            savedFingerprint: nil, currentKey: "1280x720@60", candidates: variants) == 2)
        precondition(DisplayModeSelectionPolicy.restoreIndex(savedKey: "2560x1440@165",
            savedFingerprint: "old-id", currentKey: "1280x720@60", candidates: variants) == 2)
        // CoreGraphics may enumerate the same underlying mode more than once.
        let duplicateEntries = [
            DisplayModeDescriptor(key: "1920x1080@2x@165", fingerprint: "same-mode"),
            DisplayModeDescriptor(key: "1920x1080@2x@165", fingerprint: "same-mode")
        ]
        precondition(DisplayModeSelectionPolicy.restoreIndex(savedKey: "1920x1080@2x@165",
            savedFingerprint: nil, currentKey: "1280x720@60", candidates: duplicateEntries) == 0)
        precondition(DisplayModeSelectionPolicy.restoreIndex(savedKey: "1920x1080@2x@165",
            savedFingerprint: "stale-id", currentKey: "1280x720@60", candidates: duplicateEntries) == 0)
        let duplicateCounts = DisplayModeSelectionPolicy.matchCounts(savedKey: "1920x1080@2x@165",
                                                                      candidates: duplicateEntries)
        precondition(duplicateCounts.raw == 2 && duplicateCounts.distinct == 1)
        let variantCounts = DisplayModeSelectionPolicy.matchCounts(savedKey: variants[0].key,
                                                                    candidates: variants)
        precondition(variantCounts.raw == 2 && variantCounts.distinct == 2)
        print("DisplayModeSelectionPolicy: all checks passed")
    }
}
