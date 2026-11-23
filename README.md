# openBetterDisplay

A lightweight, open-source macOS menu bar utility focused on the essential MacBook + external monitor workflow — with zero bloat, instant response, and first-class support for super-ultrawide panels such as the Samsung Odyssey G9 49" (`LC49G95T`).

> **Status:** **v1.0 Implemented & Verified.** Built with Swift 6, SwiftUI, and AppKit for macOS 14.0+ on Apple Silicon (`arm64`). Fully audited and covered by 210 unit, integration, and edge-case tests.

---

## Why openBetterDisplay?

Display tools on macOS often fall into two extremes: bare-bones brightness sliders that cannot handle HDR or multi-monitor quirks, or heavy, paid commercial suites packed with virtual display pipelines that introduce latency, DSC handshake issues, and complex virtual screens.

`openBetterDisplay` focuses on the daily essentials MacBook users need when docking to external monitors:

1. **One-Click Built-in Display Soft-Disconnect:** Turn off the MacBook screen while leaving the lid open. Your built-in keyboard, trackpad, and Touch ID remain fully active.
2. **Zero Black-Screen Failsafe:** Air-tight protection guaranteed by session-scoped configuration (`kCGConfigureForSession`), hotplug disconnect watchdogs, sleep/wake observers, a quit watchdog, and an emergency global restore shortcut (**`⌃⌥⌘R`**).
3. **Per-Monitor Profiles & Hotplug Memory:** Automatically restores resolution, refresh rate, HDR state, combined brightness, hardware volume, Main Display designation, and internal-screen state ~1.5s after cable connection.
4. **Combined Brightness & HDR Dimming:** Seamless hardware DDC/CI (`VCP 0x10`) in SDR, transitioning smoothly to a private, non-leaking software dimming overlay (`sharingType = .none`) below hardware 0% or when HDR mode locks out DDC brightness.
5. **Hybrid Blue Light / Night Shift:** Hardware `CBBlueLightClient` integration plus a calibrated warm software fallback for external monitors and HDR mode, running on an automatic local schedule (`18:00–05:00` default).
6. **Hardware Volume with Native Routing Respect:** Controls external monitor speakers via DDC/CI (`VCP 0x62`/`0x8D`) *only* when the external monitor is macOS's active CoreAudio output. MacBook speakers, wired headphones, and Bluetooth audio are passed untouched to native macOS volume controls.

---

## v1.0 Implemented Features

### 1. Display Connection & Soft-Disconnect
- **Lid-Open Internal Display Off:** Safely toggles the MacBook screen off using private WindowServer / SkyLight session configuration (`SLSConfigureDisplayEnabled` / `CGSConfigureDisplayEnabled`).
- **Single-Display Guard:** Refuses to disable the built-in screen unless at least one active external display is connected and online.
- **Auto-Restore Watchdogs:** Instantly recovers the internal display if the external cable is unplugged, if waking without an external display, or when quitting the app (`applicationWillTerminate`).
- **Emergency Restore:** Press **`⌃⌥⌘R`** at any time to re-enable all online displays, reset all overlays, and restore default display state.

### 2. Per-Monitor Profiles & Hotplug Automation
- **Persistent Composite Keys:** Monitors are identified by Vendor, Model, and Serial Number (with EDID UUID fallback).
- **Automated Reconnect Restore:** Known monitors restore resolution, refresh rate, HDR, brightness, DDC volume, Main Display, and internal screen state.
- **Safe New-Monitor Defaults:** First-time monitors capture defaults with `autoDisableBuiltInOnConnect = false` — the internal screen is never automatically turned off for an unseen monitor until you explicitly choose to.

### 3. Combined Brightness & Dimming
- **SDR Range (20%–100%):** Direct hardware DDC/CI luminance writes over Apple Silicon `IOAVService`.
- **Sub-Zero Dimming (0%–20%):** DDC hardware stays at minimum while a borderless `NSWindow` overlay smoothly dims the display for late-night work.
- **Automatic HDR Transition:** When HDR locks DDC brightness (standard on Samsung Odyssey G9 and many HDR panels), the pipeline seamlessly transitions to software overlay dimming so keyboard keys (`F1`/`F2`) and menu bar sliders continue working without interruption.
- **Zero Screen-Capture Leakage:** Every dimming overlay uses `window.sharingType = .none`, guaranteeing screenshots, Zoom/Teams screen shares, and QuickTime recordings stay clean and un-dimmed.

### 4. Hybrid Blue Light / Night Shift
- **Dual Pipeline:** Uses native macOS `CoreBrightness` (`CBBlueLightClient`) where supported, and automatically blends a calibrated warm color overlay on external displays or in HDR mode where native Night Shift is locked.
- **Configurable Schedule:** Default `18:00` to `05:00` local time (`Europe/Warsaw` fallback), with customizable start/end times and smooth gradual fade transitions.

### 5. Hardware Audio & Volume
- **DDC/CI Volume Control:** Adjust external monitor volume via menu bar slider or keyboard keys (`F10`/`F11`/`F12`).
- **Strict macOS Audio Respect:** Media keys are intercepted *only* when the monitor is the active default CoreAudio output device. Selecting audio devices remains entirely in macOS Control Center.

### 6. Native Modes, HDR & Display Utilities
- **Native Resolutions & Refresh Rates:** Discovers native 1:1 modes (`5120×1440`), native HiDPI modes (`3840×1080 HiDPI`), and full refresh rates (60Hz, 120Hz, 240Hz) via CoreGraphics without virtual-display overhead.
- **HDR Toggle:** Per-monitor HDR switch persisted across reconnects.
- **Set as Main Display:** One-click assignment of the primary display origin `(0,0)`, Dock, and menu bar.
- **Display Mirroring & Rotation:** 0°, 90°, 180°, and 270° rotation, plus display mirroring.
- **DDC Input Source Switching:** Quick-switch monitor inputs via DDC VCP `0x60` (DisplayPort 1/2, HDMI 1/2, USB-C).

### 7. Global Shortcuts, Media Keys & Translucent OSD
- **Keyboard Interception:** Intercepts brightness and volume media keys via `CGEventTap` targeting the screen under the mouse cursor (or synchronizing all displays).
- **Translucent OSD HUD:** macOS-styled floating HUD displaying brightness, volume, mute state, or status notices at the highest window level.
- **Launch at Login:** Native `SMAppService.mainApp` toggle in Settings.

---

## System Requirements & Permissions

- **Operating System:** macOS 14.0 (Sonoma) or newer
- **Architecture:** Apple Silicon (`arm64`)
- **Permissions:**
  - **Accessibility (`AXIsProcessTrusted`):** Required for keyboard brightness/volume media-key interception and global hotkeys. The app remains fully functional via menu bar sliders even before granting Accessibility.
  - **Screen Recording Permission:** **NOT required.** Dimming and warm tint overlays use `window.sharingType = .none`, which completely shields them from screen captures without requiring any screen recording permissions.

---

## Build, Test & Install Instructions

### Prerequisites
- macOS 14.0+ on Apple Silicon (`arm64`)
- Xcode 15+ (tested on Xcode 16) with command line tools
- XcodeGen: `brew install xcodegen`
- Note: System Swift compiler at `/usr/bin/swift` is used by build scripts.

### 1. Generate Xcode Project
```bash
xcodegen generate
```
This generates `openBetterDisplay.xcodeproj` with the `OpenBetterDisplayCore` static framework, `openBetterDisplay` app, and `openBetterDisplayTests` unit test bundle.

### 2. Run Test Suite
```bash
xcodebuild \
  -project openBetterDisplay.xcodeproj \
  -scheme openBetterDisplay \
  -destination 'platform=macOS,arch=arm64' \
  test
```
Runs the complete 210-test suite covering failsafe watchdog logic, DDC packet framing and error recovery, combined brightness curves, Night Shift schedule math, profile persistence, and HUD levels.

### 3. Build Signed Release App
```bash
./scripts/build-app.sh
```
Builds `openBetterDisplay.app` in `.derived/Build/Products/Release/openBetterDisplay.app` with Hardened Runtime enabled, non-sandboxed entitlements, and automatic code signing.

### 4. Install Locally
```bash
./scripts/install.sh
```
Builds the app, installs it into `/Applications/openBetterDisplay.app`, removes quarantine attributes, and launches the menu bar application.

### 5. Build Notarized Developer ID Release DMG
```bash
./scripts/release.sh 1.0.0
# Or also create a GitHub release:
./scripts/release.sh 1.0.0 --gh
```
Archives the Release build, exports using Developer ID certificate (`ExportOptions.plist`), packages a compressed `.dmg` in `dist/`, submits to Apple `notarytool`, staples the notarization ticket, and validates Gatekeeper compliance (`spctl`).

---

## Distribution: Developer ID vs. Mac App Store

`openBetterDisplay` is distributed directly as a notarized Developer ID DMG via GitHub Releases.

**Why not the Mac App Store?**  
App Store sandbox rules strictly prohibit:
1. Session-scoped display reconfiguration and disabling the internal panel (`SkyLight.framework` / `CoreGraphics`).
2. Private HDR mode switching (`CoreDisplay.framework` / `MonitorPanel.framework`).
3. Hardware DDC/CI communication over Apple Silicon IOKit (`IOAVService`).
4. Global keyboard media-key interception (`CGEventTap`).

Direct Developer ID distribution with Apple Notarization provides a verified Gatekeeper install experience while allowing full, direct control over external monitor hardware.

---

## Documentation

- [Full Product & Technical Specification (docs/SPEC.md)](docs/SPEC.md)

---

## License

Released under the [MIT License](LICENSE).  
Copyright (c) 2026 pisze-programy.
