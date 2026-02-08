// SPDX-License-Identifier: MIT
// AggregationTests.swift - Tests for aggregation functions per SPEC.md Section 8.2

import Foundation
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

    // MARK: - Totals by Hour

    /// Helper: create a timestamp for a specific hour:minute in UTC
    private func tsUs(hour: Int, minute: Int = 0, second: Int = 0) -> Int64 {
        // Use a fixed date: 2024-01-15 in UTC
        // 2024-01-15 00:00:00 UTC = 1705276800
        let baseEpoch: Int64 = 1_705_276_800
        return (baseEpoch + Int64(hour * 3600 + minute * 60 + second)) * 1_000_000
    }

    @Test("totalsByHour groups single-hour segment correctly")
    func testTotalsByHourSingleSegment() {
        let tz = TimeZone(identifier: "UTC")!
        // 30 minutes at hour 9 (09:00 – 09:30)
        let segments = [
            makeSegment(startTsUs: tsUs(hour: 9, minute: 0),
                        endTsUs: tsUs(hour: 9, minute: 30),
                        appName: "Safari")
        ]
        let result = Aggregations.totalsByHour(segments: segments, timeZone: tz, groupBy: .app)
        #expect(result.count == 1)
        #expect(result[0].hour == 9)
        #expect(result[0].label == "Safari")
        #expect(abs(result[0].seconds - 1800.0) < 0.01)
    }

    @Test("totalsByHour splits segment across hour boundary")
    func testTotalsByHourCrossHour() {
        let tz = TimeZone(identifier: "UTC")!
        // 09:45 – 10:15 → 15 min in hour 9, 15 min in hour 10
        let segments = [
            makeSegment(startTsUs: tsUs(hour: 9, minute: 45),
                        endTsUs: tsUs(hour: 10, minute: 15),
                        appName: "Code")
        ]
        let result = Aggregations.totalsByHour(segments: segments, timeZone: tz, groupBy: .app)
        #expect(result.count == 2)
        let h9 = result.first(where: { $0.hour == 9 })!
        let h10 = result.first(where: { $0.hour == 10 })!
        #expect(abs(h9.seconds - 900.0) < 0.01)  // 15 min
        #expect(abs(h10.seconds - 900.0) < 0.01) // 15 min
    }

    @Test("totalsByHour excludes unobserved gaps")
    func testTotalsByHourExcludesGaps() {
        let tz = TimeZone(identifier: "UTC")!
        let segments = [
            makeSegment(startTsUs: tsUs(hour: 9), endTsUs: tsUs(hour: 10),
                        appName: "App", coverage: .observed),
            makeSegment(startTsUs: tsUs(hour: 10), endTsUs: tsUs(hour: 11),
                        appName: "Gap", coverage: .unobservedGap),
        ]
        let result = Aggregations.totalsByHour(segments: segments, timeZone: tz, groupBy: .app)
        #expect(result.count == 1)
        #expect(result[0].hour == 9)
    }

    @Test("totalsByHour groups by tag, multi-tag segment contributes to each")
    func testTotalsByHourGroupByTag() {
        let tz = TimeZone(identifier: "UTC")!
        let segments = [
            makeSegment(startTsUs: tsUs(hour: 14), endTsUs: tsUs(hour: 14, minute: 30),
                        appName: "IDE", tags: ["billable", "dev"])
        ]
        let result = Aggregations.totalsByHour(segments: segments, timeZone: tz, groupBy: .tag)
        #expect(result.count == 2)
        for entry in result {
            #expect(entry.hour == 14)
            #expect(abs(entry.seconds - 1800.0) < 0.01)
        }
        let labels = Set(result.map { $0.label })
        #expect(labels.contains("billable"))
        #expect(labels.contains("dev"))
    }

    @Test("totalsByHour empty segments returns empty")
    func testTotalsByHourEmpty() {
        let tz = TimeZone(identifier: "UTC")!
        let result = Aggregations.totalsByHour(segments: [], timeZone: tz, groupBy: .app)
        #expect(result.isEmpty)
    }

    @Test("totalsByHour appWindow grouping")
    func testTotalsByHourAppWindow() {
        let tz = TimeZone(identifier: "UTC")!
        let segments = [
            makeSegment(startTsUs: tsUs(hour: 8), endTsUs: tsUs(hour: 8, minute: 20),
                        appName: "Xcode", title: "Project.swift"),
            makeSegment(startTsUs: tsUs(hour: 8, minute: 20), endTsUs: tsUs(hour: 8, minute: 40),
                        appName: "Xcode", title: "Tests.swift"),
        ]
        let result = Aggregations.totalsByHour(segments: segments, timeZone: tz, groupBy: .appWindow)
        #expect(result.count == 2)
        let labels = Set(result.map { $0.label })
        #expect(labels.contains("Xcode — Project.swift"))
        #expect(labels.contains("Xcode — Tests.swift"))
    }
}

