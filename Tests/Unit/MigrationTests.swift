// SPDX-License-Identifier: MIT
// MigrationTests.swift - Tests for schema versioning and migration system

import Testing
import SQLite3
@testable import Storage

/// Tests for schema versioning and migration paths.
@Suite("Migration Tests")
struct MigrationTests {

    /// Creates a fresh in-memory connection
    private func createConnection() throws -> DatabaseConnection {
        let connection = DatabaseConnection(path: ":memory:")
        try connection.open()
        return connection
    }

    // MARK: - Schema Version Tests

    @Test("Fresh database has version zero")
    func freshDatabaseHasVersionZero() throws {
        let connection = try createConnection()
        defer { connection.close() }

        let version = try connection.getSchemaVersion()
        #expect(version == 0, "Fresh database should have version 0")
    }

    @Test("Schema version can be set")
    func schemaVersionCanBeSet() throws {
        let connection = try createConnection()
        defer { connection.close() }

        try connection.setSchemaVersion(42)
        let version = try connection.getSchemaVersion()
        #expect(version == 42)
    }

    @Test("Schema version persists across queries")
    func schemaVersionPersistsAcrossQueries() throws {
        let connection = try createConnection()
        defer { connection.close() }

        try connection.setSchemaVersion(5)

        // Execute some other queries
        try connection.execute("SELECT 1;")
        try connection.execute("SELECT 2;")

        let version = try connection.getSchemaVersion()
        #expect(version == 5)
    }

    // MARK: - Migration System Tests

    @Test("Initialize schema from scratch")
    func initializeSchemaFromScratch() throws {
        let connection = try createConnection()
        defer { connection.close() }

        let schemaManager = SchemaManager(connection: connection)

        // Before initialization
        #expect(try connection.getSchemaVersion() == 0)

        // Initialize
        try schemaManager.initializeSchema()

        // After initialization
        #expect(try connection.getSchemaVersion() == Schema.currentVersion)
    }

    @Test("Migration is recorded in schema_migrations table")
    func migrationRecordedInTable() throws {
        let connection = try createConnection()
        defer { connection.close() }

        let schemaManager = SchemaManager(connection: connection)
        try schemaManager.initializeSchema()

        // Check that migration was recorded
        guard let db = connection.rawPointer else {
            Issue.record("Database not open")
            return
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = "SELECT version, description FROM schema_migrations WHERE version = ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            Issue.record("Failed to prepare statement")
            return
        }

        sqlite3_bind_int(statement, 1, Schema.currentVersion)

        #expect(sqlite3_step(statement) == SQLITE_ROW, "Migration record should exist")

        let version = sqlite3_column_int(statement, 0)
        #expect(version == Schema.currentVersion)
    }

    @Test("isSchemaUpToDate returns correct value")
    func isSchemaUpToDate() throws {
        let connection = try createConnection()
        defer { connection.close() }

        let schemaManager = SchemaManager(connection: connection)

        // Before initialization
        #expect(try schemaManager.isSchemaUpToDate() == false)

        // After initialization
        try schemaManager.initializeSchema()
        #expect(try schemaManager.isSchemaUpToDate() == true)
    }

    @Test("Schema version mismatch throws error")
    func schemaVersionMismatchThrows() throws {
        let connection = try createConnection()
        defer { connection.close() }

        // Set a version higher than current
        try connection.setSchemaVersion(Schema.currentVersion + 10)

        let schemaManager = SchemaManager(connection: connection)

        #expect(throws: DatabaseError.self) {
            try schemaManager.initializeSchema()
        }
    }

    @Test("Multiple initializations are safe")
    func multipleInitializationsAreSafe() throws {
        let connection = try createConnection()
        defer { connection.close() }

        let schemaManager = SchemaManager(connection: connection)

        // Initialize multiple times
        try schemaManager.initializeSchema()
        try schemaManager.initializeSchema()
        try schemaManager.initializeSchema()

        // Should still be at current version
        #expect(try connection.getSchemaVersion() == Schema.currentVersion)
    }

    // MARK: - Schema Constants Tests

    @Test("Schema current version is positive")
    func schemaCurrentVersionIsPositive() {
        #expect(Schema.currentVersion > 0, "Schema version should be positive")
    }

    @Test("All statement arrays are not empty")
    func allStatementsNotEmpty() {
        #expect(!Schema.allStatements.isEmpty, "Should have DDL statements")
        #expect(!Schema.allTableStatements.isEmpty, "Should have table statements")
        #expect(!Schema.allIndexStatements.isEmpty, "Should have index statements")
        #expect(!Schema.allTriggerStatements.isEmpty, "Should have trigger statements")
    }

    @Test("All statements are valid SQL")
    func allStatementsAreValidSQL() throws {
        let connection = try createConnection()
        defer { connection.close() }

        // Each statement should be valid SQL (parseable)
        for statement in Schema.allStatements {
            try connection.execute(statement)
        }
    }
}

