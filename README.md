# DeepSeek Harness for iOS

[![iOS Build](https://github.com/hicongcn/dsh-ios/actions/workflows/ios.yml/badge.svg)](https://github.com/hicongcn/dsh-ios/actions/workflows/ios.yml)

A native iOS client for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness).

It speaks the **same wire protocol as the official browser UI** — the `/api` RPC
channel and the `/api/remote.mux` WebSocket mux — so it is not a reimplementation
with its own state. A session you start on the phone is the same durable session
the desktop client sees, and vice versa.

```
┌─────────────────────┐        POST /api/<endpoint>        ┌──────────────────────┐
│  iPhone / iPad      │  ───────────────────────────────▶  │                      │
│  DeepSeek Harness   │        {type:client-request,...}   │   dsh web host       │
│                     │  ◀───────────────────────────────  │   (your computer)    │
│  DSHKit + SwiftUI   │        WSS /api/remote.mux         │                      │
└─────────────────────┘   {type:item|end|error,streamId}   └──────────────────────┘
```

## What works

- **Connect** by pasting the URL that `dsh web` prints. Its `?token=` is exchanged
  for the signed `dsh-auth-…` cookie exactly as the browser does, then stored in
  the Keychain so later launches reconnect without a token.
- **Sessions**: list, create (with a working directory), rename, fork, and read
  backwards history pages.
- **Live conversation**: the opening snapshot, then durable events streamed as
  they happen, including process-local assistant chunks so text appears while it
  is still being generated.
- **Queue and jobs**: the `session/control` stream drives the pending-prompt count
  and background-job rows.
- **Models and skills**: the routable catalog is read from the Host and selection
  is written back per session.

## Requirements

| Piece | Needs |
| --- | --- |
| `DSHKit` protocol layer + self-test | macOS 13+ with command line tools (no Xcode) |
| SwiftUI app + `.ipa` | Xcode, iOS 17+ deployment target, `xcodegen` |

The split is deliberate: the protocol layer has no iOS-only dependency, so it is
verifiable on any Mac, and only the UI shell requires Xcode.

## Quick start

```bash
# 1. On your computer, start a Harness host and copy the printed URL.
dsh web

# 2. Verify the protocol layer (offline + live against that host).
./scripts/build.sh --live "http://127.0.0.1:3080/?token=…"

# 3. Generate the Xcode project and run the app.
brew install xcodegen
xcodegen generate
open DeepSeekHarness.xcodeproj
```

Then paste the URL from step 1 into the connect screen.

### Simulator vs device

The simulator shares the Mac's loopback, so `http://127.0.0.1:3080` works
directly. A physical device needs the Host's LAN address instead:

```bash
dsh web --host 0.0.0.0 --trusted-host 192.168.1.20:3080
```

Use the **LAN** URL it prints. The `/api` fence refuses any authority that is
neither loopback nor declared as trusted, so an undeclared LAN address is rejected
with `403` — that is the fence working, not a client bug.

Cleartext HTTP is permitted only for `localhost`, `127.0.0.1`, and local
networking (see `NSAppTransportSecurity` in `project.yml`). Reaching a Host
through a public hostname requires TLS or an added exception.

## Architecture

```
Sources/DSHKit/
  Wire/
    DSHJSON.swift            lossless JSON value (no non-finite numbers, no -0)
    DSHWireEnvelope.swift    client-request / server-response + mux frames
    DSHModels.swift          typed session, catalog, timeline, control models
    DSHTimeline.swift        folds events + chunks into displayable rows
  Transport/
    DSHHostConfiguration.swift  parses the dsh web URL, derives /api and ws routes
    DSHAuthBootstrap.swift      token exchange, Keychain and in-memory stores
    DSHRPCClient.swift          one POST per endpoint, rpcId-verified
    DSHStreamMux.swift          one socket, many concurrent logical streams
  API/
    DSHClient.swift             the session facade the app calls

Apps/DeepSeekHarness/Sources/
  App/DeepSeekHarnessApp.swift
  Model/AppState.swift          @Observable, @MainActor connection + timeline state
  Views/ConnectView.swift       paste-URL entry
  Views/MainView.swift          session list
  Views/ConversationView.swift  transcript, prompt bar, model picker
```

## Protocol notes

Details that a reimplementation must get right, all verified against a live host:

- **Envelope.** `POST /api/<endpoint>` with
  `{"type":"client-request","rpcId":…,"method":…,"payload":{"args":{…}}}`. The
  response is `{"type":"server-response","rpcId":…,"result":{"ok":true,"value":…}}`
  or `{"ok":false,"error":{"code","message","details"}}`. The `rpcId` is minted by
  the caller and **must** be verified; the client rejects a mismatch rather than
  delivering the wrong value.
- **Arguments.** Every method takes exactly one `request` field (some take
  `_request`). This is confirmed by the generated descriptors in
  `@deepseek-ai/dsh-api-session-controller/typert.host.js`.
- **Streams.** One WebSocket carries all logical streams. Open with
  `{"type":"open","streamId","endpoint","payload":{"args":…}}`; the Host replies
  `{"type":"item","streamId","value"}`, then `end` or `error`. Keys must match
  exactly — extra or missing keys make the Host reject the frame.
- **Auth.** `GET /?token=…` returns `303` with `Set-Cookie: dsh-auth-<sha256(authority)>=v1.<payload>.<hmac>`.
  The cookie is bound to the request authority, so it is stored per `host:port`.
  A restarted Host rotates its signing secret, which invalidates old cookies —
  `DSHClient` therefore retries once with a fresh token exchange on `401`.
- **Origin.** A missing `Origin` header passes the fence, which is what lets a
  native client connect at all. `Host` must be loopback or declared trusted.
- **Heartbeats.** The Host pings; two missed pongs drop the socket. The client
  surfaces that as a stream failure so the caller can re-follow.

### Behavior inherited from the Host

A cancelled or dropped follow stream is not an error: the next `session/follow`
re-opens with a fresh snapshot, which is how reconnect resyncs. `DSHTimeline`
applies snapshots by replacing its opening window, so re-following is safe.

Session deletion is **not** exposed by the protocol (only workspace archiving), so
the app offers no delete action rather than implying one.

## Building the IPA without a local Xcode

If Xcode is not installed locally, GitHub Actions builds the app for you — the
macOS runner has Xcode preinstalled. Two workflows are provided:

| Workflow | Needs secrets | Produces |
| --- | --- | --- |
| `.github/workflows/ios.yml` | none | unsigned `.ipa`, device `.app`, simulator `.app` |
| `.github/workflows/ios-signed.yml` | signing identity | signed, device-installable `.ipa` |

The unsigned workflow runs on every push. Download the artifact from the run
summary, or with the CLI:

```bash
gh run list --repo <owner>/dsh-ios
gh run watch --repo <owner>/dsh-ios
gh run download --repo <owner>/dsh-ios -n DeepSeekHarness-unsigned-ipa
```

### What an unsigned IPA can and cannot do

An unsigned `.ipa` is a real arm64 build — it is the same binary a signed build
produces, just without a signature. That has concrete consequences:

- **Cannot** be installed on a physical device by iTunes, Apple Configurator, or
  `ideviceinstaller`. iOS refuses to run an unsigned binary, and there is no
  supported way around that on a stock device.
- **Can** be inspected, diffed, and re-signed later with `codesign` if you obtain
  an identity.
- **Can** be installed on a jailbroken device, which is the one case where an
  unsigned bundle is directly runnable.

For anything you actually want to use on your iPhone, either sign it (below) or
use the simulator build, which runs on any Mac with Xcode:

```bash
xcrun simctl install booted <path>/DeepSeekHarness.app
xcrun simctl launch booted ai.deepseek.harness.ios
```

### Signing

A Development or Ad Hoc profile requires a paid Apple Developer account; a free
Apple ID cannot create one. Once you have it, add four repository secrets and run
the signed workflow:

| Secret | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | `base64 -i Certificates.p12` |
| `P12_PASSWORD` | the `.p12` export password |
| `BUILD_PROVISION_PROFILE_BASE64` | `base64 -i profile.mobileprovision` |
| `KEYCHAIN_PASSWORD` | any throwaway string for the temporary keychain |

Then either push a `v*` tag or trigger it manually:

```bash
gh workflow run ios-signed.yml --repo <owner>/dsh-ios
```

The signing certificate, profile, and keychain are all removed from the runner at
the end of the job; nothing is persisted.

### Pushing a workflow file

GitHub refuses to accept a workflow file from an OAuth token that lacks the
`workflow` scope. If the push is rejected with that message, grant it once:

```bash
gh auth refresh -h github.com -s workflow
```

## Verification

`./scripts/build.sh` runs the check suite; `--live URL` adds real-host integration.

```bash
swift run dshkit-selftest                    # offline checks
DSH_LIVE_URL="http://…/?token=…" swift run dshkit-selftest   # + live checks
```

The live checks exercise the real carriers end to end: token exchange,
`session/list`, `session/create`, the WebSocket snapshot, history paging,
`session/control`, a real `session/prompt`, and subsequent live events — plus a
socket-drop reconnect and two streams multiplexed concurrently.

CI additionally does what a local run cannot: it compiles the SwiftUI layer with a
real Xcode, then **boots a simulator, installs the app, launches it and confirms
the process stays alive**, capturing a screenshot as evidence. Compiling is not
running, and only CI can prove the latter without Xcode locally.

Two bugs were found and fixed by these checks rather than by inspection:

- `JSONSerialization` bridges `NSNumber` such that `1 as? Bool` is `true`. Reading
  booleans by casting silently turned the number `1` into a boolean, which broke
  `header.version` and any todo payload containing a numeric `1`. Booleans are now
  identified through `CFBoolean`, with a regression test over `0`, `1`, `2`,
  `1.5`, `-1`, `true`, and `false`.
- Streaming rows were keyed by attempt id while the committed `assistant/message`
  carries only a turn, so a finished reply appeared twice. A `turn → attempt` map
  now bridges the two and the streamed row is upgraded in place.

CI found three more that a local build could not, because this machine has no Xcode:

- Nesting `Menu → ForEach → Section → ForEach → Button` with optional comparisons
  made the Swift type checker give up entirely. The picker is now split into
  `ModelMenu` and `ModelGroupRows` with explicitly typed values.
- `DSHModelSelection` had **no public initializer**: Swift synthesizes the
  memberwise one as `internal`, so the app target could not construct it even
  though the type is `public`. Added an explicit `public init`.
- The bundle path in the packaging step still used `DeepSeek Harness.app` after
  `PRODUCT_NAME` was made space-free; that would have broken packaging once
  compilation succeeded.

## Limitations

- No destructive session delete (not in the protocol).
- No image or file attachment upload yet; `PromptContentPart` supports text.
- The control stream is re-established on reconnect rather than resumed.
- The app targets one Host at a time.
