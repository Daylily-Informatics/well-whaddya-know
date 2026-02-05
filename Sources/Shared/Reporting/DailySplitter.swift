// SPDX-License-Identifier: MIT
// DailySplitter.swift - Split segments at local midnight boundaries per SPEC.md Section 8.3

import Foundation
import Timeline

/// Splits effective segments at local midnight boundaries for daily reporting.
/// Handles DST transitions correctly by using TimeZone parameter for all conversions.
public enum DailySplitter {

    /// Split segments at local midnight boundaries
    /// - Parameters:
    ///   - segments: The effective segments to split
    ///   - timeZone: The timezone for local midnight calculation
    /// - Returns: Segments split at midnight boundaries, sorted by start time
    public static func splitSegmentsByDay(
        segments: [EffectiveSegment],
        timeZone: TimeZone
    ) -> [EffectiveSegment] {
        var result: [EffectiveSegment] = []
        
        for segment in segments {
            let splitParts = splitSingleSegment(segment: segment, timeZone: timeZone)
            result.append(contentsOf: splitParts)
        }
        
        // Sort by start time for deterministic output
        return result.sorted { $0.startTsUs < $1.startTsUs }
    }

    /// Split a single segment at midnight boundaries
    private static func splitSingleSegment(
        segment: EffectiveSegment,
        timeZone: TimeZone
    ) -> [EffectiveSegment] {
        // Zero or negative duration - return unchanged
        guard segment.endTsUs > segment.startTsUs else {
            return [segment]
        }
        
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        
        let startDate = Date(timeIntervalSince1970: Double(segment.startTsUs) / 1_000_000.0)
        let endDate = Date(timeIntervalSince1970: Double(segment.endTsUs) / 1_000_000.0)
        
        // Get midnight boundaries between start and end
        let midnights = getMidnightsBetween(start: startDate, end: endDate, calendar: calendar)
        
        // If no midnights crossed, return unchanged
        if midnights.isEmpty {
            return [segment]
        }
        
        // Split at each midnight
        var result: [EffectiveSegment] = []
        var currentStartUs = segment.startTsUs
        
        for midnight in midnights {
            let midnightUs = Int64(midnight.timeIntervalSince1970 * 1_000_000.0)
            
            // Create segment from current start to midnight
            if midnightUs > currentStartUs {
                result.append(createSplitSegment(
                    from: segment,
                    startTsUs: currentStartUs,
                    endTsUs: midnightUs
                ))
            }
            
            currentStartUs = midnightUs
        }
        
        // Create final segment from last midnight to end
        if segment.endTsUs > currentStartUs {
            result.append(createSplitSegment(
                from: segment,
                startTsUs: currentStartUs,
                endTsUs: segment.endTsUs
            ))
        }
        
        return result
    }

    /// Get all midnight timestamps between start and end dates
    private static func getMidnightsBetween(
        start: Date,
        end: Date,
        calendar: Calendar
    ) -> [Date] {
        var midnights: [Date] = []
        
        // Get the start of the next day after start
        guard let startOfStartDay = calendar.startOfDay(for: start) as Date?,
              let nextDay = calendar.date(byAdding: .day, value: 1, to: startOfStartDay) else {
            return []
        }
        
        var currentMidnight = nextDay
        
        // Collect all midnights that fall within (start, end)
        while currentMidnight < end {
            if currentMidnight > start {
                midnights.append(currentMidnight)
            }
            
            guard let next = calendar.date(byAdding: .day, value: 1, to: currentMidnight) else {
                break
            }
            currentMidnight = next
        }
        
        return midnights
    }

    /// Create a new segment with updated timestamps, preserving all other fields
    private static func createSplitSegment(
        from original: EffectiveSegment,
        startTsUs: Int64,
        endTsUs: Int64
    ) -> EffectiveSegment {
        EffectiveSegment(
            startTsUs: startTsUs,
            endTsUs: endTsUs,
            source: original.source,
            appBundleId: original.appBundleId,
            appName: original.appName,
            windowTitle: original.windowTitle,
            tags: original.tags,
            coverage: original.coverage,
            supportingIds: original.supportingIds
        )
    }
}

