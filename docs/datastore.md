# Database Schema

WellWhaddyaKnow uses SQLite with WAL mode for storage. All tables are append-only with immutability enforced by triggers.

## Location

```
~/Library/Group Containers/group.com.daylily.wellwhaddyaknow/WellWhaddyaKnow/wwk.sqlite
```

## Schema Version

Current schema version: **1**

## Tables

### identity

Machine and user identification (single row).

```sql
CREATE TABLE identity (
    id INTEGER PRIMARY KEY CHECK (id = 1),
    machine_id TEXT NOT NULL,           -- UUID for this machine
    username TEXT NOT NULL,             -- macOS username
    created_ts_us INTEGER NOT NULL,     -- Creation timestamp (microseconds)
    schema_version INTEGER NOT NULL     -- Current schema version
);
```

### agent_runs

Records each agent session.

```sql
CREATE TABLE agent_runs (
    run_id INTEGER PRIMARY KEY AUTOINCREMENT,
    start_ts_us INTEGER NOT NULL,       -- Agent start time
    end_ts_us INTEGER,                  -- Agent end time (NULL if running)
    end_reason TEXT                     -- 'graceful', 'crash', etc.
);
```

### system_state_events

Lock/unlock, sleep/wake, and shutdown events.

```sql
CREATE TABLE system_state_events (
    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_us INTEGER NOT NULL,             -- Event timestamp (microseconds)
    mono_ns INTEGER NOT NULL,           -- Monotonic timestamp (nanoseconds)
    run_id INTEGER NOT NULL,            -- Agent run reference
    kind TEXT NOT NULL,                 -- Event type (see below)
    FOREIGN KEY (run_id) REFERENCES agent_runs(run_id)
);
```

**Event kinds:**
- `screenLocked`, `screenUnlocked`
- `systemWillSleep`, `systemDidWake`
- `systemWillShutdown`
- `sessionDidResignActive`, `sessionDidBecomeActive` (fast user switching)

### raw_activity_events

Foreground application changes.

```sql
CREATE TABLE raw_activity_events (
    event_id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_us INTEGER NOT NULL,             -- Event timestamp
    mono_ns INTEGER NOT NULL,           -- Monotonic timestamp
    run_id INTEGER NOT NULL,
    bundle_id TEXT NOT NULL,            -- App bundle identifier
    app_name TEXT NOT NULL,             -- App display name
    window_title TEXT,                  -- Window title (NULL if no permission)
    title_status TEXT NOT NULL,         -- 'captured', 'denied', 'unavailable'
    reason TEXT NOT NULL,               -- Why event was recorded
    FOREIGN KEY (run_id) REFERENCES agent_runs(run_id)
);
```

**Reason values:**
- `appActivation` - User switched to this app
- `titleChange` - Window title changed
- `periodicSample` - Periodic capture
- `resumed` - After unlock/wake

### user_edit_events

User modifications to the timeline.

```sql
CREATE TABLE user_edit_events (
    edit_id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts_us INTEGER NOT NULL,             -- When edit was made
    operation TEXT NOT NULL,            -- 'deleteRange', 'addRange', 'applyTag', etc.
    payload TEXT NOT NULL,              -- JSON with operation details
    undone_ts_us INTEGER,               -- When undone (NULL if active)
    note TEXT                           -- User-provided note
);
```

**Operations:**
- `deleteRange` - Remove time from timeline
- `addRange` - Add time to timeline
- `applyTag` - Apply tag to range
- `removeTag` - Remove tag from range

### tags

Tag definitions.

```sql
CREATE TABLE tags (
    tag_id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL UNIQUE,          -- Tag name
    created_ts_us INTEGER NOT NULL,     -- Creation time
    retired_ts_us INTEGER               -- Retirement time (NULL if active)
);
```

## Immutability

All event tables have triggers that prevent UPDATE and DELETE:

```sql
CREATE TRIGGER prevent_update_system_state_events
BEFORE UPDATE ON system_state_events
BEGIN
    SELECT RAISE(ABORT, 'Updates not allowed on immutable table');
END;

CREATE TRIGGER prevent_delete_system_state_events
BEFORE DELETE ON system_state_events
BEGIN
    SELECT RAISE(ABORT, 'Deletes not allowed on immutable table');
END;
```

## Indexes

```sql
CREATE INDEX idx_system_state_ts ON system_state_events(ts_us);
CREATE INDEX idx_raw_activity_ts ON raw_activity_events(ts_us);
CREATE INDEX idx_user_edit_ts ON user_edit_events(ts_us);
```

## Migration Strategy

1. Schema version stored in `identity.schema_version`
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

