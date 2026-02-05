// SPDX-License-Identifier: MIT
// AggregationTests.swift - Tests for aggregation functions per SPEC.md Section 8.2

import Reporting
import Testing
import Timeline

@Suite("Aggregation Tests")
struct AggregationTests {

    // MARK: - Test Helpers

    /// Create an effective segment for testing
    func makeSegment(
        startTsUs: Int64,
        endTsUs: Int64,
        bundleId: String = "com.test.app",
        appName: String = "Test App",
        title: String? = "Window",
        tags: [String] = [],
        coverage: SegmentCoverage = .observed,
        source: SegmentSource = .raw
    ) -> EffectiveSegment {
        EffectiveSegment(
            startTsUs: startTsUs,
            endTsUs: endTsUs,
            source: source,
            appBundleId: bundleId,
            appName: appName,
            windowTitle: title,
            tags: tags,
            coverage: coverage,
            supportingIds: []
        )
    }

    // MARK: - Fixture 1: Multi-app, multi-tag

    @Test("Multi-app, multi-tag totals")
    func testMultiAppMultiTag() {
        // 3 segments, 2 different apps, 3 different tags
        // Segment 1: app1, 60 seconds, tags: ["billable", "meeting"]
        // Segment 2: app2, 120 seconds, tags: ["billable"]
        // Segment 3: app1, 30 seconds, tags: ["research"]
        let segments = [
            makeSegment(startTsUs: 0, endTsUs: 60_000_000, bundleId: "com.app1", appName: "App1", tags: ["billable", "meeting"]),
            makeSegment(startTsUs: 60_000_000, endTsUs: 180_000_000, bundleId: "com.app2", appName: "App2", tags: ["billable"]),
            makeSegment(startTsUs: 180_000_000, endTsUs: 210_000_000, bundleId: "com.app1", appName: "App1", tags: ["research"]),
        ]

        // Totals by application
        let appTotals = Aggregations.totalsByApplication(segments: segments)
        #expect(appTotals["com.app1"] == 90.0)  // 60 + 30
        #expect(appTotals["com.app2"] == 120.0)

        // Totals by tag (segments with multiple tags contribute full duration to each)
        let tagTotals = Aggregations.totalsByTag(segments: segments)
        #expect(tagTotals["billable"] == 180.0)  // 60 + 120
        #expect(tagTotals["meeting"] == 60.0)
        #expect(tagTotals["research"] == 30.0)
    }

    // MARK: - Fixture 5: Unobserved gaps

    @Test("Unobserved gaps vs observed segments")
    func testUnobservedGaps() {
        // Mix of observed and unobserved_gap segments
        let segments = [
            makeSegment(startTsUs: 0, endTsUs: 60_000_000, coverage: .observed),  // 60s observed
            makeSegment(startTsUs: 60_000_000, endTsUs: 120_000_000, coverage: .unobservedGap),  // 60s gap
            makeSegment(startTsUs: 120_000_000, endTsUs: 240_000_000, coverage: .observed),  // 120s observed
            makeSegment(startTsUs: 240_000_000, endTsUs: 300_000_000, coverage: .unobservedGap),  // 60s gap
        ]

        // totalWorkingTime excludes gaps
        let workingTime = Aggregations.totalWorkingTime(segments: segments)
        #expect(workingTime == 180.0)  // 60 + 120

        // totalUnobservedGaps includes only gaps
        let gapTime = Aggregations.totalUnobservedGaps(segments: segments)
        #expect(gapTime == 120.0)  // 60 + 60
    }

    // MARK: - Window title handling

    @Test("Window title nil handling")
    func testWindowTitleNil() {
        let segments = [
            makeSegment(startTsUs: 0, endTsUs: 60_000_000, title: "Document.txt"),
            makeSegment(startTsUs: 60_000_000, endTsUs: 120_000_000, title: nil),
            makeSegment(startTsUs: 120_000_000, endTsUs: 180_000_000, title: "Document.txt"),
        ]

        let titleTotals = Aggregations.totalsByWindowTitle(segments: segments)
        #expect(titleTotals["Document.txt"] == 120.0)  // 60 + 60
        #expect(titleTotals["(no title)"] == 60.0)
    }

    // MARK: - Empty bundle ID handling

    @Test("Empty bundle ID handling")
    func testEmptyBundleId() {
        let segments = [
            makeSegment(startTsUs: 0, endTsUs: 60_000_000, bundleId: "com.app1"),
            makeSegment(startTsUs: 60_000_000, endTsUs: 120_000_000, bundleId: ""),
        ]

        let appTotals = Aggregations.totalsByApplication(segments: segments)
        #expect(appTotals["com.app1"] == 60.0)
        #expect(appTotals["(no bundle id)"] == 60.0)
    }

    // MARK: - Untagged segments

    @Test("Untagged segments grouped under (untagged)")
    func testUntaggedSegments() {
        let segments = [
            makeSegment(startTsUs: 0, endTsUs: 60_000_000, tags: ["billable"]),
            makeSegment(startTsUs: 60_000_000, endTsUs: 120_000_000, tags: []),
        ]

        let tagTotals = Aggregations.totalsByTag(segments: segments)
        #expect(tagTotals["billable"] == 60.0)
        #expect(tagTotals["(untagged)"] == 60.0)
    }

    // MARK: - Empty segments array

    @Test("Empty segments array returns zero/empty")
    func testEmptySegments() {
        let segments: [EffectiveSegment] = []

        #expect(Aggregations.totalWorkingTime(segments: segments) == 0.0)
        #expect(Aggregations.totalUnobservedGaps(segments: segments) == 0.0)
        #expect(Aggregations.totalsByApplication(segments: segments).isEmpty)
        #expect(Aggregations.totalsByWindowTitle(segments: segments).isEmpty)
        #expect(Aggregations.totalsByTag(segments: segments).isEmpty)
    }
}

