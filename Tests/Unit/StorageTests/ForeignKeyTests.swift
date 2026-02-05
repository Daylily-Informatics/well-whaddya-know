// SPDX-License-Identifier: MIT
// ForeignKeyTests.swift - Tests for foreign key constraint enforcement

import Testing
import SQLite3
@testable import Storage

/// Tests that foreign key constraints are properly enforced.
@Suite("Foreign Key Constraint Tests")
struct ForeignKeyTests {

    /// Creates a connection with schema initialized
    private func setupConnection() throws -> DatabaseConnection {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()
        return connection
    }

    // MARK: - Foreign Key Enforcement Tests

    @Test("system_state_events requires valid run_id")
    func systemStateEventsRequiresValidRunId() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Given: No agent_runs exist
        // When: We try to insert a system_state_event with invalid run_id
        // Then: Foreign key constraint should fail
        #expect(throws: DatabaseError.self) {
            try connection.execute("""
                INSERT INTO system_state_events (
                    run_id, event_ts_us, event_monotonic_ns,
                    is_system_awake, is_session_on_console, is_screen_locked, is_working,
                    event_kind, source, tz_identifier, tz_offset_seconds
                ) VALUES (
                    'nonexistent-run', 1000000, 1000000000,
                    1, 1, 0, 1,
                    'agent_start', 'startup_probe', 'America/Los_Angeles', -28800
                );
                """)
        }
    }

    @Test("raw_activity_events requires valid run_id")
    func rawActivityEventsRequiresValidRunId() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Given: An application exists but no agent_runs
        try connection.execute("""
            INSERT INTO applications (app_id, bundle_id, display_name, first_seen_ts_us)
            VALUES (1, 'com.test.app', 'Test App', 1000000);
            """)

        // When: We try to insert with invalid run_id
        // Then: Foreign key constraint should fail
        #expect(throws: DatabaseError.self) {
            try connection.execute("""
                INSERT INTO raw_activity_events (
                    run_id, event_ts_us, event_monotonic_ns,
                    app_id, pid, title_status, reason, is_working
                ) VALUES (
                    'nonexistent-run', 1000000, 1000000000,
                    1, 12345, 'ok', 'working_began', 1
                );
                """)
        }
    }

    @Test("raw_activity_events requires valid app_id")
    func rawActivityEventsRequiresValidAppId() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Given: An agent_run exists but no applications
        try connection.execute("""
            INSERT INTO agent_runs (run_id, started_ts_us, started_monotonic_ns, agent_version, os_version)
            VALUES ('test-run-1', 1000000, 1000000000, '1.0.0', '14.0');
            """)

        // When: We try to insert with invalid app_id
        // Then: Foreign key constraint should fail
        #expect(throws: DatabaseError.self) {
            try connection.execute("""
                INSERT INTO raw_activity_events (
                    run_id, event_ts_us, event_monotonic_ns,
                    app_id, pid, title_status, reason, is_working
                ) VALUES (
                    'test-run-1', 1000000, 1000000000,
                    999, 12345, 'ok', 'working_began', 1
                );
                """)
        }
    }

    @Test("user_edit_events allows null tag_id")
    func userEditEventsAllowsNullTagId() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Given: Valid prerequisites
        // When: We insert a user_edit_event without a tag_id
        // Then: It should succeed (tag_id is nullable)
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
    }

    @Test("user_edit_events requires valid tag_id when provided")
    func userEditEventsRequiresValidTagIdWhenProvided() throws {
        let connection = try setupConnection()
        defer { connection.close() }

        // Given: No tags exist
        // When: We try to insert with invalid tag_id
        // Then: Foreign key constraint should fail
        #expect(throws: DatabaseError.self) {
            try connection.execute("""
                INSERT INTO user_edit_events (
                    created_ts_us, created_monotonic_ns,
                    author_username, author_uid,
                    client, client_version,
                    op, start_ts_us, end_ts_us,
                    tag_id
                ) VALUES (
                    1000000, 1000000000,
                    'testuser', 501,
                    'cli', '1.0.0',
                    'tag_range', 1000000, 2000000,
                    999
                );
                """)
        }
    }
}

