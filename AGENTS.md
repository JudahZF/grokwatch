# Agent notes

Grokwatch is an unofficial watch-only SwiftUI client for Grok Bot that talks straight to the service's internal API.

## Layout

- `watch/GrokWatch/{API,Model,Views}`: the app (network client, state, screens)
- `watch/Shared`: code compiled into both the app and the widget
- `watch/Widgets`: the complication
- `watch/Tests`: unit tests (Swift Testing)
- `proto/`: the service's protobuf schema; `docs/`: protocol notes

## Commands (repo root)

```sh
xcodebuild -project watch/GrokWatch.xcodeproj -scheme GrokWatch -destination 'generic/platform=watchOS Simulator' -derivedDataPath /tmp/grokwatch-dd CODE_SIGNING_ALLOWED=NO build
SIM=$(xcrun simctl list devices available | grep -i 'Apple Watch' | head -1 | grep -oE '[0-9A-F-]{36}')
xcodebuild test -project watch/GrokWatch.xcodeproj -scheme GrokWatch -destination "platform=watchOS Simulator,id=$SIM" -derivedDataPath /tmp/grokwatch-dd
```

## Rules

- `watch/project.yml` is the source. The `.xcodeproj`, entitlements and `Info.plist` files are generated: run `cd watch && xcodegen generate`, never edit them by hand. A new Swift file also needs a regenerate.
- Do not edit `watch/GrokWatch/Generated/`. Regenerate it from `proto/` (see `watch/README.md`).
- Never commit `watch/Local.xcconfig`. It holds the signing identity.
- Seeded debug tokens sign out the client they came from, because refresh tokens rotate.
- Call audio hangs in the simulator. Test real audio on a watch.
- To look at the UI without an account, launch a Debug build with `SIMCTL_CHILD_GROKWATCH_DEMO=1` (sample data in `watch/GrokWatch/Demo.swift`, no network).
- Tests must never reach the network. Pass an `HTTPLoader` closure to `Auth` and `ConnectClient`; `URLProtocol` stubs do not run on watchOS, so a stubbed `URLSession` sends real requests.
- The service API is internal and undocumented. Keep the protocol notes in `docs/` in step with the code.
