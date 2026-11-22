# Contributing to Shuttle

Issues and pull requests are welcome — in English or Chinese.

- **Bugs and ideas**: use the issue templates and include your platform, version (Settings → More → Version) and steps to reproduce.
- **Security problems**: please don't open a public issue — see [SECURITY.md](SECURITY.md).
- **Code changes**: open an issue first to talk about what you'd like to change. Keep pull requests small and focused, with tests.

## Building

Shuttle is a Flutter (UI) + Rust (networking, crypto) project. The layout, commands and design notes are in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

```bash
cd app
flutter pub get
dart run slang          # generate the translations
flutter run             # needs the Rust toolchain (see rust-toolchain.toml)
```

Before sending a pull request:

```bash
dart format --set-exit-if-changed lib test
flutter analyze
flutter test
```

## Relationship to LocalSend

Shuttle is based on [LocalSend](https://github.com/localsend/localsend) (Apache-2.0). Bugs in parts Shuttle didn't change (the protocol, the Rust networking layer) may also exist in LocalSend — feel free to report them upstream too. Please don't report Shuttle-specific issues to the LocalSend team.
