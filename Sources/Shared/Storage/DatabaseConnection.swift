// SPDX-License-Identifier: MIT
// DatabaseConnection.swift - SQLite connection management with required PRAGMAs

import Foundation
import SQLite3

/// Errors that can occur during database operations
public enum DatabaseError: Error, Equatable {
    case failedToOpen(String)
    case failedToExecute(String)
    case failedToSetPragma(String)
    case schemaVersionMismatch(expected: Int32, actual: Int32)
    case migrationFailed(version: Int32, reason: String)
    case foreignKeyViolation(String)
    case immutabilityViolation(String)
}

/// Manages SQLite database connections with proper configuration.
/// Implements connection initialization with required PRAGMAs from SPEC.md Section 6.1.
public final class DatabaseConnection {
    
    /// The underlying SQLite database pointer
    private var db: OpaquePointer?
    
    /// Path to the database file
    public let path: String
    
    /// Whether the connection is currently open
    public var isOpen: Bool { db != nil }
    
    /// Creates a new database connection manager
    /// - Parameter path: Path to the SQLite database file. Use ":memory:" for in-memory database.
    public init(path: String) {
        self.path = path
    }
    
    deinit {
        close()
    }
    
    /// Opens the database connection and applies required PRAGMAs.
    /// PRAGMAs applied (per SPEC.md Section 6.1):
    /// - foreign_keys = ON
    /// - journal_mode = WAL
    /// - synchronous = NORMAL
    /// - busy_timeout = 5000
    /// - temp_store = MEMORY
    public func open() throws {
        guard db == nil else { return }
        
        let result = sqlite3_open(path, &db)
        guard result == SQLITE_OK else {
            let message = String(cString: sqlite3_errmsg(db))
            sqlite3_close(db)
            db = nil
            throw DatabaseError.failedToOpen(message)
        }
        
        try applyRequiredPragmas()
    }
    
    /// Closes the database connection
    public func close() {
        if let db = db {
            sqlite3_close(db)
        }
        db = nil
    }
    
    /// Applies the required PRAGMAs as specified in SPEC.md Section 6.1
    private func applyRequiredPragmas() throws {
        // foreign_keys = ON - Enable foreign key constraint enforcement
        try executePragma("PRAGMA foreign_keys = ON;")

        // journal_mode = WAL - Write-Ahead Logging for better concurrency
        try executePragma("PRAGMA journal_mode = WAL;")

        // synchronous = NORMAL - Balance between safety and performance
        try executePragma("PRAGMA synchronous = NORMAL;")

        // busy_timeout = 5000 - Wait up to 5 seconds when database is locked
        try executePragma("PRAGMA busy_timeout = 5000;")

        // temp_store = MEMORY - Store temporary tables in memory
        try executePragma("PRAGMA temp_store = MEMORY;")

        // Performance tuning: 8 MB page cache (default is 2 MB)
        try executePragma("PRAGMA cache_size = -8000;")

        // Performance tuning: memory-map up to 256 MB of the DB file.
        // For a ~4 MB DB this maps the entire file, avoiding read syscalls.
        try executePragma("PRAGMA mmap_size = 268435456;")
    }
    
    /// Executes a PRAGMA statement
    private func executePragma(_ pragma: String) throws {
        guard let db = db else {
            throw DatabaseError.failedToSetPragma("Database not open")
        }
        
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, pragma, nil, nil, &errorMessage)
        
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw DatabaseError.failedToSetPragma("\(pragma): \(message)")
        }
    }
    
    /// Executes a SQL statement
    /// - Parameter sql: The SQL statement to execute
    public func execute(_ sql: String) throws {
        guard let db = db else {
            throw DatabaseError.failedToExecute("Database not open")
        }
        
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMessage)
        
        if result != SQLITE_OK {
            let message = errorMessage.map { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errorMessage)
            throw DatabaseError.failedToExecute("\(sql): \(message)")
        }
    }
    
    /// Gets the current schema version from PRAGMA user_version
    public func getSchemaVersion() throws -> Int32 {
        guard let db = db else {
            throw DatabaseError.failedToExecute("Database not open")
        }
        
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        
        let result = sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw DatabaseError.failedToExecute("Failed to prepare PRAGMA user_version")
        }
        
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.failedToExecute("Failed to read user_version")
        }
        
        return sqlite3_column_int(statement, 0)
    }
    
    /// Sets the schema version using PRAGMA user_version
    public func setSchemaVersion(_ version: Int32) throws {
        try execute("PRAGMA user_version = \(version);")
    }

    /// Queries a PRAGMA value and returns it as a string
    public func getPragmaValue(_ pragma: String) throws -> String? {
        guard let db = db else {
            throw DatabaseError.failedToExecute("Database not open")
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = "PRAGMA \(pragma);"
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw DatabaseError.failedToExecute("Failed to prepare PRAGMA \(pragma)")
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        if let text = sqlite3_column_text(statement, 0) {
            return String(cString: text)
        }
        return nil
    }

    /// Queries a PRAGMA value and returns it as an integer
    public func getPragmaIntValue(_ pragma: String) throws -> Int32? {
        guard let db = db else {
            throw DatabaseError.failedToExecute("Database not open")
        }

        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }

        let sql = "PRAGMA \(pragma);"
        let result = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard result == SQLITE_OK else {
            throw DatabaseError.failedToExecute("Failed to prepare PRAGMA \(pragma)")
        }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            return nil
        }

        return sqlite3_column_int(statement, 0)
    }

    /// Verifies that all required PRAGMAs are set correctly
    /// Returns a dictionary of pragma names to their current values
    public func verifyPragmas() throws -> [String: String] {
        var results: [String: String] = [:]

        results["foreign_keys"] = try getPragmaValue("foreign_keys") ?? "unknown"
        results["journal_mode"] = try getPragmaValue("journal_mode") ?? "unknown"
        results["synchronous"] = try getPragmaValue("synchronous") ?? "unknown"
        results["busy_timeout"] = try getPragmaValue("busy_timeout") ?? "unknown"
        results["temp_store"] = try getPragmaValue("temp_store") ?? "unknown"

        return results
    }

    /// Returns the underlying SQLite database pointer for advanced operations
    /// Use with caution - prefer using the provided methods
    public var rawPointer: OpaquePointer? { db }
}
