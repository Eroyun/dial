/// CoreGraphics mode identity is more specific than the size and rate shown in Dial.
/// This does not encode macOS's HDR preference, which is separate from these fields.
struct DisplayModeDescriptor: Equatable {
    let key: String
    let fingerprint: String
}

enum DisplayModeSelectionPolicy {
    /// An exact saved mode wins. Legacy preferences can be restored only when their
    /// size/rate identifies one distinct mode; choosing among variants could change color behavior.
    static func restoreIndex(savedKey: String, savedFingerprint: String?, currentKey: String,
                             candidates: [DisplayModeDescriptor]) -> Int? {
        guard savedKey != currentKey else { return nil }
        let matching = candidates.indices.filter { candidates[$0].key == savedKey }
        if let savedFingerprint,
           let exact = matching.first(where: { candidates[$0].fingerprint == savedFingerprint }) {
            return exact
        }
        var fingerprints = Set<String>()
        let distinct = matching.filter { fingerprints.insert(candidates[$0].fingerprint).inserted }
        return distinct.count == 1 ? distinct[0] : nil
    }

    static func matchCounts(savedKey: String, candidates: [DisplayModeDescriptor]) -> (raw: Int, distinct: Int) {
        let matching = candidates.filter { $0.key == savedKey }
        return (matching.count, Set(matching.map(\.fingerprint)).count)
    }
}
