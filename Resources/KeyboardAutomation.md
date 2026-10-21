# Dial keyboard automation

Start discovery with `/Applications/Dial.app/Contents/MacOS/Dial --capabilities` or `--help`. Both return JSON without opening the GUI or starting display discovery.

The installed executable supports a headless JSON interface. Read its machine-readable help before acting:

```sh
/Applications/Dial.app/Contents/MacOS/Dial --keyboard help
/Applications/Dial.app/Contents/MacOS/Dial --keyboard list
```

To make Print capture a selected screenshot and Control+Print copy a selected screenshot:

```sh
/Applications/Dial.app/Contents/MacOS/Dial --keyboard assign --key print --action screenshot-selection
/Applications/Dial.app/Contents/MacOS/Dial --keyboard assign --key ctrl+print --action copy-screenshot-selection
/Applications/Dial.app/Contents/MacOS/Dial --keyboard list
```

For Dial's native scrolling capture, assign Scroll Lock (F14) and Control+Scroll Lock:

```sh
/Applications/Dial.app/Contents/MacOS/Dial --keyboard assign --key scroll --action scrolling-screenshot
/Applications/Dial.app/Contents/MacOS/Dial --keyboard assign --key ctrl+scroll --action copy-scrolling-screenshot
```

`scrolling-screenshot` runs Dial's capture coordinator once per physical press; `copy-scrolling-screenshot` copies the finished capture. `screenshot-selection` and `copy-screenshot-selection` launch macOS's built-in screenshot selection tool directly, saving to the configured screenshot folder or copying to the clipboard. These native actions consume repeats and the matching release. Dial must be running with keyboard accessibility permission, and capture requires Screen Recording permission. Arbitrary shortcut mappings emit ordinary macOS shortcuts. `list`/`inspect` identify native mappings with `nativeAction` and `actionLabel`; their retained `output` is only an identity chord for backward compatibility, not an emitted shortcut. Assigning a shortcut replaces a native action, and assigning a native action replaces a shortcut.

Other screenshot actions are `screenshot-screen`, `copy-screenshot-screen`, and `screenshot-options`. They emit standard macOS shortcuts, whose effect depends on the user's macOS shortcut configuration. Arbitrary ordinary-key shortcuts are supported:

```sh
/Applications/Dial.app/Contents/MacOS/Dial --keyboard assign --key numpad-1 --shortcut cmd+c
/Applications/Dial.app/Contents/MacOS/Dial --keyboard enable false --key print
/Applications/Dial.app/Contents/MacOS/Dial --keyboard enable true
/Applications/Dial.app/Contents/MacOS/Dial --keyboard remove --key numpad-1
```

`assign` replaces an existing input chord and enables that mapping. `enable true|false` controls all mappings; optional `--key CHORD` controls an existing mapping. `remove` is idempotent. Unknown arguments, repeated options, invalid keys, and incomplete commands fail before writing preferences. Exit codes are 0 for success, 2 for invalid requests, and 1 for runtime failures. Output is one JSON object with sorted keys. `inspect` is an alias for `list`.

Keys and aliases appear in `help`. Chords are case-insensitive; modifiers precede a key, separated by `+`. Use `numpad-add` for keypad plus. Explicit macOS virtual key codes use `code:105` or `code:0x69`; modifier-only codes are rejected. Print aliases F13 (code 105), and Scroll Lock aliases F14 (code 107); neither physical key identity is confirmed until observed from a native key press. There is no per-device mapping, media-key support, or headless recording. For an unknown physical key, use the GUI's bounded recording control.

The interface stores configuration in `io.github.eroyun.dial` and asks a running GUI to reload after changes. It does not start display discovery, start a keyboard event tap, or verify accessibility permissions or event delivery. `effectiveEnabled` describes the stored global and individual switches plus Num Lock eligibility, not proven runtime activation. `blockedByNumLock` marks mapped keypad inputs blocked by the disabled pad. Keep Dial running with the required permission to apply mappings.

```sh
/Applications/Dial.app/Contents/MacOS/Dial --keyboard open
```

`open` sends a keyboard-window request to an already running GUI and reports the request, not delivery. Bare `--keyboard` retains the normal GUI launch behavior. Automation should use explicit subcommands to avoid launching a second GUI instance.

Software NumLock state and the off-state keypad behavior are configurable:

```sh
/Applications/Dial.app/Contents/MacOS/Dial --keyboard numlock off
/Applications/Dial.app/Contents/MacOS/Dial --keyboard numpad-mode navigation
/Applications/Dial.app/Contents/MacOS/Dial --keyboard numpad-mode disabled
```

`disabled` is the default and suppresses keypad keys when NumLock is off. `numlock on` enables the keypad; `numlock off` disables it. The optional `navigation` mode selects navigation keys when NumLock is off. These are software settings; no physical NumLock LED behavior is verified. `numlock` and `num-lock` name the macOS keypad Clear key (code 71), whose physical NumLock identity needs verification. An explicit mapping for that key takes priority over the software toggle.

Related AULA screen-clock automation is discoverable through `--aula-clock status` and `--aula-clock sync --timezone TIMEZONE [--device REGISTRY_ID]`. A single compatible wired keyboard is selected automatically. Multiple matches require an explicit registry ID from status; there is no fallback to a different keyboard. Inspect clock status before synchronization; use the requested timezone rather than inferring it from filesystem paths. The clock packet has no documented LCD date-order setting.

`--panel open` requests the main control panel in a running app. This reports a request only, just like `--keyboard open`.

`--capture scroll` chooses the nearer starting boundary when a valid scroll fraction is available, otherwise it seeks the top. It reaches that boundary before composing an image, then captures toward the opposite boundary. Upward observations are joined into normal top-to-bottom output with verified overlaps. Preparation is bounded to 48 scroll attempts or 15 seconds; if neither a native scrollbar endpoint nor a visually verified boundary is obtained, no scrolling image is produced. A visual boundary requires stationary observations, positive matched movement away, and an exact RGB return inside the positively movement-verified content body; stationary imagery alone cannot start capture. Geometry-derived scroll fractions choose direction only and never prove an endpoint. `--capture copy-scroll` uses the same workflow and copies the resulting PNG. Dial uses its existing Accessibility and Screen Recording permissions. Stop retains accepted content after capture begins; Cancel discards an active capture. No manual scrolling or Done step is required.

For automation, `--capture copy-scroll --application com.google.Chrome` activates and captures one running instance of Chrome explicitly. Use `com.apple.TextEdit` for TextEdit. Without this option the keyboard shortcut uses the app already in front. The optional app selector is valid only for automatic start commands; it never starts or installs an app.

`--capture status` reads permission and fresh running-app metadata without starting capture. `runningAppReport` contains the responding PID, session ID, phase, outcome, dimensions, copied flag, target application bundle identifier and scroll-attempt count; it is a running-app report, not physical clipboard or image-quality proof. `end_observed` means a native scrollbar confirmed the top and bottom and a further scroll produced a stable frame. `end_inferred` means either the page start or end lacked a native confirmation. `startPreparationEvidence` and `startPreparationAttempts` report endpoint preparation separately from capture. `traversalDirection`, `acceptedCaptureFrames`, `lastStitchResult`, `lastStitchRejection` and `captureRegion` expose direction, accepted frame count and non-content diagnostics. `end_inferred`, `end_unverified`, `partial` and `stopped_early` must not be reported as a confirmed whole page. A missing reply means unknown. Multiple matching GUI instances are reported as ambiguous. Commands target the matching executable's single responding PID; Stop/Cancel also target its reported session. Requests still report `deliveryVerified: false`; inspect fresh status for completion.

Use `--capture stop` to finish an active session early, or `--capture cancel` to discard it. `--capture manual-scroll` and `--capture manual-copy-scroll` retain click-for-screen or drag-for-area selection, manual scrolling and Done. For manual stitching, exclude fixed sidebars and headers. The preview can copy or save to a chosen location. Manual sessions stop at two minutes or the image limit. Automatic whole-page sessions use a private, unlinked disk-backed row store and stop at ten minutes, 4,000 frames, 512 million output pixels or 1 million rows; uncertain overlap is reported and accepted content is retained. Apps that do not expose usable scrolling, animated pages and fixed sidebars may require manual capture. No history, upload, audio recording or unattended capture is started. Where the native scrollbar permits it, Dial restores the original page position after finishing or cancelling the same unchanged document.

Dragged capture areas resolve their scrolling target at the center of the crop. Before composing, an endpoint seek uses a separate bounded wheel request through the same selected-window destination checks; ordinary capture steps and strict overlap verification are unchanged.

Automatic page selections remove stationary edge columns from the exported image; explicitly dragged areas keep their chosen width. Image export propagates cancellation to disk-copy work and checks a cancellation token during native PNG output. Temporary raw pixels are unlinked immediately, so process exit releases the backing data.
