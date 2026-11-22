// Shuttle auto-update: format and verification of the signed manifest.
//
// The published shuttle-update.json is an "envelope" holding both the manifest and its signature, so one download gets both:
//   { "format": "shuttle-update-1", "key": "<key ID>", "payload": "<manifest, base64>", "signature": "<Ed25519 signature, base64>" }
// The signature is RFC 8032 Ed25519 over the raw decoded payload bytes (the release workflow signs with OpenSSL `pkeyutl -sign -rawin`).
// Unlike Sparkle / Tauri, which sign each file separately, the whole manifest is signed here, so version, size and SHA-256 can't be
// tampered with; the files themselves are checked against the SHA-256 in the manifest.
//
// Manifest (payload):
//   { "schema": 1, "version": "2026.11.20", "build": 2275, "date": "2026-11-20T08:00:00Z",
//     "notes": { "zh": "…", "en": "…" },
//     "files": { "windows-x64": { "url": "…", "size": 123, "sha256": "<lowercase hex>" }, "android-arm64": { … } } }
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';

const updateEnvelopeFormat = 'shuttle-update-1';
const updateManifestSchema = 1;

/// Signature, format or file mismatch. The UI says the new version failed verification and was not installed.
class UpdateVerifyException implements Exception {
  final String message;

  const UpdateVerifyException(this.message);

  @override
  String toString() => 'UpdateVerifyException: $message';
}

class UpdateFile {
  final String url;
  final int size;

  /// Lowercase hex.
  final String sha256;

  const UpdateFile({required this.url, required this.size, required this.sha256});
}

class UpdateManifest {
  final String version;
  final int build;
  final DateTime? date;
  final Map<String, String> notes;

  /// Platform → file. For the platform names see [currentUpdatePlatform] in update_installer.dart.
  final Map<String, UpdateFile> files;

  const UpdateManifest({required this.version, required this.build, required this.date, required this.notes, required this.files});

  /// zh for a Chinese UI, en otherwise; falls back to the other one if missing.
  String? notesFor(String languageCode) {
    final preferred = languageCode.startsWith('zh') ? 'zh' : 'en';
    return notes[preferred] ?? notes[preferred == 'zh' ? 'en' : 'zh'];
  }
}

/// Shuttle: whether the already downloaded and verified [ready] is still the [platform] version in the latest manifest [latest]
/// (same build number, same file). If so, keep using it; if not (newer version, replaced file, or no longer listed), replace it.
bool isSameUpdate(UpdateManifest ready, UpdateManifest latest, String platform) {
  final a = ready.files[platform];
  final b = latest.files[platform];
  return a != null && b != null && latest.build == ready.build && a.sha256 == b.sha256 && a.size == b.size;
}

/// Key ID: the first 16 hex characters of SHA-256(raw 32-byte public key). The release workflow writes it into the envelope the same way.
String updateKeyId(List<int> rawPublicKey) => crypto.sha256.convert(rawPublicKey).toString().substring(0, 16);

/// Verifies the envelope's signature, then parses the manifest. Any failed step throws [UpdateVerifyException].
Future<UpdateManifest> verifyUpdateEnvelope(
  String body, {
  required List<String> trustedKeys,
  required String downloadPrefix,
}) async {
  final Object? envelope;
  try {
    envelope = jsonDecode(body);
  } on FormatException {
    throw const UpdateVerifyException('envelope is not JSON');
  }
  if (envelope is! Map<String, dynamic>) throw const UpdateVerifyException('envelope is not an object');
  if (envelope['format'] != updateEnvelopeFormat) throw UpdateVerifyException('unknown format ${envelope['format']}');
  final keyId = envelope['key'];
  final payload = _base64(envelope['payload'], 'payload');
  final signature = _base64(envelope['signature'], 'signature');
  if (signature.length != 64) throw const UpdateVerifyException('signature must be 64 bytes');
  if (payload.isEmpty || payload.length > 32 * 1024) throw const UpdateVerifyException('payload size');

  final candidates = <Uint8List>[];
  for (final key in trustedKeys) {
    final Uint8List raw;
    try {
      raw = base64.decode(key);
    } on FormatException {
      continue;
    }
    if (raw.length == 32 && updateKeyId(raw) == keyId) candidates.add(raw);
  }
  if (candidates.isEmpty) throw UpdateVerifyException('signed with an unknown key $keyId');

  final ed25519 = Ed25519();
  var verified = false;
  for (final key in candidates) {
    final ok = await ed25519.verify(
      payload,
      signature: Signature(signature, publicKey: SimplePublicKey(key, type: KeyPairType.ed25519)),
    );
    if (ok) {
      verified = true;
      break;
    }
  }
  if (!verified) throw const UpdateVerifyException('bad signature');

  final Object? manifest;
  try {
    manifest = jsonDecode(utf8.decode(payload));
  } on FormatException {
    throw const UpdateVerifyException('payload is not UTF-8 JSON');
  }
  return parseUpdateManifest(manifest, downloadPrefix: downloadPrefix);
}

/// Parses the (already signature-checked) manifest. A bad format throws [UpdateVerifyException]: a signed but malformed manifest
/// means the release process is broken, so nothing is installed either.
UpdateManifest parseUpdateManifest(Object? json, {required String downloadPrefix}) {
  if (json is! Map<String, dynamic>) throw const UpdateVerifyException('manifest is not an object');
  if (json['schema'] != updateManifestSchema) throw UpdateVerifyException('unknown schema ${json['schema']}');

  final version = json['version'];
  if (version is! String || !RegExp(r'^[0-9A-Za-z.+-]{1,32}$').hasMatch(version)) throw const UpdateVerifyException('bad version');
  final build = json['build'];
  if (build is! int || build <= 0) throw const UpdateVerifyException('bad build');

  final dateRaw = json['date'];
  final date = dateRaw is String ? DateTime.tryParse(dateRaw) : null;

  final notes = <String, String>{};
  final notesRaw = json['notes'];
  if (notesRaw is Map<String, dynamic>) {
    for (final e in notesRaw.entries) {
      if (e.value is String) notes[e.key] = e.value as String;
    }
  }

  final filesRaw = json['files'];
  if (filesRaw is! Map<String, dynamic>) throw const UpdateVerifyException('files missing');
  final files = <String, UpdateFile>{};
  for (final e in filesRaw.entries) {
    final f = e.value;
    if (f is! Map<String, dynamic>) throw UpdateVerifyException('bad file entry ${e.key}');
    final url = f['url'];
    final size = f['size'];
    final sha256 = f['sha256'];
    if (url is! String || !url.startsWith(downloadPrefix) || Uri.tryParse(url) == null) {
      throw UpdateVerifyException('file ${e.key} is not hosted at $downloadPrefix');
    }
    if (size is! int || size <= 0) throw UpdateVerifyException('bad size for ${e.key}');
    if (sha256 is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(sha256)) throw UpdateVerifyException('bad sha256 for ${e.key}');
    files[e.key] = UpdateFile(url: url, size: size, sha256: sha256);
  }

  return UpdateManifest(version: version, build: build, date: date, notes: notes, files: files);
}

Uint8List _base64(Object? value, String field) {
  if (value is! String) throw UpdateVerifyException('$field missing');
  try {
    return base64.decode(value);
  } on FormatException {
    throw UpdateVerifyException('$field is not base64');
  }
}
