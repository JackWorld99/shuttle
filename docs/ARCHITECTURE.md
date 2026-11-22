# Architecture

A map of the code for contributors. Shuttle is a fork of [LocalSend](https://github.com/localsend/localsend) 1.18.2, so most of
the structure below is LocalSend's. Shuttle's own code mostly lives in files named `shareme_*` (the project's working name) and
its comments are marked `Shuttle:` where it changes upstream behavior. Internal identifiers (`localsend_app`, `org.localsend…`,
the `/api/localsend/v2` protocol paths) are kept on purpose so that upstream fixes still merge cleanly.

## Repository layout

A multi-language monorepo: a Flutter app on top of a Rust protocol implementation.

| Path                           | What it is                                                                                                                  |
|--------------------------------|-----------------------------------------------------------------------------------------------------------------------------|
| `app/`                         | The Flutter app (`localsend_app`): UI, providers, persistence, platform channels.                                          |
| `packages/localsend_isolates/` | Dart isolate layer + `flutter_rust_bridge` (FRB) bindings. Owns `rust/` (the plugin crate) and `rust_builder/` (cargokit). |
| `packages/core/`               | Rust crate `localsend`: protocol, HTTP server/client, crypto, multicast. No Flutter dependency.                             |
| `packages/typed_isolates/`     | Small package wrapping Dart `Isolate` with typed send/receive channels.                                                     |
| `server/`                      | Upstream WebSocket signaling server for WebRTC (not used by Shuttle).                                                       |
| `cli/`                         | Rust CLI crate: terminal client on top of `packages/core`.                                                                  |
| `support/scripts/`             | Packaging scripts (Inno Setup installer, version number, update manifest signing).                                          |

The Rust crates (`packages/core`, `packages/localsend_isolates/rust`, `server`, `cli`) form one Cargo workspace at the repository
root (one `Cargo.lock`, one `target/`; `[profile.*]` only in the root `Cargo.toml`). The Dart packages (`app`,
`packages/localsend_isolates`, `packages/typed_isolates`) form a pub workspace at the root (one `pubspec.lock`).

Dependency direction: `app` → `localsend_isolates` → (`typed_isolates`, Rust plugin → `localsend` core). The app depends **only**
on `localsend_isolates`.

## Building and checks

The Flutter version is pinned in `.fvmrc` (also in `.github/workflows/ci.yml` and `app/pubspec.yaml`); use that version, with
[fvm](https://fvm.app) or a matching system install. Run from `app/` unless stated otherwise:

```bash
flutter pub get
dart run build_runner build   # dart_mappable, freezed, flutter_gen, mockito
dart run slang                # i18n code generation
flutter run
```

Checks (what CI runs on pull requests):

```bash
dart format --set-exit-if-changed lib test   # generated code in lib/gen is not format-checked
flutter analyze
flutter test
```

Formatting is **150 columns** (`page_width: 150` in `analysis_options.yaml`). Rust: `cargo test --features full` and
`cargo clippy --features full` in `packages/core` — `packages/core` gates almost everything behind Cargo features and has
`default = []`, so always use `--features full`. FRB code generation: `flutter_rust_bridge_codegen generate` in
`packages/localsend_isolates/` (it tends to rewrite `app/test/mocks.mocks.dart` at 80 columns; revert that file).

## App architecture

**State management** is Refena (`refena_flutter`). Providers live in `app/lib/provider/`: `NotifierProvider` for plain state,
`ReduxProvider` + action classes for anything the isolate layer touches. `app/lib/config/init.dart` (`preInit`) is the bootstrap:
logging, `RustLib.init()`, persistence, the isolate container, tray/window.

**Models** use `dart_mappable`; `fromJson`/`toJson` are the Map converters and `deserialize`/`serialize` the string ones.

**Persistence**: on desktop, settings live in a `settings.json` next to the executable (portable) or under `%APPDATA%\Shuttle`;
it is written atomically with a `.bak` copy and recovered from the backup if it is ever damaged. On Android, the app's data is
excluded from system backups and device transfer so the device's private key never leaves the phone.

**Isolates**: heavy networking never runs on the main isolate. `packages/localsend_isolates/lib/src/isolate/` holds one child
isolate per job (HTTP scan discovery, multicast discovery, upload, HTTP server); the app talks to them only through
`parent/actions.dart` and `parent/actions_sync.dart`. Children read `syncState` when they start, so sync before starting the server.

## Networking (Rust)

The HTTP server and client are Rust. `packages/core/src/http/server/` implements protocol v2 plus the "send via browser" flow
(`server/web.rs`). Integration is channel-based: the server emits `ServerEventV2` events (`Register`, `PrepareUpload` with a
decision channel, `FileUpload` with a byte stream, …) and the app answers them. Only **one upload session** is active at a time.

TLS uses per-device certificates with **mandatory client certificates**; a peer's identity is the uppercase-hex SHA-256 of its
certificate. Shuttle builds on this: "My devices" are pinned to that fingerprint, pairing derives a shared secret
(`app/lib/util/shareme_pairing/`), and only devices with a pairing record are accepted automatically. QR pairing is authenticated
by the code itself (certificate fingerprint + one-time key). Computer-to-computer pairing is authenticated by each person typing
half of a 12-digit check derived from the handshake transcript (commit-then-reveal), so a man in the middle can't make both halves
match.

Save targets are decided in Dart (`prepareFileSaveTarget`) and written by Rust: a path, or an Android file descriptor from the
`org.localsend.localsend_app/localsend` method channel. On Android 10+ photos and videos are written straight into a pending
MediaStore entry, published when the transfer completes.

**Discovery**: UDP multicast announcements (`packages/core/src/multicast/`, protocol v2.2, IPv4 + an IPv6 extension); answers go
back over HTTP. Shuttle adds a lightweight presence check for "My devices" and uses Tailscale addresses when devices aren't on the
same network.

## Auto-update

Installed copies check a manifest on GitHub Releases once a day. The manifest is signed with Ed25519 and the app trusts only the
public key compiled into `app/lib/util/shareme_update/update_config.dart`; the downloaded installer is checked against the
manifest's size and SHA-256 before it runs, and versions never go backwards. Releases are built, signed and published by
`.github/workflows/shareme_release.yml`; the signing keys are secrets of the protected `release` environment (main branch only,
every run approved by the maintainer) and are not in the code.

## i18n

[Slang](https://pub.dev/packages/slang): sources in `app/assets/i18n/`, generated code in `app/lib/gen/`. Shuttle's own strings
exist in English and Simplified Chinese; a pull request may edit `en.json` and `zh-CN.json` directly. The app follows the
system language until the user picks one.

## Versions

The version name is the date of the last commit and the build number is the commit count plus 100
(`support/scripts/shuttle_version.sh`); the offset keeps build numbers above those released before the source was published.
