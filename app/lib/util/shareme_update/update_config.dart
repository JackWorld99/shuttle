// Shuttle: fixed configuration for auto-update.
//
// Release files are published in this repository's GitHub Releases (JackWorld99/shuttle) by the release workflow,
// .github/workflows/shareme_release.yml. The app only accepts manifests signed with an Ed25519 public key hard-coded here; the
// private key is a secret of the repository's protected "release" environment (SHUTTLE_UPDATE_SIGNING_KEY), never in the code.

/// Signed manifest of the latest version. GitHub's releases/latest/download redirects to the file of that name in the latest full release.
const updateManifestUrl = 'https://github.com/JackWorld99/shuttle/releases/latest/download/shuttle-update.json';

/// Download URLs in the manifest must start with this (an extra safeguard; tamper protection really comes from the signature and SHA-256).
const updateDownloadPrefix = 'https://github.com/JackWorld99/shuttle/releases/download/';

/// Trusted Ed25519 public keys (raw 32 bytes, standard base64). To rotate keys: first ship a version that contains both the old and
/// the new public key and is signed with the old key; once devices have updated to it, switch to signing with the new key.
/// Before publishing, the release workflow checks that the signing key's public key is in this list (the "Sign manifest" step of
/// shareme_release.yml).
const updateTrustedKeys = <String>[
  // Key ID 471a5bae683028e6, used from build 2301. Builds up to 2289 trusted an earlier key (9d79e6efdfff087c) that stayed
  // with the build setup used before the source was published, so those installs have to install 2301 once by hand.
  'HLZRgUtThznOWSnVxUUK46ORCw/eiQAkf3If/N5HahU=',
];

/// First check 1 minute after launch (so it doesn't compete with the startup scan and server start); then every 24 hours (Sparkle's default).
const updateFirstCheckDelay = Duration(minutes: 1);
const updateCheckInterval = Duration(hours: 24);

/// The manifest may be at most 64 KB and the installer at most 500 MB. Anything larger is treated as corrupt.
const updateManifestMaxBytes = 64 * 1024;
const updateFileMaxBytes = 500 * 1024 * 1024;
