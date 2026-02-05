// SPDX-License-Identifier: MIT
// TimelineBuilderTests.swift - Comprehensive tests for timeline builder

import CoreModel
import Testing
import Timeline

@Suite("Timeline Builder Tests")
struct TimelineBuilderTests {
    // MARK: - Test Helpers
    
    /// Create a system state event for testing
    func makeSSE(
        id: Int64,
        tsUs: Int64,
        isWorking: Bool,
        kind: SystemStateEventKind = .stateChange
    ) -> SystemStateEvent {
        SystemStateEvent(
            sseId: id,
            runId: "test-run",
            eventTsUs: tsUs,
            eventMonotonicNs: UInt64(tsUs * 1000),
            isSystemAwake: isWorking,
            isSessionOnConsole: isWorking,
            isScreenLocked: !isWorking,
            isWorking: isWorking,
            eventKind: kind,
            source: .workspaceNotification,
            tzIdentifier: "America/Los_Angeles",
            tzOffsetSeconds: -28800
        )
    }
    
    /// Create a raw activity event for testing
    func makeRAE(
        id: Int64,
        tsUs: Int64,
        bundleId: String = "com.test.app",
        appName: String = "Test App",
        title: String? = "Window Title"
    ) -> RawActivityEvent {
        RawActivityEvent(
            raeId: id,
            runId: "test-run",
            eventTsUs: tsUs,
            eventMonotonicNs: UInt64(tsUs * 1000),
            appId: 1,
            appBundleId: bundleId,
            appDisplayName: appName,
            pid: 1234,
            titleId: title != nil ? 1 : nil,
            windowTitle: title,
            titleStatus: title != nil ? .ok : .noWindow,
            reason: .appActivated,
            isWorking: true
        )
    }
    
    /// Create a user edit event for testing
    func makeUEE(
        id: Int64,
        createdTsUs: Int64,
        op: EditOperation,
        startTsUs: Int64,
        endTsUs: Int64,
        tagName: String? = nil,
        manualBundleId: String? = nil,
        manualAppName: String? = nil,
        targetUeeId: Int64? = nil
    ) -> UserEditEvent {
        UserEditEvent(
            ueeId: id,
            createdTsUs: createdTsUs,
            createdMonotonicNs: UInt64(createdTsUs * 1000),
            authorUsername: "testuser",
            authorUid: 501,
            client: .cli,
            clientVersion: "1.0.0",
            op: op,
            startTsUs: startTsUs,
            endTsUs: endTsUs,
            tagId: tagName != nil ? 1 : nil,
            tagName: tagName,
            manualAppBundleId: manualBundleId,
            manualAppName: manualAppName,
            targetUeeId: targetUeeId
        )
    }
    
    // MARK: - Empty Input Tests
    
    @Test("Empty input returns empty output")
    func testEmptyInput() {
        let result = buildEffectiveTimeline(
            systemStateEvents: [],
            rawActivityEvents: [],
            userEditEvents: [],
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )
        #expect(result.isEmpty)
    }
    
    @Test("No working intervals returns empty output")
    func testNoWorkingIntervals() {
        // System was never working
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: false),
            makeSSE(id: 2, tsUs: 500_000, isWorking: false)
        ]
        let rae = [
            makeRAE(id: 1, tsUs: 100_000)
        ]
        
        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: [],
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )
        #expect(result.isEmpty)
    }
    
    // MARK: - Simple Working Interval Tests
    
    @Test("Single working interval with single app")
    func testSingleWorkingInterval() {
        // Working from t=100ms to t=500ms
        let sse = [
            makeSSE(id: 1, tsUs: 100_000, isWorking: true),
            makeSSE(id: 2, tsUs: 500_000, isWorking: false)
        ]
        let rae = [
            makeRAE(id: 1, tsUs: 100_000, bundleId: "com.test.app", appName: "Test App")
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: [],
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        #expect(result.count == 1)
        #expect(result[0].startTsUs == 100_000)
        #expect(result[0].endTsUs == 500_000)
        #expect(result[0].appBundleId == "com.test.app")
        #expect(result[0].source == .raw)
        #expect(result[0].coverage == .observed)
    }

    // MARK: - App Switch Attribution Tests

    @Test("App switch creates separate segments")
    func testAppSwitch() {
        // Working from t=0 to t=600ms, switch apps at t=300ms
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 600_000, isWorking: false)
        ]
        let rae = [
            makeRAE(id: 1, tsUs: 0, bundleId: "com.app.one", appName: "App One"),
            makeRAE(id: 2, tsUs: 300_000, bundleId: "com.app.two", appName: "App Two")
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: [],
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        #expect(result.count == 2)
        #expect(result[0].appBundleId == "com.app.one")
        #expect(result[0].startTsUs == 0)
        #expect(result[0].endTsUs == 300_000)
        #expect(result[1].appBundleId == "com.app.two")
        #expect(result[1].startTsUs == 300_000)
        #expect(result[1].endTsUs == 600_000)
    }

    // MARK: - Delete Range Tests

    @Test("Delete range removes time from segment")
    func testDeleteRange() {
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [
            makeRAE(id: 1, tsUs: 0)
        ]
        // Delete from 400ms to 600ms
        let uee = [
            makeUEE(id: 1, createdTsUs: 1, op: .deleteRange, startTsUs: 400_000, endTsUs: 600_000)
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        // Should split into two segments
        #expect(result.count == 2)
        #expect(result[0].startTsUs == 0)
        #expect(result[0].endTsUs == 400_000)
        #expect(result[1].startTsUs == 600_000)
        #expect(result[1].endTsUs == 1_000_000)
    }

    @Test("Delete range at start removes prefix")
    func testDeleteRangeStart() {
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]
        let uee = [
            makeUEE(id: 1, createdTsUs: 1, op: .deleteRange, startTsUs: 0, endTsUs: 300_000)
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        #expect(result.count == 1)
        #expect(result[0].startTsUs == 300_000)
        #expect(result[0].endTsUs == 1_000_000)
    }

    // MARK: - Add Range Tests

    @Test("Add range inserts manual segment")
    func testAddRange() {
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [
            makeRAE(id: 1, tsUs: 0, bundleId: "com.original.app", appName: "Original")
        ]
        // Add manual segment from 400ms to 600ms
        let uee = [
            makeUEE(
                id: 1, createdTsUs: 1, op: .addRange,
                startTsUs: 400_000, endTsUs: 600_000,
                manualBundleId: "com.manual.app", manualAppName: "Manual App"
            )
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        #expect(result.count == 3)
        // First segment: original app 0-400ms
        #expect(result[0].appBundleId == "com.original.app")
        #expect(result[0].endTsUs == 400_000)
        #expect(result[0].source == .raw)
        // Second segment: manual app 400-600ms
        #expect(result[1].appBundleId == "com.manual.app")
        #expect(result[1].startTsUs == 400_000)
        #expect(result[1].endTsUs == 600_000)
        #expect(result[1].source == .manual)
        // Third segment: original app 600-1000ms
        #expect(result[2].appBundleId == "com.original.app")
        #expect(result[2].startTsUs == 600_000)
    }

    // MARK: - Precedence Tests (Delete beats Add)

    @Test("Delete beats add per SPEC.md Section 7.4")
    func testDeleteBeatsAdd() {
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]
        // First add a manual segment, then delete part of it
        let uee = [
            makeUEE(
                id: 1, createdTsUs: 1, op: .addRange,
                startTsUs: 200_000, endTsUs: 800_000,
                manualBundleId: "com.manual.app", manualAppName: "Manual"
            ),
            makeUEE(
                id: 2, createdTsUs: 2, op: .deleteRange,
                startTsUs: 400_000, endTsUs: 600_000
            )
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        // Manual segment should be split by delete
        let manualSegments = result.filter { $0.source == .manual }
        #expect(manualSegments.count == 2)
        #expect(manualSegments[0].endTsUs == 400_000)
        #expect(manualSegments[1].startTsUs == 600_000)
    }

    // MARK: - Undo Tests

    @Test("Undo edit removes target edit effect")
    func testUndoEdit() {
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]
        // Delete a range, then undo the delete
        let uee = [
            makeUEE(id: 1, createdTsUs: 1, op: .deleteRange, startTsUs: 400_000, endTsUs: 600_000),
            makeUEE(id: 2, createdTsUs: 2, op: .undoEdit, startTsUs: 0, endTsUs: 1, targetUeeId: 1)
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        // Delete was undone, so segment should be continuous
        #expect(result.count == 1)
        #expect(result[0].startTsUs == 0)
        #expect(result[0].endTsUs == 1_000_000)
    }

    // MARK: - Tag Tests

    @Test("Tag range adds tags to overlapping segments")
    func testTagRange() {
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [
            makeRAE(id: 1, tsUs: 0, bundleId: "com.app.one"),
            makeRAE(id: 2, tsUs: 500_000, bundleId: "com.app.two")
        ]
        // Tag from 200ms to 700ms (overlaps both segments)
        let uee = [
            makeUEE(id: 1, createdTsUs: 1, op: .tagRange, startTsUs: 200_000, endTsUs: 700_000, tagName: "meeting")
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        #expect(result.count == 2)
        // Both segments should have the tag
        #expect(result[0].tags.contains("meeting"))
        #expect(result[1].tags.contains("meeting"))
    }

    @Test("Untag range removes tags")
    func testUntagRange() {
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]
        // First tag, then untag
        let uee = [
            makeUEE(id: 1, createdTsUs: 1, op: .tagRange, startTsUs: 0, endTsUs: 1_000_000, tagName: "work"),
            makeUEE(id: 2, createdTsUs: 2, op: .untagRange, startTsUs: 0, endTsUs: 1_000_000, tagName: "work")
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        #expect(result.count == 1)
        #expect(result[0].tags.isEmpty)
    }

    // MARK: - Range Clipping Tests

    @Test("Results are clipped to requested range")
    func testRangeClipping() {
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]

        // Request only 200ms-600ms of the 0-1000ms working interval
        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: [],
            requestedRange: (startUs: 200_000, endUs: 600_000)
        )

        #expect(result.count == 1)
        #expect(result[0].startTsUs == 200_000)
        #expect(result[0].endTsUs == 600_000)
    }
}

