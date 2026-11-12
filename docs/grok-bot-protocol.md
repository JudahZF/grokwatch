# Grok Bot client protocol (unofficial)

These are notes on the Grok Bot client API, as observed from the official desktop app. The wire format and the RPCs come from version 0.78.1. The avatar shapes and the entry author rules come from version 0.79.3. The watch sends client version 0.78.1 (`ConnectClient.clientVersion`).
Items marked **unverified** still need a live test.

This is an internal API with no contract. Any app update can change it.

## Live test results (2026-10-30, a command-line probe, not in this repo)

| Check | Result |
|---|---|
| Deep login + `/auth/poll` | Works. 404 means "still waiting"; 200 returns `{accessToken, refreshToken}`. |
| Non-desktop client with the headers below and a random sha256-hex `machineId` | Accepted |
| `ListGrokBotAgents` | Works. `viewer_session_id` is empty for your own Bots. Send `session_id: ""`. |
| Agent ID | Both `agent_id` (UUID) and `id` (numeric) work. Use `agent_id`. |
| Transcript `body` on the wire | Plain UTF-8 JSON, the same as the local cache |
| `SendGrokBotUserMessage` | `dispatched: true`, delivery `ACCEPTED_TEMPORAL`, mode `LIVE`. `GetGrokBotSendStatus` returns `PENDING` right after the send. |
| `WatchGrokBotTranscripts` | Frames arrive in order: `connected`, `agent_state` (thinking → tool → composing), echo of your `message` row, then the Bot's `send-message`. Trivial prompt: reply at **+4.8 s**. |
| `AiService.TextToSpeech` with the Bot's `voice_id` | `audio/mpeg`, ~31 KB for one sentence, 682 ms to synthesize |
| Card replies, reactions, attachments | `ResolveGrokBotAttachmentReads` verified (signed S3 URL for both `file://` URLs and box paths). Card actions use the desktop app's request shapes but are not yet sent live. |
| Voice call setup | Verified (2026-10-31, the command-line probe and the watch simulator): empty `MintSandVoiceCallSecret` → `grok-voice-3.0` at `wss://api.x.ai/v1/realtime`; `VoiceCallHarnessSession` → tools `send_task`, `search_conversations`, `end_the_call`; the greeting plays. Mic audio, tool calls, and call records are not tested yet. |
| Token refresh | The watch app implements refresh in `watch/GrokWatch/API/Auth.swift`. No separate live test is recorded. |

## Transport

- Base URL: `https://api2.cursor.sh`
- Protocol: [Connect](https://connectrpc.com/docs/protocol) with **binary protobuf** (`useBinaryFormat: true`).
  - Unary: `POST /aiserver.v1.GrokBotService/<Method>`, `content-type: application/proto`, `connect-protocol-version: 1`.
  - Server streaming: the same path with `content-type: application/connect+proto` and enveloped frames.
- Schemas: [`proto/grokbot.proto`](../proto/grokbot.proto) is derived from the desktop app's schemas. Field numbers and types are exact. Enum values get a standard `UPPER_SNAKE` prefix so that codegen strips it. The server's original value names are unknown, but the binary format does not use them.

## Request headers

| Header | Value |
|---|---|
| `authorization` | `Bearer <accessToken>` |
| `x-cursor-client-type` | `sand` |
| `x-cursor-client-version` | app version, e.g. `0.78.1` |
| `x-cursor-client-os` | `CLIENT_OS_MACOS` / `_WINDOWS` / `_LINUX` (no iOS value seen) |
| `x-sand-box-namespace` | `prod` |
| `x-ghost-mode` | `"true"` unless the account allows training |
| `x-cursor-checksum` | `base64url(obfuscate(6-byte BE floor(nowMs / 1e6))) + machineId` |
| `x-request-id` | random UUID |
| `x-cursor-team-id` | only when acting in a team |

The obfuscation step is implemented in `ConnectClient.checksum` in [`watch/GrokWatch/API/Connect.swift`](../watch/GrokWatch/API/Connect.swift), byte for byte as the desktop app does it.

A stable random sha256-hex `machineId` for each device is accepted. This is verified.

Device attestation (`ClaimSandTrialWithDeviceAttestation`, `x-sand-devicecheck-supported`) is used only to claim a trial. Normal RPCs do not need it.

## Auth (Cursor account, PKCE "deep login")

1. `verifier = base64url(32 random bytes)`, `challenge = base64url(sha256(verifier))`, `uuid = randomUUID()`.
2. Open `https://cursor.com/loginDeepControl?challenge=<c>&uuid=<u>&mode=login&redirectTarget=<target>` in a browser. The desktop default target is `cli`.
3. Poll `GET https://api2.cursor.sh/auth/poll?uuid=<u>&verifier=<v>` until it returns 200 with `{accessToken, refreshToken}`. The desktop app polls up to 150 times with backoff.
4. Refresh: `POST https://api2.cursor.sh/oauth/token` with body `{client_id, grant_type: "refresh_token", refresh_token}`. The watch app implements this with the prod client id in `Auth.clientID` ([`watch/GrokWatch/API/Auth.swift`](../watch/GrokWatch/API/Auth.swift)). No separate live test of refresh is recorded.
   **Refresh tokens rotate.** Each client must log in on its own. Never copy the desktop app's tokens, because the desktop will be signed out the next time either client refreshes.

There is also `POST /auth/exchange_user_api_key` (`Bearer <user API key>`), which returns `{accessToken, refreshToken}`.

On the watch, show the login URL as a QR code, scan it with the phone, and poll from the watch.

## Bot list (sidebar)

| Data | RPC |
|---|---|
| Hidden, unread, last activity, running | `ListGrokBotAgentStatuses {agent_ids}` → `client.hidden_from_sidebar`, `client.unread_count` + `unread_thread_count`, `client.last_activity_at_ms`, `is_running` |
| Pinned Bots, custom sections, main Bot | `GetGrokBotUserRuntimeSettings` → `pinned_agents.agent_ids`, `sidebar_sections.sections[{id, name, agent_ids}]`, `main_agent_id` (synced per account) |
| Mark read / unread, hide, mute | `SetGrokBotAgentClientState {agent_id, mark_read \| mark_unread \| hidden_from_sidebar \| notifications_enabled}` |
| Pin / unpin | `UpdateGrokBotUserRuntimeSettings {pinned_agents: {agent_ids}}` (send the whole new list) |
| Row preview | `client.last_entry_preview` (oneof: text, agent message, attachments, link, widget prompt / answer / options), else `client.last_message_preview` |
| Avatar | `avatar_url` when the Bot has its own picture, else `avatar_shape` (`blob`, `clover`, `wedge`, …) and `avatar_color` (`black`, `brown`, `red`, `orange`, `yellow`, `green`, `cyan`, `blue`, `violet`, `magenta`, `gray`). Both are empty for some Bots. The outlines in [`watch/GrokWatch/Views/BotShapes.swift`](../watch/GrokWatch/Views/BotShapes.swift) follow the desktop app's shapes. |
| Waits for you | `live.awaiting` on the status, or a `widget_prompt` / `widget_options` preview. The list does not carry the card, so the watch reads the newest transcript entries of each candidate (`AppSession.loadWaiting`). The desktop's own rule for its orange dot is not mapped. |

Desktop rules, mirrored in [`watch/GrokWatch/Model/Roster.swift`](../watch/GrokWatch/Model/Roster.swift):
- Bots you own with `hidden_from_sidebar` go to a separate hidden list. Shared Bots that are hidden are dropped, unless they are the team default.
- Order: pinned Bots in pin order, then sections in their saved order. The section with id `__agents__` holds every Bot that is not in another section. Inside each group, Bots are sorted by `max(agent.updated_at_ms, client.last_activity_at_ms)`, newest first.
- A Bot is unread when `unread_count > 0` or `unread_thread_count > 0`.

## Chat

| Step | RPC | Notes |
|---|---|---|
| List Bots | `ListGrokBotAgents` | `GrokBotAgent.id`, `name`, `avatar_url`, `voice_id`, `voice_speed`, `viewer_session_id` |
| Load history | `ListGrokBotTranscriptEntries` | `agent_id`, `session_id` (= `viewer_session_id`), `limit`, `before_seq` for paging |
| Send | `SendGrokBotUserMessage` | `agent_id`, client `message_id` (UUID, idempotent: `DUPLICATE` delivery), `text`, `sent_at_ms`, `session_id`, `source = MOBILE`, `initiator = USER`, `send_source = CHAT` |
| Confirm | `GetGrokBotSendStatus` | `ACCEPTED` / `PENDING` / `REJECTED` / … |
| Live updates | `WatchGrokBotTranscripts` (server stream) | cursors per Bot (`after_updated_seq`). Frames: `rows`, `agent_state` (running/composing), `turn_failed`, `heartbeat` |
| Stop | `InterruptGrokBotAgentRun` | `reason: "user_interrupt"` |
| Older history | `ListGrokBotTranscriptEntries` | `before_seq` = the oldest loaded `seq` |
| React | `ReactToGrokBotMessage` | `entry_id`, `emoji` |
| Attachments | `ResolveGrokBotAttachmentReads` | `paths` = `message.url` (bot `attachment`) or `file_path` (`user-attachment`) → `url`, `size_bytes`, `content_type` |

Transcript entries are `{seq, entry_kind, body bytes}`. Decoded entries (from the local cache) are JSON:

- `message`: `{role: "user" | …, content, isStreaming, clientNonce, …}`. These are your messages.
- `send-message`: `{message: {content, type}}`. **These are the Bot's replies to you.**
- Also `tool-call`, `notice` (`text`), `event`, `voice-call`, `user-attachment`, `feedback`, `mcp-app`.

On the wire, `body` is plain UTF-8 JSON. This is verified.

## Chat cards

A `send-message` body has `message.type`. Card state lives next to `message` in the same body. `entry_id` in every card RPC is the transcript entry id, which equals the body's `id`. Request shapes follow the desktop app.

| `message.type` | Open when | Answer with |
|---|---|---|
| `text` | | `message.content` (markdown) |
| `widget` (question) | no `respondedValue` and no `widgetSkipped` | `RespondGrokBotWidget {entry_id, value}` where `value` is the option's `value`; skip with `DismissGrokBotWidget` |
| `auto-review-approval` | `message.approval.status == "pending"` | `ResolveGrokBotAutoReviewApproval {request_id: approval.requestId, resolution: APPROVED \| DENIED \| ALWAYS, approval_platform}`. The desktop sends `"desktop"`; the watch sends `"ios"` (`watch/GrokWatch/API/GrokBotAPI+Actions.swift:71`). `ALWAYS` is "Always allow": it also saves an Allow rule. The watch has not sent `ALWAYS` live. |
| `email-draft`, `slack-draft` | `draftSendState ?? draftSaveState ?? "editable"` is `"editable"` | `SendGrokBotDraft {entry_id, email \| slack}` (copy `message.draft`), or `DiscardGrokBotDraft` |
| `user-form` | no `formResolution` | `SubmitGrokBotUserForm {entry_id, values: {field id: text}, platform}`, or `DismissGrokBotUserForm {mode: DISMISSED}` |
| `attachment` | | `url`, `file_name`, `alt`; `width`/`height` for images |
| `credential-request`, `secret-request`, `connector`, `imessage-draft` | | Need the phone or desktop (1Password, secrets, OAuth, a Mac) |

Who wrote an entry (as the desktop app decides it): in a chat you own, your `message` entries have no `author`, `fromUser` or `channelSender`. An entry with one of these comes from another person (`author: {kind, id, name}`). This account has no group or shared chat, so the watch's sender names are **unverified**.

Other entry kinds the chat shows: `user-attachment` (your photos and files), `notice` (`text`), and `event` with `event.type == "automation-changed"`. Reactions are `reactions: [{emoji, by}]` on any body.

## Voice

**TTS:** `AiService.TextToSpeech {text, voice_id, speed}` returns `{audio bytes, mime_type}`. Use the Bot's own `voice_id` and `voice_speed`.
**STT:** `AiService.TranscribeAudio` (unary), or the bidi `StreamStt`. Unary is simpler on the watch, and watchOS system dictation is also an option.

**Live voice call** (the sequence the desktop app uses):

1. `MintSandVoiceCallSecret {}` (the desktop sends an empty request) → `{client_secret, model, websocket_url}`. Verified: `grok-voice-3.0`, `wss://api.x.ai/v1/realtime`.
2. `VoiceCallHarnessSession {agent_id, agent_name, has_speed_setting}` → `{instructions, tools[], greeting {direction, with_landed_work}, receipt {output, instructions}}`.
3. Open `websocket_url?model=<model>` with the WebSocket subprotocol `xai-client-secret.<client_secret>`.
4. Send `session.update`: `voice` (the Bot's `voice_id`), `instructions`, `turn_detection: {type: "server_vad"}`, `audio.input.format` and `audio.output.format` = `{type: "audio/pcm", rate: 24000}` (mono PCM16), `audio.input.transcription.model: "grok-transcribe"`, `audio.output.speed`, and `tools` (the descriptors as JSON).
5. After `session.updated`, greet: `response.create {response: {instructions: greeting.direction}}`.
6. Mic audio: `input_audio_buffer.append {audio: base64 PCM16}`. Speech: `response.output_audio.delta`; captions: `response.output_audio_transcript.delta` and `conversation.item.input_audio_transcription.completed`.
7. Tools (`response.function_call_arguments.done {call_id, name, arguments}`):
   - `send_task {request}`: answer at once with `conversation.item.create {type: function_call_output, output: receipt.output}` and `response.create {instructions: receipt.instructions}`, then relay with `VoiceCallHarnessTool {agent_id, call_id: <voice call id>, name: "send_task", input: {request}}` → `{relay, spoken}`.
   - `end_the_call`: call the harness tool, let the speech finish, then hang up.
   - Others (`search_conversations`): `VoiceCallHarnessTool`, return its `output` as the `function_call_output`, then `response.create`.
8. The Bot's news reaches the call as a seeded tool pair: `function_call {name: "work_landed", call_id, arguments: "{}"}` then `function_call_output {output: {status: "landed", updates: [text], at}}`, then `response.create`. The watch sends one for each new Bot `send-message` during the call.
9. When the call ends, `RecordGrokBotVoiceCall {agent_id, record}`. The record is `{callId, agentId, realtimeConversationId, startedAtMs, endedAtMs, durationMs, ending: "hung-up" | "disconnected" | "failed", turns: [{id, speaker, text, atMs}], nudges, events, toolCalls, overheard, harnessMayCollect}`, the same shape the desktop app records. Whether the server accepts the watch's record is **unverified**.

The voice model is a front end. The tools it receives connect it to the real Bot, so the watch needs no relay.

On watchOS, a WebSocket is allowed only during audio streaming or a CallKit VoIP call. The watch reports the call with CallKit (`UIBackgroundModes: voip`).
