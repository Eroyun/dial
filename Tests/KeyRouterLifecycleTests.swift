import AppKit

@main @MainActor
struct KeyRouterLifecycleTests {
    static func main() async {
        let selected = Set(CommandLine.arguments.dropFirst())
        if selected.isEmpty || selected.contains("native") { await nativePickerLifecycle() }
        if selected.isEmpty || selected.contains("paired") { pairedReleases() }
        if selected.isEmpty || selected.contains("termination") { terminationDrainsOnce() }
        print("Key router lifecycle: picker repeat, paired releases, and termination drain passed")
    }

    static func fixture(_ body: (KeyboardMappings) -> Void) {
        let suite = "Dial.KeyRouterLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        body(KeyboardMappings(defaults: defaults))
    }

    static func event(_ code: UInt16, down: Bool = true, repeating: Bool = false,
                      flags: CGEventFlags = []) -> CGEvent {
        let value = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)!
        value.flags = flags
        value.setIntegerValueField(.keyboardEventAutorepeat, value: repeating ? 1 : 0)
        return value
    }

    static func flushActions() async {
        // FIFO sentinel observes native callbacks already queued by handle().
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    static func routed(_ router: KeyRouter, _ type: CGEventType, _ input: CGEvent) -> CGEvent? {
        let output = router.handle(type, input)?.takeUnretainedValue()
        withExtendedLifetime(input) {}
        return output
    }

    static func nativePickerLifecycle() async {
        let suite = "Dial.KeyRouterLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let mappings = KeyboardMappings(defaults: defaults)
        mappings.assign(input: DialKeyChord(keyCode: 107, modifiers: 0), action: .scrollingScreenshot)
        let router = KeyRouter(store: nil, startMonitoring: false, mappings: mappings,
                               postRelease: { _ in preconditionFailure("Native inputs do not synthesize releases") })
        var picker = false
        var cancellations = 0
        var actions = 0
        router.cancelCaptureSelectionForKey = {
            guard picker else { return false }
            cancellations += 1
            picker = false
            return true
        }
        router.onNativeAction = { action in
            precondition(action == .scrollingScreenshot)
            actions += 1
            picker = true
        }
        precondition(router.handle(.keyDown, event(107)) == nil)
        await flushActions()
        precondition(picker && actions == 1)
        precondition(router.handle(.keyDown, event(107, repeating: true)) == nil)
        await flushActions()
        precondition(picker && cancellations == 0 && actions == 1,
                     "A held native shortcut must not cancel its own picker")
        precondition(router.handle(.keyUp, event(107, down: false)) == nil)
        precondition(router.handle(.keyDown, event(107)) == nil)
        precondition(!picker && cancellations == 1, "A fresh press still cancels selection")
        precondition(router.handle(.keyUp, event(107, down: false)) == nil)
        precondition(router.handle(.keyDown, event(107)) == nil)
        await flushActions()
        precondition(picker && actions == 2, "The paired release must clear the native held route")
        precondition(router.handle(.keyUp, event(107, down: false)) == nil)
    }

    static func pairedReleases() {
        fixture { mappings in
            let output = DialKeyChord(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue)
            mappings.assign(input: DialKeyChord(keyCode: 0, modifiers: 0), output: output)
            mappings.numLockOn = false
            mappings.numpadMode = "navigation"
            let router = KeyRouter(store: nil, startMonitoring: false, mappings: mappings,
                                   postRelease: { _ in preconditionFailure("Paired releases must finish in handle") })
            var picker = false
            var cancellations = 0
            router.cancelCaptureSelectionForKey = {
                guard picker else { return false }
                cancellations += 1
                picker = false
                return true
            }
            for (input, destination, flags) in [(UInt16(0), UInt16(8), CGEventFlags.maskCommand),
                                                (UInt16(83), UInt16(119), CGEventFlags())] {
                picker = false
                let down = routed(router, .keyDown, event(input))!
                precondition(down.getIntegerValueField(.keyboardEventKeycode) == Int64(destination))
                picker = true
                for repeating in [true, false] {
                    // Both repeats and extra downs retain the original route.
                    let held = routed(router, .keyDown, event(input, repeating: repeating))
                    precondition(picker && cancellations == 0,
                                 "Selection cannot steal a route whose output is already held")
                    if input == 0 {
                        precondition(held == nil, "Custom mappings consume held downs without duplicating output presses")
                    } else {
                        precondition(held?.getIntegerValueField(.keyboardEventKeycode) == Int64(destination),
                                     "Numpad navigation retains transformed held downs")
                    }
                }
                let up = routed(router, .keyUp, event(input, down: false))!
                precondition(up.getIntegerValueField(.keyboardEventKeycode) == Int64(destination))
                precondition(up.flags == flags, "Transformed key-up retains the original output modifiers")
            }
            precondition(router.handle(.keyDown, event(2)) == nil)
            precondition(!picker && cancellations == 1)
            precondition(router.handle(.keyUp, event(2, down: false)) == nil)
        }
    }

    static func terminationDrainsOnce() {
        fixture { mappings in
            let output = DialKeyChord(keyCode: 8, modifiers: CGEventFlags.maskCommand.rawValue)
            mappings.assign(input: DialKeyChord(keyCode: 0, modifiers: 0), output: output)
            mappings.assign(input: DialKeyChord(keyCode: 107, modifiers: 0), action: .scrollingScreenshot)
            mappings.numLockOn = false
            mappings.numpadMode = "navigation"
            var releases: [DialKeyChord] = []
            var router: KeyRouter? = KeyRouter(store: nil, startMonitoring: false, mappings: mappings,
                                               postRelease: { releases.append($0) })
            let isReleased = { [weak router] in router == nil }
            precondition(router!.handle(.keyDown, event(0)) != nil)
            precondition(router!.handle(.keyDown, event(83)) != nil)
            precondition(router!.handle(.keyDown, event(107)) == nil)
            precondition(releases.isEmpty)
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            precondition(releases == [output, DialKeyChord(keyCode: 119, modifiers: 0)],
                         "Normal quit must release all mapped outputs while the router is retained")
            NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
            router = nil
            precondition(isReleased(), "The termination observer must not retain the router")
            precondition(releases.count == 2, "Repeated notification and deinit must not duplicate key-ups")
        }
    }
}
