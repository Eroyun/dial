import Foundation
import CoreGraphics

// Querying saved preferences is independent of the router's runtime state.
enum KeyboardSection: Hashable { case setup, mappings }
enum MappingFilter: String, CaseIterable { case all = "All", enabled = "Enabled", disabled = "Disabled" }
enum MappingSort: String, CaseIterable { case key = "Key", action = "Action" }

struct MappingQuery {
    static func displayOutput(for mapping: KeyMapping) -> DialKeyChord {
        let modifiers = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        switch mapping.nativeAction {
        case .screenshotSelection: return DialKeyChord(keyCode: 21, modifiers: modifiers)
        case .copyScreenshotSelection: return DialKeyChord(keyCode: 21, modifiers: modifiers | CGEventFlags.maskControl.rawValue)
        default: return mapping.output
        }
    }

    static func actionName(for mapping: KeyMapping) -> String {
        mapping.nativeAction?.displayName ?? actionName(for: mapping.output)
    }
    static func actionName(for chord: DialKeyChord) -> String {
        let screenshot = CGEventFlags.maskCommand.rawValue | CGEventFlags.maskShift.rawValue
        if chord == DialKeyChord(keyCode: 21, modifiers: screenshot) { return "Screenshot selection" }
        if chord == DialKeyChord(keyCode: 21, modifiers: screenshot | CGEventFlags.maskControl.rawValue) { return "Copy screenshot selection" }
        if chord == DialKeyChord(keyCode: 23, modifiers: screenshot) { return "Screenshot controls" }
        return "Custom shortcut"
    }

    static func count(_ filter: MappingFilter, in mappings: [KeyMapping]) -> Int {
        mappings.filter { accepts($0, filter: filter) }.count
    }

    static func results(in mappings: [KeyMapping], search: String = "", filter: MappingFilter = .all,
                        sort: MappingSort = .key) -> [KeyMapping] {
        let tokens = normalized(search).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let modifiers: Set<String> = ["control", "command", "shift", "option"]
        let keyWords: Set<String> = ["keypad", "print", "screen", "page", "up", "down", "left", "right", "return", "enter", "space", "tab", "escape", "delete", "forward", "home", "end", "help", "num", "lock", "clear"]
        let shortcutQuery = tokens.contains(where: { modifiers.contains($0) }) &&
            tokens.allSatisfy { modifiers.contains($0) || keyWords.contains($0) || exactKeyToken($0) }
        return mappings.filter { mapping in
            guard accepts(mapping, filter: filter) else { return false }
            let chords = [mapping.input, displayOutput(for: mapping)]
            if shortcutQuery {
                // A shortcut must occur on one side of the mapping; modifiers from
                // the input cannot accidentally qualify an unrelated output key.
                return chords.contains { chord in
                    let words = Set(searchText(chord).split(whereSeparator: { $0.isWhitespace }).map(String.init))
                    return tokens.allSatisfy { words.contains($0) }
                }
            }
            let text = normalized("\(searchText(mapping.input)) \(actionName(for: mapping)) \(searchText(displayOutput(for: mapping)))")
            let keyTokens = Set(chords.flatMap { normalized(DialKeyChord.name(for: $0.keyCode)).split(whereSeparator: { $0.isWhitespace }).map(String.init) })
            return tokens.allSatisfy { exactKeyToken($0) ? keyTokens.contains($0) : text.contains($0) }
        }.sorted { lhs, rhs in
            let lhsPrimary = sort == .action ? actionName(for: lhs).lowercased() : lhs.input.label.lowercased()
            let rhsPrimary = sort == .action ? actionName(for: rhs).lowercased() : rhs.input.label.lowercased()
            if lhsPrimary != rhsPrimary { return lhsPrimary < rhsPrimary }
            if lhs.input.keyCode != rhs.input.keyCode { return lhs.input.keyCode < rhs.input.keyCode }
            if lhs.input.modifiers != rhs.input.modifiers { return lhs.input.modifiers < rhs.input.modifiers }
            if lhs.output.keyCode != rhs.output.keyCode { return lhs.output.keyCode < rhs.output.keyCode }
            if lhs.output.modifiers != rhs.output.modifiers { return lhs.output.modifiers < rhs.output.modifiers }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private static func accepts(_ mapping: KeyMapping, filter: MappingFilter) -> Bool {
        filter == .all || (filter == .enabled ? mapping.enabled : !mapping.enabled)
    }

    private static func exactKeyToken(_ token: String) -> Bool {
        token.count == 1 || token.allSatisfy(\.isNumber) ||
            (token.first == "f" && token.dropFirst().isEmpty == false && token.dropFirst().allSatisfy(\.isNumber))
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "⌃", with: " control ")
            .replacingOccurrences(of: "⌘", with: " command ")
            .replacingOccurrences(of: "⇧", with: " shift ")
            .replacingOccurrences(of: "⌥", with: " option ")
            .replacingOccurrences(of: #"\b(control|ctrl|command|cmd|shift|option|alt)\s*\+\s*"#, with: "$1 ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace }).map { token in
                switch token { case "ctrl": return "control"; case "cmd": return "command"; case "alt": return "option"; default: return String(token) }
            }.joined(separator: " ")
    }

    private static func searchText(_ chord: DialKeyChord) -> String {
        // Spaces between modifier names and the key also support "cmd shift 4".
        normalized(chord.label)
    }
}

#if !MAPPING_BROWSER_QUERY_ONLY
import SwiftUI

struct MappingBrowser: View {
    let editor: KeyboardEditor

    private var results: [KeyMapping] {
        MappingQuery.results(in: editor.mappings.mappings, search: editor.mappingSearch,
                             filter: editor.mappingFilter, sort: editor.mappingSort)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search keys, actions or shortcuts", text: Binding(get: { editor.mappingSearch }, set: { editor.mappingSearch = $0 }))
                    .textFieldStyle(.plain).accessibilityLabel("Search mappings")
                if !editor.mappingSearch.isEmpty {
                    Button { editor.mappingSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear mapping search")
                }
            }.padding(12).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))

            HStack {
                Picker("Saved mapping status", selection: Binding(get: { editor.mappingFilter }, set: { editor.mappingFilter = $0 })) {
                    ForEach(MappingFilter.allCases, id: \.self) { filter in
                        Text("\(filter.rawValue) (\(MappingQuery.count(filter, in: editor.mappings.mappings)))").tag(filter)
                    }
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 410)
                Spacer()
                Picker("Sort by", selection: Binding(get: { editor.mappingSort }, set: { editor.mappingSort = $0 })) {
                    ForEach(MappingSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.frame(width: 145)
            }

            HStack {
                Text("\(results.count) of \(editor.mappings.mappings.count) mappings").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Text(editor.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if !editor.mappings.enabled || (!editor.mappings.numLockOn && editor.mappings.numpadMode == "disabled") || editor.router.recording {
                runtimeStatus
            }

            if editor.mappings.mappings.isEmpty {
                emptyState(title: "No mappings yet", detail: "Set up a key to give it a shortcut.") {
                    Button("Set up a key") { editor.section = .setup }.buttonStyle(.borderedProminent)
                }
            } else if results.isEmpty {
                emptyState(title: "No matching mappings", detail: "Try another key, action or shortcut, or clear your filters.") {
                    Button("Clear filters") { editor.clearFilters() }
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(results) { mapping in row(mapping).id(mapping.id) }
                        }.padding(.vertical, 2)
                    }
                    .onAppear { if let id = editor.savedMappingID { proxy.scrollTo(id, anchor: .center) } }
                    .onChange(of: editor.savedMappingID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
            Text("Search by key or action, or type a shortcut like “cmd shift 4”.")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxHeight: .infinity, alignment: .top)
    }

    private var runtimeStatus: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !editor.mappings.enabled {
                Label("Mappings are globally off. Enabled preferences are saved.", systemImage: "pause.circle")
            }
            if !editor.mappings.numLockOn && editor.mappings.numpadMode == "disabled" {
                Label("Numpad keys are paused while Num Lock is off.", systemImage: "pause.circle")
            }
            if editor.router.recording {
                Label("Mappings are paused while recording a key.", systemImage: "record.circle")
            }
        }.font(.subheadline).foregroundStyle(.secondary)
    }

    private func row(_ mapping: KeyMapping) -> some View {
        HStack(spacing: 16) {
            Toggle("Enable \(mapping.input.label)", isOn: Binding(get: {
                editor.mappings.mappings.first(where: { $0.id == mapping.id })?.enabled ?? false
            }, set: { editor.mappings.setEnabled(id: mapping.id, on: $0) }))
                .labelsHidden().toggleStyle(.switch).controlSize(.small)
                .help("Saved enabled preference")
            Text(mapping.input.label).font(.system(size: 16, weight: .medium, design: .rounded))
                .frame(width: 175, alignment: .leading).lineLimit(2)
            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
            VStack(alignment: .leading, spacing: 5) {
                Text(MappingQuery.actionName(for: mapping)).fontWeight(.medium)
                Text(mapping.nativeAction == .scrollingScreenshot || mapping.nativeAction == .copyScrollingScreenshot ? "Select an area · capture automatically" : MappingQuery.displayOutput(for: mapping).label).font(.subheadline).foregroundStyle(.secondary)
                if !mapping.enabled {
                    Text("Disabled").font(.caption).foregroundStyle(.secondary)
                } else if !editor.mappings.enabled {
                    Text("Enabled · globally off").font(.caption).foregroundStyle(.secondary)
                } else if mapping.input.isKeypadKey && !editor.mappings.numLockOn && editor.mappings.numpadMode == "disabled" {
                    Text("Enabled · numpad paused").font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit") { editor.edit(mapping) }.accessibilityLabel("Edit \(mapping.input.label)")
            Button { editor.mappings.remove(id: mapping.id) } label: { Image(systemName: "trash") }
                .help("Remove \(mapping.input.label)").accessibilityLabel("Remove \(mapping.input.label)")
        }.padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(mapping.id == editor.savedMappingID ? Color.accentColor.opacity(0.5) : .clear))
    }

    private func emptyState<Actions: View>(title: String, detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "keyboard").font(.system(size: 32)).foregroundStyle(.secondary)
            Text(title).font(.title3).fontWeight(.semibold)
            Text(detail).foregroundStyle(.secondary)
            actions()
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
