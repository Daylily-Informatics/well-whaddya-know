# Database Schema

WellWhaddyaKnow uses SQLite with WAL mode for storage. All timestamps are stored as **UTC microseconds since Unix epoch** (`INTEGER`). Event tables are append-only with immutability enforced by triggers.

## Location

```
~/Library/Group Containers/group.com.daylily.wellwhaddyaknow/WellWhaddyaKnow/wwk.sqlite
```

## Schema Version

Current schema version: **1** (stored in `PRAGMA user_version`)

## Tables

### identity

Machine and user identification (single row).

```sql
CREATE TABLE identity (
  identity_id   INTEGER PRIMARY KEY CHECK (identity_id = 1),
  machine_id    TEXT NOT NULL,          -- UUID generated on first run
  username      TEXT NOT NULL,          -- macOS short username at creation
  uid           INTEGER NOT NULL,       -- numeric user id at creation
  created_ts_us INTEGER NOT NULL,       -- UTC microseconds
  app_group_id  TEXT NOT NULL,          -- app group container id (diagnostics)
  notes         TEXT
);
```

### kv_metadata

Generic key-value store for runtime metadata.

```sql
CREATE TABLE kv_metadata (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
```

### applications

Dimension table for application bundle IDs (deduplicated).

```sql
CREATE TABLE applications (
  app_id           INTEGER PRIMARY KEY,
  bundle_id        TEXT NOT NULL UNIQUE,
  display_name     TEXT NOT NULL,
  first_seen_ts_us INTEGER NOT NULL
);
```

### window_titles

Dimension table for window title strings (deduplicated).

```sql
CREATE TABLE window_titles (
  title_id         INTEGER PRIMARY KEY,
  title            TEXT NOT NULL UNIQUE,
  first_seen_ts_us INTEGER NOT NULL
);
```

### tags

Tag definitions.

```sql
CREATE TABLE tags (
  tag_id        INTEGER PRIMARY KEY,
  name          TEXT NOT NULL UNIQUE,
  created_ts_us INTEGER NOT NULL,
  retired_ts_us INTEGER,                -- NULL = active
  sort_order    INTEGER NOT NULL DEFAULT 0
);
```

### agent_runs

Records each agent session. `run_id` is a UUID string.

```sql
CREATE TABLE agent_runs (
  run_id             TEXT PRIMARY KEY,   -- UUID
  started_ts_us      INTEGER NOT NULL,
  started_monotonic_ns INTEGER NOT NULL,
  agent_version      TEXT NOT NULL,
  os_version         TEXT NOT NULL,
  hardware_model     TEXT,
  boot_session_id    TEXT                -- best-effort stable ID for this boot
);
```

### system_state_events (immutable)

System state snapshots: sleep/wake, lock/unlock, agent lifecycle, timezone changes.

```sql
CREATE TABLE system_state_events (
  sse_id              INTEGER PRIMARY KEY,
  run_id              TEXT NOT NULL REFERENCES agent_runs(run_id),
  event_ts_us         INTEGER NOT NULL,   -- UTC microseconds
  event_monotonic_ns  INTEGER NOT NULL,
  is_system_awake     INTEGER NOT NULL CHECK (is_system_awake IN (0,1)),
  is_session_on_console INTEGER NOT NULL CHECK (is_session_on_console IN (0,1)),
  is_screen_locked    INTEGER NOT NULL CHECK (is_screen_locked IN (0,1)),
  is_working          INTEGER NOT NULL CHECK (is_working IN (0,1)),
  event_kind          TEXT NOT NULL,      -- see below
  source              TEXT NOT NULL,      -- see below
  tz_identifier       TEXT NOT NULL,      -- IANA timezone at event time
  tz_offset_seconds   INTEGER NOT NULL,   -- UTC offset at event time
  payload_json        TEXT
);
```

**`event_kind` values:** `agent_start`, `agent_stop`, `state_change`, `sleep`, `wake`, `poweroff`, `gap_detected`, `clock_change`, `tz_change`, `accessibility_denied`, `accessibility_granted`

**`source` values:** `startup_probe`, `workspace_notification`, `timer_poll`, `iokit_power`, `shutdown_hook`, `manual`

### raw_activity_events (immutable)

Foreground application snapshots. References `applications` and `window_titles` dimension tables via foreign keys.

```sql
CREATE TABLE raw_activity_events (
  rae_id             INTEGER PRIMARY KEY,
  run_id             TEXT NOT NULL REFERENCES agent_runs(run_id),
  event_ts_us        INTEGER NOT NULL,
  event_monotonic_ns INTEGER NOT NULL,
  app_id             INTEGER NOT NULL REFERENCES applications(app_id),
  pid                INTEGER NOT NULL,
  title_id           INTEGER REFERENCES window_titles(title_id),
  title_status       TEXT NOT NULL,      -- see below
  reason             TEXT NOT NULL,      -- see below
  is_working         INTEGER NOT NULL CHECK (is_working IN (0,1)),
  ax_error_code      INTEGER,           -- AXError raw value (NULL on success)
  payload_json       TEXT
);
```

**`title_status` values:** `ok`, `no_permission`, `not_supported`, `no_window`, `error`

**`reason` values:** `working_began`, `app_activated`, `ax_title_changed`, `ax_focused_window_changed`, `poll_fallback`


### user_edit_events (immutable)

User modifications to the timeline. Edits never mutate raw events — they are applied during timeline building.

```sql
CREATE TABLE user_edit_events (
  uee_id               INTEGER PRIMARY KEY,
  created_ts_us        INTEGER NOT NULL,
  created_monotonic_ns INTEGER NOT NULL,
  author_username      TEXT NOT NULL,
  author_uid           INTEGER NOT NULL,
  client               TEXT NOT NULL CHECK (client IN ('ui', 'cli')),
  client_version       TEXT NOT NULL,
  op                   TEXT NOT NULL,     -- see below
  start_ts_us          INTEGER NOT NULL,
  end_ts_us            INTEGER NOT NULL CHECK (end_ts_us > start_ts_us),
  tag_id               INTEGER REFERENCES tags(tag_id),
  manual_app_bundle_id TEXT,
  manual_app_name      TEXT,
  manual_window_title  TEXT,
  note                 TEXT,
  target_uee_id        INTEGER REFERENCES user_edit_events(uee_id),
  payload_json         TEXT
);
```

**`op` values:** `delete_range`, `add_range`, `tag_range`, `untag_range`, `undo_edit`

The `undo_edit` operation references another edit via `target_uee_id`. The timeline builder uses recursive resolution to determine which edits are active.

### schema_migrations

Tracks applied schema migrations.

```sql
CREATE TABLE schema_migrations (
  version     INTEGER PRIMARY KEY,
  applied_ts_us INTEGER NOT NULL,
  description TEXT
);
```

## Immutability

All event tables (`system_state_events`, `raw_activity_events`, `user_edit_events`) have triggers that prevent UPDATE and DELETE:

```sql
CREATE TRIGGER trg_sse_no_update BEFORE UPDATE ON system_state_events
BEGIN SELECT RAISE(ABORT, 'system_state_events is immutable'); END;

CREATE TRIGGER trg_sse_no_delete BEFORE DELETE ON system_state_events
BEGIN SELECT RAISE(ABORT, 'system_state_events is immutable'); END;

-- Same pattern for raw_activity_events (trg_rae_*) and user_edit_events (trg_uee_*)
```

## Indexes

```sql
-- system_state_events
CREATE INDEX idx_sse_event_ts ON system_state_events(event_ts_us);
CREATE INDEX idx_sse_run_id ON system_state_events(run_id);

-- raw_activity_events
CREATE INDEX idx_rae_event_ts ON raw_activity_events(event_ts_us);
CREATE INDEX idx_rae_app_id_ts ON raw_activity_events(app_id, event_ts_us);
CREATE INDEX idx_rae_run_id ON raw_activity_events(run_id);

-- user_edit_events
CREATE INDEX idx_uee_created_ts ON user_edit_events(created_ts_us);
CREATE INDEX idx_uee_range ON user_edit_events(start_ts_us, end_ts_us);
CREATE INDEX idx_uee_op ON user_edit_events(op);
```

## Migration Strategy

1. Schema version stored in `PRAGMA user_version` and tracked in `schema_migrations`
2. Migrations run on agent startup
3. Each migration is idempotent
4. Migrations never delete data
5. Tests verify data preservation across migrations

## Backup

The database can be backed up by copying the SQLite file while the agent is not running, or by using SQLite's backup API.

## WAL Mode

Write-Ahead Logging (WAL) is enabled for:
- Concurrent reads during writes
- Better crash recovery
- Improved performance

```sql
PRAGMA journal_mode = WAL;
```