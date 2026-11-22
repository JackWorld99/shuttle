/// The LocalSend version Shuttle is based on.
///
/// Shuttle's own version is computed at build time and passed to Flutter: version name = date of the latest commit
/// (e.g. 2026.11.16), build number = commit count + 100 (support/scripts/shuttle_version.sh).
/// The 1.18.2+64 in pubspec.yaml is left alone (fewer conflicts when merging upstream); only local builds without the
/// version arguments show it. The settings page shows "2026.11.16 (2261) · Based on LocalSend 1.18.2".
/// Update this when merging a new LocalSend version.
const localSendBaseVersion = '1.18.2';
