<div align="center">

<img src="https://github.com/aefotograph/AEQPro/raw/main/AEQPro/Assets.xcassets/AppIcon.appiconset/icon_512_2x.png" width="128" height="128" alt="AEQ Pro icon" />

# AEQ Pro 🎚️

### A system-wide audio equalizer for macOS

EQ everything your Mac plays — Safari, Music, games, anything — in real time.
31 bands, smart auto-presets, four visualizers, two themes, per-app routing,
and your own savable presets.

*created by [aefotograph](https://www.aefotograph.art) 🇱🇰 · [Buy me a coffee ☕](https://buymeacoffee.com/aefotograph)*


</div>

---

## ✨ Features

### 🎛️ Equalizer
- **31-band graphic EQ** with a draggable live curve and ±12 dB range
- **17 built-in genre presets** — Hip-Hop, Jazz, Baila 🇱🇰, Arabic, Movies, Bass, Rock, Pop, EDM, Classical, Acoustic, R&B, Latin, Vocal, Cinema, Air, Flat
- **Save your own presets** — dial in a curve, name it, it persists across launches
- **Remember last preset** — reopens exactly where you left off

### 🤖 Smart Auto Preset
- Toggle **Auto Preset** on and the app detects what's playing every 2 seconds
- **Video apps** (Safari, Chrome, Apple TV, Zoom, Teams, Discord) → **Movies** preset automatically
- **Music apps** (Apple Music, Spotify, iTunes) → spectrum classifier picks the best match
- Classifier reads live bass/mid/treble ratios — never falls back to Flat
- Suggestion shown live: *"Detected: Rock"* or *"Movies (video detected)"*
- Override anytime by tapping any preset pill

### 🎨 Visualizers (1 / 2 / 3 / 4)
- **Winamp classic** — retro segmented green/yellow/red bars with falling peak caps on black
- **Oscilloscope** — glowing green waveform on a CRT-style grid
- **Mirror bars** — gradient bars mirrored symmetrically from the center line
- **Siri waves** — three flowing, glowing layered waves driven by bass, mids, treble

### 🎨 Themes
- **Dark** — minimal black and deep purple, easy on the eyes
- **JET** — blue metallic inspired by JetAudio; navy gradients, cyan LCD accents, chrome borders

### 🔊 Audio Engine
- **System-wide capture** via Core Audio process taps — EQs everything your Mac plays
- **Per-app routing** — send Safari to your headphones and Music to your speakers simultaneously
- **Master controls** — preamplifier, amplifier, compressor, output gain
- **Auto gain protection** — built-in peak limiter protects your ears and speakers
- **Output device selector** — AirPods, built-in speakers, audio interfaces, anything macOS sees
- **True power toggle** — off releases your Mac's audio instantly, no muting artefacts
- **Clipping warning** and live capture indicator

### ⚙️ System
- **Launch at login** — starts silently on every login, always on
- **Remembers everything** — last preset, auto-preset state, launch preference all survive restarts

---

## 🖥️ Requirements

- macOS **14.4 or newer** (required for Core Audio process taps)
- The **System Audio Recording** permission (the app asks on first launch)
- No App Sandbox — system-wide audio capture requires running unsandboxed

---

## 📦 Install

1. Download the latest `.dmg` from [**Releases**](https://github.com/aefotograph/AEQPro/releases)
2. Open it and drag **AEQ Pro** into your Applications folder
3. **First launch:** right-click the app → **Open** to get past the macOS security warning
4. Allow the **System Audio Recording** permission when prompted
5. Play any audio — the green **Live** indicator confirms it's working

---

## 🛠️ Building from source

```bash
git clone https://github.com/aefotograph/AEQPro.git
cd AEQPro
open AEQPro.xcodeproj
```

1. Select the **AEQPro** target → **Signing & Capabilities** → set your Apple ID team
2. **General** tab → set **Minimum Deployments** to macOS 14.4
3. **Info** tab → confirm `NSAudioCaptureUsageDescription` key exists
4. Build and run (**⌘R**) → allow permissions when prompted

---

## 🎛️ How it works

```
System Audio
     │
     ▼
Core Audio Process Tap  ←── taps ALL Mac audio, mutes original
     │
     ▼
IOProc Callback  ──►  Ring Buffer  ──►  AVAudioSourceNode
                                              │
                                              ▼
                                    31-band AVAudioUnitEQ
                                              │
                                         Compressor
                                              │
                                     Peak Limiter (AGP)
                                              │
                                              ▼
                                      Your Output Device
```

A low-level `IOProc` callback captures audio from the tap into a lock-free stereo ring buffer. An `AVAudioSourceNode` reads from that buffer on the playback thread, feeding the EQ chain. Real-time FFT (Hann-windowed, 2048-point) drives the visualizer and auto-preset classifier simultaneously.

---

## 🎵 Preset guide

| Preset | Best for |
|--------|----------|
| **Movies** | Films, streaming, anything with dialogue and surround effects |
| **Hip-Hop** | Heavy sub-bass tracks, trap, drill |
| **Jazz** | Warm, acoustic, low centroid music |
| **Baila 🇱🇰** | Sri Lankan baila — driving bass, conga punch, brass bite |
| **Arabic** | Oud, darbuka, maqam vocals, qanun shimmer |
| **Rock** | V-curve — big lows and highs, scooped mids |
| **EDM** | Sub + sparkle, electronic dance |
| **Classical** | Gentle smile curve, stays out of the music's way |
| **Air** | Extreme high-shelf for bright, airy content |

---

## ⚠️ Notes

- **Not notarized** — right-click → Open on first launch
- **Not sandboxed** — system audio capture requires this
- If your Mac goes silent after a crash, choose your output in Control Center → Sound
- Safari is always treated as a video source; use Spotify desktop app for music-aware classification

---

## 📄 License

MIT — do whatever you like, just keep the credit.

---

<div align="center">

Built at midnight in Dubai with ☕ and way too much baila 🇱🇰

**[Download](https://github.com/aefotograph/AEQPro/releases) · [Buy me a coffee](https://buymeacoffee.com/aefotograph) · [aefotograph.art](https://www.aefotograph.art)**

</div>
