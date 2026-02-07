# Architecture Overview

WellWhaddyaKnow uses an **event-sourcing architecture** where all state changes are recorded as immutable events in SQLite.

## Components

```
┌─────────────────────────────────────────────────────────────────┐
│                        User Interface                            │
├─────────────────┬─────────────────────┬─────────────────────────┤
│  Menu Bar App   │   Viewer/Editor     │         CLI             │
│  (popover)      │   (window)          │        (wwk)            │
└────────┬────────┴──────────┬──────────┴────────────┬────────────┘
         │                   │                       │
         │              XPC Protocol                 │
         │                   │                       │
         ▼                   ▼                       ▼
┌─────────────────────────────────────────────────────────────────┐
│                    Background Agent (wwkd)                       │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    State Machine                          │   │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐  ┌─────────────┐  │   │
│  │  │ Session │  │  Sleep  │  │Foreground│  │Accessibility│  │   │
│  │  │ Sensor  │  │ Sensor  │  │  Sensor  │  │   Sensor    │  │   │
│  │  └────┬────┘  └────┬────┘  └────┬────┘  └──────┬──────┘  │   │
│  │       │            │            │              │          │   │
│  │       └────────────┴────────────┴──────────────┘          │   │
│  │                         │                                  │   │
│  │                    Event Stream                            │   │
│  └─────────────────────────┼────────────────────────────────┘   │
│                            │                                     │
│                            ▼                                     │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │                    Storage Layer                          │   │
│  │                   (SQLite + WAL)                          │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
```

## Event Sourcing Model

### Core Principles

1. **Immutability**: Raw events are never modified after creation
2. **Append-only**: New events are always appended, never updated
3. **Deterministic replay**: Timeline can be rebuilt from events at any time
4. **Audit trail**: Complete history of all changes is preserved
5. **UTC storage**: All timestamps stored as UTC microseconds; display timezone is presentation-only

### Event Tables

| Table | Description | Trigger |
|-------|-------------|---------|
| `system_state_events` | State snapshots (sleep/wake, lock/unlock, agent lifecycle) | System notifications, IOKit, timer poll |
| `raw_activity_events` | Foreground app/window snapshots | App activation, AX title change, poll |
| `user_edit_events` | Deletes, adds, tag/untag, undo | User actions via UI or CLI |

### Dimension Tables

| Table | Description |
|-------|-------------|
| `applications` | Deduplicated app bundle IDs and display names |
| `window_titles` | Deduplicated window title strings |
| `tags` | Tag definitions with optional retirement |

### Timeline Building

The timeline is computed by:

1. Loading all events for a date range
2. Building "effective segments" from raw activity intersected with working intervals
3. Filtering active edits (resolving undo chains recursively)
4. Applying user edits (deletes, adds, tags)
5. Splitting by day boundaries
6. Computing aggregations

```
Raw Events → Timeline Builder → Effective Segments → Reports
                    ↑
         User Edits (filtered by undo resolution)
```

## State Machine

The agent maintains a boolean-flag state with a derived `isWorking` property:

```
isWorking = !isPausedByUser && isSystemAwake && isSessionOnConsole && !isScreenLocked
```

| Flag | Source |
|------|--------|
| `isSystemAwake` | IOKit / NSWorkspace sleep/wake notifications |
| `isSessionOnConsole` | `CGSessionCopyCurrentDictionary` (fast user switching) |
| `isScreenLocked` | `CGSessionCopyCurrentDictionary` (screen lock state) |
| `isPausedByUser` | Manual pause via UI/CLI (resets on agent restart) |

Initial state is conservative: `isSessionOnConsole=false, isScreenLocked=true` until the first probe.

### State Transitions

```
                    unlock / wake / resume
    ┌────────────────────────────────────────┐
    │                                        ▼
┌───┴────────┐                         ┌──────────┐
│ isWorking  │                         │ isWorking │
│  = false   │                         │  = true   │
└───┬────────┘                         └────┬─────┘
    ▲                                       │
    │                                       │
    └───────────────────────────────────────┘
              lock / sleep / pause / switch-out
```

## Sensors

### SessionStateSensor
- Monitors screen lock/unlock via `CGSessionCopyCurrentDictionary`
- Polls `kCGSessionOnConsoleKey` and `CGSSessionScreenIsLocked`
- Emits `state_change` events when `isWorking` transitions

### SleepWakeSensor
- Monitors system sleep/wake via `NSWorkspace` notifications and IOKit
- Emits `sleep`, `wake`, `poweroff` events

### ForegroundAppSensor
- Monitors active application via `NSWorkspace.didActivateApplicationNotification`
- Records `app_id` (FK into `applications` dimension table) and process ID
- Self-tracking prevention: excludes `com.daylily.wellwhaddyaknow` bundle IDs

### AccessibilitySensor
- Captures window titles via macOS Accessibility API (`AXUIElementCopyAttributeValue`)
- Monitors `AXFocusedWindowChanged` and `AXTitleChanged` notifications
- Records `title_id` (FK into `window_titles` dimension table)
- Falls back gracefully if permission denied; records `ax_error_code` on failure

## Data Flow

```
1. Sensor detects change
2. Agent state machine updates boolean flags, derives isWorking
3. Event appended to SQLite (immutable, UTC microseconds)
4. UI/CLI queries timeline builder (reads directly via WAL)
5. Timeline builder computes effective segments
6. Display timezone applied at presentation layer
```

## IPC Protocol

The menu bar app and CLI communicate with the agent via **JSON-RPC over Unix domain sockets** (not Apple XPC). The socket path is derived from the app group container.

| Method | Direction | Description |
|--------|-----------|-------------|
| `getStatus` | Client → Agent | Current working state, app, title, AX status |
| `submitDeleteRange` | Client → Agent | Delete a time range |
| `submitAddRange` | Client → Agent | Add a manual time range |
| `submitUndoEdit` | Client → Agent | Undo a previous edit |
| `applyTag` | Client → Agent | Apply tag to time range |
| `removeTag` | Client → Agent | Remove tag from time range |
| `listTags` | Client → Agent | List all tags |
| `createTag` | Client → Agent | Create a new tag |
| `retireTag` | Client → Agent | Retire (soft-delete) a tag |
| `exportTimeline` | Client → Agent | Export timeline to CSV/JSON |
| `getHealth` | Client → Agent | DB integrity, permissions, uptime |
| `verifyDatabase` | Client → Agent | Run `PRAGMA integrity_check` |
| `pauseTracking` | Client → Agent | Manually pause tracking |
| `resumeTracking` | Client → Agent | Resume after manual pause |

## Concurrency Model

- **Single writer**: Only the agent writes to SQLite
- **Multiple readers**: App and CLI can read directly via WAL
- **WAL mode**: Enables concurrent reads during writes
- **Actor isolation**: The `Agent` is a Swift actor; sensors dispatch events to it
- **Sendable compliance**: All shared types conform to `Sendable` (Swift 6 strict concurrency)
