// SPDX-License-Identifier: MIT
// ImmutabilityTests.swift - Tests for immutability triggers on event tables

import Testing
import SQLite3
@testable import Storage

/// Tests that immutability triggers correctly prevent UPDATE and DELETE operations
/// on system_state_events, raw_activity_events, and user_edit_events tables.
@Suite("Immutability Trigger Tests")
struct ImmutabilityTests {

    /// Creates a connection with schema and prerequisite data
    private func setupConnection() throws -> DatabaseConnection {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()
        try insertPrerequisiteData(connection)
        return connection
    }

    /// Inserts data required by foreign key constraints
    private func insertPrerequisiteData(_ connection: DatabaseConnection) throws {
        // Insert an agent_run for foreign key references
        try connection.execute("""
            INSERT INTO agent_runs (run_id, started_ts_us, started_monotonic_ns, agent_version, os_version)
            VALUES ('test-run-1', 1000000, 1000000000, '1.0.0', '14.0');
            """)

        // Insert an application for raw_activity_events
        try connection.execute("""
            INSERT INTO applications (app_id, bundle_id, display_name, first_seen_ts_us)
            VALUES (1, 'com.test.app', 'Test App', 1000000);
            """)

        // Insert a tag for user_edit_events
        try connection.execute("""
            INSERT INTO tags (tag_id, name, created_ts_us, sort_order)
            VALUES (1, 'test-tag', 1000000, 0);
            """)
    }
    
    // MARK: - system_state_events Immutability Tests

    @Test("system_state_events rejects UPDATE")
    func systemStateEventsRejectsUpdate() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Given: A row in system_state_events
        try connection.execute("""
            INSERT INTO system_state_events (
                run_id, event_ts_us, event_monotonic_ns,
                is_system_awake, is_session_on_console, is_screen_locked, is_working,
                event_kind, source, tz_identifier, tz_offset_seconds
            ) VALUES (
                'test-run-1', 1000000, 1000000000,
                1, 1, 0, 1,
                'agent_start', 'startup_probe', 'America/Los_Angeles', -28800
            );
            """)

        // When: We attempt to UPDATE the row
        // Then: The trigger should abort with an error
        #expect(throws: DatabaseError.self) {
            try connection.execute("""
                UPDATE system_state_events SET is_working = 0 WHERE sse_id = 1;
                """)
        }
    }

    @Test("system_state_events rejects DELETE")
    func systemStateEventsRejectsDelete() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Given: A row in system_state_events
        try connection.execute("""
            INSERT INTO system_state_events (
                run_id, event_ts_us, event_monotonic_ns,
                is_system_awake, is_session_on_console, is_screen_locked, is_working,
                event_kind, source, tz_identifier, tz_offset_seconds
            ) VALUES (
                'test-run-1', 1000000, 1000000000,
                1, 1, 0, 1,
                'agent_start', 'startup_probe', 'America/Los_Angeles', -28800
            );
            """)

        // When: We attempt to DELETE the row
        // Then: The trigger should abort with an error
        #expect(throws: DatabaseError.self) {
            try connection.execute("""
                DELETE FROM system_state_events WHERE sse_id = 1;
                """)
        }
    }

    // MARK: - raw_activity_events Immutability Tests

    @Test("raw_activity_events rejects UPDATE")
    func rawActivityEventsRejectsUpdate() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Given: A row in raw_activity_events
        try connection.execute("""
            INSERT INTO raw_activity_events (
                run_id, event_ts_us, event_monotonic_ns,
                app_id, pid, title_status, reason, is_working
            ) VALUES (
                'test-run-1', 1000000, 1000000000,
                1, 12345, 'ok', 'working_began', 1
            );
            """)

        // When: We attempt to UPDATE the row
        // Then: The trigger should abort with an error
        #expect(throws: DatabaseError.self) {
            try connection.execute("""
                UPDATE raw_activity_events SET is_working = 0 WHERE rae_id = 1;
                """)
        }
    }

    @Test("raw_activity_events rejects DELETE")
    func rawActivityEventsRejectsDelete() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Given: A row in raw_activity_events
        try connection.execute("""
            INSERT INTO raw_activity_events (
                run_id, event_ts_us, event_monotonic_ns,
                app_id, pid, title_status, reason, is_working
            ) VALUES (
                'test-run-1', 1000000, 1000000000,
                1, 12345, 'ok', 'working_began', 1
            );
            """)

        // When: We attempt to DELETE the row
        // Then: The trigger should abort with an error
        #expect(throws: DatabaseError.self) {
            try connection.execute("""
                DELETE FROM raw_activity_events WHERE rae_id = 1;
                """)
        }
    }

    // MARK: - user_edit_events Immutability Tests

    @Test("user_edit_events rejects UPDATE")
    func userEditEventsRejectsUpdate() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Given: A row in user_edit_events
        try connection.execute("""
            INSERT INTO user_edit_events (
                created_ts_us, created_monotonic_ns,
                author_username, author_uid,
                client, client_version,
                op, start_ts_us, end_ts_us
            ) VALUES (
                1000000, 1000000000,
                'testuser', 501,
                'cli', '1.0.0',
                'delete_range', 1000000, 2000000
            );
            """)

        // When: We attempt to UPDATE the row
        // Then: The trigger should abort with an error
        #expect(throws: DatabaseError.self) {
            try connection.execute("""
                UPDATE user_edit_events SET note = 'modified' WHERE uee_id = 1;
                """)
        }
    }

    @Test("user_edit_events rejects DELETE")
    func userEditEventsRejectsDelete() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Given: A row in user_edit_events
        try connection.execute("""
            INSERT INTO user_edit_events (
                created_ts_us, created_monotonic_ns,
                author_username, author_uid,
                client, client_version,
                op, start_ts_us, end_ts_us
            ) VALUES (
                1000000, 1000000000,
                'testuser', 501,
                'cli', '1.0.0',
                'delete_range', 1000000, 2000000
            );
            """)

        // When: We attempt to DELETE the row
        // Then: The trigger should abort with an error
        #expect(throws: DatabaseError.self) {
            try connection.execute("""
                DELETE FROM user_edit_events WHERE uee_id = 1;
                """)
        }
    }

    // MARK: - INSERT Still Works Tests

    @Test("system_state_events allows INSERT")
    func systemStateEventsAllowsInsert() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Verify INSERT still works (triggers only block UPDATE/DELETE)
        try connection.execute("""
            INSERT INTO system_state_events (
                run_id, event_ts_us, event_monotonic_ns,
                is_system_awake, is_session_on_console, is_screen_locked, is_working,
                event_kind, source, tz_identifier, tz_offset_seconds
            ) VALUES (
                'test-run-1', 2000000, 2000000000,
                1, 1, 0, 1,
                'state_change', 'timer_poll', 'America/Los_Angeles', -28800
            );
            """)
    }

    @Test("raw_activity_events allows INSERT")
    func rawActivityEventsAllowsInsert() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        try connection.execute("""
            INSERT INTO raw_activity_events (
                run_id, event_ts_us, event_monotonic_ns,
                app_id, pid, title_status, reason, is_working
            ) VALUES (
                'test-run-1', 2000000, 2000000000,
                1, 12345, 'ok', 'app_activated', 1
            );
            """)
    }

    @Test("user_edit_events allows INSERT")
    func userEditEventsAllowsInsert() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        try connection.execute("""
            INSERT INTO user_edit_events (
                created_ts_us, created_monotonic_ns,
                author_username, author_uid,
                client, client_version,
                op, start_ts_us, end_ts_us
            ) VALUES (
                2000000, 2000000000,
                'testuser', 501,
                'ui', '1.0.0',
                'add_range', 3000000, 4000000
            );
            """)
    }
}
