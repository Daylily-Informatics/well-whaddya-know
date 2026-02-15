# App Store Notes

This document covers entitlements, privacy manifest, and App Store compliance for WellWhaddyaKnow.

## Entitlements

### WellWhaddyaKnow.app

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.daylily.wellwhaddyaknow</string>
    </array>
</dict>
</plist>
```

### wwkd (Background Agent)

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.daylily.wellwhaddyaknow</string>
    </array>
</dict>
</plist>
```

## Privacy Manifest

Each target requires a `PrivacyInfo.xcprivacy` file declaring use of required reason APIs.

### Required Reason APIs Used

| API Category | Reason | Usage |
|--------------|--------|-------|
| File timestamp APIs | `DDA9.1` | Checking database file modification time |
| System boot time APIs | `35F9.1` | Monotonic timestamp for event ordering |
| User defaults APIs | `CA92.1` | Storing user preferences |

### PrivacyInfo.xcprivacy Template

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>DDA9.1</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategorySystemBootTime</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>35F9.1</string>
            </array>
        </dict>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

## Permission Prompts

### Accessibility Permission

The app requests Accessibility permission to capture window titles. This is optional but recommended.

**Usage description (Info.plist):**
```xml
<key>NSAccessibilityUsageDescription</key>
<string>WellWhaddyaKnow uses Accessibility to capture window titles for more detailed time tracking. Without this permission, only application names are recorded.</string>
```

> ⚠️ **Dual-permission requirement**: Accessibility must be granted to **both** the GUI app
> (`WellWhaddyaKnow.app`) and the agent binary (`wwkd` inside `.app/Contents/MacOS/`).
> The agent is the process that actually captures window titles. Adding `wwkd` to the
> Accessibility list may produce **no visible change** in System Settings — this is normal
> macOS TCC behavior. The permission is recorded internally regardless.

### Behavior When Denied

- App continues to function normally
- Only application names are recorded
- Window titles show as "unavailable"
- User can grant permission later via System Settings → Privacy & Security → Accessibility
- The **Agent** tab in Preferences shows per-process Accessibility status (GUI app vs agent)

## Background Agent Registration

The agent uses `SMAppService` (macOS 13+) for login item registration:

```swift
import ServiceManagement

let service = SMAppService.agent(plistName: "com.daylily.wellwhaddyaknow.agent.plist")
try service.register()
```

Users can disable the agent in System Settings → General → Login Items.

## CLI Exclusion

**The Mac App Store build does NOT include the CLI (`wwk`).**

- CLI is distributed separately via Homebrew and direct download
- No command-line executables in the App Store bundle
- CLI functionality is available through the Viewer window

## App Store Review Notes

### What the App Does

WellWhaddyaKnow is a local-only time tracker that records which applications were in the foreground while the user's screen was unlocked. All data stays on the device.

### Permissions Requested

- **Accessibility (optional)**: To capture window titles for more detailed tracking

### No Network Access

The app makes zero network connections. All data is stored locally.

### No Analytics

No third-party analytics or telemetry SDKs are included.

