# Development

Requirements: macOS 13+, Xcode Command Line Tools (Xcode itself is not needed), BlackHole 2ch.

## Layout

| Path | Contents |
|---|---|
| `Sources/Jumphertz` | Executable: background agent (`--agent`) and command line |
| `Sources/JumphertzCore` | Swift: device matching, configuration, controller, CoreAudio legs |
| `Sources/JumphertzRT` | C, real-time only: IOProcs, lock-free ring, resampling stage with drift control |
| `Sources/CSampleRate` | libsamplerate 0.2.2, vendored unmodified (BSD-2), see `VENDORED.md` |
| `Tests/` | Unit tests (swift-testing), clock simulator, end-to-end CLI test |
| `Resources/` | Info.plist, entitlements, LaunchAgent template, third-party notices |
| `scripts/` | build, install, uninstall, test, development signing |
| `docs/ideas.md` | Measured options that were deliberately left out |

## Architecture

- **Output leg**: an IOProc on BlackHole 2ch alone. It runs as long as Discord runs and never changes the
  device's format (Discord loses its microphone when the input format changes during a call).
- **Input leg**: an IOProc on the Scarlett alone, at whatever rate the Scarlett runs. Rebuilt on its own when
  the interface changes (rate, hot plug, wake), while the output leg writes silence.
- Between them: a lock-free single-producer / single-consumer ring and libsamplerate (medium quality) with a
  ratio driven by the HAL rate scalars and a PI loop on a timestamp-extrapolated fill estimate.
- The real-time callbacks are plain C: no allocation, no lock, no Objective-C / Swift, no logging.
- The controller (`BridgeController`) runs on the main thread, is event driven (NSWorkspace, HAL property
  listeners, kqueue on the config directory) and does nothing while Discord is not running.

## Build, test, install

```sh
scripts/test.sh                 # unit tests (wraps swift test for the Command Line Tools)
scripts/build.sh                # universal Jumphertz.app in ~/Library/Caches/Jumphertz/build
scripts/install.sh              # build + install for the current user
scripts/check-test-summary.sh   # hardware check: jumphertz --test interrupted after 20 s
```

The bundle is assembled outside the source tree because `codesign` fails on exFAT volumes.

## Signing during development

By default the app is signed ad hoc, and `install.sh` resets the microphone permission because every build
has a new signature. To keep the permission across reinstalls, create a local signing identity once:

```sh
scripts/dev-create-identity.sh
JUMPHERTZ_SIGN_IDENTITY="Jumphertz Local Signing" scripts/install.sh
```

The identity lives in a dedicated keychain (`~/Library/Keychains/jumphertz-dev.keychain-db`, password in
`~/Library/Application Support/Jumphertz/dev-keychain-pass`), so building never prompts, whatever the state of
the login keychain. `scripts/uninstall.sh --dev` removes it.

## Logs

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "com.zeropablo.jumphertz" AND process == "Jumphertz"'
```

Unit tests log under `com.zeropablo.jumphertz.tests`.
