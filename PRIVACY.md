# Privacy Policy

**Last updated:** February 2026

WellWhaddyaKnow is a **local-only** time tracking application. This document describes what data is collected, where it is stored, and how it is used.

## Summary

- ✅ All data stays on your device
- ✅ No cloud sync
- ✅ No telemetry or analytics
- ✅ No network connections
- ✅ You control your data completely

## Data Collected

### What We Collect

| Data Type | Description | Purpose |
|-----------|-------------|---------|
| **Timestamps** | When your screen was unlocked/locked | Determine working intervals |
| **Foreground App** | Bundle ID and display name of the active application | Track which apps you used |
| **Window Title** | Title of the frontmost window (requires Accessibility permission) | More detailed activity tracking |
| **User Edits** | Deleted ranges, added ranges, tags you create | Allow you to correct and categorize your time |
| **Machine Identity** | Locally-generated UUID for this machine | Distinguish data if you use multiple Macs |

### What We Do NOT Collect

- ❌ Keystrokes
- ❌ Mouse movements or clicks
- ❌ Screenshots
- ❌ File contents
- ❌ Clipboard contents
- ❌ Network traffic
- ❌ Location data
- ❌ Contacts or calendar data
- ❌ Any data from other applications

## Data Storage

All data is stored locally in a SQLite database:

```
~/Library/Group Containers/group.com.daylily.wellwhaddyaknow/WellWhaddyaKnow/wwk.sqlite
```

### Storage Characteristics

- **Local only**: Data never leaves your machine
- **Append-only**: Raw events are immutable (never modified)
- **User-controlled**: You can delete all data at any time via Preferences

## Data Sharing

**We do not share your data with anyone.**

- No cloud services
- No analytics providers
- No advertising networks
- No third parties of any kind

The application makes **zero network connections**.

## Permissions

### Accessibility Permission (Optional)

If you grant Accessibility permission, the app can capture window titles for more detailed tracking. Without this permission:

- The app still functions normally
- Only application names are recorded (not window titles)
- No functionality is lost, just less detail

### How to Revoke

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Remove `WellWhaddyaKnow.app` and `wwkd` from the list

## Your Rights

### View Your Data

- Use the Viewer window in the app
- Use the CLI: `wwk summary --from <date> --to <date>`
- Open the SQLite database directly with any SQLite viewer

### Export Your Data

- Use the Export tab in the Viewer window
- Use the CLI: `wwk export --from <date> --to <date> --format csv --out data.csv`

### Delete Your Data

- Use Preferences → Data → "Delete All Data"
- Or manually delete the SQLite file at the path shown above

### Modify Your Data

- Use the Edit commands to delete or add time ranges
- Apply tags to categorize your time
- All edits are recorded as separate events (original data preserved)

## Children's Privacy

This application does not knowingly collect data from children under 13. The app is designed for personal productivity tracking by adults.

## Changes to This Policy

If we make changes to this privacy policy, we will update the "Last updated" date at the top. Significant changes will be noted in release notes.

## Contact

For privacy questions or concerns:

- GitHub Issues: https://github.com/Daylily-Informatics/well-whaddya-know/issues
- Email: privacy@daylily-informatics.com

## Open Source

This application is open source under the MIT License. You can review the source code to verify our privacy claims:

https://github.com/Daylily-Informatics/well-whaddya-know

