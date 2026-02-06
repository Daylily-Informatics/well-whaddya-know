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

    // MARK: - Private Helpers

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

