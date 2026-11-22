/// Shuttle: for security, a sending device is identified only by its TLS certificate.
///
/// When the server doesn't ask the peer for a certificate (while "Share via link" or "Receive from a browser" is on, since browsers
/// have no certificate, or when encryption is turned off), the fingerprint the peer claims in its request can't be verified, and
/// anyone can impersonate it (fingerprints are public in the broadcasts anyway). This used to fall back to the claimed fingerprint,
/// so an impostor was treated as one of "My devices": auto-accept, text auto-copied to the clipboard, and the "My devices" badge in
/// the history.
library;

const _unverifiedPrefix = 'unverified:';

/// The sender's fingerprint: the certificate's if there is one; otherwise the claimed fingerprint with a prefix, so it never matches
/// "My devices" and auto-accept, auto-copy, the badge and "remember this device" never happen ([isUnverifiedFingerprint]).
String verifiedSenderFingerprint({required String? certFingerprint, required String claimed}) {
  return certFingerprint ?? '$_unverifiedPrefix$claimed';
}

/// Whether this fingerprint was not verified against a certificate (see [verifiedSenderFingerprint]).
bool isUnverifiedFingerprint(String fingerprint) => fingerprint.startsWith(_unverifiedPrefix);

/// Whether the server currently verifies the peer's certificate: encryption is on and "Share via link" / "Receive from a browser" is off.
bool serverVerifiesClients({required bool https, required bool webShareActive}) => https && !webShareActive;
