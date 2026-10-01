# DeepSeek Harness for iOS

[![iOS Build](https://github.com/hicongcn/dsh-ios/actions/workflows/ios.yml/badge.svg)](https://github.com/hicongcn/dsh-ios/actions/workflows/ios.yml)

Native iOS clients for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness),
built from its own source. Two apps, one protocol package:

| App | What it is | Size |
| --- | --- | --- |
| **DeepSeekHarness** (standalone) | The whole harness embedded in the app. Runs on device with no host. | ~14 MB |
| **DeepSeekHarnessClient** | A thin client for a `dsh web` host running on your computer. | ~350 KB |

Both speak the upstream wire protocol or run the upstream runtime, so neither
reimplements the product.

```
┌─ DeepSeekHarness (standalone) ───────────────────────────┐
│  SwiftUI shell  →  LocalAssetServer (127.0.0.1)          │
│                        ↓                                 │
│  WKWebView  →  preview.html  →  Web Worker (harness)     │
│                                    ↓ inflates            │
│                              vfs-image.tar.gz            │
│                              (844 modules, no Node host) │
└──────────────────────────────────────────────────────────┘
```

## Download a build

```bash
gh run download --repo hicongcn/dsh-ios -n DeepSeekHarnessStandalone-unsigned-ipa
```

Or from the [Actions page](https://github.com/hicongcn/dsh-ios/actions/workflows/ios.yml):
open a green run and take the artifact you want.

## How the standalone app works

The harness is a Web Worker application: the page starts a worker, the worker
inflates a packed VFS image and boots the full plugin tree. WebKit gives a
`file://` page **no origin at all**, and a worker cannot start without one. So
`WKWebView.loadFileURL` cannot work here, and the app serves its own bundle over
`127.0.0.1` instead — an origin with no off-device surface.

`DSHAssetServer` is that server. It binds loopback only, answers `GET`/`HEAD`
only, and confines every resolved path to the served root. Its self-test asserts
the invariant that matters — *no request resolves outside the root* — rather than
a list of forbidden strings, so inputs nobody enumerated are still covered.

The assets themselves are not in this repository. They are build products of the
upstream project (16 MB, mostly the 14 MB VFS image), so
`scripts/fetch-harness-assets.sh` downloads them and the app icon is generated
from the upstream brand mark. Committing them would add binaries that silently
drift from whatever built them.

### Boot sources

The preview page renders a developer-facing source chooser unless it is told
otherwise, so the app always passes a source and offers a switcher in place of
the chooser it replaces:

| In-app name | Query value | Effect |
| --- | --- | --- |
| Empty environment | `preview-fixture=none` | Clean start; connect your own model. |
| Showcase sample | `preview-fixture=vfs-example` | Bundled sample workspace and history. |

`none` is the runtime's own sentinel for "no overlays" — the literal string
`none`, not `empty`; the page rejects anything it does not recognise.

## Building it yourself

Requires Xcode and `xcodegen`.

```bash
brew install xcodegen
./scripts/fetch-harness-assets.sh     # pull the harness into the app bundle
python3 scripts/make-app-icon.py      # needs Pillow and rsvg-convert
xcodegen generate
open DeepSeekHarness.xcodeproj        # pick a scheme, run on iOS 17+
```

CI does exactly this on a macOS runner (`.github/workflows/ios.yml`) and then
smoke-launches the app on a simulator, confirming the process stays alive and
capturing a screenshot — compiling is not running.

### Pointing at a different harness build

```bash
HARNESS_ASSETS_URL=https://your.host/path ./scripts/fetch-harness-assets.sh
```

The script discovers content-hashed filenames from the served pages and the
bootstrap module rather than pinning hashes, and verifies every overlay the
fixtures manifest promises.

## Signing

An unsigned `.ipa` is a real arm64 binary, but iOS will not install it on a
stock device, and there is no supported way around that. For a device-installable
build you need a Development or Ad Hoc profile, which requires a paid Apple
Developer account (a free Apple ID cannot create one).

Add four repository secrets and run the signed workflow:

| Secret | Value |
| --- | --- |
| `BUILD_CERTIFICATE_BASE64` | `base64 -i Certificates.p12` |
| `P12_PASSWORD` | the `.p12` export password |
| `BUILD_PROVISION_PROFILE_BASE64` | `base64 -i profile.mobileprovision` |
| `KEYCHAIN_PASSWORD` | any throwaway string |

```bash
gh workflow run ios-signed.yml --repo hicongcn/dsh-ios
```

Without signing, the simulator build is fully usable:

```bash
xcrun simctl install booted DeepSeekHarness.app
xcrun simctl launch booted ai.deepseek.harness.standalone
```

## Verification

`swift run` the two self-test executables; neither needs Xcode.

```bash
swift build
swift run dshkit-selftest             # 110 checks
swift run dsh-asset-server-selftest   # 56 checks
```

`dshkit-selftest` covers the wire protocol, including live checks against a real
`dsh web` host when `DSH_LIVE_URL` is set (token exchange, session list/create,
streaming snapshot, paging, control stream, prompt, reconnect, concurrent
multiplexing). `dsh-asset-server-selftest` covers path resolution, traversal
refusal, content types, request parsing, and the live server over real sockets.

### Bugs these checks found

Found by running, not by reading:

- `JSONSerialization` bridges `NSNumber` so that `1 as? Bool` is `true`, which
  silently turned the number `1` into a boolean and broke `header.version`.
  Booleans now go through `CFBoolean`, with a regression test.
- Streamed assistant rows were keyed by attempt id while the committed message
  carries only a turn, so a finished reply rendered twice.
- `DSHModelSelection` had no public initializer — Swift synthesizes it as
  `internal`, so the app could not construct one across the module boundary.
- Nested `Menu → ForEach → Section → ForEach → Button` defeated the Swift type
  checker outright.
- The app sent no fixture query, so it booted to the developer chooser instead of
  the harness; and it used `empty` where the runtime expects `none`.
- The fetch script dropped the fixture overlay archives, which are named only
  inside `fixtures.json`, leaving the showcase source broken.

## Limitations

- **Unsigned builds do not install on a stock device.** Use the simulator, or
  sign it.
- **Model access needs your own API key.** The harness calls the model API from
  the page; the app stores nothing and proxies nothing. DeepSeek's API sends the
  CORS headers a browser client needs, which is what makes this work at all.
- **The embedded runtime is upstream's `experimental` package.** The worker
  confinement is a VFS boundary, not kernel isolation; the shell is not bash; and
  `git`, native DNS, and package installation are unavailable by design.
- The standalone app targets one embedded harness build; changing it means
  re-fetching assets.
- The client app requires a reachable `dsh web` host. For a LAN host, start it
  with `--host 0.0.0.0 --trusted-host <your-ip>:<port>`; the `/api` fence refuses
  authorities it was not told about.
