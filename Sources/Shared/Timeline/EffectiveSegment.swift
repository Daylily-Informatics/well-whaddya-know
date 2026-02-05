// SPDX-License-Identifier: MIT
// EffectiveSegment.swift - Output type for timeline builder per SPEC.md Section 8.1

import Foundation

/// Represents a segment of effective working time after applying all edits
/// This is the "reporting IR" - all reports are derived from these segments
public struct EffectiveSegment: Sendable, Equatable {
    /// Start timestamp in microseconds since Unix epoch (inclusive)
    public let startTsUs: Int64
    
    /// End timestamp in microseconds since Unix epoch (exclusive)
    public let endTsUs: Int64
    
    /// Duration in seconds (computed from timestamps)
    public var durationSeconds: Double {
        Double(endTsUs - startTsUs) / 1_000_000.0
    }
    
    /// Source of this segment
    public let source: SegmentSource
    
    /// Application bundle identifier
    public let appBundleId: String
    
    /// Application display name
    public let appName: String
    
    /// Window title (nullable - may not be available)
    public let windowTitle: String?
    
    /// Tags applied to this segment
    public let tags: [String]
    
    /// Coverage type - observed or gap
    public let coverage: SegmentCoverage
    
    /// Supporting event IDs for debugging/export (optional)
    public let supportingIds: [Int64]
    
    public init(
        startTsUs: Int64,
        endTsUs: Int64,
        source: SegmentSource,
        appBundleId: String,
        appName: String,
        windowTitle: String?,
        tags: [String] = [],
        coverage: SegmentCoverage,
        supportingIds: [Int64] = []
    ) {
        self.startTsUs = startTsUs
        self.endTsUs = endTsUs
        self.source = source
        self.appBundleId = appBundleId
        self.appName = appName
        self.windowTitle = windowTitle
        self.tags = tags
        self.coverage = coverage
        self.supportingIds = supportingIds
    }
}

/// Source of the segment - raw observation or manual entry
public enum SegmentSource: String, Sendable, Equatable {
    case raw = "raw"
    case manual = "manual"
}

/// Coverage type - whether time was observed or is a gap
public enum SegmentCoverage: String, Sendable, Equatable {
    case observed = "observed"
    case unobservedGap = "unobserved_gap"
}

// MARK: - Interval Type for Internal Processing

/// Half-open interval [start, end) for internal timeline processing
public struct TimeInterval: Sendable, Equatable, Comparable {
    public let startUs: Int64
    public let endUs: Int64
    
    public var isEmpty: Bool {
        endUs <= startUs
    }
    
    public var durationUs: Int64 {
        max(0, endUs - startUs)
    }
    
    public init(startUs: Int64, endUs: Int64) {
        self.startUs = startUs
        self.endUs = endUs
    }
    
    /// Check if this interval overlaps with another
    public func overlaps(with other: TimeInterval) -> Bool {
        startUs < other.endUs && other.startUs < endUs
    }
    
    /// Check if this interval contains a timestamp
    public func contains(_ tsUs: Int64) -> Bool {
        tsUs >= startUs && tsUs < endUs
    }
    
    /// Intersect with another interval
    public func intersection(with other: TimeInterval) -> TimeInterval? {
        let newStart = max(startUs, other.startUs)
        let newEnd = min(endUs, other.endUs)
        if newStart < newEnd {
            return TimeInterval(startUs: newStart, endUs: newEnd)
        }
        return nil
    }
    
    /// Subtract another interval, returning 0, 1, or 2 intervals
    public func subtracting(_ other: TimeInterval) -> [TimeInterval] {
        guard overlaps(with: other) else {
            return [self]
        }
        
        var result: [TimeInterval] = []
        
        // Left piece (before the subtracted interval)
        if startUs < other.startUs {
            result.append(TimeInterval(startUs: startUs, endUs: other.startUs))
        }
        
        // Right piece (after the subtracted interval)
        if endUs > other.endUs {
            result.append(TimeInterval(startUs: other.endUs, endUs: endUs))
        }
        
        return result
    }
    
    public static func < (lhs: TimeInterval, rhs: TimeInterval) -> Bool {
        if lhs.startUs != rhs.startUs {
            return lhs.startUs < rhs.startUs
        }
        return lhs.endUs < rhs.endUs
    }
}

