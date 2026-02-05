# CLI Reference

The `wwk` command-line interface provides read-only reporting and edit commands for WellWhaddyaKnow.

## Installation

### Homebrew

```bash
brew tap Daylily-Informatics/tap
brew install wwk
```

### From Source

```bash
swift build -c release
cp .build/release/wwk /usr/local/bin/
```

## Commands

### wwk status

Show current tracking status.

```bash
wwk status [--json]
```

**Output:**
- Current working state
- Active application and window title
- Today's total time
- Agent status

### wwk today

Show today's time summary.

```bash
wwk today [--json]
```

### wwk week

Show this week's time summary.

```bash
wwk week [--json]
```

### wwk summary

Show time summary for a date range.

```bash
wwk summary --from <ISO-DATE> --to <ISO-DATE> [--group-by <GROUP>] [--json]
```

**Options:**
- `--from` - Start date (ISO 8601: `2024-01-01` or `2024-01-01T09:00:00`)
- `--to` - End date (ISO 8601)
- `--group-by` - Grouping: `app`, `title`, `tag`, `day` (default: `app`)
- `--json` - Output as JSON

**Examples:**

```bash
# Summary by app
wwk summary --from 2024-01-01 --to 2024-01-31 --group-by app

# Summary by day
wwk summary --from 2024-01-01 --to 2024-01-07 --group-by day

# JSON output
wwk summary --from 2024-01-01 --to 2024-01-31 --json
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
wwk export --from 2024-01-01 --to 2024-01-31 --format csv --out report.csv

# Export to JSON stdout
wwk export --from 2024-01-01 --to 2024-01-31 --format json --out -

# Export without titles
wwk export --from 2024-01-01 --to 2024-01-31 --format csv --out report.csv --include-titles false
```

### wwk tag

Manage tags.

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

# Rename a tag
wwk tag rename <OLD-NAME> <NEW-NAME>
```

### wwk edit

Edit the timeline.

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

- Date only: `2024-01-15`
- Date and time: `2024-01-15T09:30:00`
- With timezone: `2024-01-15T09:30:00-08:00`

## Environment Variables

| Variable | Description |
|----------|-------------|
| `WWK_DB_PATH` | Override database path (for testing) |

