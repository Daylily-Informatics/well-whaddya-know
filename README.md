# WellWhaddyaKnow

[![GitHub Release](https://img.shields.io/github/v/release/Daylily-Informatics/well-whaddya-know?style=flat-square&label=release)](https://github.com/Daylily-Informatics/well-whaddya-know/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square)](https://www.apple.com/macos/)

A **local-only** macOS time tracker that records how time passed on your machine by observing which application and window was frontmost while your screen was unlocked.

**No timers. No idle detection. No cloud. No telemetry.**

## What It Does

- 📊 **Automatic tracking**: Records foreground app and window title when your screen is unlocked
- 🏷️ **Tagging**: Categorize time ranges with custom tags
- ✏️ **Editing**: Delete or add time ranges, undo edits
- 📤 **Export**: CSV and JSON export with date range selection
- 🔒 **Privacy-first**: All data stays on your machine in a local SQLite database

## What It Does NOT Do

- ❌ No keystroke logging
- ❌ No screenshots
- ❌ No mouse tracking
- ❌ No "productivity scoring"
- ❌ No cloud sync
- ❌ No telemetry or analytics

## Components

| Component | Description |
|-----------|-------------|
| **WellWhaddyaKnow.app** | Menu bar app with status popover, viewer/editor, and preferences |
| **wwkd** | Background agent (login item) that writes events to SQLite |
| **wwk** | Command-line interface for reporting and editing (Homebrew/direct download) |

## Requirements

- macOS 13 (Ventura) or later
- Accessibility permission (optional, for window title capture)

## Installation

### From Source (Swift Package Manager)

```bash
git clone https://github.com/Daylily-Informatics/well-whaddya-know.git
cd well-whaddya-know
swift build -c release
```

### Homebrew (CLI only)

```bash
brew tap Daylily-Informatics/tap
brew install wwk
```

### Mac App Store

Coming soon.

## Quick Start

```bash
# Build the project
swift build

# Run tests
swift test

# Build release
swift build -c release

# The executables are in .build/release/
ls .build/release/
# wwk          - CLI
# wwkd         - Background agent
```

## Usage

### Menu Bar App

1. Launch `WellWhaddyaKnow.app`
2. Click the clock icon in the menu bar to see current status
3. Click "Open Viewer" to see timeline, manage tags, and export data
4. Click "Preferences..." to configure settings and check permissions

### CLI Commands

```bash
# Show current status
wwk status

# Today's summary
wwk today

# This week's summary
wwk week

# Custom date range summary
wwk summary --from 2024-01-01 --to 2024-01-31

# Group by app, title, tag, or day
wwk summary --from 2024-01-01 --to 2024-01-31 --group-by app

# Export to CSV
wwk export --from 2024-01-01 --to 2024-01-31 --format csv --out report.csv

# Export to JSON (stdout)
wwk export --from 2024-01-01 --to 2024-01-31 --format json --out -

# Tag management
wwk tag list
wwk tag create "project-alpha"
wwk tag apply --from 2024-01-15T09:00:00 --to 2024-01-15T12:00:00 --tag "project-alpha"

# Edit timeline
wwk edit delete --from 2024-01-15T12:00:00 --to 2024-01-15T13:00:00 --note "lunch break"
wwk edit undo --id <edit-id>

# System health check
wwk doctor

# Database info
wwk db info
wwk db verify
```

### JSON Output

Add `--json` to most commands for machine-readable output:

```bash
wwk status --json
wwk today --json
wwk summary --from 2024-01-01 --to 2024-01-31 --json
```

## Data Storage

All data is stored locally in:

```
~/Library/Group Containers/group.com.daylily.wellwhaddyaknow/WellWhaddyaKnow/wwk.sqlite
```

The database uses SQLite with WAL mode and immutable append-only event tables.

## Permissions

### Accessibility Permission

To capture window titles, grant Accessibility permission:

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Add `WellWhaddyaKnow.app` and `wwkd`

Without this permission, the app still tracks by application but window titles will be unavailable.

## Architecture

WellWhaddyaKnow uses an **event-sourcing architecture**:

- All state changes are recorded as immutable events
- Timeline is computed deterministically from events
- User edits are stored as separate events (never modify raw data)
- See [docs/architecture.md](docs/architecture.md) for details

## Documentation

- [Architecture Overview](docs/architecture.md)
- [Database Schema](docs/datastore.md)
- [CLI Reference](docs/cli.md)
- [App Store Notes](docs/app-store.md)
- [Privacy Policy](PRIVACY.md)

## Development

### Build

```bash
swift build
```

### Test

```bash
swift test
```

### Lint

```bash
# If using SwiftLint
swiftlint
```

## License

MIT License. See [LICENSE](LICENSE) for details.

## Privacy

See [PRIVACY.md](PRIVACY.md) for our privacy policy.

**TL;DR**: All data stays on your machine. No cloud. No telemetry. No analytics.
