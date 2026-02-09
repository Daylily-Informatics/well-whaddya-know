# WellWhaddyaKnow

[![GitHub Release](https://img.shields.io/github/v/release/Daylily-Informatics/well-whaddya-know?style=flat-square&label=release)](https://github.com/Daylily-Informatics/well-whaddya-know/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg?style=flat-square)](https://opensource.org/licenses/MIT)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-blue?style=flat-square)](https://www.apple.com/macos/)

A **local-only** macOS time tracker that records how time passed on your machine by observing which application and window was frontmost while your screen was unlocked.

**No timers. No idle detection. No cloud. No telemetry.**

> *"Time is an illusion, lunchtime doubly so."*
> — **Ford Prefect**, *The Hitchhiker's Guide to the Galaxy*

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

### Homebrew — CLI (`wwk` + `wwkd` agent)

```bash
brew tap Daylily-Informatics/tap
brew install wwk
```

Or as a single command:

```bash
brew install Daylily-Informatics/tap/wwk
```

This installs:
- `wwk` — the command-line interface
- `wwkd` — the background agent that records events

After installing, set up the agent to start at login:

```bash
wwk agent install   # creates a launchd plist and starts wwkd
wwk agent status    # verify it's running
```

### Homebrew — GUI app (`WellWhaddyaKnow.app`)

```bash
brew install --cask Daylily-Informatics/tap/wellwhaddyaknow
```

This installs `WellWhaddyaKnow.app` to `/Applications` (requires admin/sudo). The app embeds its own copy of `wwkd` and manages the agent lifecycle automatically.

**Non-admin users** (no sudo access): install to your home Applications folder instead:

```bash
mkdir -p ~/Applications
brew install --cask Daylily-Informatics/tap/wellwhaddyaknow --appdir=~/Applications
```

macOS recognizes `~/Applications` as a valid launch location — Spotlight, Launchpad, and `open -a WellWhaddyaKnow` all work from there.

### Build from Source

Requires **Xcode 14+** (Swift 6.0) and **macOS 13+**.

#### GUI app (`.app` bundle)

```bash
git clone https://github.com/Daylily-Informatics/well-whaddya-know.git
cd well-whaddya-know
./scripts/build-app.sh            # debug build
# or
./scripts/build-app.sh --release  # optimized release build
```

The script builds both `WellWhaddyaKnow` and `wwkd`, assembles a signed `.app` bundle, and prints the path:

```
.build/debug/WellWhaddyaKnow.app    # debug
.build/release/WellWhaddyaKnow.app  # release
```

To run:

```bash
open .build/debug/WellWhaddyaKnow.app
```

To install system-wide:

```bash
sudo cp -R .build/release/WellWhaddyaKnow.app /Applications/
```

#### CLI only

```bash
git clone https://github.com/Daylily-Informatics/well-whaddya-know.git
cd well-whaddya-know
swift build -c release
```

Binaries land in `.build/release/`:

```
.build/release/wwk    # CLI
.build/release/wwkd   # background agent
```

Copy them somewhere on your `PATH`:

```bash
cp .build/release/wwk .build/release/wwkd /usr/local/bin/
# or for a single-user install:
mkdir -p ~/.local/bin
cp .build/release/wwk .build/release/wwkd ~/.local/bin/
```

Then install the agent as a login item:

```bash
wwk agent install
```

> **Multi-user macOS note:** Homebrew is single-user by default. If `/opt/homebrew` is owned by
> another account, either share ownership (add both users to a `brew` group) or build from source
> and copy binaries to a per-user location as shown above. For the GUI cask, non-admin users
> should use `--appdir=~/Applications` (see [Homebrew GUI](#homebrew--gui-app-wellwhaddyaknowapp) above).

## Quick Start

```bash
# Prerequisites: macOS 13+, Xcode 14+ (or Command Line Tools with Swift 6)

# --- Option A: Homebrew ---
brew tap Daylily-Informatics/tap
brew install wwk                                          # CLI + agent
brew install --cask Daylily-Informatics/tap/wellwhaddyaknow  # GUI app
wwk agent install                                         # start agent at login

# --- Option B: Build from source ---
git clone https://github.com/Daylily-Informatics/well-whaddya-know.git
cd well-whaddya-know
./scripts/build-app.sh --release                          # builds .app bundle
open .build/release/WellWhaddyaKnow.app                   # launch the GUI

# --- Verify ---
wwk status          # should show current tracking state
wwk today           # today's time breakdown by app
```

## GUI Overview

### Menu Bar

Click the eye icon in the menu bar to see real-time tracking status, current app/window, today's total, and quick actions.

![Menu bar status popover](docs/images/wwk_gui_menu.png)

---

### Viewer — Reports

Open the Viewer window to explore your time data. The **Reports** tab offers multiple visualization modes:

**Hourly Bar Chart** — stacked bars showing time per app across each hour of the day:

![Hourly bar chart grouped by app](docs/images/report_bar_by_app.png)

**Space Fill (by App)** — treemap with proportional blocks sized by total time:

![Space fill treemap by app](docs/images/report_spacefill_by_app.png)

**Space Fill (by App + Window)** — drill down to see time per window within each app:

![Space fill treemap by app and window name](docs/images/report_spacefill_by_app_windowname.png)

**Timeline** — Gantt-style view showing exactly when each app was in the foreground:

![Timeline gantt view by app](docs/images/report_timeline_by_app.png)

---

### Viewer — Tags

Create, apply, and manage tags to categorize time ranges. Tags persist across sessions and appear in exports.

![Tags tab](docs/images/report_tags.png)

---

### Preferences

Configure the app via **Preferences…** in the menu bar dropdown.

| Tab | What it does |
|-----|-------------|
| **General** | Display timezone, polling interval, appearance |
| **Permissions** | Accessibility permission status and setup guide |
| **Diagnostics** | Live agent status, IPC health, database stats, event counts |
| **Data** | Database location, size, backup/reset options |
| **About** | Version info, links, credits |

<details>
<summary><strong>Preferences screenshots</strong> (click to expand)</summary>

**General** — display timezone and tracking preferences:

![Preferences — General tab](docs/images/pref_general.png)

**Permissions** — accessibility permission status and instructions:

![Preferences — Permissions tab](docs/images/pref_permissions.png)

**Diagnostics** — live agent, IPC, and database health:

![Preferences — Diagnostics tab](docs/images/pref_diagnostics.png)

**Data** — database location and management:

![Preferences — Data tab](docs/images/pref_data.png)

**About** — version and credits:

![Preferences — About tab](docs/images/pref_about.png)

</details>

---

## Usage

> *"Over time, you spend too much time thinking about what you need to do, and not doing what you need to do."*
> — **Mel Robbins**

### Menu Bar App

1. Launch `WellWhaddyaKnow.app` (or install the cask — it appears in the menu bar automatically)
2. Click the clock icon in the menu bar to see current status
3. Click **Open Viewer** to see timeline, reports, tags, and export data
4. Click **Preferences…** to configure display timezone, permissions, and the login-item agent

### CLI Commands

```bash
# Reporting
wwk status                                  # current tracking state
wwk today                                   # today's summary (by app)
wwk week                                    # this week's summary
wwk summary --from 2026-01-01 --to 2026-01-31 --group-by app
wwk summary --from 2026-01-01 --to 2026-01-07 --group-by day

# Export
wwk export --from 2026-01-01 --to 2026-01-31 --format csv --out report.csv
wwk export --from 2026-01-01 --to 2026-01-31 --format json --out -

# Tags
wwk tag list
wwk tag create "project-alpha"
wwk tag apply  --from 2026-01-15T09:00:00 --to 2026-01-15T12:00:00 --tag "project-alpha"
wwk tag remove --from 2026-01-15T09:00:00 --to 2026-01-15T12:00:00 --tag "project-alpha"

# Edit timeline
wwk edit delete --from 2026-01-15T12:00:00 --to 2026-01-15T13:00:00 --note "lunch break"
wwk edit undo --id <edit-id>

# Agent management
wwk agent status     # show agent process, launchd, and IPC socket state
wwk agent install    # install launchd plist and start agent
wwk agent start      # start agent (must be installed first)
wwk agent stop       # stop agent
wwk agent uninstall  # stop agent and remove launchd plist

# Diagnostics
wwk doctor           # permissions, agent, db integrity
wwk db info          # schema version, event counts, date ranges
wwk db verify        # PRAGMA integrity_check
```

### Global Options

All commands accept these flags:

| Flag | Description |
|------|-------------|
| `--json` | Machine-readable JSON output |
| `--db <path>` | Override database path (default: app group container) |
| `--timezone <IANA>` | Display timezone, e.g. `America/New_York` (default: GUI preference or system) |

```bash
wwk today --json
wwk summary --from 2026-01-01 --to 2026-01-31 --json --timezone America/Chicago
```

See [docs/cli.md](docs/cli.md) for the full CLI reference.

## Data Storage

All data is stored locally in:

```
~/Library/Group Containers/group.com.daylily.wellwhaddyaknow/WellWhaddyaKnow/wwk.sqlite
```

The database uses SQLite with WAL mode and immutable append-only event tables. All timestamps are stored as UTC microseconds since Unix epoch. See [docs/datastore.md](docs/datastore.md) for the full schema.

## Permissions

### Accessibility Permission

To capture window titles, grant Accessibility permission:

1. Open **System Settings** → **Privacy & Security** → **Accessibility**
2. Add `WellWhaddyaKnow.app` (and `wwkd` if running standalone)

Without this permission, the app still tracks which application is active but window titles will show as "unavailable".

## Architecture

WellWhaddyaKnow uses an **event-sourcing architecture**:

- All state changes are recorded as immutable events in SQLite
- Timeline is computed deterministically from events
- User edits are stored as separate events (raw data is never modified)
- All timestamps stored in UTC; display timezone is presentation-only
- See [docs/architecture.md](docs/architecture.md) for details

## Documentation

- [Architecture Overview](docs/architecture.md)
- [Database Schema](docs/datastore.md)
- [CLI Reference](docs/cli.md)
- [App Store Notes](docs/app-store.md)
- [Privacy Policy](PRIVACY.md)
- [Specification](SPEC.md)

## Development

```bash
# Build (debug)
swift build

# Build (release)
swift build -c release

# Build .app bundle (includes agent, code signing)
./scripts/build-app.sh           # debug
./scripts/build-app.sh --release # release

# Run tests (228 tests)
swift test
```

## License

MIT License. See [LICENSE](LICENSE) for details.

## Privacy

See [PRIVACY.md](PRIVACY.md) for our privacy policy.

**TL;DR**: All data stays on your machine. No cloud. No telemetry. No analytics.
