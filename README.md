<div align="center">

# AEQ Pro 🎚️

### A system-wide audio equalizer for macOS

EQ everything your Mac plays — Safari, Music, games, anything — in real time.
31 bands, genre presets, a Siri-inspired visualizer, and per-app routing.

*created by [aefotograph](https://www.aefotograph.art) 🇱🇰*

</div>

---

## ✨ Features

- **System-wide EQ** — processes all macOS audio live using Core Audio process taps
- **31-band graphic equalizer** with a draggable curve and ±12 dB range
- **15 built-in presets** — Flat, Bass, Rock, Pop, Hip-Hop, EDM, Jazz, Classical, Acoustic, R&B, Latin, Vocal, Cinema, Air, and a custom **Baila 🇱🇰** preset tuned for Sri Lankan baila
- **Siri-inspired visualizer** — three flowing, glowing waves driven by bass, mids, and treble
- **Per-app routing** — send Safari to your headphones and Music to your speakers, at the same time
- **Master controls** — preamplifier, amplifier, compressor, output gain, and auto gain protection (a built-in limiter that protects your ears and speakers)
- **Output device selector** — AirPods, speakers, audio interfaces, anything your Mac sees
- **True power toggle** — flip it off and your Mac's audio returns to normal instantly
- **Clipping warning** and a live capture indicator

## 🖥️ Requirements

- macOS 14.4 or newer (required for Core Audio process taps)
- The **System Audio Recording** permission (the app asks on first launch)

## 🚀 Building from source

1. Open `AEQPro.xcodeproj` in Xcode
2. Select the **AEQPro** target → **Signing & Capabilities** → set your team
3. Make sure **Minimum Deployments** is set to macOS 14.4
4. Build and run (⌘R)
5. Allow the system-audio permission when prompted, then play any audio

## 🎛️ How it works

AEQ Pro creates a Core Audio process tap that captures system audio, mutes the
original output, and replays it through an `AVAudioEngine` chain
(EQ → compressor → limiter) to your chosen output device. A ring buffer bridges
the low-level capture callback and the playback engine for stable, low-latency
audio.

## ⚠️ Note

This app is not sandboxed and is not notarized. When sharing the built app,
other users may need to right-click → Open the first time, or enable it under
**System Settings → Privacy & Security**.

## 📄 License

MIT — do whatever you like, just keep the credit.

---

<div align="center">
<sub>Made with ☕ and 🎶 in Dubai</sub>
</div>
