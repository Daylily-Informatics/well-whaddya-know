// SPDX-License-Identifier: MIT
// SchemaManager.swift - Schema versioning and forward-only migrations

import Foundation

/// Represents a single database migration
public struct Migration {
    /// The version this migration upgrades to
    public let version: Int32
    
    /// Human-readable description of the migration
    public let description: String
    
    /// SQL statements to execute for this migration
    public let statements: [String]
    
    public init(version: Int32, description: String, statements: [String]) {
        self.version = version
        self.description = description
        self.statements = statements
    }
}

/// Manages database schema versioning and migrations.
/// Implements forward-only migration system per SPEC.md Section 6.3.
public final class SchemaManager {
    
    private let connection: DatabaseConnection
    
    /// All registered migrations in version order
    private var migrations: [Migration] = []
    
    /// Creates a new schema manager
    /// - Parameter connection: An open database connection
    public init(connection: DatabaseConnection) {
        self.connection = connection
        registerMigrations()
    }
    
    /// Registers all known migrations
    private func registerMigrations() {
        // Version 1: Initial schema
        migrations.append(Migration(
            version: 1,
            description: "Initial schema with all tables, indexes, and immutability triggers",
            statements: Schema.allStatements
        ))
        
        // Future migrations would be added here:
        // migrations.append(Migration(version: 2, description: "...", statements: [...]))
    }
    
    /// Gets the current schema version from the database
    public func getCurrentVersion() throws -> Int32 {
        try connection.getSchemaVersion()
    }
    
    /// Initializes a new database with the current schema
    /// - Throws: DatabaseError if initialization fails
    public func initializeSchema() throws {
        let currentVersion = try getCurrentVersion()
        
        if currentVersion == 0 {
            // Fresh database - apply all statements directly
            try applyInitialSchema()
        } else if currentVersion < Schema.currentVersion {
            // Existing database - run migrations
            try runMigrations(from: currentVersion)
        } else if currentVersion > Schema.currentVersion {
            throw DatabaseError.schemaVersionMismatch(
                expected: Schema.currentVersion,
                actual: currentVersion
            )
        }
        // If currentVersion == Schema.currentVersion, nothing to do
    }
    
    /// Applies the initial schema to a fresh database
    private func applyInitialSchema() throws {
        // Execute all DDL statements
        for statement in Schema.allStatements {
            try connection.execute(statement)
        }
        
        // Record the migration
        try recordMigration(version: Schema.currentVersion, description: "Initial schema")
        
        // Set the schema version
        try connection.setSchemaVersion(Schema.currentVersion)
    }
    
    /// Runs all pending migrations from the given version
    private func runMigrations(from startVersion: Int32) throws {
        let pendingMigrations = migrations.filter { $0.version > startVersion }
            .sorted { $0.version < $1.version }
        
        for migration in pendingMigrations {
            try applyMigration(migration)
        }
    }
    
    /// Applies a single migration
    private func applyMigration(_ migration: Migration) throws {
        // Execute all statements in the migration
        for statement in migration.statements {
            do {
                try connection.execute(statement)
            } catch {
                throw DatabaseError.migrationFailed(
                    version: migration.version,
                    reason: "Failed to execute: \(statement). Error: \(error)"
                )
            }
        }
        
        // Record the migration
        try recordMigration(version: migration.version, description: migration.description)
        
        // Update the schema version
        try connection.setSchemaVersion(migration.version)
    }
    
    /// Records a migration in the schema_migrations table
    private func recordMigration(version: Int32, description: String) throws {
        let nowMicroseconds = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let escapedDescription = description.replacingOccurrences(of: "'", with: "''")
        
        let sql = """
            INSERT INTO schema_migrations (version, applied_ts_us, description)
            VALUES (\(version), \(nowMicroseconds), '\(escapedDescription)');
            """
        
        try connection.execute(sql)
    }
    
    /// Checks if the schema is up to date
    public func isSchemaUpToDate() throws -> Bool {
        try getCurrentVersion() == Schema.currentVersion
    }
    
    /// Returns a list of applied migrations from the database
    public func getAppliedMigrations() throws -> [(version: Int32, appliedAt: Int64, description: String?)] {
        // This would require a query method on DatabaseConnection
        // For now, we just verify the version
        let version = try getCurrentVersion()
        if version > 0 {
            return [(version: version, appliedAt: 0, description: nil)]
        }
        return []
    }
}

