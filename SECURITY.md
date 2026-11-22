# Security

## Reporting a vulnerability

**Please don't report security issues in public issues.** Use **Security → Report a vulnerability** in this repository to send a private report. We aim to reply within 7 days.

Please include the affected version (Settings → More → Version), the platform, steps to reproduce, and the possible impact.

## How Shuttle protects your files

- **Only between your devices**: no servers, no accounts. Devices on the same Wi-Fi talk directly; across networks, traffic only goes through your own [Tailscale](https://tailscale.com) network.
- **Encryption**: every device creates its own certificate on first launch. Transfers use HTTPS (TLS), and "My devices" check each other's certificate fingerprints both ways, so a man in the middle can't pretend to be one of them.
- **Pairing is verified**: when pairing by QR code (or computer-to-computer under Nearby), both screens show the same picture and 12 digits, and nothing is saved until you confirm they match. Only verified devices are accepted automatically or get text copied to your clipboard; anything else asks you first.
- **Signed updates**: auto-update only accepts a manifest signed with a fixed Ed25519 key, checks the installer's size and SHA-256, and never downgrades.
- **No data collection**: no analytics, no ads. The only outside connection is a daily update check on GitHub (can be turned off in Settings → More).
- **Risky files**: executable files (`.exe`, `.bat`, `.lnk`, …) can't be opened from inside Shuttle, only shown in their folder. On Windows, files from unverified devices are marked as coming from the internet, like browser downloads, so SmartScreen warns before they run.

## Known limitations

- The Windows installer and the macOS build are **not code-signed** yet, so the system warns about an unknown publisher on first install. Only download from this project's Releases.
- The "send me via browser" link page is not encrypted (browsers don't trust Shuttle's self-signed certificate) and has no password by default. Turn it off when you're done.
- On Android, Shuttle's data is excluded from system backups and device-to-device transfer (so the private key never leaves the phone). After moving to a new phone, pair again.
