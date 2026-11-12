# GrokWatch (watchOS app)

A watch-only SwiftUI client for Grok Bot. It talks straight to the app's internal API (`../docs/grok-bot-protocol.md`), with no relay.

- **Login:** the watch shows a QR code. Scan it with your phone and sign in to Cursor; the watch gets its own tokens (Keychain).
- **Look:** follows the official apps. Each Bot has its own shape and colour; your bubbles are white, or the Bot's colour (Settings → My bubbles).
- **Bots:** "Waiting for you" is first: each Bot with an open question or approval, with its answers on the card. Then the pinned Bots as a row of large avatars, and the other Bots as on the phone (sections, recent first), with previews, times, unread counts, and a spinner while a Bot works. Swipe right to pin or mark read/unread; swipe left to hide or mute. Long-press a pinned Bot for the same actions. Changes sync to your account.
- **Chat:** recent history plus a live stream, "Earlier messages" to page back, photos, reactions (long-press a message), and what the Bot is doing now. The composer stays at the bottom: tap the field to dictate, scribble, or type, or tap + for a quick reply. A message that fails to send stays in the chat; tap it to send it again. The top-right button stops a running Bot, or starts a call.
- **Cards:** answer questions, allow an action once or always or deny it, send or discard email and Slack drafts, and fill in forms. Sign-in, secret, and connector requests say to use the phone.
- **Settings** (gear, top left): bubble colour, "Read replies aloud", hidden Bots, and sign out.
- **Voice:** tap a Bot reply to hear it in that Bot's voice, or turn on "Read replies aloud" in Settings. The phone button starts a live voice call (CallKit); the Bot works on what you ask and tells you when it is done.
- **Complication:** unread count on the watch face; tap it to open the Bot with unread messages. Background refresh keeps it current.

## Build and run

```sh
xcodegen                     # after editing project.yml
open GrokWatch.xcodeproj     # pick your watch as the run destination, then Run
```

Proto changes: regenerate `GrokWatch/Generated/` with
`protoc -I ../proto --swift_out=GrokWatch/Generated --swift_opt=Visibility=Internal grokbot.proto`
(the `protoc-gen-swift` version must match the `SwiftProtobuf` package version in `project.yml`).

## Simulator testing (Debug builds only)

```sh
SIMCTL_CHILD_GROKWATCH_SEED_TOKENS='{"accessToken":"…","refreshToken":"…"}' \
SIMCTL_CHILD_GROKWATCH_OPEN_BOT=penelope \
xcrun simctl launch <sim-id> com.example.grokwatch
```

`SEED_TOKENS` skips the QR login. `OPEN_BOT` opens the first Bot (hidden ones too) whose name starts with that text. Seeded tokens rotate on the next refresh, so whatever client they came from has to log in again.

Add `SIMCTL_CHILD_GROKWATCH_CALL=1` to start a voice call on open, and `SIMCTL_CHILD_GROKWATCH_SILENT_CALL=1` to run it with no audio engine. The simulator's call audio hangs CoreAudio, so test real audio on a watch.

## Signing

The complication needs an App Group (`group.com.example.grokwatch`) on both targets and a profile for `com.example.grokwatch.widgets`. Xcode creates them when it is signed in to your Apple ID (Settings → Accounts) and builds with `-allowProvisioningUpdates`.
