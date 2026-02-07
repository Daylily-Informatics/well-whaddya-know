# CLI Reference

The `wwk` command-line interface provides reporting, editing, tagging, and agent management for WellWhaddyaKnow.

## Installation

### Homebrew

```bash
brew tap Daylily-Informatics/tap
brew install wwk
```

This installs both `wwk` (CLI) and `wwkd` (background agent).

### From Source

```bash
git clone https://github.com/Daylily-Informatics/well-whaddya-know.git
cd well-whaddya-know
swift build -c release
cp .build/release/wwk .build/release/wwkd /usr/local/bin/
```

## Global Options

All commands accept these flags:

| Flag | Description |
|------|-------------|
| `--json` | Machine-readable JSON output |
| `--db <path>` | Override database path (default: app group container) |
| `--timezone <IANA>` | Display timezone, e.g. `America/New_York` (default: GUI preference → system) |

The `--timezone` flag controls how date-only strings (e.g. `2026-01-15`) are interpreted and how timestamps are displayed. Priority: `--timezone` flag → UserDefaults preference (set in the GUI) → system timezone.

## Commands

### wwk status

Show current tracking status.

```bash
wwk status [--json]
```

**Output:**
- Current working state
- Active application and window title
- Accessibility status
- Agent version and uptime

### wwk today

Show today's time summary.

```bash
wwk today [--json] [--timezone <IANA>]
```

### wwk week

Show this week's time summary.

```bash
wwk week [--json] [--timezone <IANA>]
```

### wwk summary

Show time summary for a date range.

```bash
wwk summary --from <ISO-DATE> --to <ISO-DATE> [--group-by <GROUP>] [--json] [--timezone <IANA>]
```

**Options:**
- `--from` - Start date (ISO 8601: `2026-01-01` or `2026-01-01T09:00:00`)
- `--to` - End date (ISO 8601)
- `--group-by` - Grouping: `app`, `title`, `tag`, `day` (default: `app`)
- `--json` - Output as JSON
- `--timezone` - Display timezone (IANA identifier)

**Examples:**

```bash
# Summary by app
wwk summary --from 2026-01-01 --to 2026-01-31 --group-by app

# Summary by day in a specific timezone
wwk summary --from 2026-01-01 --to 2026-01-07 --group-by day --timezone America/New_York

# JSON output
wwk summary --from 2026-01-01 --to 2026-01-31 --json
```

### wwk export

Export timeline data to CSV or JSON.

```bash
wwk export --from <ISO-DATE> --to <ISO-DATE> --format <FORMAT> --out <PATH> [--include-titles <BOOL>]
```

**Options:**
- `--from` - Start date
- `--to` - End date
- `--format` - Output format: `csv` or `json`
- `--out` - Output path (use `-` for stdout)
- `--include-titles` - Include window titles (default: `true`)

**Examples:**

```bash
# Export to CSV file
wwk export --from 2026-01-01 --to 2026-01-31 --format csv --out report.csv

# Export to JSON stdout
wwk export --from 2026-01-01 --to 2026-01-31 --format json --out -

# Export without titles
wwk export --from 2026-01-01 --to 2026-01-31 --format csv --out report.csv --include-titles false
```

### wwk tag

Manage tags. Tag mutations require the agent (`wwkd`) to be running.

```bash
wwk tag <SUBCOMMAND>
```

**Subcommands:**

```bash
# List all tags
wwk tag list [--json]

# Create a new tag
wwk tag create <NAME>

# Apply tag to time range
wwk tag apply --from <ISO-DATE> --to <ISO-DATE> --tag <NAME>

# Remove tag from time range
wwk tag remove --from <ISO-DATE> --to <ISO-DATE> --tag <NAME>

# Retire a tag (hide from new applications)
wwk tag retire <NAME>

# Rename a tag (creates new + retires old)
wwk tag rename --from <OLD-NAME> --to <NEW-NAME>
```

### wwk edit

Edit the timeline. All edit operations require the agent (`wwkd`) to be running.

```bash
wwk edit <SUBCOMMAND>
```

**Subcommands:**

```bash
# Delete a time range
wwk edit delete --from <ISO-DATE> --to <ISO-DATE> [--note <TEXT>]

# Add a time range
wwk edit add --from <ISO-DATE> --to <ISO-DATE> --app-name <NAME> [--bundle-id <ID>] [--title <TEXT>] [--tags <T1,T2>] [--note <TEXT>]

# Undo an edit
wwk edit undo --id <EDIT-ID>
```

### wwk agent

Manage the `wwkd` background agent via launchd. This is relevant when running `wwk`/`wwkd` standalone (installed via Homebrew or built from source). The GUI app manages the agent lifecycle automatically.

```bash
wwk agent <SUBCOMMAND>
```

**Subcommands:**

```bash
# Show agent status (launchd, process, IPC socket)
wwk agent status [--json]

# Install launchd plist and start agent at login
wwk agent install [--json]

# Remove launchd plist and stop agent
wwk agent uninstall [--json]

# Start the agent (must be installed first)
wwk agent start [--json]

# Stop the agent
wwk agent stop [--json]
```

The `install` subcommand locates `wwkd` automatically (same directory as `wwk`, Homebrew paths, or `PATH`) and creates a launchd plist at `~/Library/LaunchAgents/com.daylily.wellwhaddyaknow.agent.plist`.

### wwk doctor

Check system health.

```bash
wwk doctor [--json]
```

**Checks:**
- Database accessibility
- Schema version
- Agent status
- Accessibility permission

### wwk db

Database operations.

```bash
wwk db <SUBCOMMAND>
```

**Subcommands:**

```bash
# Verify database integrity
wwk db verify

# Show database info
wwk db info [--json]
```

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | General error |
| 2 | Agent not running (for commands requiring agent) |
| 3 | Invalid input |
| 4 | Database error |

## Date Formats

The CLI accepts ISO 8601 dates:

- Date only: `2026-01-15` (interpreted in the effective display timezone)
- Date and time: `2026-01-15T09:30:00`
- With timezone offset: `2026-01-15T09:30:00-08:00`

## Environment Variables

| Variable | Description |
|----------|-------------|
| `WWK_DB_PATH` | Override database path (for testing) |
