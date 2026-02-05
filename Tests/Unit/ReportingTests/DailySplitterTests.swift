// SPDX-License-Identifier: MIT
// DailySplitterTests.swift - Tests for midnight/DST splitting per SPEC.md Section 8.3

import Foundation
import Reporting
import Testing
import Timeline

@Suite("Daily Splitter Tests")
struct DailySplitterTests {

    // MARK: - Test Helpers

    let pacificTZ = TimeZone(identifier: "America/Los_Angeles")!

    /// Create an effective segment for testing
    func makeSegment(
        startTsUs: Int64,
        endTsUs: Int64,
        bundleId: String = "com.test.app",
        appName: String = "Test App",
        title: String? = "Window",
        tags: [String] = [],
        coverage: SegmentCoverage = .observed
    ) -> EffectiveSegment {
        EffectiveSegment(
            startTsUs: startTsUs,
            endTsUs: endTsUs,
            source: .raw,
            appBundleId: bundleId,
            appName: appName,
            windowTitle: title,
            tags: tags,
            coverage: coverage,
            supportingIds: []
        )
    }

    /// Convert a local date/time to Unix timestamp in microseconds
    func localToTsUs(year: Int, month: Int, day: Int, hour: Int, minute: Int, timeZone: TimeZone) -> Int64 {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        let date = calendar.date(from: components)!
        return Int64(date.timeIntervalSince1970 * 1_000_000.0)
    }

    // MARK: - Segment entirely within one day

    @Test("Segment within one day returns unchanged")
    func testSegmentWithinOneDay() {
        // 10:00 to 11:00 on 2026-02-05 PST
        let startUs = localToTsUs(year: 2026, month: 2, day: 5, hour: 10, minute: 0, timeZone: pacificTZ)
        let endUs = localToTsUs(year: 2026, month: 2, day: 5, hour: 11, minute: 0, timeZone: pacificTZ)
        let segment = makeSegment(startTsUs: startUs, endTsUs: endUs)

        let result = DailySplitter.splitSegmentsByDay(segments: [segment], timeZone: pacificTZ)

        #expect(result.count == 1)
        #expect(result[0].startTsUs == startUs)
        #expect(result[0].endTsUs == endUs)
    }

    // MARK: - Fixture 2: Midnight crossing

    @Test("Segment crossing midnight splits into 2")
    func testMidnightCrossing() {
        // 23:30 on 2026-02-05 to 00:30 on 2026-02-06 (1 hour total)
        let startUs = localToTsUs(year: 2026, month: 2, day: 5, hour: 23, minute: 30, timeZone: pacificTZ)
        let endUs = localToTsUs(year: 2026, month: 2, day: 6, hour: 0, minute: 30, timeZone: pacificTZ)
        let segment = makeSegment(startTsUs: startUs, endTsUs: endUs, tags: ["test"])

        let result = DailySplitter.splitSegmentsByDay(segments: [segment], timeZone: pacificTZ)

        #expect(result.count == 2)
        // First segment: 23:30 to midnight (30 min)
        #expect(result[0].durationSeconds == 1800.0)
        #expect(result[0].tags == ["test"])
        // Second segment: midnight to 00:30 (30 min)
        #expect(result[1].durationSeconds == 1800.0)
        #expect(result[1].tags == ["test"])

        // Verify totalsByDay
        let dayTotals = Aggregations.totalsByDay(segments: [segment], timeZone: pacificTZ)
        #expect(dayTotals["2026-02-05"] == 1800.0)
        #expect(dayTotals["2026-02-06"] == 1800.0)
    }

    // MARK: - Zero duration segment

    @Test("Zero duration segment returns unchanged")
    func testZeroDurationSegment() {
        let tsUs = localToTsUs(year: 2026, month: 2, day: 5, hour: 12, minute: 0, timeZone: pacificTZ)
        let segment = makeSegment(startTsUs: tsUs, endTsUs: tsUs)

        let result = DailySplitter.splitSegmentsByDay(segments: [segment], timeZone: pacificTZ)

        #expect(result.count == 1)
        #expect(result[0].durationSeconds == 0.0)
    }

    // MARK: - Segment crossing 2+ midnights

    @Test("Segment crossing 2 midnights splits into 3")
    func testMultipleMidnightsCrossing() {
        // 22:00 on 2026-02-05 to 02:00 on 2026-02-07 (28 hours total)
        let startUs = localToTsUs(year: 2026, month: 2, day: 5, hour: 22, minute: 0, timeZone: pacificTZ)
        let endUs = localToTsUs(year: 2026, month: 2, day: 7, hour: 2, minute: 0, timeZone: pacificTZ)
        let segment = makeSegment(startTsUs: startUs, endTsUs: endUs)

        let result = DailySplitter.splitSegmentsByDay(segments: [segment], timeZone: pacificTZ)

        #expect(result.count == 3)
        // Day 1: 22:00 to midnight (2 hours)
        #expect(result[0].durationSeconds == 7200.0)
        // Day 2: midnight to midnight (24 hours)
        #expect(result[1].durationSeconds == 86400.0)
        // Day 3: midnight to 02:00 (2 hours)
        #expect(result[2].durationSeconds == 7200.0)

        // Verify totalsByDay
        let dayTotals = Aggregations.totalsByDay(segments: [segment], timeZone: pacificTZ)
        #expect(dayTotals["2026-02-05"] == 7200.0)
        #expect(dayTotals["2026-02-06"] == 86400.0)
        #expect(dayTotals["2026-02-07"] == 7200.0)
    }

    // MARK: - Exactly at midnight boundary

    @Test("Segment exactly at midnight boundary no split")
    func testExactlyAtMidnight() {
        // midnight to 01:00 on 2026-02-06
        let startUs = localToTsUs(year: 2026, month: 2, day: 6, hour: 0, minute: 0, timeZone: pacificTZ)
        let endUs = localToTsUs(year: 2026, month: 2, day: 6, hour: 1, minute: 0, timeZone: pacificTZ)
        let segment = makeSegment(startTsUs: startUs, endTsUs: endUs)

        let result = DailySplitter.splitSegmentsByDay(segments: [segment], timeZone: pacificTZ)

        #expect(result.count == 1)
        #expect(result[0].durationSeconds == 3600.0)
    }

    // MARK: - Fields preservation

    @Test("Split segments preserve all fields")
    func testFieldsPreservation() {
        let startUs = localToTsUs(year: 2026, month: 2, day: 5, hour: 23, minute: 0, timeZone: pacificTZ)
        let endUs = localToTsUs(year: 2026, month: 2, day: 6, hour: 1, minute: 0, timeZone: pacificTZ)
        let segment = makeSegment(
            startTsUs: startUs, endTsUs: endUs,
            bundleId: "com.custom.app", appName: "Custom App",
            title: "My Document", tags: ["work", "urgent"], coverage: .observed
        )

        let result = DailySplitter.splitSegmentsByDay(segments: [segment], timeZone: pacificTZ)

        #expect(result.count == 2)
        for part in result {
            #expect(part.appBundleId == "com.custom.app")
            #expect(part.appName == "Custom App")
            #expect(part.windowTitle == "My Document")
            #expect(part.tags == ["work", "urgent"])
            #expect(part.coverage == .observed)
            #expect(part.source == .raw)
        }
    }
}

