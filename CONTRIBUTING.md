# Contributing

Dial stays small on purpose: brightness, volume, resolution and touch for external displays. Changes that keep it that way are very welcome.

## Develop

```bash
swift build                    # debug build
.build/debug/Dial --probe      # what Dial sees on your machine
./scripts/build-app.sh         # build/Dial.app
```

Only the Xcode Command Line Tools are required. SwiftUI's `@State` macro is not available without full Xcode, so app state lives in `@Observable` classes held by plain `let`s.

Rebuilt apps are ad-hoc signed, so macOS treats each build as a new app: switch Dial off and on again in Accessibility after rebuilding.

## Pull requests

- One focused change per PR; CI must pass.
- Say which Mac, macOS version, monitor and cable you tested on — DDC behaviour varies a lot between monitors.
- Update `docs/panel-*.png` with `.build/debug/Dial --snapshot docs/panel.png` if the panel changes.
