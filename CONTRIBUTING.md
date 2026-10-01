# Contributing

Dial stays small on purpose: brightness, volume, resolution and touch for external displays. Changes that keep it that way are very welcome.

## Develop

```bash
swift build                    # debug build
.build/debug/Dial --probe      # what Dial sees on your machine
./scripts/build-app.sh --install   # build and install to /Applications
```

Only the Xcode Command Line Tools are required. SwiftUI's `@State` macro is not available without full Xcode, so app state lives in `@Observable` classes held by plain `let`s.

Without a certificate, rebuilt apps are signed ad hoc and macOS treats each build as a new app, so Dial's Accessibility switch has to be turned on again after every rebuild. To avoid that, make a self-signed code-signing certificate named **Dial Developer** in your login keychain (Keychain Access → Certificate Assistant → Create a Certificate…, type *Code Signing*). `build-app.sh` uses it automatically, and the permission then survives rebuilds.

## Pull requests

- One focused change per PR; CI must pass.
- Say which Mac, macOS version, monitor and cable you tested on — DDC behaviour varies a lot between monitors.
- Update `docs/panel-*.png` with `.build/debug/Dial --snapshot docs/panel.png` if the panel changes.
