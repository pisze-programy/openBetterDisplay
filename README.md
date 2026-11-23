# openBetterDisplay

A lightweight, open-source macOS menu bar utility focused on the essential MacBook + external monitor workflow — with zero bloat and first-class support for super-ultrawide displays such as the Samsung Odyssey G9 49" (`LC49G95T`).

> **Status:** Specification phase (v1.0 MVP design complete). See [docs/SPEC.md](docs/SPEC.md) for the full technical and product specification.

## Why openBetterDisplay?

Great display managers on macOS can feel either too minimal (brightness-only) or overwhelming and paid when all you want is a rock-solid daily workflow:

- **One-click / automatic Built-in Display soft-disconnect** while keeping the MacBook lid open (keyboard, trackpad, and Touch ID stay usable).
- **Zero black-screen failsafe** — automatically restores the built-in screen when disconnecting an external monitor, waking without one, quitting the app, or pressing an emergency global hotkey (`⌃⌥⌘R`).
- **Per-monitor memory & auto-switching** — plug in a known external monitor and automatically restore its resolution, refresh rate, HDR mode, brightness, hardware volume, Main Display assignment, and built-in display state.
- **Combined brightness & hybrid Night Shift** — seamless hardware DDC/CI + software dimming overlay (essential when external monitors lock DDC brightness in HDR) and a scheduled warm Blue Light filter (`18:00–05:00` local time by default).

## Planned v1.0 Feature Highlights

- **Built-in Display Soft-Disconnect & Failsafe Watchdog** (`SLSConfigureDisplayEnabled` / session-scoped configuration)
- **Per-Monitor Profiles & Automatic Hotplug Restore**
- **Combined Brightness Control** (Apple Silicon DDC/CI via `IOAVService` + `sharingType = .none` software dimming overlay)
- **Hybrid Blue Light / Night Shift** (`CoreBrightness` + warm software fallback for external displays and HDR, configurable schedule defaulting to `18:00–05:00`)
- **Hardware Volume via DDC/CI** (intercepts keyboard volume keys *only* when the external monitor is macOS's active audio output; respects macOS native audio routing for speakers/headphones)
- **Native Resolution, Refresh Rate & HiDPI Picker** (CoreGraphics native modes including `5120×1440`, `3840×1080 HiDPI`, 60/120/240 Hz)
- **HDR Toggle** (per-monitor persisted)
- **Display Utilities** (`Set as Main Display`, `Mirror Display`, `Screen Rotation`, DDC `Input Source` switching)
- **Keyboard Media Keys, Global Shortcuts & Translucent OSD HUD**
- **Launch at Login** (`SMAppService`)

## Requirements & Distribution

- **Architecture:** Apple Silicon (`arm64`)
- **OS:** macOS 14.0 (Sonoma) or newer
- **Distribution:** Direct download (`.dmg` via GitHub Releases), signed with **Developer ID Application** and **Notarized** by Apple.
  - *Why not the Mac App Store?* Soft-disconnecting the internal display (`SkyLight`), toggling external HDR (`CoreDisplay` / `MonitorPanel`), Apple Silicon DDC (`IOAVService`), and media key interception (`CGEventTap`) require non-sandboxed entitlements and private macOS frameworks that are incompatible with Mac App Store review rules.

## Documentation

- [Project Specification (docs/SPEC.md)](docs/SPEC.md)

## License

Released under the [MIT License](LICENSE). Copyright (c) 2026 pisze-programy.
