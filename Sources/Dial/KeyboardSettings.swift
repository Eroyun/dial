import AppKit
import SwiftUI
import Observation

@Observable
final class KeyboardEditor {
    let router: KeyRouter
    let mappings: KeyboardMappings
    var section: KeyboardSection
    var mappingSearch = ""
    var mappingFilter = MappingFilter.all
    var mappingSort = MappingSort.key
    var savedMappingID: UUID?
    let screen = AULAScreenSettings()
    var input = DialKeyChord(keyCode: 105, modifiers: 0)
    var output = DialKeyChord(keyCode: 21, modifiers: CGEventFlags([.maskCommand, .maskShift]).rawValue)
    var preset = "Screenshot selection"
    var recordingOutput = false
    var message = ""
    var customReady = true
    var nativeAction: KeyboardNativeAction? { KeyboardNativeAction.allCases.first { $0.displayName == preset } }
    var scrollingAction: Bool { nativeAction == .scrollingScreenshot || nativeAction == .copyScrollingScreenshot }
    var actionShortcutLabel: String {
        if preset == "Screenshot selection" || preset == "Copy screenshot selection" {
            return Self.screenshot(copy: preset == "Copy screenshot selection").label
        }
        return scrollingAction ? "Capture page content" : output.label
    }
    private var timer: Timer?

    init(router: KeyRouter, mappings: KeyboardMappings = .shared) {
        self.router = router
        self.mappings = mappings
        section = mappings.mappings.isEmpty ? .setup : .mappings
    }

    func showMappings() { stopRecording(); section = .mappings }
    func edit(_ mapping: KeyMapping) { select(mapping.input); section = .setup }
    func clearFilters() { mappingSearch = ""; mappingFilter = .all }

    func record(output: Bool = false) {
        recordingOutput = output
        message = ""
        router.beginRecording()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            if let chord = self.router.capturedChord {
                if self.recordingOutput { self.output = chord; self.preset = "Custom shortcut"; self.customReady = true }
                else { self.input = chord }
                self.router.clearCapturedChord()
                self.stopRecording()
            } else if !self.router.recording { self.stopRecording() }
        }
    }

    func stopRecording() { timer?.invalidate(); timer = nil; router.cancelRecording() }

    func select(_ chord: DialKeyChord) {
        stopRecording()
        input = chord
        if let mapping = mappings.mappings.first(where: { $0.input == chord }) {
            output = mapping.output
            preset = mapping.nativeAction?.displayName ?? Self.preset(for: output)
            customReady = true
        }
        message = ""
    }

    func choose(_ name: String) {
        preset = name
        customReady = name != "Custom shortcut"
        if name == "Screenshot selection" { output = Self.screenshot() }
        if name == "Copy screenshot selection" { output = Self.screenshot(copy: true) }
        if name == "Screenshot controls" { output = DialKeyChord(keyCode: 23, modifiers: CGEventFlags([.maskCommand, .maskShift]).rawValue) }
    }

    func save() {
        guard customReady else { return }
        stopRecording()
        if let action = nativeAction { mappings.assign(input: input, action: action) }
        else { mappings.assign(input: input, output: output) }
        message = "Saved · \(input.label) → \(nativeAction?.displayName ?? output.label)"
        savedMappingID = mappings.mappings.first(where: { $0.input == input })?.id
        clearFilters()
        section = .mappings
    }

    static func screenshot(copy: Bool = false) -> DialKeyChord {
        DialKeyChord(keyCode: 21, modifiers: CGEventFlags(copy ? [.maskControl, .maskCommand, .maskShift] : [.maskCommand, .maskShift]).rawValue)
    }

    static func preset(for chord: DialKeyChord) -> String {
        MappingQuery.actionName(for: chord)
    }
}

final class KeyboardSettingsWindow: NSObject, NSWindowDelegate {
    let editor: KeyboardEditor
    private var window: NSWindow?

    init(router: KeyRouter) {
        editor = KeyboardEditor(router: router)
        super.init()
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(mappingsChanged), name: Notification.Name(KeyboardCommand.changedNotification), object: nil)
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(openRequested), name: Notification.Name(KeyboardCommand.openNotification), object: nil)
    }

    deinit { editor.screen.endMonitoring(); DistributedNotificationCenter.default().removeObserver(self) }
    @objc private func mappingsChanged() { KeyboardMappings.shared.reload() }
    @objc private func openRequested() { show() }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 780), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Keyboard · Dial"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: KeyboardSettingsView(editor: editor))
            window.center()
            self.window = window
            editor.router.recordingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        editor.screen.beginMonitoring()
    }

    func windowWillClose(_ notification: Notification) { editor.stopRecording(); editor.screen.endMonitoring() }
    func windowDidResignKey(_ notification: Notification) { editor.stopRecording() }
}

struct KeyboardSettingsView: View {
    let editor: KeyboardEditor
    var showConnectionStatus = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Your keys, your shortcuts").font(.system(size: 23, weight: .semibold, design: .rounded))
                    Text(editor.section == .setup ? "Choose a key below, or press the actual key on your keyboard." : "Find and manage the shortcuts you have saved.").foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    Toggle("Mappings", isOn: Binding(get: { editor.mappings.enabled }, set: { editor.mappings.enabled = $0 })).toggleStyle(.switch)
                    Toggle("Numpad", isOn: Binding(get: { editor.mappings.numLockOn }, set: { editor.mappings.numLockOn = $0 })).toggleStyle(.switch)
                }.fixedSize()
            }

            if showConnectionStatus && !Access.shared.granted {
                HStack {
                    Label("Allow Dial in Privacy & Security to use your shortcuts.", systemImage: "hand.raised")
                    Spacer()
                    Button("Open Settings") { Access.shared.ask() }
                }.padding(12).background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            } else if showConnectionStatus && !editor.router.active {
                Text("Keyboard connection unavailable. Quit and reopen Dial to reconnect.").foregroundStyle(.orange)
            }

            HStack {
            Picker("Keyboard view", selection: Binding(get: { editor.section }, set: {
                editor.stopRecording()
                editor.section = $0
            })) {
                Text("Set up a key").tag(KeyboardSection.setup)
                Text("Mappings (\(editor.mappings.mappings.count))").tag(KeyboardSection.mappings)
            }.pickerStyle(.segmented).labelsHidden()
            Button("Scrolling screenshot") { ScrollScreenshot.shared.start() }
                .help("Capture the page automatically; Stop finishes early")
            }

            if editor.section == .mappings {
                MappingBrowser(editor: editor)
            } else {
                keyboard

                AULAScreenCard(model: editor.screen)

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("1  Choose a key").font(.headline)
                        HStack {
                            Text(editor.input.label).font(.system(size: 18, weight: .medium, design: .rounded))
                            Spacer()
                            Button(editor.router.recording && !editor.recordingOutput ? "Cancel" : "Press a key…") {
                                if editor.router.recording { editor.stopRecording() } else { editor.record() }
                            }.disabled(showConnectionStatus && !editor.router.active)
                                .accessibilityLabel(editor.router.recording && !editor.recordingOutput ? "Cancel key recording" : "Press a key")
                        }
                        if editor.router.recording && !editor.recordingOutput {
                            Text("Press a key, with any modifiers you want.").foregroundStyle(.tint)
                        } else {
                            Text("Include Control, Shift, Option or Command for a combination.").foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)

                    Divider()

                    VStack(alignment: .leading, spacing: 10) {
                        Text("2  Choose an action").font(.headline)
                        Picker("Action", selection: Binding(get: { editor.preset }, set: { editor.choose($0) })) {
                            ForEach(["Screenshot selection", "Copy screenshot selection", "Screenshot controls", "Scrolling screenshot", "Copy scrolling screenshot", "Custom shortcut"], id: \.self) { Text($0).tag($0) }
                        }.labelsHidden()
                        HStack {
                            Text(editor.actionShortcutLabel).font(.system(size: 16, weight: .medium, design: .rounded))
                            Spacer()
                            if editor.preset == "Custom shortcut" {
                                Button(editor.router.recording && editor.recordingOutput ? "Cancel" : "Record…") {
                                    if editor.router.recording { editor.stopRecording() } else { editor.record(output: true) }
                                }.disabled(showConnectionStatus && !editor.router.active)
                                    .accessibilityLabel(editor.router.recording && editor.recordingOutput ? "Cancel shortcut recording" : "Record shortcut")
                            }
                            Button("Save mapping") { editor.save() }.buttonStyle(.borderedProminent).disabled(editor.router.recording || (editor.nativeAction == nil && editor.input == editor.output) || !editor.customReady).accessibilityLabel("Save mapping")
                        }
                        Text(editor.scrollingAction ? "Captures the page automatically. Stop finishes early.\(editor.nativeAction == .copyScrollingScreenshot ? " Copies the result." : "")" : editor.router.recording && editor.recordingOutput ? "Press the shortcut your key should perform." : editor.preset == "Copy screenshot selection" ? "Select an area to copy to the clipboard." : editor.preset == "Screenshot selection" ? "Select an area to save a screenshot." : editor.preset == "Custom shortcut" ? "Record the shortcut your key should perform." : "Open macOS screenshot and recording controls.")
                            .foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 112).padding(16).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))

                HStack {
                    Text(editor.message).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Browse mappings (\(editor.mappings.mappings.count))") { editor.showMappings() }
                }
                Spacer(minLength: 0)
            }
            if editor.section == .setup {
                Text("Num Lock controls the numpad. Mappings apply to connected keyboards; use “Press a key” to confirm Print Screen / F13.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.padding(24).frame(width: 820, height: 780).background(Color(nsColor: .windowBackgroundColor))
    }

    private var keyboard: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 6) {
                keyRow([53,122,120,99,118,96,97,98,100,101,109,103,111,105,107,113])
                keyRow([50,18,19,20,21,23,22,26,28,25,29,27,24,51,114,115,116])
                keyRow([48,12,13,14,15,17,16,32,34,31,35,33,30,42,117,119,121])
                keyRow([57,0,1,2,3,5,4,38,40,37,41,39,36])
                keyRow([56,6,7,8,9,11,45,46,43,47,44,60,126])
                keyRow([59,58,55,49,54,61,62,123,125,124])
            }
            VStack(spacing: 6) {
                Text("Numpad").font(.system(size: 10)).foregroundStyle(.secondary).frame(height: 25)
                keyRow([71,75,67,78])
                keyRow([89,91,92,69])
                keyRow([86,87,88])
                keyRow([83,84,85,76])
                keyRow([82,65])
            }.frame(width: 110)
        }.padding(12).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func keyRow(_ codes: [UInt16]) -> some View {
        HStack(spacing: 4) {
            ForEach(codes, id: \.self) { code in
                let selected = editor.input.keyCode == code
                Button { editor.select(DialKeyChord(keyCode: code, modifiers: 0)) } label: {
                    Text(keyLabel(code))
                        .font(.system(size: 10, weight: selected ? .bold : .medium, design: .rounded))
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity).frame(height: 25)
                        .background(selected ? Color.accentColor.opacity(0.2) : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.08)))
                }.buttonStyle(.plain).accessibilityLabel(DialKeyChord.name(for: code))
                    .disabled(DialKeyChord(keyCode: code, modifiers: 0).isModifierOnly)
            }
        }
    }

    private func keyLabel(_ code: UInt16) -> String {
        if code == 105 { return "Print" }
        if code == 71 { return "Num" }
        if code == 51 { return "⌫" }
        if code == 117 { return "Del" }
        if code == 114 { return "Ins" }
        if code == 53 { return "Esc" }
        if code == 116 { return "PgUp" }
        if code == 121 { return "PgDn" }
        if code == 54 || code == 55 { return "⌘" }
        if code == 56 || code == 60 { return "⇧" }
        if code == 58 || code == 61 { return "⌥" }
        if code == 59 || code == 62 { return "⌃" }
        return DialKeyChord.name(for: code).replacingOccurrences(of: "Keypad ", with: "")
    }
}
