# well-whaddya-know (macOS) Implementation Specification

> This specification is frozen. Implementations must follow it exactly.
> Changes require an explicit revision.

A macOS-only, local-only time tracker that counts **working time strictly as “screen is unlocked”**, and attributes that time continuously to the **foreground application + window title**.

This document is an implementation spec (not code). It is written to be handed to an implementation model for mechanical build-out.

---

## Scope, invariants, and hard constraints

### Core definition (non-negotiable)

**Working time** is defined strictly as:

* Any time the macOS user session is **UNLOCKED**.

**Not working time** is defined strictly as:

* Screen locked
* System asleep
* System shut down

**No keyboard, mouse, idle, or “activity” heuristics** are used. If the user walks away without locking, time is counted intentionally.

**Foreground attribution** occurs continuously during unlocked time.

### Required capabilities

* macOS only
* Local-only storage (no cloud, no network)
* Continuous tracking while screen is unlocked
* Foreground application + window title attribution
* Accurate handling of lock, sleep, wake, shutdown
* Per-machine + per-username attribution
* Menu bar app as primary entry point
* GUI viewer/editor (timeline + edits)
* Command-line interface (CLI) using the same data store, distributed via Homebrew and direct download (not included in the Mac App Store build)
* User editing:

  * delete time ranges
  * add time ranges
  * apply tags
* CSV and JSON export
* App Store viable
* Open-source and free

### Non-goals (explicitly excluded)

* No keystroke logging
* No screenshots
* No behavior scoring
* No cloud sync
* No productivity judgment

---

## Recommended implementation path (one path, explicit trade-offs)

### Recommended path

Build a sandboxed macOS app suite with:

* A **login item background agent** (`wwkd`) that is the **only writer** to SQLite.
* A **menu bar UI app** (`WellWhaddyaKnow.app`) that is a reader and sends edit/export commands to the agent via XPC.
* A **viewer/editor window** inside `WellWhaddyaKnow.app` (same binary, different UI scenes).
* A **command-line interface (CLI)** (`wwk`) implemented as a separate executable sharing the same schema and reporting logic, **distributed via Homebrew and direct download**.

  * **The Mac App Store build omits the CLI entirely.**
  * The CLI is not installed to PATH by the App Store build.
  * CLI edit operations communicate with the background agent via XPC when available.

### Assumptions

* Minimum supported OS: **macOS 13 (Ventura)** so we can use `SMAppService` for login item and background task registration. ([Apple Developer][1])
* Users will grant **Accessibility permission** to capture window titles. If not granted, we still track by app but window titles are `NULL`.
* SQLite is sufficient (no Core Data required).

### Trade-offs

* Single-writer design (agent owns writes) simplifies concurrency and auditability, but means UI and CLI must talk to agent for edits.
* Window title capture requires Accessibility permission; without it, attribution is lower fidelity.
* “Accurate shutdown” is best-effort: graceful shutdown is detectable; hard power loss is not.

---

## 1. System architecture overview

### High-level components

1. **wwkd (Background Agent)**

   * Runs at login as a registered background task/login item.
   * Observes:

     * session lock/unlock state
     * system sleep/wake
     * system power-off/logout request
     * frontmost application changes
     * focused window title changes (via Accessibility)
   * Emits **immutable event log** into SQLite:

     * `system_state_events` (lock/unlock/sleep/wake/poweroff snapshots)
     * `raw_activity_events` (foreground context snapshots)
   * Applies edits by writing `user_edit_events` (append-only).

2. **WellWhaddyaKnow.app (Menu bar + Viewer/Editor)**

   * Primary entry point via menu bar status item.
   * Viewer/editor window for timeline + edits + tags.
   * No direct DB writes (except optional emergency recovery mode, disabled by default).

3. **wwk (CLI — non–App Store distribution)**

   * Distributed via Homebrew and direct download.
   * Uses the same SQLite schema and reporting logic as the app.
   * Read-only reporting directly via SQLite.
   * Edits and tag mutations go through XPC to the agent when available.


### Data flow

Sensors → Agent state machine → append events → SQLite (WAL) → reporting queries / timeline builder → UI + CLI outputs.

### Storage location

* SQLite file is stored in **App Group container**:

  * `~/Library/Group Containers/<group-id>/WellWhaddyaKnow/wwk.sqlite`
* Ensures the agent + app + CLI share the same file under sandbox.

---

## 2. Process model

### 2.1 Background Agent: `wwkd`

**Lifetime**

* Starts at user login.
* Runs continuously in user session.
* Continues running while screen is locked (to observe unlock), but reduces activity when not working.

**Responsibilities**

* Owns all DB writes.
* Maintains in-memory state machine:

  * current working state
  * current foreground context (app + title)
  * permission status (Accessibility)
* Provides XPC API:

  * current status (working state + current context)
  * read-only summary endpoints (optional)
  * edit operations (delete/add/tag)
  * export operations (optional; UI may export directly read-only, but agent export ensures consistent snapshot)

**Crash and restart behavior**

* On start, records an `agent_start` state snapshot.
* On normal termination, records `agent_stop`.
* If prior run ended without `agent_stop`, records a `gap_detected` state snapshot and marks the gap as “unobserved” (see edge cases).

### 2.2 Menu bar app: `WellWhaddyaKnow.app`

**Lifetime**

* User launches it; it can also auto-launch.
* Shows status item and popover.
* Can open the viewer/editor window.

**Responsibilities**

* Displays:

  * current working/not working state
  * current foreground app + title (if available)
  * today’s total working time
* Entry points:

  * Open Viewer
  * Export (date range)
  * Preferences (permissions, datastore path, about)
  * Quit (stops tracking)

### 2.3 Viewer/Editor (inside `WellWhaddyaKnow.app`)

**Responsibilities**

* Timeline visualization
* Range edits:

  * delete range
  * add range
  * apply tags
* Tag management
* Export UI

### 2.4 CLI: `wwk`

**Lifetime**

* On-demand.
* Read-only queries can work even if agent is not running.
* Mutating operations require agent.

**Responsibilities**

* Status, summaries, exports, edits.

---

## 3. macOS APIs used

### 3.1 Screen lock detection

Primary mechanism: **Quartz session dictionary** via:

* `CGSessionCopyCurrentDictionary()` (CoreGraphics/Quartz) ([Apple Developer][2])

Interpretation rules (best available in practice):

* `CGSSessionScreenIsLocked == 1` implies locked.
* `kCGSessionOnConsoleKey == 1` implies this session owns the console (not fast-user-switched out). ([Stack Overflow][3])

Event triggers to prompt re-check (documented):

* `NSWorkspace.sessionDidResignActiveNotification`
* `NSWorkspace.sessionDidBecomeActiveNotification` ([Apple Developer][4])

Design note:

* Do not depend on undocumented distributed notifications like `com.apple.screenIsLocked` for App Store builds. They may be used only in a non-App Store “developer build” behind a compile-time flag. (If included at all, keep out of release targets.)

### 3.2 Sleep/wake detection

Use NSWorkspace notifications:

* `NSWorkspace.willSleepNotification` ([Apple Developer][5])
* `NSWorkspace.didWakeNotification` ([Apple Developer][6])

For shutdown/logout request:

* `NSWorkspace.willPowerOffNotification` ([Apple Developer][7])

Reliability hardening:

* Add an IOKit power notification source as a secondary channel if NSWorkspace is missed (implementation detail). NSWorkspace is still the primary documented surface.

### 3.3 Foreground app detection

Use NSWorkspace:

* `NSWorkspace.didActivateApplicationNotification` ([Apple Developer][8])
* Query `NSWorkspace.shared.frontmostApplication` for current app bundle id, PID, localized name.

### 3.4 Foreground window title detection

Use Accessibility API:

* `AXUIElementCreateApplication(pid)`
* Read:

  * `kAXFocusedWindowAttribute`
  * `kAXTitleAttribute` (or on the window element)
* Subscribe via AXObserver:

  * `kAXTitleChangedNotification` ([Apple Developer][9])
  * `kAXFocusedWindowChangedNotification` (and optionally main window changed)

Permission:

* `AXIsProcessTrustedWithOptions` to prompt and detect accessibility authorization state.

Fallback:

* If AX notifications fail for an app, poll title every N seconds while working (see tracking loop).

---

## 4. Precise definition of working vs non-working states

### 4.1 State variables

The agent maintains these booleans continuously:

1. `isSystemAwake`

* True when system is not asleep.
* Set false on `willSleep`.
* Set true on `didWake`.

2. `isSessionOnConsole`

* Derived from `CGSessionCopyCurrentDictionary()`:

  * `kCGSessionOnConsoleKey == 1` means on-console. ([Stack Overflow][3])
  * If dictionary missing or key missing, treat as false.

3. `isScreenLocked`

* Derived from `CGSessionCopyCurrentDictionary()`:

  * `CGSSessionScreenIsLocked == 1` means locked. ([Stack Overflow][3])
  * If key missing, treat as unlocked only if session is on console; otherwise unknown defaults to not working.

### 4.2 Derived working state (single authoritative rule)

`isWorking = isSystemAwake && isSessionOnConsole && !isScreenLocked`

This is the only rule used to count time.

### 4.3 Handling “unknown”

If `CGSessionCopyCurrentDictionary()` returns `NULL` or a dictionary without required fields, treat as:

* `isSessionOnConsole = false`
* `isScreenLocked = true` (conservative)
* Therefore `isWorking = false`

This avoids inventing working time when the agent cannot observe state.

---

## 5. Event lifecycle and edge cases

### 5.1 Event types (conceptual)

All persisted events are immutable append-only rows. There are three event streams:

1. `system_state_events` (snapshots and transitions)
2. `raw_activity_events` (foreground context snapshots)
3. `user_edit_events` (user-driven overlays)

### 5.2 Agent startup sequence

On agent launch:

1. Generate a `run_id` (UUID).
2. Load identity (machine_id, username, uid) from DB or initialize.
3. Initialize SQLite connection in WAL mode.
4. Probe current session state via `CGSessionCopyCurrentDictionary()`.
5. Emit `system_state_events` row of kind `agent_start` with full snapshot.
6. If `isWorking`, immediately emit a `raw_activity_events` snapshot of current frontmost app + title (if permitted).

### 5.3 Main loop behavior

While running:

* State updates are triggered by:

  * NSWorkspace session active/resign notifications
  * willSleep/didWake
  * willPowerOff
  * periodic probe timer (recommended: every 2 seconds while not working; every 1 second while working)
* Foreground context updates are triggered by:

  * didActivateApplicationNotification
  * AX observer notifications on active app
  * fallback poll timer (recommended: 1 second while working)

### 5.4 Transition rules

When state changes cause `isWorking` to flip:

* If `isWorking` transitions `false -> true`:

  * Emit `system_state_events` snapshot
  * Emit `raw_activity_events` snapshot immediately (so the working interval begins attributed as soon as possible)
* If `isWorking` transitions `true -> false`:

  * Emit `system_state_events` snapshot
  * Stop AX observation and polling until working resumes

### 5.5 Edge cases and required behaviors

#### A. Fast User Switching (session switched out)

* `isSessionOnConsole` becomes false. Count no time.
* Continue running but minimize activity.
* When session returns on console:

  * Re-probe CGSession dictionary
  * Only resume working if unlocked.

Apple explicitly notes that processes in a switched-out session continue running but do not receive input, and it may be beneficial to adjust behavior. ([Apple Developer][10])

#### B. Display sleep vs system sleep

* Display sleep (screens sleep) is NOT system sleep. Do not treat it as not working.
* Only system sleep counts as not working (from willSleep to didWake).

#### C. Sleep while unlocked

* On `willSleep`, end working at that timestamp (via state event).
* After `didWake`, do not assume unlocked; lock screen may appear. Re-probe.

#### D. Shutdown / logout

* On `willPowerOff`, emit a `system_state_events` snapshot that forces `isWorking = false` at that timestamp. ([Apple Developer][7])
* After `willPowerOff`, flush DB immediately (fsync behavior is SQLite-dependent; use `PRAGMA synchronous=FULL` during final flush if needed. This is best-effort and not relied upon for correctness.).
* If shutdown is hard (power loss), no event will be logged; see gap handling.

#### E. Agent crash / kill / disabled login item

* If the agent is not running, there is no tracking. This is an observability gap.
* On next start:

  * Detect last `agent_start` without a matching `agent_stop`.
  * Emit a `system_state_events` row with kind `gap_detected` including:

    * `gap_start_ts_us = last_seen_event_ts_us`
    * `gap_end_ts_us = now_ts_us`
  * Reporting must treat gap time as **not working / unobserved**, never as working.

Rationale: do not invent work time when the observer is down.

#### F. System clock changes (NTP jumps or manual changes)

Required mitigation:

* Store wall-clock timestamps as UTC microseconds.
* Also store a monotonic time sample (see schema) at each system state snapshot.
* If wall-clock delta deviates from monotonic delta by > 120 seconds, emit a `clock_change` system state event.
* Reporting must prefer monotonic deltas for ordering checks, but durations are still computed in wall-clock for user-facing time ranges.

#### G. Accessibility permission revoked mid-run

* If AX permission becomes unavailable:

  * Emit a `system_state_events` event of kind `accessibility_denied`.
  * Continue tracking by app only (window title `NULL`).
  * UI must show degraded attribution status.

---

## 6. Exact SQLite schema

### 6.1 SQLite configuration

On every connection open:

* `PRAGMA foreign_keys = ON;`
* `PRAGMA journal_mode = WAL;`
* `PRAGMA synchronous = NORMAL;` (agent uses NORMAL during steady-state; temporarily elevate on shutdown flush)
* `PRAGMA busy_timeout = 5000;`
* `PRAGMA temp_store = MEMORY;`

### 6.2 Timestamp conventions

* All timestamps stored as **UTC microseconds since Unix epoch** in `INTEGER` columns named `*_ts_us`.
* Intervals are always treated as half-open: `[start_ts_us, end_ts_us)`.

### 6.3 Schema versioning

* Use `PRAGMA user_version` as schema version integer.
* All migrations are forward-only, with a migration table recording applied versions.

### 6.4 DDL

The following schema is normative.

```sql
-- =========================
-- Core identity and metadata
-- =========================

CREATE TABLE IF NOT EXISTS identity (
  identity_id            INTEGER PRIMARY KEY CHECK (identity_id = 1),
  machine_id             TEXT NOT NULL,         -- UUID generated on first run, stored locally
  username               TEXT NOT NULL,         -- short username at DB creation time
  uid                    INTEGER NOT NULL,      -- numeric user id at DB creation time
  created_ts_us          INTEGER NOT NULL,
  app_group_id           TEXT NOT NULL,         -- for diagnostics
  notes                  TEXT
);

CREATE TABLE IF NOT EXISTS kv_metadata (
  key                    TEXT PRIMARY KEY,
  value                  TEXT NOT NULL
);

-- =========================
-- Dimension tables (optional but required by this spec)
-- =========================

CREATE TABLE IF NOT EXISTS applications (
  app_id                 INTEGER PRIMARY KEY,
  bundle_id              TEXT NOT NULL UNIQUE,
  display_name           TEXT NOT NULL,
  first_seen_ts_us       INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS window_titles (
  title_id               INTEGER PRIMARY KEY,
  title                  TEXT NOT NULL UNIQUE,
  first_seen_ts_us       INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS tags (
  tag_id                 INTEGER PRIMARY KEY,
  name                   TEXT NOT NULL UNIQUE,
  created_ts_us          INTEGER NOT NULL,
  retired_ts_us          INTEGER,               -- NULL = active
  sort_order             INTEGER NOT NULL DEFAULT 0
);

-- =========================
-- Run tracking (diagnostic, immutable)
-- =========================

CREATE TABLE IF NOT EXISTS agent_runs (
  run_id                 TEXT PRIMARY KEY,      -- UUID
  started_ts_us          INTEGER NOT NULL,
  started_monotonic_ns   INTEGER NOT NULL,
  agent_version          TEXT NOT NULL,
  os_version             TEXT NOT NULL,
  hardware_model         TEXT,
  boot_session_id        TEXT                  -- best-effort stable ID for this boot
);

-- =========================
-- System state events (immutable, append-only)
-- =========================

CREATE TABLE IF NOT EXISTS system_state_events (
  sse_id                 INTEGER PRIMARY KEY,
  run_id                 TEXT NOT NULL REFERENCES agent_runs(run_id),

  event_ts_us            INTEGER NOT NULL,
  event_monotonic_ns     INTEGER NOT NULL,

  -- Observed state snapshot AFTER applying this event
  is_system_awake        INTEGER NOT NULL CHECK (is_system_awake IN (0,1)),
  is_session_on_console  INTEGER NOT NULL CHECK (is_session_on_console IN (0,1)),
  is_screen_locked       INTEGER NOT NULL CHECK (is_screen_locked IN (0,1)),
  is_working             INTEGER NOT NULL CHECK (is_working IN (0,1)),

  -- Event classification
  event_kind             TEXT NOT NULL CHECK (
                           event_kind IN (
                             'agent_start',
                             'agent_stop',
                             'state_change',
                             'sleep',
                             'wake',
                             'poweroff',
                             'gap_detected',
                             'clock_change',
                             'tz_change',
                             'accessibility_denied',
                             'accessibility_granted'
                           )
                         ),

  -- Source channel for observability
  source                 TEXT NOT NULL CHECK (
                           source IN (
                             'startup_probe',
                             'workspace_notification',
                             'timer_poll',
                             'iokit_power',
                             'shutdown_hook',
                             'manual'
                           )
                         ),

  -- Optional additional fields
  tz_identifier          TEXT NOT NULL,          -- TimeZone.current.identifier at event time
  tz_offset_seconds      INTEGER NOT NULL,       -- seconds east of UTC at event time

  payload_json           TEXT                    -- JSON object, strictly optional; avoid PII
);

CREATE INDEX IF NOT EXISTS idx_sse_event_ts
ON system_state_events(event_ts_us);

CREATE INDEX IF NOT EXISTS idx_sse_run_id
ON system_state_events(run_id);

-- Enforce immutability for system_state_events
CREATE TRIGGER IF NOT EXISTS trg_sse_no_update
BEFORE UPDATE ON system_state_events
BEGIN
  SELECT RAISE(ABORT, 'system_state_events is immutable');
END;

CREATE TRIGGER IF NOT EXISTS trg_sse_no_delete
BEFORE DELETE ON system_state_events
BEGIN
  SELECT RAISE(ABORT, 'system_state_events is immutable');
END;

-- =========================
-- Raw activity events (immutable, append-only)
-- Foreground context snapshots during working time
-- =========================

CREATE TABLE IF NOT EXISTS raw_activity_events (
  rae_id                 INTEGER PRIMARY KEY,
  run_id                 TEXT NOT NULL REFERENCES agent_runs(run_id),

  event_ts_us            INTEGER NOT NULL,
  event_monotonic_ns     INTEGER NOT NULL,

  -- Foreground app
  app_id                 INTEGER NOT NULL REFERENCES applications(app_id),
  pid                    INTEGER NOT NULL,

  -- Foreground window title (nullable if not permitted or not available)
  title_id               INTEGER REFERENCES window_titles(title_id),

  -- Whether this snapshot had title access
  title_status           TEXT NOT NULL CHECK (
                           title_status IN (
                             'ok',
                             'no_permission',
                             'not_supported',
                             'no_window',
                             'error'
                           )
                         ),

  -- Reason for emitting this snapshot
  reason                 TEXT NOT NULL CHECK (
                           reason IN (
                             'working_began',
                             'app_activated',
                             'ax_title_changed',
                             'ax_focused_window_changed',
                             'poll_fallback'
                           )
                         ),

  -- Defensive flag, should be 1 for all rows
  is_working             INTEGER NOT NULL CHECK (is_working IN (0,1)),

  ax_error_code          INTEGER,                -- AXError as integer if title_status='error'
  payload_json           TEXT                    -- optional diagnostics, no PII beyond title
);

CREATE INDEX IF NOT EXISTS idx_rae_event_ts
ON raw_activity_events(event_ts_us);

CREATE INDEX IF NOT EXISTS idx_rae_app_id_ts
ON raw_activity_events(app_id, event_ts_us);

CREATE INDEX IF NOT EXISTS idx_rae_run_id
ON raw_activity_events(run_id);

-- Enforce immutability for raw_activity_events
CREATE TRIGGER IF NOT EXISTS trg_rae_no_update
BEFORE UPDATE ON raw_activity_events
BEGIN
  SELECT RAISE(ABORT, 'raw_activity_events is immutable');
END;

CREATE TRIGGER IF NOT EXISTS trg_rae_no_delete
BEFORE DELETE ON raw_activity_events
BEGIN
  SELECT RAISE(ABORT, 'raw_activity_events is immutable');
END;

-- =========================
-- User edit events (immutable, append-only overlays)
-- =========================

CREATE TABLE IF NOT EXISTS user_edit_events (
  uee_id                 INTEGER PRIMARY KEY,
  created_ts_us          INTEGER NOT NULL,
  created_monotonic_ns   INTEGER NOT NULL,

  author_username        TEXT NOT NULL,
  author_uid             INTEGER NOT NULL,

  client                 TEXT NOT NULL CHECK (client IN ('ui', 'cli')),
  client_version         TEXT NOT NULL,

  op                     TEXT NOT NULL CHECK (
                           op IN (
                             'delete_range',
                             'add_range',
                             'tag_range',
                             'untag_range',
                             'undo_edit'
                           )
                         ),

  start_ts_us            INTEGER NOT NULL,
  end_ts_us              INTEGER NOT NULL CHECK (end_ts_us > start_ts_us),

  -- Tag ops
  tag_id                 INTEGER REFERENCES tags(tag_id),

  -- Manual add attribution (only for add_range)
  manual_app_bundle_id   TEXT,
  manual_app_name        TEXT,
  manual_window_title    TEXT,

  -- Optional note shown in UI
  note                   TEXT,

  -- Undo support
  target_uee_id          INTEGER REFERENCES user_edit_events(uee_id),

  payload_json           TEXT
);

CREATE INDEX IF NOT EXISTS idx_uee_created_ts
ON user_edit_events(created_ts_us);

CREATE INDEX IF NOT EXISTS idx_uee_range
ON user_edit_events(start_ts_us, end_ts_us);

CREATE INDEX IF NOT EXISTS idx_uee_op
ON user_edit_events(op);

-- Enforce immutability for user_edit_events
CREATE TRIGGER IF NOT EXISTS trg_uee_no_update
BEFORE UPDATE ON user_edit_events
BEGIN
  SELECT RAISE(ABORT, 'user_edit_events is immutable');
END;

CREATE TRIGGER IF NOT EXISTS trg_uee_no_delete
BEFORE DELETE ON user_edit_events
BEGIN
  SELECT RAISE(ABORT, 'user_edit_events is immutable');
END;
```

---

## 7. How edits are layered without mutating raw data

### 7.1 Core principle: event sourcing with overlays

* `system_state_events` and `raw_activity_events` define the **raw observed timeline**.
* `user_edit_events` define a **layered “patch set”** that transforms the raw timeline into an “effective timeline”.
* Raw tables are immutable by triggers. All user modifications are expressed as additional events.

### 7.2 Effective timeline construction order (deterministic)

Given a requested report range `[R0, R1)`:

1. **Compute base working intervals** from `system_state_events`.
2. **Compute base attribution segments** from `raw_activity_events` intersected with working intervals.
3. **Apply user edits** in this strict order:

   1. Apply all `undo_edit` (filter out undone edits first, see below)
   2. Apply all `delete_range` (subtract time)
   3. Apply all `add_range` (insert time, with precedence over base segments)
   4. Apply `tag_range` / `untag_range` as metadata overlays (no duration changes)

### 7.3 Undo semantics

* `undo_edit` targets a prior `uee_id`.
* An edit is considered **inactive** if it is targeted by an `undo_edit` that is itself not undone.
* If multiple undos exist, the most recent (by `created_ts_us`) wins.
* No raw edit row is ever deleted or updated.

### 7.4 Precedence rules for overlaps

Overlaps can occur when:

* user adds a range overlapping raw observed time
* user deletes a range that overlaps a user-added range

Precedence rules:

1. **Delete beats everything**: if a time slice is deleted, it is removed even if it came from a manual add.
2. **Manual add beats raw observation**: for overlapping time, the manual add replaces the raw segment attribution.
3. Tags are additive overlays and can overlap anything unless explicitly untagged.

### 7.5 Segment subtraction and splitting

All timeline manipulation is done by:

* subtracting intervals from segments (may split into up to 2 segments)
* inserting segments and then resolving overlaps by splitting neighbors

This must be implemented in a pure, deterministic function so:

* UI and CLI outputs match exactly
* regression testing is possible using fixture event streams

---

## 8. Reporting primitives derivable from the model

### 8.1 Primitive outputs (the internal “reporting IR”)

All reporting should be derived from a canonical list of **effective segments**:

`EffectiveSegment` fields:

* `start_ts_us`, `end_ts_us`, `duration_seconds`
* `source` = `raw` | `manual`
* `app_bundle_id`, `app_name`
* `window_title` (nullable)
* `tags`: `[String]`
* `coverage` = `observed` | `unobserved_gap`
* `supporting_ids`: list of event IDs used (optional for debugging/export)

### 8.2 Required reports

From effective segments, derive:

* Total working time in range
* Daily totals (local timezone)
* Totals by application (bundle id)
* Totals by window title (optional, only when title present)
* Totals by tag
* Unattributed time (no title, or no app due to errors)
* Gap time (agent down / unobserved)

### 8.3 “Today” definition

“Today” in UI means local calendar day based on the user’s current timezone, but daily grouping must respect `tz_identifier` and DST transitions based on segment timestamps.

Implementation requirement:

* Convert each segment’s start/end to local time and split at local midnight boundaries.

### 8.4 Export formats

#### CSV export (effective segments)

Header (exact columns):

1. `machine_id`
2. `username`
3. `segment_start_local`
4. `segment_end_local`
5. `segment_start_utc`
6. `segment_end_utc`
7. `duration_seconds`
8. `source`
9. `app_bundle_id`
10. `app_name`
11. `window_title`
12. `tags` (semicolon-separated)
13. `coverage` (`observed` or `unobserved_gap`)

Rules:

* `window_title` is empty string if NULL.
* Timestamps are ISO-8601 strings with timezone offsets for local, and `Z` for UTC.

#### JSON export (effective segments)

Top-level object:

* `identity`: { machine_id, username, uid }
* `exported_at_utc`
* `range`: { start_utc, end_utc }
* `segments`: array of segment objects matching the EffectiveSegment fields (timestamps as ISO-8601 strings)

No raw events are exported by default unless user explicitly selects “debug export”.

---

## 9. UI scope and interaction flows

### 9.1 Menu bar UI (primary)

Popover content:

* Status line:

  * “Working” if `isWorking==1`
  * “Not working” otherwise
* Current attribution:

  * App name
  * Window title (if available; otherwise show “(title unavailable)”)
* Today total working time
* Buttons:

  * Open Viewer
  * Export…
  * Preferences…
  * Quit (stops tracking)

UI requirements:

* Always show whether Accessibility permission is granted.
* If denied, show a single click path to open System Settings Privacy and Security Accessibility panel (deep-link if possible; otherwise open System Settings and instruct).

### 9.2 Viewer/Editor window

Three primary tabs (or sidebar items):

1. **Timeline**
2. **Tags**
3. **Exports**

#### Timeline view

* Date picker (day-level) plus week navigation
* Main list view of segments:

  * start-end
  * duration
  * app + title
  * tag chips

Selection:

* User can select a contiguous time range (drag on a timeline or shift-select rows) and apply actions:

  * Delete range
  * Add range (opens dialog pre-filled with selection)
  * Tag range (choose existing tag)
  * Untag range (choose tag)

#### Add range dialog

Fields:

* Start (local datetime)
* End (local datetime)
* Attribution:

  * App name (free text) and optional bundle id
  * Window title (free text)
* Tags (multi-select)
* Note

On save:

* Emit `user_edit_events.op = add_range`
* Also emit `tag_range` events for selected tags (or store tags in payload_json, but spec prefers separate tag events for audit clarity)

#### Delete range dialog

Fields:

* Start/end (fixed)
* Note (optional)
  On save:
* Emit `delete_range`

#### Tag management view

* List tags
* Create tag
* Rename tag (implemented as: create new tag + retire old tag OR allow updating `tags.name` with an audit entry in payload_json; choose one approach and stick to it)
* Retire tag (sets `retired_ts_us`)

### 9.3 Preferences

* Data location (read-only display + “Reveal in Finder”)
* Accessibility permission status
* Background agent running status (XPC ping)
* Export defaults (format, include titles yes/no default toggle)
* “Delete all data” action:

  * Requires explicit confirmation
  * Implemented as: move SQLite file to trash and recreate identity

---

## 10. CLI command surface (`wwk`)

### 10.1 Command design rules

* Every command must support:

  * `--db <path>` optional override (default: app group path)
  * `--json` machine-readable output when applicable
* Commands that mutate must:

  * Require agent reachable via XPC
  * Fail clearly if agent not running

### 10.2 Commands (normative)

#### Status

* `wwk status [--json]`
  Outputs:
* is_working
* current_app
* current_title (nullable)
* accessibility_status
* agent_version

#### Summaries

* `wwk summary --from <ISO> --to <ISO> [--group-by app|title|tag|day] [--json]`
* `wwk today [--json]`
* `wwk week [--json]`

#### Export

* `wwk export --from <ISO> --to <ISO> --format csv|json --out <path|-> [--include-titles true|false]`

#### Edits

* `wwk edit delete --from <ISO> --to <ISO> [--note <text>]`
* `wwk edit add --from <ISO> --to <ISO> --app-name <text> [--bundle-id <id>] [--title <text>] [--tags <t1,t2>] [--note <text>]`
* `wwk tag apply --from <ISO> --to <ISO> --tag <name>`
* `wwk tag remove --from <ISO> --to <ISO> --tag <name>`
* `wwk edit undo --id <uee_id>`

#### Tag management

* `wwk tag list [--json]`
* `wwk tag create --name <text>`
* `wwk tag retire --name <text>`
* `wwk tag rename --from <old> --to <new>` (implementation can be create+retire)

#### Diagnostics

* `wwk doctor` (checks permissions, agent running, db integrity)
* `wwk db verify` (runs `PRAGMA integrity_check`)
* `wwk db info` (schema version, counts, date ranges)

---

## 11. Repo structure and module boundaries

### 11.1 Top-level layout

```
repo/
  README.md
  LICENSE
  PRIVACY.md
  SECURITY.md
  CONTRIBUTING.md
  CODE_OF_CONDUCT.md
  docs/
    architecture.md
    datastore.md
    cli.md
    app-store.md
  WellWhaddyaKnow.xcodeproj (or SwiftPM + Xcode workspace)

  Sources/
    Shared/
      CoreTime/
      CoreModel/
      Storage/
      Sensors/
      Timeline/
      Reporting/
      XPCProtocol/

    WellWhaddyaKnowApp/         (menu bar + viewer)
    WellWhaddyaKnowAgent/       (wwkd)
    WellWhaddyaKnowCLI/         (wwk)

  Tests/
    Unit/
    Integration/
    Fixtures/
```

### 11.2 Module responsibilities

#### Shared/CoreModel

* Domain models: identity, events, edits, tags
* Strict types for timestamps and intervals

#### Shared/Storage

* SQLite connection management
* Migrations
* Insert helpers for dimension tables (applications, window_titles)
* Query helpers for reporting primitives

#### Shared/Sensors

* Wrappers around NSWorkspace notifications, Quartz session probe, Accessibility observer
* Emits typed in-memory events into agent pipeline

#### Shared/Timeline

* Deterministic timeline builder:

  * build working intervals from system_state_events
  * build raw segments from raw_activity_events
  * apply edits overlay

#### Shared/Reporting

* Grouping and aggregation over EffectiveSegments
* Export serialization (CSV/JSON)

#### Shared/XPCProtocol

* NSXPC interfaces:

  * status
  * submit edit event
  * tag operations
  * export snapshot request
  * health/doctor

#### WellWhaddyaKnowAgent

* Owns event loop
* Owns write transactions
* Implements XPC listener

#### WellWhaddyaKnowApp

* Menu bar and viewer UI
* Reads reports via direct DB reads OR via agent “snapshot” call
* All edits go to agent

#### WellWhaddyaKnowCLI

* Read-only reports via SQLite
* Edits via XPC

---

## 12. App Store compliance considerations

### 12.1 Background agent / login item

* Use `SMAppService` (macOS 13+) to register the agent as a background task/login item. ([Apple Developer][1])
* Respect user control: users can disable background items in System Settings. The app must handle “agent disabled” gracefully and surface the disabled state.

### 12.2 Sandboxing and entitlements

Must-have:

* App Sandbox enabled for all executables (app, agent, CLI).
* App Group entitlement for shared SQLite access.

Must NOT include:

* Network client/server entitlements.
* Screen Recording entitlements (avoid ScreenCaptureKit, avoid CGWindowListCreateImage).
* Apple Events automation entitlements (do not control other apps).

### 12.3 Accessibility permission

* Accessibility access is user-granted via System Settings.
* The app must not attempt to bypass permission.
* If permission not granted, must still function with app-only attribution.

### 12.4 Privacy manifest / required reason APIs

* Include `PrivacyInfo.xcprivacy` for each target.
* Apple requires describing use of certain “required reason APIs” for App Store submissions (effective May 1, 2024 for acceptance in App Store Connect). ([Apple Developer][11])

Implementation requirement:

* Inventory APIs used (file timestamps, system boot time, etc.) and declare reasons accordingly.

### 12.5 No telemetry, no analytics

* Do not include third-party analytics SDKs.
* Do not phone home.
* Do not collect device identifiers beyond the locally-generated machine_id stored in identity.

### 12.5 CLI exclusion from Mac App Store build

* The Mac App Store build **does not include** the `wwk` CLI.
* No command-line executables are installed, exposed, or added to PATH by the App Store build.
* The CLI is distributed separately via Homebrew and direct download.

---

## 13. Privacy and threat model

### 13.1 Data collected (explicit)

Collected:

* Timestamps of working intervals (unlock-derived)
* Foreground app bundle id and display name
* Foreground window title (when Accessibility is granted)
* User edits: added/deleted ranges, tags

Not collected:

* Keystrokes
* Mouse movement
* Screenshots
* Screen contents
* Network activity

### 13.2 Storage and access boundaries

* Data stored only locally in sandboxed App Group container.
* Other apps cannot read it unless they share the same App Group entitlement (which they should not).
* Any process running as the same user with sufficient filesystem access could read data if it breaks out of sandbox via user action (exports) or local compromise.

### 13.3 Threats and mitigations

Threat: Window titles contain sensitive info (documents, client names, URLs in some apps)

* Mitigation: make title capture permission explicit and clearly described.
* Mitigation: support deletion of time ranges as first-class.
* Mitigation: export UI includes “exclude window titles” toggle.

Threat: Agent downtime creates ambiguous time

* Mitigation: never invent time during gaps; label as unobserved.

Threat: Tampering with DB

* Mitigation: append-only raw tables enforced by triggers.
* Mitigation: edits are also append-only; destructive operations are expressed as edit events.

Threat: Forensics

* Mitigation: if user deletes ranges, ensure export and UI views respect deletions.
* Note: physical disk recovery is out of scope; FileVault is recommended for at-rest protection.

### 13.4 Privacy posture statement

* The product is an on-device personal log.
* No “productivity scoring.”
* No remote sync.

---

## 14. Licensing and documentation expectations

### 14.1 License

* Use an OSI-approved license (recommendation: **MIT** or **Apache-2.0**).
* Must include:

  * `LICENSE`
  * SPDX identifier in source headers (implementation detail)

### 14.2 Documentation (minimum set)

* `README.md`: what it does, what it does not, how to install, how to use menu bar + viewer + CLI
* `PRIVACY.md`: plain-language disclosure of collected data fields and where stored
* `docs/architecture.md`: brief overview of event sourcing model and state machine
* `docs/datastore.md`: schema description and migration strategy
* `docs/cli.md`: CLI command reference
* `docs/app-store.md`: entitlements, privacy manifest notes, permission prompts

### 14.3 Maintenance expectations

* Semantic versioning.
* Migration tests: schema upgrades must preserve all prior data.

---

### 14.4 Testing
## Testing policy (normative)

Testing is a first-class requirement of this specification.

### General rules

* All public functions, methods, and exported APIs **must** have direct unit test coverage.
* All CLI subcommands **must** have at least one test covering:
  * successful execution
  * invalid input or error handling
* Tests are written **as development proceeds**, not deferred.
* A feature or module is considered incomplete if corresponding tests are missing.

### Scope-specific requirements

* Storage and schema code:
  * Every mutation path must be covered by tests.
  * Immutability guarantees must be asserted by failing tests.
* Timeline builder:
  * All edge cases described in the spec must be covered by fixture-driven tests.
  * Determinism must be verified by repeated runs against the same fixtures.
* CLI:
  * Each top-level command and subcommand requires explicit tests.
  * CLI output must be testable in both human-readable and `--json` modes where applicable.

### Enforcement

* Code that introduces new public behavior without tests is **non-compliant with this specification**.
* Test coverage is expected to grow monotonically with functionality.

## Implementation acceptance criteria (must-pass checks)

1. If user unlocks screen at T0 and locks at T1, working time includes `[T0, T1)` exactly.
2. If user sleeps system at T2, working time ends at T2 even if previously unlocked.
3. If user wakes at T3 and remains locked, no working time is counted until unlock.
4. Foreground attribution:

   * Switching apps changes attribution within 1 second.
   * Title changes (tab changes, document changes) are captured when AX supports it; fallback polling captures within 1 second.
5. No network entitlements; no outbound network calls in codebase.
6. Raw tables reject UPDATE/DELETE due to triggers.
7. Edits do not mutate raw data and are reflected in UI, CLI, exports.
8. CSV/JSON exports match effective timeline exactly.

---

## Do this next:

1. Create the repo skeleton and targets: `WellWhaddyaKnowApp`, `WellWhaddyaKnowAgent`, `WellWhaddyaKnowCLI`, plus `Shared/*` modules.
2. Implement SQLite migrations exactly per schema above, including immutability triggers and WAL configuration.
3. Implement the agent state machine first (lock/console/awake -> working), then emit `system_state_events`.
4. Add foreground app detection (`didActivateApplicationNotification`) and emit `raw_activity_events`.
5. Add Accessibility title capture with AXObserver + 1s poll fallback, including degraded mode without permission.
6. Implement the deterministic timeline builder (raw -> effective with edits) and lock it down with fixtures.
7. Build UI timeline + editing actions that only write `user_edit_events` via XPC.
8. Build CLI read-only reporting + XPC edit commands + export.

[1]: https://developer.apple.com/documentation/servicemanagement/smappservice?utm_source=chatgpt.com "SMAppService | Apple Developer Documentation"
[2]: https://developer.apple.com/documentation/coregraphics/cgsessioncopycurrentdictionary%28%29?utm_source=chatgpt.com "CGSessionCopyCurrentDictionary()"
[3]: https://stackoverflow.com/questions/11505255/osx-check-if-the-screen-is-locked?utm_source=chatgpt.com "macos - OSX: check if the screen is locked"
[4]: https://developer.apple.com/documentation/appkit/nsworkspace/sessiondidresignactivenotification?utm_source=chatgpt.com "sessionDidResignActiveNotificati..."
[5]: https://developer.apple.com/documentation/appkit/nsworkspace/willsleepnotification?utm_source=chatgpt.com "willSleepNotification | Apple Developer Documentation"
[6]: https://developer.apple.com/documentation/appkit/nsworkspace/didwakenotification?language=objc&utm_source=chatgpt.com "NSWorkspaceDidWakeNotification"
[7]: https://developer.apple.com/documentation/appkit/nsworkspace/willpoweroffnotification?utm_source=chatgpt.com "willPowerOffNotification | Apple Developer Documentation"
[8]: https://developer.apple.com/documentation/appkit/nsworkspace/didactivateapplicationnotification?utm_source=chatgpt.com "didActivateApplicationNotification"
[9]: https://developer.apple.com/documentation/applicationservices/kaxtitlechangednotification?utm_source=chatgpt.com "kAXTitleChangedNotification"
[10]: https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/FastUserSwitching.html "https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPMultipleUsers/Concepts/FastUserSwitching.html"
[11]: https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api?utm_source=chatgpt.com "Describing use of required reason API"
