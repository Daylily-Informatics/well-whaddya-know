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

    @Test("Tag range adds tags to overlapping segments with proper splitting")
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
        // Base segments: [0-500 app.one], [500-1000 app.two]
        // After tag splitting:
        // [0-200 app.one no-tag], [200-500 app.one tag], [500-700 app.two tag], [700-1000 app.two no-tag]
        let uee = [
            makeUEE(id: 1, createdTsUs: 1, op: .tagRange, startTsUs: 200_000, endTsUs: 700_000, tagName: "meeting")
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        #expect(result.count == 4)
        // Segment 1: 0-200ms app.one, no tag
        #expect(result[0].startTsUs == 0)
        #expect(result[0].endTsUs == 200_000)
        #expect(result[0].appBundleId == "com.app.one")
        #expect(result[0].tags.isEmpty)
        // Segment 2: 200-500ms app.one, with tag
        #expect(result[1].startTsUs == 200_000)
        #expect(result[1].endTsUs == 500_000)
        #expect(result[1].appBundleId == "com.app.one")
        #expect(result[1].tags.contains("meeting"))
        // Segment 3: 500-700ms app.two, with tag
        #expect(result[2].startTsUs == 500_000)
        #expect(result[2].endTsUs == 700_000)
        #expect(result[2].appBundleId == "com.app.two")
        #expect(result[2].tags.contains("meeting"))
        // Segment 4: 700-1000ms app.two, no tag
        #expect(result[3].startTsUs == 700_000)
        #expect(result[3].endTsUs == 1_000_000)
        #expect(result[3].appBundleId == "com.app.two")
        #expect(result[3].tags.isEmpty)
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

    // MARK: - Nested Undo Chain Tests

    @Test("Nested undo chains resolve correctly per SPEC.md Section 7.3")
    func testNestedUndoChains() {
        // Scenario:
        // - Edit E (id=1): delete_range 400-600ms
        // - Undo A (id=2): targets E → E becomes inactive
        // - Undo B (id=3): targets A → A becomes inactive → E becomes active again
        // - Undo C (id=4): targets B → B becomes inactive → A becomes active → E becomes inactive
        // Expected: E should be undone (inactive) because A is ultimately active

        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]
        let uee = [
            // Edit E: delete 400-600ms
            makeUEE(id: 1, createdTsUs: 100, op: .deleteRange, startTsUs: 400_000, endTsUs: 600_000),
            // Undo A: targets E
            makeUEE(id: 2, createdTsUs: 200, op: .undoEdit, startTsUs: 0, endTsUs: 0, targetUeeId: 1),
            // Undo B: targets A
            makeUEE(id: 3, createdTsUs: 300, op: .undoEdit, startTsUs: 0, endTsUs: 0, targetUeeId: 2),
            // Undo C: targets B
            makeUEE(id: 4, createdTsUs: 400, op: .undoEdit, startTsUs: 0, endTsUs: 0, targetUeeId: 3)
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        // C undoes B → B is inactive
        // B's effect (undoing A) is nullified → A is active
        // A's effect (undoing E) is active → E is undone
        // Since E (delete 400-600) is undone, the segment should NOT have a gap
        // Result: single segment 0-1000ms
        #expect(result.count == 1)
        #expect(result[0].startTsUs == 0)
        #expect(result[0].endTsUs == 1_000_000)
    }

    @Test("Double undo reactivates deleted segment")
    func testDoubleUndoReactivatesDelete() {
        // Scenario:
        // - Edit E (id=1): delete_range 400-600ms
        // - Undo A (id=2): targets E → E becomes inactive (delete is undone)
        // Expected: The delete is undone, so full segment 0-1000ms exists

        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]
        let uee = [
            makeUEE(id: 1, createdTsUs: 100, op: .deleteRange, startTsUs: 400_000, endTsUs: 600_000),
            makeUEE(id: 2, createdTsUs: 200, op: .undoEdit, startTsUs: 0, endTsUs: 0, targetUeeId: 1)
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        // Delete is undone, so single continuous segment
        #expect(result.count == 1)
        #expect(result[0].startTsUs == 0)
        #expect(result[0].endTsUs == 1_000_000)
    }

    @Test("Undo of undo restores original delete effect")
    func testUndoOfUndoRestoresDelete() {
        // Scenario:
        // - Edit E (id=1): delete_range 400-600ms
        // - Undo A (id=2): targets E → E becomes inactive
        // - Undo B (id=3): targets A → A becomes inactive → E becomes active again
        // Expected: The delete is active again, so gap exists at 400-600ms

        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]
        let uee = [
            makeUEE(id: 1, createdTsUs: 100, op: .deleteRange, startTsUs: 400_000, endTsUs: 600_000),
            makeUEE(id: 2, createdTsUs: 200, op: .undoEdit, startTsUs: 0, endTsUs: 0, targetUeeId: 1),
            makeUEE(id: 3, createdTsUs: 300, op: .undoEdit, startTsUs: 0, endTsUs: 0, targetUeeId: 2)
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        // Undo B undoes Undo A, so A is inactive, so E (delete) is active
        // Result: two segments with gap at 400-600ms
        #expect(result.count == 2)
        #expect(result[0].startTsUs == 0)
        #expect(result[0].endTsUs == 400_000)
        #expect(result[1].startTsUs == 600_000)
        #expect(result[1].endTsUs == 1_000_000)
    }

    // MARK: - Partial Tag Overlap Tests

    @Test("Tag range only affects overlapping portion of segment")
    func testPartialTagOverlap() {
        // Scenario:
        // - Segment covers 0-1000ms
        // - Tag edit covers 200-300ms with tag "meeting"
        // Expected: 3 segments [0-200 no tag, 200-300 with tag, 300-1000 no tag]

        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]
        let uee = [
            makeUEE(id: 1, createdTsUs: 1, op: .tagRange, startTsUs: 200_000, endTsUs: 300_000, tagName: "meeting")
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        #expect(result.count == 3)
        // First segment: 0-200ms, no tags
        #expect(result[0].startTsUs == 0)
        #expect(result[0].endTsUs == 200_000)
        #expect(result[0].tags.isEmpty)
        // Second segment: 200-300ms, has "meeting" tag
        #expect(result[1].startTsUs == 200_000)
        #expect(result[1].endTsUs == 300_000)
        #expect(result[1].tags.contains("meeting"))
        // Third segment: 300-1000ms, no tags
        #expect(result[2].startTsUs == 300_000)
        #expect(result[2].endTsUs == 1_000_000)
        #expect(result[2].tags.isEmpty)
    }

    @Test("Tag at segment start creates two segments")
    func testTagAtSegmentStart() {
        // Tag covers 0-200ms of a 0-1000ms segment
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]
        let uee = [
            makeUEE(id: 1, createdTsUs: 1, op: .tagRange, startTsUs: 0, endTsUs: 200_000, tagName: "standup")
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        #expect(result.count == 2)
        // First: 0-200ms with tag
        #expect(result[0].startTsUs == 0)
        #expect(result[0].endTsUs == 200_000)
        #expect(result[0].tags.contains("standup"))
        // Second: 200-1000ms no tag
        #expect(result[1].startTsUs == 200_000)
        #expect(result[1].endTsUs == 1_000_000)
        #expect(result[1].tags.isEmpty)
    }

    @Test("Tag at segment end creates two segments")
    func testTagAtSegmentEnd() {
        // Tag covers 800-1000ms of a 0-1000ms segment
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]
        let uee = [
            makeUEE(id: 1, createdTsUs: 1, op: .tagRange, startTsUs: 800_000, endTsUs: 1_000_000, tagName: "wrapup")
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        #expect(result.count == 2)
        // First: 0-800ms no tag
        #expect(result[0].startTsUs == 0)
        #expect(result[0].endTsUs == 800_000)
        #expect(result[0].tags.isEmpty)
        // Second: 800-1000ms with tag
        #expect(result[1].startTsUs == 800_000)
        #expect(result[1].endTsUs == 1_000_000)
        #expect(result[1].tags.contains("wrapup"))
    }

    @Test("Untag range only affects overlapping portion")
    func testPartialUntagOverlap() {
        // Scenario:
        // - First tag entire segment with "project"
        // - Then untag only middle portion 400-600ms
        let sse = [
            makeSSE(id: 1, tsUs: 0, isWorking: true),
            makeSSE(id: 2, tsUs: 1_000_000, isWorking: false)
        ]
        let rae = [makeRAE(id: 1, tsUs: 0)]
        let uee = [
            makeUEE(id: 1, createdTsUs: 1, op: .tagRange, startTsUs: 0, endTsUs: 1_000_000, tagName: "project"),
            makeUEE(id: 2, createdTsUs: 2, op: .untagRange, startTsUs: 400_000, endTsUs: 600_000, tagName: "project")
        ]

        let result = buildEffectiveTimeline(
            systemStateEvents: sse,
            rawActivityEvents: rae,
            userEditEvents: uee,
            requestedRange: (startUs: 0, endUs: 1_000_000)
        )

        #expect(result.count == 3)
        // First: 0-400ms with tag
        #expect(result[0].startTsUs == 0)
        #expect(result[0].endTsUs == 400_000)
        #expect(result[0].tags.contains("project"))
        // Second: 400-600ms no tag (untagged)
        #expect(result[1].startTsUs == 400_000)
        #expect(result[1].endTsUs == 600_000)
        #expect(!result[1].tags.contains("project"))
        // Third: 600-1000ms with tag
        #expect(result[2].startTsUs == 600_000)
        #expect(result[2].endTsUs == 1_000_000)
        #expect(result[2].tags.contains("project"))
    }
}

