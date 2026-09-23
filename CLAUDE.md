# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Faro: an iOS app that runs MLX language models locally on-device (any Hugging
Face repo, not a closed catalog), exposes an OpenAI-compatible HTTP server so
other devices on the LAN can use the phone's model, and includes an MCP
client so the local model can call tools. Everything in Spanish (UI strings,
commit messages) — match that when writing user-facing text.

## Commands

There is no committed `.xcodeproj` — it's generated from `project.yml` via
[XcodeGen]. Regenerate it any time you add/remove/rename a source file or
change `project.yml` itself:

```sh
brew install xcodegen   # once
xcodegen generate       # after any file add/remove/rename, or project.yml edit
open Faro.xcodeproj
```

Build and test both require Xcode 26.4+ (Swift 6.3, pinned by `mlx-swift`)
and a macOS runner — there is no way to build or run this on Linux.

```sh
# Build (unsigned, matches CI)
xcodebuild build -project Faro.xcodeproj -scheme Faro -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

# Run the full test suite (Swift Testing, not XCTest — `@Test`/`#expect`)
xcodebuild test -project Faro.xcodeproj -scheme Faro \
  -destination 'platform=iOS Simulator,name=iPhone 17'

# Run a single test (swift-testing filter syntax)
xcodebuild test -project Faro.xcodeproj -scheme Faro \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:FaroTests/ThinkTagSplitterTests
```

CI (`.github/workflows/ios.yml`) runs `build` and `test` as separate jobs on
every push to `main`/`master` and on PRs; `build` additionally packages an
unsigned `.ipa` and asserts `default.metallib` made it into the bundle (a
missing Metal shader library means MLX's GPU ops would crash on a real
device — the simulator wouldn't catch that). Tag `vX.Y.Z` attaches the `.ipa`
to a GitHub release.

Real usage needs Apple Silicon (A17 Pro+/M-series) and several GB of free
RAM per loaded model — the simulator can build and run pure-logic tests but
can't meaningfully exercise MLX inference.

## Architecture

### The actor that owns every model: `InferenceEngine`

`Faro/Inference/InferenceEngine.swift` is the one place that loads models and
runs generation. It's an `actor` specifically because `ChatSession` isn't
thread-safe and three independent surfaces call into it — the in-app chat
(`ChatViewModel`), the local HTTP server (`APIServer`), and Siri/App Intents
(`AskFaroIntent`) — so this actor serializes all of them onto one queue
instead of racing multiple sessions over one GPU/KV cache.

It keeps two caches: `containers: [String: ModelContainer]` (**one** resident
model — loading a different repo id evicts the previous one, because two sets
of multi-GB weights don't fit on a phone) and `sessions: [UUID: (modelID,
ChatSession)]` (one live conversation session per `conversationID`, holding
chat history + generation params + tool config baked in at creation; a session
retains its container, so evicting a model drops its sessions too). Changing a
conversation's model, its generation settings, or its thinking-effort level
all call `invalidateSession(conversationID:)` — the session's parameters are
baked in at construction, so there's no in-place update, only rebuild-next-turn.
`ChatViewModel` also drops the session after any turn that reasoned or failed:
mlx-swift-lm 3.31.4's `ChatSession` only ever appends to its KV cache, so that
reasoning would otherwise ride along in the context for every later turn.

One more quirk shapes `InferenceEngine.session`: the system prompt is seeded
as the first *history* message, not as `instructions` (`ChatSession` re-renders
`instructions` and appends it on every turn, which would pile up the profile,
skills and project documents once per turn).

`MLXSwiftLM` is pinned past its `3.31.4` tag (`project.yml`, a `revision:`
not a `from:`) to a `main` commit: that tag can't load Gemma 4 (missing
`k_proj`/`v_proj` on its KV-shared tail layers) and its `ChatSession` hands a
tool's result back by rendering the `tool` message alone, which a template
that refuses to render without a preceding user turn (Qwen3.5) throws a Jinja
`TemplateException` on. Revert to a plain `from:` once a tag past that commit
ships.

Models load via `#huggingFaceLoadModelContainer` (a macro from
`MLXHuggingFace`), which downloads through Hugging Face's `HubClient` into
`HubCache.default` — the same on-disk, Python-`huggingface_hub`-compatible
cache (`models--<namespace>--<name>` directories) that `ModelCacheStore.swift`
reads directly to answer "what's actually on disk," and that
`ModelDownloadCoordinator` reports live progress for. Don't trust an
in-memory "is it downloaded" flag: iOS can purge `Library/Caches` under disk
pressure, so `ModelCacheStore.downloadedIDs()` (a real `FileManager` listing of
`HubCache`) is the only correct source of truth — this already
caused one real bug (a stale in-memory `ready` set that lied after relaunch).

### The Sendable boundary: `HistoryTurn`

`ChatMessage` is a SwiftData `@Model` (not `Sendable`) and MLXLMCommon's
`Chat.Message` can carry non-`Sendable` media (`CIImage`). Neither can cross
into the `InferenceEngine` actor directly. `HistoryTurn` is the plain
`Sendable` struct (role, text, raw image `Data`) that does — the actor
rebuilds real `Chat.Message`/`UserInput.Image` values from it internally
(`CIImage(data:)` runs *inside* the actor, never before). Follow this pattern
for anything else that needs to reach the actor: shrink it to `Sendable` data
at the call site, reconstitute the real type inside `InferenceEngine`.

The whole project builds under `SWIFT_STRICT_CONCURRENCY: complete` — expect
to think about actor isolation and `@Sendable` closures on almost every
change that touches `InferenceEngine`, `ModelDownloadCoordinator`, or
`MCPConnectionManager` (all actors or `@MainActor` singletons).

### Reasoning extraction: `ThinkTagSplitter`

Reasoning models stream `<think>...</think>` inline in plain text — MLXLMCommon's
`Generation` has no separate reasoning case. `ThinkTagSplitter` (used by
`ChatViewModel`, by `APIServer` so reasoning never leaves the device, and by
`AskFaroIntent` so Siri doesn't read it aloud) splits that stream chunk-by-chunk
into visible content vs. reasoning. It holds back *only* the trailing
characters that could still grow into a tag, so text reaches the screen token
by token — an earlier version buffered until a tag appeared, which meant models
that never reason aloud printed nothing until they finished.

Chat templates (Qwen3 and kin) pre-inject the opening `<think>` into the
*prompt*, so the model's own output only ever contains the closing tag. A bare
`</think>` with no prior `<think>` therefore closes an implicitly-open block —
and since that text has already been streamed out as content, the delta raises
`contentWasReasoning` and every consumer moves what it already emitted into
reasoning. Streaming immediately and correcting beats stalling the stream.

Gemma 4 marks the same span with its own channel delimiters
(`<|channel>thought` / `<channel|>`) instead of `<think>`/`</think>` —
`ThinkTagSplitter` normalizes them to the `<think>` pair as the first step of
`consume`, so every dialect after that point only has to know one.

### Replaying a turn in order: `TurnRecorder` and `TurnStep`

A turn with tool calls thinks, calls a tool, thinks again, then answers —
`ChatViewModel.startTurn` needs the bubble to show exactly that sequence, not
one reasoning blob followed by every tool card at the end. `TurnRecorder`
(`Faro/Inference/TurnRecorder.swift`) is the one place that owns the turn's
`ThinkTagSplitter` and writes both `ChatMessage.content`/`.reasoning` and its
ordered `steps: [TurnStep]` — a `.reasoning(start:end:)` range into
`.reasoning`, or a `.tool(ToolCallRecord)`, each carrying a `contentOffset`
(how much of `.content` existed when it started) that says where it slots
back in. A step only records where it sits, never a copy of the text, so
`stepsRaw` only changes at block boundaries, not per token; `TurnStep.timeline`
is the pure function (`MessageView` and the tests both call it) that
interleaves `content`/`reasoning`/`steps` back into display order.

The tool-call listener in `startTurn` calls `recorder.toolStarted`/
`.toolFinished` directly instead of mutating `ChatMessage` itself, because it
has to close whatever reasoning step is open *before* the call — Qwen3 calls a
tool right after `</think>` with no content in between, so the generation
loop's own `consume()` would never see a boundary there. `toolStarted` also
calls `splitter.commitContent()`, which draws that same boundary inside the
splitter, so text written just before the call (e.g. "Voy a buscar…") isn't
later reclaimed as the *next* implicitly-reopened block's leaked reasoning.
`recorder.finish()` is the safety net for a cancellation that lands between a
call starting and its own `.finished` event arriving — it fails any step still
`.running` instead of leaving its card spinning forever.

A message saved before any of this existed (`reasoning`/`reasoningSeconds`
from `master`, no `stepsRaw`) has no on-disk data to migrate — `ChatMessage.steps`
synthesizes one reasoning step covering all of it on read, so an old
conversation renders exactly as it always did.

### The second backend: Apple Foundation

`AppleFoundationEngine` (`Faro/Inference/`) wraps Apple's on-device model
behind the same signature as the MLX path — same `HistoryTurn` input, same
`AsyncThrowingStream<Generation, Error>` out — so `streamResponse` only picks
a branch, on the reserved id `AppleFoundationModel.id` (`"apple/foundation"`,
a plain `String` in `Conversation.modelID`, so no schema change). That id is
not a Hugging Face repo: `ModelDownloadCoordinator`, the load band and the
preflight all have to skip it.

**Every reference to `FoundationModels` lives in that one file**, and it is
`@MainActor` rather than an actor on purpose: `SystemLanguageModel` and
`LanguageModelSession` are the observable types Apple's samples drive from a
view model, so pinning them to one known isolation beats guessing at their
`Sendable` conformance under strict concurrency. It answers with a single
`.chunk` — `streamResponse` there emits cumulative snapshots rather than
deltas and the snapshot type for a `String` answer moves between SDK
revisions, so `respond(to:)` is the stable surface (there's a `ponytail:`
note with the upgrade path).

### Data model and settings

`Conversation` and `ChatMessage` are the two SwiftData models
(`Faro/Models/`). A `Conversation` owns its model id, system prompt, thinking
effort, and either the recommended `GenerationSettings` or a full set of
custom overrides (`useCustomGeneration` gates `effectiveGenerationSettings`).
`ChatMessage.imageData` uses `@Attribute(.externalStorage)` to keep attached
images out of the main SwiftData store.

App-wide preferences are `enum`s over `UserDefaults`, never SwiftData:
`AppSettings` (`defaultSystemPrompt`, `lastModelID`), `VoiceSettings`
(recognition locale + synthesis voice id) and `ServerSettings`. `lastModelID`
is written in exactly one place — `ChatViewModel.changeModel(to:)`, which
every model pick funnels through — and read by `DefaultModel.resolve`, which
falls back to the curated default when the remembered model is no longer on
disk. An existing conversation always keeps its own `modelID`; only *new*
ones start from the remembered one.

Secrets never go in either: the local server's bearer token and each MCP
server's token live in the Keychain (`Faro/Settings/Keychain.swift`,
`ThisDeviceOnly`, so they stay out of backups). "Restablecer Faro"
(`AppReset`) wipes SwiftData, those `UserDefaults` keys and the Keychain,
so anything new that persists state has to be added there too.

Settings are one screen (`Faro/Settings/SettingsView.swift`): models, voice,
the local server and MCP are presented from it as sheets, unmodified, because
each already brings its own `NavigationStack` and close button.

### The three callers of `InferenceEngine.streamResponse`

- `ChatViewModel` (`Faro/Inference/`) — the in-app chat loop. Builds the
  `HistoryTurn` array from `Conversation.messages`, passes the thinking-effort
  level to the chat template as `enable_thinking`, and owns the download/load status
  band shown while a model is fetched or paged in.
- `APIServer` (`Faro/Server/`) — an OpenAI-compatible `/v1/chat/completions`
  + `/v1/models` server over `FlyingFox`, bearer-token gated, LAN-discoverable
  via Bonjour. Text-only by design (`ponytail` note in the file explains
  vision-over-HTTP is deliberately deferred). One `InferenceEngine` session
  per HTTP request (`requestID` as the conversation id), invalidated when the
  request completes.
- `AskFaroIntent` (`Faro/Intents/`) — the Siri/App Intents entry point.
  `openAppWhenRun` is `true` on purpose: MLX generation on anything but a
  tiny model can outlast the background execution window App Intents get.

### MCP tool calling

`MCPConnectionManager` (actor) owns connections to configured MCP servers and
exposes `enabledToolSpecs()` / `dispatch(_:)`, which `InferenceEngine.session`
wires straight into `ChatSession(tools:toolDispatch:)`. `MCPToolBridge` is
the pure translation layer between MCP's JSON mirror type (`MCP.Value`) and
MLXLMCommon's (`JSONValue`/`ToolSpec`) — round-trips arguments through actual
JSON encoding rather than a hand-written case-by-case converter. Tool-call
routing is fail-closed by MLXLMCommon's own design: only tool names present
in the schemas handed to `ChatSession(tools:)` ever reach `dispatch`.

The `toolDispatch` closure built in `InferenceEngine.session` reports a
`ToolCallEvent.started` carrying a full `ToolCallRecord` — name, which server
owns it (`MCPConnectionManager.serverName(forTool:)`), and its arguments
pretty-printed — before calling `MCPConnectionManager.dispatch`/running a
skill, so the chat bubble can show what was actually asked, not just that a
call happened. `.finished` carries the result (a few KB, not a stub) or the
error. Both cross the actor boundary as `Sendable` events on
`toolCallEvents(conversationID:)`, consumed by `TurnRecorder` in
`ChatViewModel.startTurn` — see "Replaying a turn in order" above.

### Everything else

`Faro/Chat/` is the SwiftUI chat surface (composer, message bubbles,
markdown rendering); `Faro/Hub/` is model discovery/download/deletion
(`ModelBrowserView`, `ModelDownloadCoordinator`, `ModelCacheStore`,
`ModelPreflight` — which sanity-checks a Hugging Face repo actually looks
like an MLX model and fits recommended device memory before downloading);
`Faro/Voice/` is the hands-free conversation mode; `Faro/Files/` extracts
text from PDF/plain-text attachments for the prompt.

`Faro/Voice/` deliberately stays on `SFSpeechRecognizer` (on-device via
`requiresOnDeviceRecognition`, but only where
`supportsOnDeviceRecognition` says the assets exist) rather than iOS 26's
`SpeechAnalyzer` — see the note at the top of `VoiceSession.swift`. Two
traps live there: anything handed to `AVSpeechSynthesis*` must be BCP-47
(`Locale.identifier(.bcp47)`, not `Locale.identifier`, which is ICU and gets
rejected), and the recognition-task error branch has to check the session is
still `.listening`, because `stopListening()` cancels the task and that
cancellation surfaces as an error *after* the state has already moved on.
