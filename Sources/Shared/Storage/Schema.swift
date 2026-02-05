// SPDX-License-Identifier: MIT
// Schema.swift - SQLite schema DDL exactly as specified in SPEC.md Section 6.4

import Foundation

/// Schema version constants and DDL for the well-whaddya-know database.
/// This schema is normative and must not be modified without a spec revision.
public enum Schema {
    /// Current schema version (stored in PRAGMA user_version)
    public static let currentVersion: Int32 = 1
    
    // MARK: - Core Identity and Metadata Tables
    
    static let createIdentityTable = """
        CREATE TABLE IF NOT EXISTS identity (
          identity_id            INTEGER PRIMARY KEY CHECK (identity_id = 1),
          machine_id             TEXT NOT NULL,
          username               TEXT NOT NULL,
          uid                    INTEGER NOT NULL,
          created_ts_us          INTEGER NOT NULL,
          app_group_id           TEXT NOT NULL,
          notes                  TEXT
        );
        """
    
    static let createKvMetadataTable = """
        CREATE TABLE IF NOT EXISTS kv_metadata (
          key                    TEXT PRIMARY KEY,
          value                  TEXT NOT NULL
        );
        """
    
    // MARK: - Dimension Tables
    
    static let createApplicationsTable = """
        CREATE TABLE IF NOT EXISTS applications (
          app_id                 INTEGER PRIMARY KEY,
          bundle_id              TEXT NOT NULL UNIQUE,
          display_name           TEXT NOT NULL,
          first_seen_ts_us       INTEGER NOT NULL
        );
        """
    
    static let createWindowTitlesTable = """
        CREATE TABLE IF NOT EXISTS window_titles (
          title_id               INTEGER PRIMARY KEY,
          title                  TEXT NOT NULL UNIQUE,
          first_seen_ts_us       INTEGER NOT NULL
        );
        """
    
    static let createTagsTable = """
        CREATE TABLE IF NOT EXISTS tags (
          tag_id                 INTEGER PRIMARY KEY,
          name                   TEXT NOT NULL UNIQUE,
          created_ts_us          INTEGER NOT NULL,
          retired_ts_us          INTEGER,
          sort_order             INTEGER NOT NULL DEFAULT 0
        );
        """
    
    // MARK: - Run Tracking Table
    
    static let createAgentRunsTable = """
        CREATE TABLE IF NOT EXISTS agent_runs (
          run_id                 TEXT PRIMARY KEY,
          started_ts_us          INTEGER NOT NULL,
          started_monotonic_ns   INTEGER NOT NULL,
          agent_version          TEXT NOT NULL,
          os_version             TEXT NOT NULL,
          hardware_model         TEXT,
          boot_session_id        TEXT
        );
        """
    
    // MARK: - System State Events Table (Immutable)
    
    static let createSystemStateEventsTable = """
        CREATE TABLE IF NOT EXISTS system_state_events (
          sse_id                 INTEGER PRIMARY KEY,
          run_id                 TEXT NOT NULL REFERENCES agent_runs(run_id),

          event_ts_us            INTEGER NOT NULL,
          event_monotonic_ns     INTEGER NOT NULL,

          is_system_awake        INTEGER NOT NULL CHECK (is_system_awake IN (0,1)),
          is_session_on_console  INTEGER NOT NULL CHECK (is_session_on_console IN (0,1)),
          is_screen_locked       INTEGER NOT NULL CHECK (is_screen_locked IN (0,1)),
          is_working             INTEGER NOT NULL CHECK (is_working IN (0,1)),

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

          tz_identifier          TEXT NOT NULL,
          tz_offset_seconds      INTEGER NOT NULL,

          payload_json           TEXT
        );
        """

    static let createSystemStateEventsIndexes = [
        "CREATE INDEX IF NOT EXISTS idx_sse_event_ts ON system_state_events(event_ts_us);",
        "CREATE INDEX IF NOT EXISTS idx_sse_run_id ON system_state_events(run_id);"
    ]

    static let createSystemStateEventsTriggers = [
        """
        CREATE TRIGGER IF NOT EXISTS trg_sse_no_update
        BEFORE UPDATE ON system_state_events
        BEGIN
          SELECT RAISE(ABORT, 'system_state_events is immutable');
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS trg_sse_no_delete
        BEFORE DELETE ON system_state_events
        BEGIN
          SELECT RAISE(ABORT, 'system_state_events is immutable');
        END;
        """
    ]

    // MARK: - Raw Activity Events Table (Immutable)

    static let createRawActivityEventsTable = """
        CREATE TABLE IF NOT EXISTS raw_activity_events (
          rae_id                 INTEGER PRIMARY KEY,
          run_id                 TEXT NOT NULL REFERENCES agent_runs(run_id),

          event_ts_us            INTEGER NOT NULL,
          event_monotonic_ns     INTEGER NOT NULL,

          app_id                 INTEGER NOT NULL REFERENCES applications(app_id),
          pid                    INTEGER NOT NULL,

          title_id               INTEGER REFERENCES window_titles(title_id),

          title_status           TEXT NOT NULL CHECK (
                                   title_status IN (
                                     'ok',
                                     'no_permission',
                                     'not_supported',
                                     'no_window',
                                     'error'
                                   )
                                 ),

          reason                 TEXT NOT NULL CHECK (
                                   reason IN (
                                     'working_began',
                                     'app_activated',
                                     'ax_title_changed',
                                     'ax_focused_window_changed',
                                     'poll_fallback'
                                   )
                                 ),

          is_working             INTEGER NOT NULL CHECK (is_working IN (0,1)),

          ax_error_code          INTEGER,
          payload_json           TEXT
        );
        """

    static let createRawActivityEventsIndexes = [
        "CREATE INDEX IF NOT EXISTS idx_rae_event_ts ON raw_activity_events(event_ts_us);",
        "CREATE INDEX IF NOT EXISTS idx_rae_app_id_ts ON raw_activity_events(app_id, event_ts_us);",
        "CREATE INDEX IF NOT EXISTS idx_rae_run_id ON raw_activity_events(run_id);"
    ]

    static let createRawActivityEventsTriggers = [
        """
        CREATE TRIGGER IF NOT EXISTS trg_rae_no_update
        BEFORE UPDATE ON raw_activity_events
        BEGIN
          SELECT RAISE(ABORT, 'raw_activity_events is immutable');
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS trg_rae_no_delete
        BEFORE DELETE ON raw_activity_events
        BEGIN
          SELECT RAISE(ABORT, 'raw_activity_events is immutable');
        END;
        """
    ]

    // MARK: - User Edit Events Table (Immutable)

    static let createUserEditEventsTable = """
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

          tag_id                 INTEGER REFERENCES tags(tag_id),

          manual_app_bundle_id   TEXT,
          manual_app_name        TEXT,
          manual_window_title    TEXT,

          note                   TEXT,

          target_uee_id          INTEGER REFERENCES user_edit_events(uee_id),

          payload_json           TEXT
        );
        """

    static let createUserEditEventsIndexes = [
        "CREATE INDEX IF NOT EXISTS idx_uee_created_ts ON user_edit_events(created_ts_us);",
        "CREATE INDEX IF NOT EXISTS idx_uee_range ON user_edit_events(start_ts_us, end_ts_us);",
        "CREATE INDEX IF NOT EXISTS idx_uee_op ON user_edit_events(op);"
    ]

    static let createUserEditEventsTriggers = [
        """
        CREATE TRIGGER IF NOT EXISTS trg_uee_no_update
        BEFORE UPDATE ON user_edit_events
        BEGIN
          SELECT RAISE(ABORT, 'user_edit_events is immutable');
        END;
        """,
        """
        CREATE TRIGGER IF NOT EXISTS trg_uee_no_delete
        BEFORE DELETE ON user_edit_events
        BEGIN
          SELECT RAISE(ABORT, 'user_edit_events is immutable');
        END;
        """
    ]

    // MARK: - Migration Tracking Table

    static let createMigrationsTable = """
        CREATE TABLE IF NOT EXISTS schema_migrations (
          version                INTEGER PRIMARY KEY,
          applied_ts_us          INTEGER NOT NULL,
          description            TEXT
        );
        """

    // MARK: - All DDL Statements (in order)

    /// Returns all table creation statements in dependency order
    public static var allTableStatements: [String] {
        [
            createIdentityTable,
            createKvMetadataTable,
            createApplicationsTable,
            createWindowTitlesTable,
            createTagsTable,
            createAgentRunsTable,
            createSystemStateEventsTable,
            createRawActivityEventsTable,
            createUserEditEventsTable,
            createMigrationsTable
        ]
    }

    /// Returns all index creation statements
    public static var allIndexStatements: [String] {
        createSystemStateEventsIndexes +
        createRawActivityEventsIndexes +
        createUserEditEventsIndexes
    }

    /// Returns all trigger creation statements
    public static var allTriggerStatements: [String] {
        createSystemStateEventsTriggers +
        createRawActivityEventsTriggers +
        createUserEditEventsTriggers
    }

    /// Returns all DDL statements in the correct order for schema initialization
    public static var allStatements: [String] {
        allTableStatements + allIndexStatements + allTriggerStatements
    }
}
