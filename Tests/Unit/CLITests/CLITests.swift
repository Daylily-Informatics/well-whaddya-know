// SPDX-License-Identifier: MIT
// CLITests.swift - CLI unit tests per SPEC.md Section 10

import Foundation
import Testing
@testable import WellWhaddyaKnowCLI

@Suite("CLI Tests")
struct CLITests {

    // MARK: - Date Parsing Tests

    @Test("parseISODate handles ISO 8601 with fractional seconds")
    func testParseISODateWithFractionalSeconds() throws {
        let tsUs = try parseISODate("2024-01-15T09:30:00.123Z")
        // Verify it parses correctly by checking the result is positive and reasonable
        #expect(tsUs > 0)
        // Verify fractional seconds are preserved (should end with 123000 microseconds)
        #expect(tsUs % 1_000_000 == 123_000)
    }

    @Test("parseISODate handles ISO 8601 without fractional seconds")
    func testParseISODateWithoutFractionalSeconds() throws {
        let tsUs = try parseISODate("2024-01-15T09:30:00Z")
        // Should be on an even second boundary
        #expect(tsUs > 0)
        #expect(tsUs % 1_000_000 == 0)
    }

    @Test("parseISODate handles date-only format")
    func testParseISODateDateOnly() throws {
        // Date-only uses local timezone, so we verify it parses without error
        let tsUs = try parseISODate("2024-01-15")
        #expect(tsUs > 0)
    }

    @Test("parseISODate throws on invalid format")
    func testParseISODateInvalidFormat() {
        #expect(throws: Error.self) {
            _ = try parseISODate("not-a-date")
        }
    }

    // MARK: - Duration Formatting Tests

    @Test("formatDuration formats hours and minutes")
    func testFormatDurationHoursMinutes() {
        let result = formatDuration(3725) // 1h 2m 5s
        #expect(result == "1h 2m")
    }

    @Test("formatDuration formats minutes only")
    func testFormatDurationMinutesOnly() {
        let result = formatDuration(125) // 2m 5s
        #expect(result == "2m")
    }

    @Test("formatDuration formats zero")
    func testFormatDurationZero() {
        let result = formatDuration(0)
        #expect(result == "0m")
    }

    // MARK: - Timestamp Formatting Tests

    @Test("formatLocalTimestamp produces ISO string")
    func testFormatLocalTimestamp() {
        let tsUs: Int64 = 1705312200 * 1_000_000 // 2024-01-15T09:30:00Z
        let result = formatLocalTimestamp(tsUs)
        // Should contain date components (exact format depends on timezone)
        #expect(result.contains("2024"))
        #expect(result.contains("01"))
        #expect(result.contains("15"))
    }

    // MARK: - Error Type Tests

    @Test("CLIError provides localized descriptions")
    func testCLIErrorDescriptions() {
        let errors: [CLIError] = [
            .databaseNotFound(path: "/tmp/test.db"),
            .databaseError(message: "connection failed"),
            .agentNotRunning,
            .invalidTimeRange(message: "start after end"),
            .invalidInput(message: "bad value"),
            .exportFailed(message: "write error"),
            .tagNotFound(name: "missing"),
            .tagAlreadyExists(name: "duplicate")
        ]

        for error in errors {
            #expect(error.errorDescription != nil)
            #expect(!error.errorDescription!.isEmpty)
        }
    }

    // MARK: - Exit Code Tests

    @Test("ExitCode values match SPEC.md")
    func testExitCodeValues() {
        #expect(ExitCode.success.rawValue == 0)
        #expect(ExitCode.generalError.rawValue == 1)
        #expect(ExitCode.agentNotRunning.rawValue == 2)
        #expect(ExitCode.invalidInput.rawValue == 3)
        #expect(ExitCode.databaseError.rawValue == 4)
    }
}

