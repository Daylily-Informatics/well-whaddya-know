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

### Event Types

| Table | Description | Trigger |
|-------|-------------|---------|
| `system_state_events` | Lock/unlock, sleep/wake, shutdown | System notifications |
| `raw_activity_events` | App/window changes | Foreground app sensor |
| `user_edit_events` | Deletes, adds, tag applications | User actions |
| `tags` | Tag definitions | User creates tag |

### Timeline Building

The timeline is computed by:

1. Loading all events for a date range
2. Building "effective segments" from raw activity
3. Applying user edits (deletes, adds)
4. Splitting by day boundaries
5. Computing aggregations

```
Raw Events → Timeline Builder → Effective Segments → Reports
                    ↑
              User Edits
```

## State Machine

The agent maintains a state machine with these states:

| State | Description |
|-------|-------------|
| `working` | Screen unlocked, user active |
| `notWorking` | Screen locked or system sleeping |
| `unknown` | Initial state before first event |

### State Transitions

```
                    unlock
    ┌──────────────────────────────────┐
    │                                  ▼
┌───┴───┐                         ┌────────┐
│  not  │                         │working │
│working│                         │        │
└───┬───┘                         └────┬───┘
    ▲                                  │
    │                                  │
    └──────────────────────────────────┘
                  lock/sleep
```

## Sensors

### SessionStateSensor
- Monitors screen lock/unlock via `CGSessionCopyCurrentDictionary`
- Emits `screenLocked` and `screenUnlocked` events

### SleepWakeSensor
- Monitors system sleep/wake via `NSWorkspace` notifications
- Emits `systemWillSleep`, `systemDidWake`, `systemWillShutdown`

### ForegroundAppSensor
- Monitors active application via `NSWorkspace.didActivateApplicationNotification`
- Emits app bundle ID and display name

### AccessibilitySensor
- Captures window titles via Accessibility API
- Requires user permission
- Falls back gracefully if permission denied

## Data Flow

```
1. Sensor detects change
2. Agent state machine processes event
3. Event appended to SQLite (immutable)
4. UI/CLI queries timeline builder
5. Timeline builder computes effective segments
6. Results displayed to user
```

## XPC Protocol

The menu bar app and CLI communicate with the agent via XPC:

| Command | Direction | Description |
|---------|-----------|-------------|
| `getStatus` | App → Agent | Get current working state |
| `submitEdit` | App → Agent | Submit delete/add/tag operation |
| `ping` | App → Agent | Health check |

## Concurrency Model

- **Single writer**: Only the agent writes to SQLite
- **Multiple readers**: App and CLI can read directly
- **WAL mode**: Enables concurrent reads during writes
- **Actor isolation**: Swift actors for thread safety

