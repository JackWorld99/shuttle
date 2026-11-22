<div align="center">

<img src="docs/readme/hero.png" alt="Shuttle: send photos, videos, files and text between your phone and computer" width="100%">

### AirDrop for the rest of us.

**Toss photos, videos, files and text between your Android phone and your Windows PC — in seconds.**<br>
Full quality. Encrypted. No cable, no cloud, no account.

[![Download for Android](https://img.shields.io/badge/Download-Android-3DDC84?style=for-the-badge&logo=android&logoColor=white)](https://github.com/JackWorld99/shuttle/releases/latest/download/Shuttle-Android.apk)
[![Download for Windows](https://img.shields.io/badge/Download-Windows-0078D4?style=for-the-badge&logo=data%3Aimage%2Fsvg%2Bxml%3Bbase64%2CPHN2ZyB4bWxucz0naHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmcnIHZpZXdCb3g9JzAgMCAyNCAyNCc%2BPHBhdGggZmlsbD0nd2hpdGUnIGQ9J00zIDNoOC41djguNUgzek0xMi41IDNIMjF2OC41aC04LjV6TTMgMTIuNWg4LjVWMjFIM3pNMTIuNSAxMi41SDIxVjIxaC04LjV6Jy8%2BPC9zdmc%2B)](https://github.com/JackWorld99/shuttle/releases/latest/download/Shuttle-Windows-Setup.exe)

[![Latest release](https://img.shields.io/github/v/release/JackWorld99/shuttle?label=latest&color=e8572a)](https://github.com/JackWorld99/shuttle/releases/latest)
[![License](https://img.shields.io/badge/license-Apache--2.0-1f2329)](LICENSE)
[![Stars](https://img.shields.io/github/stars/JackWorld99/shuttle?style=social)](https://github.com/JackWorld99/shuttle)

[中文](README.zh-CN.md) · [Why Shuttle](#why-shuttle) · [Get started](#get-started-in-a-minute) · [FAQ](#faq) · [Security](SECURITY.md)

</div>

<p align="center"><img src="docs/readme/demo.gif" alt="Share a photo on the phone, it lands on the computer a moment later" width="92%"></p>

## You know the drill

You took a great photo. Now you want it on your computer. So you…

- 💬 **send it to yourself in a chat app** — and it arrives blurry and compressed,
- ☁️ **upload it to the cloud** — and wait, then download it again, then delete it,
- 🔌 **look for a cable** — which is never where you left it.

**Shuttle skips all of that.** Your phone and your computer talk to each other directly over your Wi-Fi.
Share → tap your PC → done. The original file, every byte checked.

## Why Shuttle

|   |   |
|---|---|
| 📸 **Your photos, untouched** | Originals only — no compression, no resizing. Every file is verified with SHA-256 on arrival. |
| ⚡ **As fast as your Wi-Fi** | Nothing goes through a server, so there's no upload and no download. In our tests, 200 photos (about 500 MB) went from phone to PC in under 40 seconds on ordinary home Wi-Fi. |
| 🤝 **Pair once, then it just works** | Scan a QR code one time. From then on your devices find each other, and files from them arrive without a single tap. |
| 📋 **Copy here, paste there** | Press <kbd>Ctrl</kbd>+<kbd>V</kbd> on your PC to send the clipboard to your phone. Share a link from your phone and it's ready to paste on your PC. |
| 🔒 **Private by design** | No account, no cloud, no tracking, no ads. Transfers are encrypted, and pairing compares 12 digits on both screens so no one can sneak in. |
| 🖥️ **Always ready** | Shuttle waits quietly in the tray, can start with Windows, and keeps itself up to date with signed updates. |
| 🌍 **Works away from home** | Add [Tailscale](https://tailscale.com) on both devices and it works over mobile data too — still without anyone's server in between. |

## How it compares

|   | **Shuttle** | Chat apps | Cloud drives | USB cable |
|---|:---:|:---:|:---:|:---:|
| Original quality | ✅ | ❌ usually compressed | ✅ | ✅ |
| No account needed | ✅ | ❌ | ❌ | ✅ |
| Works without internet | ✅ | ❌ | ❌ | ✅ |
| Files never leave your devices | ✅ | ❌ | ❌ | ✅ |
| No cable to find | ✅ | ✅ | ✅ | ❌ |

## Take a look

| Your phone | Pick where it goes | Your PC | Pair in one scan |
|:---:|:---:|:---:|:---:|
| <img src="docs/readme/phone-home.png" width="200"> | <img src="docs/readme/phone-send.png" width="200"> | <img src="docs/readme/pc-home.png" width="260"> | <img src="docs/readme/pc-pair.png" width="260"> |

## Get started in a minute

1. **Install** Shuttle on your phone and your PC (buttons above) and connect both to the same Wi-Fi.
2. **Pair**: on the PC click **Add device**; on the phone tap the scan button and point it at the QR code. Both screens show the same 12 digits — confirm, and you're paired.
3. **Toss things over**:
   - **Phone → PC**: in any app, tap **Share → Shuttle**.
   - **PC → phone**: drag files onto Shuttle, or press <kbd>Ctrl</kbd>+<kbd>V</kbd>.

> **Windows says "Windows protected your PC"?** The installer isn't code-signed yet. Click **More info → Run anyway**.<br>
> **Android asks about unknown apps?** Allow your browser to install it once.

## FAQ

<details>
<summary><b>Is it really free?</b></summary>

Yes. Shuttle is open source (Apache-2.0), with no ads, no paid tier and no account.
</details>

<details>
<summary><b>Is it safe? Could someone else on the Wi-Fi get my files?</b></summary>

Files go directly between your devices and are encrypted on the way. Only devices you paired (and checked the 12 digits for) can send to you without asking; anything else needs your OK first. Details in [SECURITY.md](SECURITY.md).
</details>

<details>
<summary><b>Do I need internet?</b></summary>

No. Both devices just need to be on the same Wi-Fi network — even one with no internet. For use away from home, install Tailscale on both.
</details>

<details>
<summary><b>The phone can't find my PC.</b></summary>

Make sure both are on the same network (guest networks and some routers keep devices apart). On Windows, allow Shuttle through the firewall on **private** networks and set your home Wi-Fi to **Private**. Office and school networks often block devices from seeing each other — Tailscale works around that.
</details>

<details>
<summary><b>iPhone? Mac? Linux?</b></summary>

Android and Windows today, and a macOS build is in testing. iPhone and Linux aren't available yet — [open an issue](../../issues/new/choose) to tell us which one you want most.
</details>

<details>
<summary><b>How is this related to LocalSend?</b></summary>

Shuttle is built on [LocalSend](https://github.com/localsend/localsend), the excellent open-source file-sharing app. It keeps LocalSend's solid transfer and encryption core and adds a redesigned interface, QR pairing with verification, trusted "My devices", clipboard sending, Tailscale support and signed auto-updates. Thank you to LocalSend's author and contributors.
</details>

## What's next

- [ ] Signed macOS build
- [ ] Resume large transfers after a dropped connection
- [ ] Send queue: files wait on your PC and go out as soon as your phone is back online

Have an idea? [Open an issue](../../issues/new/choose).

## Contributing

Bug reports, ideas and pull requests are all welcome — see [CONTRIBUTING.md](CONTRIBUTING.md). Found a security problem? Please report it privately as described in [SECURITY.md](SECURITY.md).

**If Shuttle saved you a cable hunt, a ⭐ helps others find it.**

## License

[Apache-2.0](LICENSE). Shuttle is a modified version of [LocalSend](https://github.com/localsend/localsend) (Copyright 2022-2026 Tien Do Nam, Apache-2.0); all changes are released under Apache-2.0 as well.
