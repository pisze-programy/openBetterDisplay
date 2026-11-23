# openBetterDisplay — Product & Technical Specification

**Repository:** `https://github.com/pisze-programy/openBetterDisplay.git`  
**License:** MIT  
**Target Platform:** macOS 14.0 (Sonoma) and newer, Apple Silicon (`arm64`)  
**Language & UI:** Swift 6, SwiftUI, AppKit / CoreGraphics / IOKit  

---

## 1. Executive Summary & Vision

`openBetterDisplay` is a lightweight, open-source **"Essential BetterDisplay"** alternative for macOS, focused on delivering a fast, reliable daily workflow for MacBook users working with external monitors — including super-ultrawide panels such as the **Samsung Odyssey G9 49" (`LC49G95T`)**.

Many users do not need a complex virtual-screen studio (Picture-in-Picture streaming, dummy screen salvaging, 3D LUTs, or custom EDID injection), yet they rely daily on capabilities that macOS leaves out or locks down:

1. **Soft-disconnecting the built-in MacBook display** while keeping the lid open (preserving Touch ID, keyboard, and trackpad access) with an airtight failsafe so the internal display *always* recovers on cable unplug, wake, app quit, or hotkey.
2. **Per-monitor state memory & hotplug automation** — automatically restoring resolution, refresh rate, HDR mode, brightness, hardware volume, Main Display designation, and internal-display state when reconnecting a known external monitor.
3. **Seamless Combined Brightness & Hybrid Blue Light / Night Shift** — controlling external displays with hardware keyboard keys (`F1`/`F2`) and menu bar sliders even when HDR locks out DDC/CI or native macOS Night Shift stops working.

---

## 2. BetterDisplay Feature Comparison Matrix

This matrix compares BetterDisplay (Free + Pro) capabilities across 8 functional categories against the planned scope for `openBetterDisplay`:

| Category | BetterDisplay Capabilities (Free & Pro) | `openBetterDisplay` Status | Notes & Rationale |
|---|---|---|---|
| **1. Display Connection & Management** | Soft-disconnect / reconnect physical displays (`Built-in Display` OFF with lid open), Set as Main Display, Mirror Display, Screen Rotation, Configuration Protection | **v1.0 MVP** | Core feature: Built-in soft-disconnect + strict failsafe watchdog, Set as Main Display, Mirror Display, and Screen Rotation (0°/90°/180°/270°). |
| **2. Brightness & Dimming** | Hardware DDC/CI (`IOAVService`), software overlay / gamma dimming, Combined Brightness, multi-monitor sync, `F1`/`F2` interception + OSD, XDR/SDR Brightness Upscaling | **v1.0 MVP** *(Upscaling → v1.2+)* | Combined Brightness (DDC/CI in SDR + `sharingType = .none` overlay below hardware 0% and in HDR), cursor-targeted or synced `F1`/`F2` keys, translucent OSD. XDR Brightness Upscaling deferred to v1.2+. |
| **3. Audio** | Hardware volume via DDC/CI, mute toggle, software volume fallback | **v1.0 MVP** *(DDC Volume)* | DDC/CI volume slider + conditional media-key interception *only* when the external monitor is macOS's active audio output; respects macOS native audio routing otherwise. |
| **4. HDR, Color & Eye Care** | `Enable HDR Mode` toggle, Night Shift on external monitors/TVs, ICC/Color modes, 3D LUTs, calibration tweaks, dithering/PWM mitigation | **v1.0 MVP** *(HDR + Night Shift)* | Per-monitor `Enable HDR Mode` toggle + Hybrid Blue Light / Night Shift (`CoreBrightness` + warm software fallback, default `18:00–05:00` local time). 3D LUTs & ICC calibration are Out of Scope. |
| **5. Resolution & HiDPI** | Native & scaled modes, Hz picker, forced custom HiDPI via Virtual Display mirroring, EDID overrides, display renaming | **v1.0 MVP** *(Native CG)*; *(Forced HiDPI → v1.2+)* | Public CoreGraphics exposes native 1:1 (`5120×1440`), native HiDPI (`3840×1080 HiDPI` on `LC49G95T`), and 60/120/240 Hz safely. Forced HiDPI/Virtual Display deferred to v1.2+. |
| **6. Hardware Control (Monitor OSD)** | DDC Input Source switching (DP / HDMI1 / HDMI2 / USB-C), DDC Power Off/On, Image Adjustments (contrast, sharpness) | **v1.0 MVP** *(Input Source)* | `Input Source` DDC switching (`VCP 0x60`) included in v1.0 for quick switching on multi-input monitors like Odyssey G9. |
| **7. Virtual Displays & Streaming** | Virtual Screens (Dummies), Picture-in-Picture (PiP), Stream Display, Teleprompter flip, Broken Screen Salvaging | **Out of Scope** | Deliberately excluded to avoid unnecessary complexity and keep the app small, fast, and maintainable. |
| **8. Automation, Profiles & Integration** | Per-monitor remembered settings, global keyboard shortcuts, Launch at Login, CLI tool, config export/import | **v1.0 MVP** *(Profiles, Shortcuts, Autostart)*; *(CLI & Export → v1.1)* | Automatic per-monitor hotplug restore & global shortcuts in v1.0; CLI (`openbetterdisplay-cli`), Sparkle updates, EN+PL localization, and profile import/export in v1.1. |

---

## 3. Core Functional Requirements (v1.0)

### 3.1 Built-in Display Soft-Disconnect & Reconnect
- Allows disabling and re-enabling the MacBook's internal display while the lid remains open (keeping keyboard, trackpad, and Touch ID active).
- Uses dynamic symbol resolution (`dlopen` / `dlsym`) for `SLSConfigureDisplayEnabled` in `/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight`, with fallback to `CGSConfigureDisplayEnabled` in `CoreGraphics`.
- Wraps display changes inside a CoreGraphics transaction (`CGBeginDisplayConfiguration` → `SLSConfigureDisplayEnabled` → `CGCompleteDisplayConfiguration(..., .forSession)`), identifying the built-in panel via `CGDisplayIsBuiltin(displayID) != 0`.
- Uses **session-scoped configuration (`kCGConfigureForSession`)** rather than permanent NVRAM/WindowServer persistence so a logout or reboot always recovers the internal display cleanly.

### 3.2 Failsafe Policy (Zero Black-Screen Guarantee)
Because disconnecting the only active display can leave the Mac locally unusable, v1.0 enforces multiple redundant safety layers:

1. **Single-Display Guard:** The app MUST refuse to disable the built-in display unless at least one other online, active external display exists in `CGGetOnlineDisplayList`.
2. **Instant Disconnect Watchdog (`CGDisplayRegisterReconfigurationCallback`):** Whenever a display reconfiguration occurs and zero active external displays remain (e.g., cable unplugged or monitor powered off), immediately re-enable the built-in display.
3. **Wake Watchdog (`NSWorkspace.didWakeNotification`):** On system wake, verify active external displays; if none are present (or the external handshake fails), immediately re-enable the built-in display.
4. **Restore on Quit:** When the user quits `openBetterDisplay`, the app MUST automatically re-enable the built-in display before terminating (because the hotplug watchdog will no longer be running to restore it if the cable is unplugged later).
5. **Instant Switching (No Popups):** Transitions happen immediately with zero confirmation dialogs or countdown modals.
6. **Global Emergency Restore Hotkey:** A user-configurable global shortcut (default: **`⌃⌥⌘R`**) immediately re-enables all online displays, resets software dimming/warmth overlays to neutral, and makes the internal display active if needed.
7. **Session-Only State (`kCGConfigureForSession`):** Even in the event of a crash or `kill -9`, rebooting or logging out restores the internal screen automatically.

### 3.3 Per-Monitor Profiles & Automatic Switching
- Every external monitor is identified by a persistent composite key derived from `CGDisplayVendorNumber(id)`, `CGDisplayModelNumber(id)`, and `CGDisplaySerialNumber(id)` (with UUID/EDID fallback when serial number is zero or omitted by a display).
- Each monitor profile persists:
  - Target resolution (`width`, `height`, `pixelWidth`, `pixelHeight`, `refreshRate`, `isHiDPI`)
  - Target `hdrEnabled` state
  - Target `combinedBrightness` level (0.0–1.0)
  - Target `ddcVolume` level (0–100) and mute state
  - Target `isMainDisplay` preference
  - Target `builtInDisplayEnabled` state (`true` / `false`) when this external monitor is connected
  - Preferred `rotation` (0° / 90° / 180° / 270°)
- **Hotplug Automation Flow:**
  - When an external monitor is attached (`CGDisplayRegisterReconfigurationCallback` add/online event), wait **~1.5 seconds** (debounced) for DisplayPort / USB-C link training and EDID/audio enumeration to stabilize.
  - **Known Monitor:** Automatically apply the saved profile in deterministic order: resolution/Hz → HDR state → brightness → Main Display → built-in display ON/OFF state.
  - **New (Unseen) Monitor:** Capture its current state into a new default profile, and **never automatically disable the Built-in Display** until the user explicitly toggles it OFF for that monitor.

### 3.4 Combined Brightness Control (DDC/CI + Software Overlay)
- **Hardware Layer (SDR):** Communicates over Apple Silicon `IOAVService` using DDC/CI VCP code **`0x10`** (Luminance) via the MIT-licensed `Arm64DDC` library.
- **Software Dimming Layer:** A borderless, full-display `NSWindow` per screen positioned at screen-saver/shield window level:
  - `ignoresMouseEvents = true`
  - `collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]`
  - `sharingType = .none` (crucial: ensures screenshots, screen sharing, and screen recordings remain clean and un-dimmed).
- **Combined Mapping:**
  - **In SDR (when DDC is supported):** Slider values from `20%–100%` (or user-tunable knee point) map across `0–100%` hardware DDC brightness; values below the knee point (`0%–20%`) keep hardware DDC at minimum (`0`) and smoothly engage the software dimming overlay for comfortable late-night use.
  - **In HDR or when DDC is unsupported:** Many monitors (including Samsung Odyssey G9 `LC49G95T`) ignore or lock DDC `0x10` while HDR is active. When HDR is enabled (or DDC brightness writes fail/are unsupported), `openBetterDisplay` automatically transitions brightness control to the software dimming overlay so `F1`/`F2` and the menu bar slider continue working smoothly.

### 3.5 Hybrid Blue Light / Night Shift
- Designed to solve macOS's limitation where native Night Shift disables itself on certain external displays or in HDR mode.
- **Hybrid Implementation:**
  1. Controls native macOS Night Shift via `CoreBrightness` (`CBBlueLightClient`, loaded dynamically) when supported by the target display/state.
  2. Applies a calibrated warm tint (`NSWindow` multiply/color overlay with `sharingType = .none` and `ignoresMouseEvents = true`, or gamma table fallback in SDR) on external displays / HDR sessions where native Night Shift is unavailable or overridden.
- **Schedule & Controls:**
  - Automatic schedule using the **MacBook's current system time zone** (`TimeZone.current`, with `Europe/Warsaw` as default fallback reference).
  - Default active window: **`18:00` to `05:00`**, fully customizable by the user (start time, end time, enable/disable schedule).
  - Smooth fade transition at schedule boundaries (configurable, e.g., 15–30 minutes or instant).
  - Color warmth slider (Kelvin/intensity) and one-click toggle in the menu bar popover.

### 3.6 Audio & Volume Control
- **Strict Separation from macOS Audio Routing:** `openBetterDisplay` does **not** include an audio output switcher; selecting between MacBook speakers, headphones, Bluetooth devices, or monitor audio remains exclusively in macOS Control Center / System Settings.
- **Native Output Behavior:** Whenever macOS's default audio output (`CoreAudio` `kAudioHardwarePropertyDefaultOutputDevice`) is MacBook speakers, wired headphones, or Bluetooth audio, `openBetterDisplay` passes volume keys (`F10`/`F11`/`F12`) straight through to macOS untouched.
- **Monitor Output Behavior:** When macOS's active default audio output device belongs to a connected external monitor (where macOS normally shows a disabled "prohibited" volume HUD), `openBetterDisplay` intercepts volume/mute media keys and sends DDC/CI VCP **`0x62`** (Audio Speaker Volume) and **`0x8D`** (Audio Mute) commands to that monitor, displaying our OSD HUD.
- **Popover Control:** A `Volume (Hardware)` DDC slider is always accessible in the menu bar popover for direct adjustment of the selected monitor's DDC volume.

### 3.7 Native Resolution, Refresh Rate & HiDPI Modes
- Enumerates all modes via public CoreGraphics `CGDisplayCopyAllDisplayModes(displayID, [kCGDisplayShowDuplicateLowResolutionModes: true])` and applies changes via `CGConfigureDisplayWithDisplayMode`.
- Surfaces:
  - Native 1:1 resolution (e.g., `5120 × 1440` on `LC49G95T`),
  - Native macOS HiDPI resolutions (e.g., `3840 × 1080 HiDPI`, `3360 × 945 HiDPI`, `3200 × 900 HiDPI`, `2560 × 720 HiDPI`),
  - All reported refresh rates (`60 Hz`, `120 Hz`, `240 Hz` depending on cable/DSC/DP version).
- **Architectural Rationale (v1.0):** Avoiding `CGVirtualDisplay` mirroring and custom EDID injection in v1.0 keeps input lag at zero, avoids extra GPU memory/bandwidth overhead, preserves native HDR compatibility, and avoids breakage across macOS updates. Furthermore, Apple Silicon M1 Pro enforces a **7680 px** horizontal framebuffer cap, meaning `3840 × 1080 HiDPI` (`7680 × 2160` backing pixels) is already the physical ceiling and is exposed natively without hacks. Forced HiDPI for atypical 16:9 displays is left for v1.2+.

### 3.8 HDR Control
- Provides an `Enable HDR Mode` toggle for HDR-capable external displays using dynamically resolved symbols from `CoreDisplay.framework` (`CoreDisplay_Display_SetHDRModeEnabled` / `CoreDisplay_Display_IsHDRModeEnabled`) and/or `MonitorPanel.framework` (`MPDisplay`).
- Persists HDR state per monitor profile and restores it automatically upon hotplug.
- Coordinates cleanly with **Combined Brightness** (switching to overlay dimming when monitor DDC brightness locks in HDR) and **Hybrid Night Shift** (maintaining warm overlay in HDR).
- XDR/SDR Brightness Upscaling (pushing SDR white levels above nominal display limits via Metal EDR) is deferred to v1.2+.

### 3.9 Display Utilities
- **Set as Main Display:** Moves the macOS primary display origin `(0, 0)` and menu bar/Dock anchor via `CGConfigureDisplayOrigin` so the target display becomes Main (`[M]`).
- **Mirror Display:** Enables/disables mirroring between displays via `CGConfigureDisplayMirrorOfDisplay`.
- **Screen Rotation:** Supports `0°`, `90°`, `180°`, and `270°` rotation for displays exposing rotation capability.
- **Input Source (DDC/CI):** Allows switching physical monitor inputs via VCP **`0x60`** (Input Source), mapping standard MCCS values (e.g., DisplayPort 1 `0x0F`, DisplayPort 2 `0x10`, HDMI 1 `0x11`, HDMI 2 `0x12`, USB-C/DP Alt `0x1B` or user-editable/probed presets for monitors like `LC49G95T`).

### 3.10 Keyboard Shortcuts, Media Keys & OSD
- **Media Key Interception (`CGEventTap`):**
  - Captures system-defined media events (`NX_SYSDEFINED`: brightness up/down, and volume up/down/mute only when the monitor is the active CoreAudio output).
  - Supports both built-in MacBook function keys and external Apple/third-party keyboards.
- **Multi-Monitor Brightness Targeting:**
  - **Default:** Brightness keys adjust the **display currently under the mouse cursor** (`NSEvent.mouseLocation` mapped to screen bounds).
  - **Optional Setting:** "Synchronize brightness across all active displays".
- **Global Keyboard Shortcuts (v1.0):**
  - Toggle Built-in Display ON/OFF
  - Toggle HDR Mode (active/primary external display)
  - Toggle Night Shift ON/OFF
  - Emergency Restore All Displays (default `⌃⌥⌘R`)
- **On-Screen Display (OSD):**
  - Lightweight translucent macOS-styled HUD (`NSPanel`, non-activating, click-through, `sharingType = .none`) rendered on the target display showing icon, percentage/level bar for Brightness, Volume, Mute, or status notices (e.g., Night Shift / Built-in Restored).

### 3.11 Launch at Login
- Implemented using native `SMAppService.mainApp` (macOS 13+ API), toggled from General Settings.

---

## 4. UI/UX Specification

### 4.1 Menu Bar Popover
A compact, BetterDisplay-inspired SwiftUI popover (`NSStatusItem` + `NSPopover` or `MenuBarExtra(.window)`), native macOS translucency (`VisualEffect` / material), structured top-to-bottom:

1. **Display Selector & Connection Toggles (Top Card):**
   - Lists `Built-in Display` and each connected external display (e.g., `LC49G95T` with `[M]` badge if Main Display).
   - Each display row has an immediate **ON/OFF toggle** (Built-in OFF toggle disabled with tooltip if no external display is active).
   - Clicking a display card selects it as the active target for the controls below (defaulting to the primary external display when connected).
2. **Sliders Section:**
   - **`Brightness (Combined)`** — `0%–100%` slider + live indicator showing active method (`DDC`, `DDC + Dim`, or `Software/HDR`).
   - **`Volume (Hardware)`** — `0%–100%` DDC slider + quick mute icon (shown when display supports DDC audio or is enabled).
   - **`Resolution`** — smooth step slider across curated scale steps for the selected display, displaying current `Width × Height`, `HiDPI` badge, and `@ Hz`.
3. **Quick Toggles:**
   - `Enable HDR Mode`
   - `Set as Main Display`
   - `Night Shift` (with subtle schedule status badge, e.g., `Scheduled 18:00–05:00` or `Active`)
4. **Expandable Utility Sub-menus / Disclosures:**
   - `Display Mode` — full picker grouped by resolution & refresh rate (e.g., `5120×1440 @ 120Hz`, `5120×1440 @ 60Hz`, `3840×1080 HiDPI @ 60Hz`).
   - `Input Source` — DP1 / DP2 / HDMI1 / HDMI2 quick picker.
   - `Mirror Display` — mirror source selection.
   - `Screen Rotation` — 0° / 90° / 180° / 270°.
5. **Footer Bar:**
   - `Settings...` (`⌘,`)
   - Subtle tooltip/hint for Emergency Restore (`⌃⌥⌘R`)
   - `Quit` (`⌘Q`) — automatically restores Built-in Display before exiting.

### 4.2 Settings Window
Standard macOS SwiftUI `Settings` window organized into 5 tabs:

1. **General:**
   - Launch at Login (`SMAppService`)
   - Brightness key target (`Display under cursor` vs. `Sync all displays`)
   - Show On-Screen Display (OSD) toggle & duration
   - Menu bar icon style
2. **Displays & Profiles:**
   - List of remembered monitor profiles (`Vendor / Model / Serial`)
   - Per-profile toggle: "Auto-restore profile on connect" / "Auto-disable Built-in Display on connect"
   - Action to reset/forget a stored monitor profile
3. **Night Shift:**
   - Enable scheduled Blue Light filter (`18:00–05:00` default, uses local system timezone)
   - Start / End time pickers
   - Warmth / Color Temperature slider
   - Transition mode (`Gradual` vs. `Instant`) & "Also apply software fallback in HDR"
4. **Shortcuts:**
   - Recorder fields for global shortcuts:
     - Toggle Built-in Display
     - Toggle HDR Mode
     - Toggle Night Shift
     - Emergency Restore All Displays (`⌃⌥⌘R` default)
5. **Diagnostics & Permissions:**
   - Live Accessibility permission (`AXIsProcessTrusted`) status + "Open System Settings" button
   - Live DDC/CI capability probe per connected display (showing `IOAVService` match, VCP `0x10` / `0x62` / `0x60` readback, and HDR status)

---

## 5. Technical Architecture & Project Setup

### 5.1 Repository & Build Convention
Mirrors the clean XcodeGen-based structure used in `CapsAwake`:

```text
openBetterDisplay/
├── docs/
│   └── SPEC.md
├── Resources/
│   ├── Assets.xcassets
│   ├── Info.plist
│   └── openBetterDisplay.entitlements
├── Sources/
│   ├── App/                 # App entry point, MenuBarController, SettingsWindow
│   ├── Core/
│   │   ├── DisplayManager/  # CoreGraphics queries, Mode switcher, Mirror/Rotation, Main Display
│   │   ├── PrivateAPIs/     # Dynamic dlopen/dlsym bridges (SkyLight, CoreDisplay, CoreBrightness)
│   │   ├── Failsafe/        # Hotplug, sleep/wake, quit watchdog & emergency restore
│   │   ├── DDC/             # Arm64DDC wrapper (Brightness, Volume, Input Source)
│   │   ├── Overlay/         # Software dimming & warm Night Shift NSWindow managers
│   │   ├── Audio/           # CoreAudio active output device observer
│   │   ├── Profiles/        # Per-monitor JSON/UserDefaults persistence & hotplug restore
│   │   └── Input/           # CGEventTap media keys, Global Hotkeys, OSD HUD
│   └── UI/                  # Popover views, Display cards, Sliders, Settings tabs
├── Tests/                   # Unit tests for profiles, schedule math, combined brightness curve
├── scripts/                 # Build, archive, Developer ID sign, notarize, DMG packaging
├── ExportOptions.plist
├── project.yml              # XcodeGen specification
├── LICENSE                  # MIT
└── README.md
```

### 5.2 Stack, Dependencies & Signing
- **Language & Frameworks:** Swift 6, SwiftUI, AppKit, CoreGraphics, CoreAudio, IOKit, ServiceManagement.
- **External SPM Dependency:** `Arm64DDC` (MIT license) for Apple Silicon `IOAVService` DDC/CI read/write operations.
- **Architecture & OS Target:** `arm64` only in v1.0, `MACOSX_DEPLOYMENT_TARGET = 14.0`.
- **Sandboxing & Distribution:**
  - `com.apple.security.app-sandbox = false` (non-sandboxed).
  - Signed with **Developer ID Application** certificate, Hardened Runtime enabled, notarized via `notarytool`, and packaged as a `.dmg` for GitHub Releases.
  - **Why Mac App Store is incompatible:** App Store rules forbid non-sandboxed apps and private frameworks (`SkyLight.framework`, `CoreDisplay.framework`, `CoreBrightness.framework`, `IOAVService` IOKit access, and global `CGEventTap`). Direct Developer ID distribution with Apple Notarization provides a seamless Gatekeeper-verified install experience without App Store limitations.
- **Permissions:**
  - **Accessibility (`AXIsProcessTrustedWithOptions`):** Required for intercepting brightness/volume media keys via `CGEventTap` and registering global hotkeys. App remains usable via menu bar sliders even before Accessibility permission is granted, with a clear onboarding banner in the popover/Settings.

---

## 6. Known Edge Cases & Technical Risks

| Risk / Edge Case | Cause | Mitigation in `openBetterDisplay` |
|---|---|---|
| **Samsung Odyssey G9 HDR DDC lockout** | In HDR mode, `LC49G95T` (and many HDR monitors) ignores/rejects DDC `0x10` luminance writes. | Detect active HDR mode (and DDC write/read mismatches) and seamlessly switch the brightness pipeline to the `sharingType = .none` software dimming overlay. |
| **Private API symbol shifts on future macOS updates** | Apple does not guarantee ABI stability for `SkyLight`, `CoreDisplay`, or `CoreBrightness`. | Resolve all private symbols at runtime via `dlopen`/`dlsym` with version-aware fallbacks (`SLSConfigureDisplayEnabled` → `CGSConfigureDisplayEnabled`; `CoreDisplay` → `MonitorPanel`) and fail safely with diagnostic status rather than crashing. |
| **Hotplug link-training race condition** | macOS fires multiple `CGDisplayRegisterReconfigurationCallback` events while DisplayPort/USB-C negotiates resolution, HDR, and audio endpoints. | Debounce external display connection events by **~1.5 seconds** before reading monitor identity/DDC capabilities and restoring the saved profile. |
| **Sleep/Wake with lid open vs. closed** | Waking a MacBook whose lid is closed (real clamshell) vs. open while external monitor was unplugged during sleep. | On `didWakeNotification`, inspect `CGGetOnlineDisplayList` and lid state; if no external monitor is online and lid is open (or built-in panel is online), immediately ensure Built-in Display is enabled. |
| **Dimming/Night Shift tint leaking into screenshots** | Standard overlay windows appear in screenshots, Zoom screen shares, and QuickTime recordings. | Set `window.sharingType = .none` on every brightness and Night Shift overlay `NSWindow`. |
| **Accidental lockout / headless state** | Disabling internal display then quitting the app or unplugging the monitor. | Enforce >= 1 active external display guard, `kCGConfigureForSession` scope, restore Built-in ON during `applicationWillTerminate`, and bind `⌃⌥⌘R` emergency restore. |

---

## 7. Roadmap

### v1.0 (MVP — Current Target)
- Built-in Display soft-disconnect & zero-black-screen failsafe policy
- Per-monitor profiles & automatic hotplug restore (~1.5s debounce; no auto-disable on unseen monitors)
- Combined Brightness (`Arm64DDC` + software overlay) & cursor-targeted `F1`/`F2` keys
- Hybrid Blue Light / Night Shift (`CoreBrightness` + warm software fallback, default `18:00–05:00` local time)
- DDC Hardware Volume + conditional volume key interception when external monitor is active audio output
- Native CoreGraphics Resolution, Refresh Rate & HiDPI mode switching
- HDR Mode toggle (`Enable HDR Mode`)
- `Set as Main Display`, `Mirror Display`, `Screen Rotation`, DDC `Input Source` switching
- Global shortcuts, translucent OSD HUD, Launch at Login (`SMAppService`)
- XcodeGen project, Developer ID signing, Apple Notarization, `.dmg` release pipeline

### v1.1 (Automation & Polish)
- Command-line interface (`openbetterdisplay` CLI) for Apple Shortcuts, Raycast, and Stream Deck integration
- Sparkle auto-updater for GitHub Releases
- Bilingual localization (English + Polish)
- Profile & configuration JSON export/import

### v1.2+ (Advanced Display Features)
- Optional forced HiDPI / Virtual Display mirroring (`CGVirtualDisplay`) for non-HiDPI 1440p/1080p monitors
- XDR / SDR Brightness Upscaling via Metal EDR
- Intel Mac DDC/CI (`IOI2CInterface`) support for Universal Binary distribution

### Explicitly Out of Scope
- Picture-in-Picture (PiP) & Desktop/Window Streaming
- Teleprompter / Stream Flipping & Broken Screen Salvaging
- Custom 3D LUTs & Hardware Color Calibration Suites
- Built-in macOS Audio Output Device Routing
