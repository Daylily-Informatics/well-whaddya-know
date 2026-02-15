// SPDX-License-Identifier: MIT
// Aggregations.swift - Pure aggregation functions per SPEC.md Section 8.2

import Foundation
import Timeline

// MARK: - Aggregation Functions

/// Pure aggregation functions that consume [EffectiveSegment] and produce reports.
/// All functions are deterministic, have no side effects, and never query SQLite.
public enum Aggregations {

    // MARK: - Total Working Time

    /// Calculate total working time (observed segments only)
    /// - Parameter segments: The effective segments to aggregate
    /// - Returns: Total seconds of observed working time
    public static func totalWorkingTime(segments: [EffectiveSegment]) -> Double {
        segments
            .filter { $0.coverage == .observed }
            .reduce(0.0) { $0 + $1.durationSeconds }
    }

    // MARK: - Totals by Application

    /// Calculate totals grouped by application bundle ID
    /// - Parameter segments: The effective segments to aggregate
    /// - Returns: Dictionary keyed by bundle ID, values are total seconds
    public static func totalsByApplication(segments: [EffectiveSegment]) -> [String: Double] {
        var result: [String: Double] = [:]
        for segment in segments {
            let key = segment.appBundleId.isEmpty ? "(no bundle id)" : segment.appBundleId
            result[key, default: 0.0] += segment.durationSeconds
        }
        return result
    }

    // MARK: - Totals by Window Title

    /// Calculate totals grouped by window title
    /// - Parameter segments: The effective segments to aggregate
    /// - Returns: Dictionary keyed by window title, values are total seconds
    public static func totalsByWindowTitle(segments: [EffectiveSegment]) -> [String: Double] {
        var result: [String: Double] = [:]
        for segment in segments {
            let key = segment.windowTitle ?? "(no title)"
            result[key, default: 0.0] += segment.durationSeconds
        }
        return result
    }

    // MARK: - Totals by Tag

    /// Calculate totals grouped by tag
    /// A segment with multiple tags contributes its full duration to each tag
    /// - Parameter segments: The effective segments to aggregate
    /// - Returns: Dictionary keyed by tag name, values are total seconds
    public static func totalsByTag(segments: [EffectiveSegment]) -> [String: Double] {
        var result: [String: Double] = [:]
        for segment in segments {
            if segment.tags.isEmpty {
                result["(untagged)", default: 0.0] += segment.durationSeconds
            } else {
                for tag in segment.tags {
                    result[tag, default: 0.0] += segment.durationSeconds
                }
            }
        }
        return result
    }

    // MARK: - Totals by Day

    /// Calculate totals grouped by local calendar day
    /// Segments crossing midnight are split before aggregation
    /// - Parameters:
    ///   - segments: The effective segments to aggregate
    ///   - timeZone: The timezone for local day calculation
    /// - Returns: Dictionary keyed by YYYY-MM-DD string, values are total seconds
    public static func totalsByDay(
        segments: [EffectiveSegment],
        timeZone: TimeZone
    ) -> [String: Double] {
        // First split segments at midnight boundaries
        let splitSegments = DailySplitter.splitSegmentsByDay(segments: segments, timeZone: timeZone)
        
        var result: [String: Double] = [:]
        let calendar = Calendar(identifier: .gregorian)
        
        for segment in splitSegments {
            let date = Date(timeIntervalSince1970: Double(segment.startTsUs) / 1_000_000.0)
            let dateKey = formatDateKey(date: date, timeZone: timeZone, calendar: calendar)
            result[dateKey, default: 0.0] += segment.durationSeconds
        }
        return result
    }

    // MARK: - Totals by App Name

    /// Calculate totals grouped by application display name (observed only)
    /// - Parameter segments: The effective segments to aggregate
    /// - Returns: Dictionary keyed by app name, values are total seconds
    public static func totalsByAppName(segments: [EffectiveSegment]) -> [String: Double] {
        var result: [String: Double] = [:]
        for segment in segments where segment.coverage == .observed {
            let key = segment.appName.isEmpty ? "(unknown)" : segment.appName
            result[key, default: 0.0] += segment.durationSeconds
        }
        return result
    }

    // MARK: - Totals by App Name + Window Title

    /// Aggregate observed time by (appName, windowTitle) pair, sorted descending by seconds
    public static func totalsByAppNameAndWindow(
        segments: [EffectiveSegment]
    ) -> [(appName: String, windowTitle: String, seconds: Double)] {
        struct Key: Hashable { let app: String; let title: String }
        var map: [Key: Double] = [:]
        for segment in segments where segment.coverage == .observed {
            let app = segment.appName.isEmpty ? "(unknown)" : segment.appName
            let title = segment.windowTitle ?? "(no title)"
            map[Key(app: app, title: title), default: 0.0] += segment.durationSeconds
        }
        return map
            .map { (appName: $0.key.app, windowTitle: $0.key.title, seconds: $0.value) }
            .sorted { $0.seconds > $1.seconds }
    }

    // MARK: - Unobserved Gap Totals

    /// Calculate total unobserved gap time
    /// - Parameter segments: The effective segments to aggregate
    /// - Returns: Total seconds of unobserved gap time
    public static func totalUnobservedGaps(segments: [EffectiveSegment]) -> Double {
        segments
            .filter { $0.coverage == .unobservedGap }
            .reduce(0.0) { $0 + $1.durationSeconds }
    }

    // MARK: - Period Grouping Strategy

    /// Grouping strategy for time-bucketed aggregation
    public enum PeriodGroupBy: Sendable {
        case app
        case appWindow
        case tag
    }

    /// Backwards-compatible alias
    public typealias HourlyGroupBy = PeriodGroupBy

    // MARK: - Totals by Hour

    /// Aggregate observed time into hourly buckets grouped by app, app+window, or tag.
    ///
    /// Segments spanning multiple hours are split at the hour boundary so each
    /// hour gets the correct proportion of time. Only `.observed` segments are
    /// included; gaps are skipped.
    ///
    /// - Parameters:
    ///   - segments: The effective segments to aggregate
    ///   - timeZone: Timezone for determining local hour-of-day
    ///   - groupBy: How to label each bucket (app name, app+window, or tag)
    /// - Returns: Array of (hour 0-23, label, seconds) tuples sorted by hour then label
    public static func totalsByHour(
        segments: [EffectiveSegment],
        timeZone: TimeZone,
        groupBy: HourlyGroupBy
    ) -> [(hour: Int, label: String, seconds: Double)] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        struct BucketKey: Hashable { let hour: Int; let label: String }
        var buckets: [BucketKey: Double] = [:]

        for segment in segments where segment.coverage == .observed {
            let labels = labelsForSegment(segment, groupBy: groupBy)

            // Split the segment at hour boundaries
            let parts = splitAtHourBoundaries(segment: segment, calendar: calendar)

            for (partStartUs, partEndUs) in parts {
                let dur = Double(partEndUs - partStartUs) / 1_000_000.0
                guard dur > 0 else { continue }
                let partDate = Date(timeIntervalSince1970: Double(partStartUs) / 1_000_000.0)
                let hour = calendar.component(.hour, from: partDate)
                for label in labels {
                    buckets[BucketKey(hour: hour, label: label), default: 0.0] += dur
                }
            }
        }

        return buckets
            .map { (hour: $0.key.hour, label: $0.key.label, seconds: $0.value) }
            .sorted { $0.hour != $1.hour ? $0.hour < $1.hour : $0.label < $1.label }
    }

    // MARK: - Totals by Day (grouped)

    /// Aggregate observed time into daily buckets grouped by category.
    /// Segments are split at midnight boundaries via DailySplitter for accuracy.
    public static func totalsByDayGrouped(
        segments: [EffectiveSegment],
        timeZone: TimeZone,
        groupBy: PeriodGroupBy
    ) -> [(period: String, label: String, seconds: Double)] {
        let split = DailySplitter.splitSegmentsByDay(segments: segments, timeZone: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        struct BK: Hashable { let period: String; let label: String }
        var buckets: [BK: Double] = [:]

        for seg in split where seg.coverage == .observed {
            let date = Date(timeIntervalSince1970: Double(seg.startTsUs) / 1_000_000.0)
            let comps = calendar.dateComponents([.year, .month, .day], from: date)
            let period = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
            for lbl in labelsForSegment(seg, groupBy: groupBy) {
                buckets[BK(period: period, label: lbl), default: 0.0] += seg.durationSeconds
            }
        }

        return buckets
            .map { (period: $0.key.period, label: $0.key.label, seconds: $0.value) }
            .sorted { $0.period != $1.period ? $0.period < $1.period : $0.label < $1.label }
    }

    // MARK: - Totals by Week (grouped)

    /// Aggregate observed time into ISO-week buckets grouped by category.
    /// Segments are split at midnight first, then assigned to their ISO week.
    public static func totalsByWeekGrouped(
        segments: [EffectiveSegment],
        timeZone: TimeZone,
        groupBy: PeriodGroupBy
    ) -> [(period: String, label: String, seconds: Double)] {
        let split = DailySplitter.splitSegmentsByDay(segments: segments, timeZone: timeZone)
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = timeZone

        struct BK: Hashable { let period: String; let label: String }
        var buckets: [BK: Double] = [:]

        for seg in split where seg.coverage == .observed {
            let date = Date(timeIntervalSince1970: Double(seg.startTsUs) / 1_000_000.0)
            let comps = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
            let period = String(format: "%04d-W%02d", comps.yearForWeekOfYear ?? 0, comps.weekOfYear ?? 0)
            for lbl in labelsForSegment(seg, groupBy: groupBy) {
                buckets[BK(period: period, label: lbl), default: 0.0] += seg.durationSeconds
            }
        }

        return buckets
            .map { (period: $0.key.period, label: $0.key.label, seconds: $0.value) }
            .sorted { $0.period != $1.period ? $0.period < $1.period : $0.label < $1.label }
    }

    // MARK: - Totals by Month (grouped)

    /// Aggregate observed time into year-month buckets grouped by category.
    /// Segments are split at midnight first, then assigned to their calendar month.
    public static func totalsByMonthGrouped(
        segments: [EffectiveSegment],
        timeZone: TimeZone,
        groupBy: PeriodGroupBy
    ) -> [(period: String, label: String, seconds: Double)] {
        let split = DailySplitter.splitSegmentsByDay(segments: segments, timeZone: timeZone)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone

        struct BK: Hashable { let period: String; let label: String }
        var buckets: [BK: Double] = [:]

        let monthNames = ["Jan","Feb","Mar","Apr","May","Jun",
                          "Jul","Aug","Sep","Oct","Nov","Dec"]

        for seg in split where seg.coverage == .observed {
            let date = Date(timeIntervalSince1970: Double(seg.startTsUs) / 1_000_000.0)
            let comps = calendar.dateComponents([.year, .month], from: date)
            let m = (comps.month ?? 1) - 1
            let period = String(format: "%04d-%02d", comps.year ?? 0, (comps.month ?? 1))
            let displayPeriod = "\(monthNames[min(max(m, 0), 11)]) \(comps.year ?? 0)"
            // Use sortable key for ordering but store display label
            _ = displayPeriod
            for lbl in labelsForSegment(seg, groupBy: groupBy) {
                buckets[BK(period: period, label: lbl), default: 0.0] += seg.durationSeconds
            }
        }

        return buckets
            .map { (period: $0.key.period, label: $0.key.label, seconds: $0.value) }
            .sorted { $0.period != $1.period ? $0.period < $1.period : $0.label < $1.label }
    }

    // MARK: - Private Helpers

    /// Extract label(s) for a segment based on grouping strategy
    private static func labelsForSegment(
        _ segment: EffectiveSegment,
        groupBy: PeriodGroupBy
    ) -> [String] {
        switch groupBy {
        case .app:
            return [segment.appName.isEmpty ? "(unknown)" : segment.appName]
        case .appWindow:
            let app = segment.appName.isEmpty ? "(unknown)" : segment.appName
            let title = segment.windowTitle ?? "(no title)"
            return ["\(app) — \(title)"]
        case .tag:
            if segment.tags.isEmpty {
                return ["(untagged)"]
            }
            return segment.tags
        }
    }

    /// Split a single segment at local hour boundaries, returning (startUs, endUs) pairs
    private static func splitAtHourBoundaries(
        segment: EffectiveSegment,
        calendar: Calendar
    ) -> [(Int64, Int64)] {
        guard segment.endTsUs > segment.startTsUs else { return [] }

        let startDate = Date(timeIntervalSince1970: Double(segment.startTsUs) / 1_000_000.0)
        let endDate = Date(timeIntervalSince1970: Double(segment.endTsUs) / 1_000_000.0)

        // Collect hour boundaries that fall strictly within (start, end)
        var boundaries: [Int64] = []
        // Start of the next hour after startDate
        var comps = calendar.dateComponents([.year, .month, .day, .hour], from: startDate)
        comps.minute = 0; comps.second = 0
        guard var nextHour = calendar.date(from: comps) else {
            return [(segment.startTsUs, segment.endTsUs)]
        }
        // Advance to the next full hour
        if nextHour <= startDate {
            guard let nh = calendar.date(byAdding: .hour, value: 1, to: nextHour) else {
                return [(segment.startTsUs, segment.endTsUs)]
            }
            nextHour = nh
        }

        while nextHour < endDate {
            boundaries.append(Int64(nextHour.timeIntervalSince1970 * 1_000_000.0))
            guard let nh = calendar.date(byAdding: .hour, value: 1, to: nextHour) else { break }
            nextHour = nh
        }

        if boundaries.isEmpty {
            return [(segment.startTsUs, segment.endTsUs)]
        }

        var result: [(Int64, Int64)] = []
        var curStart = segment.startTsUs
        for boundary in boundaries {
            if boundary > curStart {
                result.append((curStart, boundary))
            }
            curStart = boundary
        }
        if segment.endTsUs > curStart {
            result.append((curStart, segment.endTsUs))
        }
        return result
    }

    private static func formatDateKey(date: Date, timeZone: TimeZone, calendar: Calendar) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        let components = cal.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      components.year ?? 0,
                      components.month ?? 0,
                      components.day ?? 0)
    }
}

