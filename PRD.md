# Govee Bar — Product Requirements Document

## Overview

**Govee Bar** is a native macOS menu bar app that automatically controls Govee RGBIC TV light bars based on whether the Apple Studio Display is connected and whether the Mac is locked or unlocked.

## Problem

Manually toggling desk lighting every time you sit down, walk away, lock your screen, or unplug from your monitor is tedious. The lights should just *know*.

## Solution

A lightweight, always-running menu bar app that monitors two system signals — display connection state and lock/unlock state — and sends on/off commands to Govee light bars over the local network.

---

## User Stories

| # | Story | Trigger | Action |
|---|-------|---------|--------|
| 1 | Unlock Mac while Studio Display is connected | `screenIsUnlocked` + Studio Display present | Lights **ON** |
| 2 | Lock Mac while Studio Display is connected | `screenIsLocked` | Lights **OFF** |
| 3 | Disconnect Studio Display while Mac is unlocked | Display removed from `NSScreen.screens` | Lights **OFF** |
| 4 | Connect Studio Display while Mac is unlocked | Display added to `NSScreen.screens` | Lights **ON** |
| 5 | Launch app | App starts | Evaluate current state → lights on or off accordingly |
| 6 | Click menu bar icon | User clicks icon | Toggle lights on/off (manual override) |

---

## Architecture

### Platform & Language
- **Swift 5.9+** / **SwiftUI**
- **MenuBarExtra** (macOS 13+) for the menu bar presence
- Minimum deployment target: **macOS 15.0** (Sequoia) — keeps things modern
- Xcode project, no third-party dependencies

### Menu Bar UI

**Icon**: A small light/lamp glyph (SF Symbols, e.g. `light.strip.2` or `lightbulb.fill`). Tinted/colored when lights are on, monochrome when off.

**Click behavior**: Single click toggles lights on/off (manual override).

**Menu (right-click or long-press, or via a dropdown affordance)**:
- **Status line**: "Studio Display: Connected / Not Connected"
- **Status line**: "Lights: On / Off"
- **Divider**
- **Settings...**  → opens a settings window:
  - **General**
    - Launch at login toggle (default: on)
    - Enable/disable automatic control toggle
  - **Devices**
    - Govee API Key (stored in macOS Keychain)
    - Device discovery + selection (which Govee device to control)
    - Control method preference: LAN (default) / Cloud API / Auto
  - **Display**
    - Target display: Apple Studio Display (hardcoded initially; configurable later)
  - **Effects**
    - On/off transition: Instant (default) or Fade
    - Fade duration (if fade enabled)
    - Brightness level (1–100)
    - Color / color temperature (future)
- **Divider**
- **Quit Govee Bar**

### System Event Detection

**Display connection monitoring:**
- Use `CGDisplayRegisterReconfigurationCallback` to detect display changes
- Identify Apple Studio Display by vendor ID (`0x610`) and model ID
- Alternatively, match by display name via `CGDisplayCopyDisplayMode` / `NSScreen.localizedName`

**Lock/Unlock detection:**
- Subscribe to `DistributedNotificationCenter.default()`:
  - `com.apple.screenIsLocked` → locked
  - `com.apple.screenIsUnlocked` → unlocked

**State machine:**

```
                    ┌─────────────┐
                    │  App Launch  │
                    └──────┬──────┘
                           │
                    Evaluate current state
                           │
              ┌────────────┴────────────┐
              │                         │
     Display connected?           Display absent?
     AND unlocked?                OR locked?
              │                         │
         Lights ON                 Lights OFF
              │                         │
              └────────┬────────────────┘
                       │
                 Listen for events
                       │
         ┌─────────────┼─────────────┐
         │             │             │
    Lock event    Unlock event   Display change
         │             │             │
    Lights OFF    Re-evaluate    Re-evaluate
```

### Govee Control Layer

**Primary: LAN Control (UDP)**
- **Discovery**: Send UDP multicast to `239.255.255.250:4001`, listen on port `4002`
  ```json
  {"msg":{"cmd":"scan","data":{"account_topic":"reserve"}}}
  ```
- **Turn on**: UDP unicast to device IP on port `4003`
  ```json
  {"msg":{"cmd":"turn","data":{"value":1}}}
  ```
- **Turn off**:
  ```json
  {"msg":{"cmd":"turn","data":{"value":0}}}
  ```
- **Status query**:
  ```json
  {"msg":{"cmd":"devStatus","data":{}}}
  ```
- **Color control** (future):
  ```json
  {"msg":{"cmd":"colorwc","data":{"color":{"r":255,"g":180,"b":100},"colorTemInKelvin":0}}}
  ```
- **Brightness** (future):
  ```json
  {"msg":{"cmd":"brightness","data":{"value":80}}}
  ```

**Fallback: Cloud API**
- Base URL: `https://openapi.api.govee.com/router/api/v1`
- Auth header: `Govee-API-Key: <key>`
- **List devices**: `GET /user/devices`
- **Control device**: `POST /device/control`
  ```json
  {
    "requestId": "uuid",
    "payload": {
      "sku": "<model>",
      "device": "<device-id>",
      "capability": {
        "type": "devices.capabilities.on_off",
        "instance": "powerSwitch",
        "value": 1
      }
    }
  }
  ```
- Rate limit: 10,000 requests/day

**Control strategy:**
1. On app launch, discover devices via LAN multicast
2. Cache discovered device IPs
3. For on/off commands, send via LAN UDP (fast, <50ms)
4. If LAN fails (no response after 2 retries, 500ms timeout each), fall back to cloud API
5. Periodically re-discover devices (every 5 minutes) to handle IP changes

### Data Storage

| Data | Storage |
|------|---------|
| Govee API key | macOS Keychain |
| Device list (SKU, device ID, IP, name) | UserDefaults or a small JSON file in Application Support |
| Preferences (launch at login, control method, etc.) | UserDefaults |

### Permissions & Entitlements

- **Network access**: Local network (UDP multicast + unicast) and outbound HTTPS
- **Login item**: `SMAppService` for launch-at-login (modern API, no helper app needed)
- **No accessibility permissions needed**
- **No screen recording permissions needed**
- Sandbox-compatible (local network entitlement + outgoing connections)

---

## Milestones

### M1 — Foundation
- [ ] Xcode project setup (SwiftUI app lifecycle, menu bar only)
- [ ] Menu bar icon with basic menu (status, quit)
- [ ] Detect Studio Display connection/disconnection
- [ ] Detect lock/unlock events
- [ ] State machine combining both signals

### M2 — Govee LAN Control
- [ ] UDP multicast device discovery
- [ ] Turn lights on/off via LAN
- [ ] Device status query
- [ ] Wire state machine → light control

### M3 — Settings & Polish
- [ ] Settings window (API key, device selection, preferences)
- [ ] Keychain storage for API key
- [ ] Cloud API fallback
- [ ] Launch at login (SMAppService)
- [ ] Manual toggle via menu bar icon click
- [ ] App icon

### M4 — Future Enhancements
- [ ] Color control (warm white for daytime, cool for evening, etc.)
- [ ] Brightness control
- [ ] Time-based color temperature shifts
- [ ] Segment color control (different colors per bar section)
- [ ] Keyboard shortcut for toggle

---

## Decisions — Resolved

| # | Question | Decision |
|---|----------|----------|
| 1 | Detect only Apple Studio Display, or any external monitor? | **Studio Display by default**, hardcoded initially. Make the target display configurable in Settings (future). |
| 2 | Launch at login? | **Yes**, enabled by default. Configurable in Settings. |
| 3 | Menu bar UI style? | Click = toggle, menu via right-click / dropdown. Status + settings in the menu. |
| 4 | Both light bars controlled together? | **Yes** — they're a single controller. Single on/off command controls both. Gradient/segment effects possible later. |
| 5 | Instant on/off or fade transition? | **Configurable in Settings.** Default to instant. Option to enable fade with adjustable duration. |

---

## Technical References

- [Govee LAN Control Protocol](https://app-h5.govee.com/user-manual/wlan-guide)
- [Govee Cloud API v1](https://developer.govee.com)
- [MenuBarExtra (SwiftUI)](https://developer.apple.com/documentation/swiftui/menubarextra)
- [CGDisplayRegisterReconfigurationCallback](https://developer.apple.com/documentation/coregraphics/1455
336-cgdisplayregisterreconfigurationcallback)
- [DistributedNotificationCenter](https://developer.apple.com/documentation/foundation/distributednotificationcenter)
- [SMAppService (Launch at Login)](https://developer.apple.com/documentation/servicemanagement/smappservice)
