// SPDX-License-Identifier: MIT
// TimelineBuilder.swift - Deterministic effective timeline builder per SPEC.md Section 7

import CoreModel
import Foundation

/// Internal segment used during timeline construction
/// Mutable to allow tag modifications
struct WorkingSegment: Equatable {
    var interval: TimeInterval
    var source: SegmentSource
    var appBundleId: String
    var appName: String
    var windowTitle: String?
    var tags: Set<String>
    var coverage: SegmentCoverage
    var supportingIds: [Int64]
    
    func toEffectiveSegment() -> EffectiveSegment {
        EffectiveSegment(
            startTsUs: interval.startUs,
            endTsUs: interval.endUs,
            source: source,
            appBundleId: appBundleId,
            appName: appName,
            windowTitle: windowTitle,
            tags: tags.sorted(),
            coverage: coverage,
            supportingIds: supportingIds
        )
    }
}

/// Build the effective timeline from raw events and user edits
/// This is a pure function with no side effects
///
/// Algorithm per SPEC.md Section 7.2:
/// 1. Compute base working intervals from system_state_events
/// 2. Compute base attribution segments from raw_activity_events intersected with working intervals
/// 3. Apply user edits in strict order:
///    a. Filter out undone edits (undo_edit)
///    b. Apply delete_range (subtract time)
///    c. Apply add_range (insert time, overrides raw)
///    d. Apply tag_range / untag_range (metadata only)
///
/// - Parameters:
///   - systemStateEvents: System state events sorted by event_ts_us
///   - rawActivityEvents: Raw activity events sorted by event_ts_us
///   - userEditEvents: User edit events sorted by created_ts_us
///   - requestedRange: Half-open range [startUs, endUs) to build timeline for
/// - Returns: Array of EffectiveSegment sorted by start time, no overlaps, no zero-duration
public func buildEffectiveTimeline(
    systemStateEvents: [SystemStateEvent],
    rawActivityEvents: [RawActivityEvent],
    userEditEvents: [UserEditEvent],
    requestedRange: (startUs: Int64, endUs: Int64)
) -> [EffectiveSegment] {
    let range = TimeInterval(startUs: requestedRange.startUs, endUs: requestedRange.endUs)
    
    // Step 1: Compute base working intervals from system_state_events
    let workingIntervals = computeWorkingIntervals(
        from: systemStateEvents,
        clippedTo: range
    )
    
    // Step 2: Compute base attribution segments from raw_activity_events
    var segments = computeBaseSegments(
        from: rawActivityEvents,
        workingIntervals: workingIntervals,
        clippedTo: range
    )
    
    // Step 3: Apply user edits in strict order
    let activeEdits = filterActiveEdits(userEditEvents)

    // 3a. Apply delete_range (subtract time) and collect deleted intervals
    // Per SPEC.md Section 7.4: Delete beats everything - even manual adds
    let deleteEdits = activeEdits.filter { $0.op == .deleteRange }
        .sorted { $0.createdTsUs < $1.createdTsUs }
    var deletedIntervals: [TimeInterval] = []
    for edit in deleteEdits {
        let deleteInterval = TimeInterval(startUs: edit.startTsUs, endUs: edit.endTsUs)
        deletedIntervals.append(deleteInterval)
        segments = applyDeleteRange(edit, to: segments)
    }

    // 3b. Apply add_range (insert time, overrides raw)
    // But respect deleted intervals - delete beats everything
    let addEdits = activeEdits.filter { $0.op == .addRange }
        .sorted { $0.createdTsUs < $1.createdTsUs }
    for edit in addEdits {
        segments = applyAddRange(edit, to: segments, clippedTo: range, deletedIntervals: deletedIntervals)
    }

    // 3c. Apply tag_range / untag_range (metadata only)
    let tagEdits = activeEdits.filter { $0.op == .tagRange || $0.op == .untagRange }
        .sorted { $0.createdTsUs < $1.createdTsUs }
    for edit in tagEdits {
        segments = applyTagEdit(edit, to: segments)
    }
    
    // Final cleanup: remove zero-duration, sort, convert to output type
    return segments
        .filter { !$0.interval.isEmpty }
        .sorted { $0.interval < $1.interval }
        .map { $0.toEffectiveSegment() }
}

// MARK: - Step 1: Compute Working Intervals

/// Compute working intervals from system state events
/// Working = isSystemAwake && isSessionOnConsole && !isScreenLocked
func computeWorkingIntervals(
    from events: [SystemStateEvent],
    clippedTo range: TimeInterval
) -> [TimeInterval] {
    guard !events.isEmpty else { return [] }
    
    // Sort events by timestamp
    let sorted = events.sorted { $0.eventTsUs < $1.eventTsUs }
    
    var intervals: [TimeInterval] = []
    var workingStart: Int64? = nil
    
    for event in sorted {
        if event.isWorking {
            // Transition to working
            if workingStart == nil {
                workingStart = event.eventTsUs
            }
        } else {
            // Transition to not working
            if let start = workingStart {
                let interval = TimeInterval(startUs: start, endUs: event.eventTsUs)
                if let clipped = interval.intersection(with: range) {
                    intervals.append(clipped)
                }
                workingStart = nil
            }
        }
    }
    
    // Handle case where working extends to end of range
    if let start = workingStart {
        let interval = TimeInterval(startUs: start, endUs: range.endUs)
        if let clipped = interval.intersection(with: range) {
            intervals.append(clipped)
        }
    }
    
    return intervals
}

// MARK: - Step 2: Compute Base Segments

/// Compute base attribution segments from raw activity events
/// Each raw event extends until the next event or end of working interval
func computeBaseSegments(
    from events: [RawActivityEvent],
    workingIntervals: [TimeInterval],
    clippedTo range: TimeInterval
) -> [WorkingSegment] {
    guard !events.isEmpty, !workingIntervals.isEmpty else { return [] }

    // Sort events by timestamp
    let sorted = events.sorted { $0.eventTsUs < $1.eventTsUs }

    var segments: [WorkingSegment] = []

    for i in 0..<sorted.count {
        let event = sorted[i]
        let eventStart = event.eventTsUs

        // Find the end of this event's attribution
        // Either the next event's timestamp or end of range
        let eventEnd: Int64
        if i + 1 < sorted.count {
            eventEnd = sorted[i + 1].eventTsUs
        } else {
            eventEnd = range.endUs
        }

        let eventInterval = TimeInterval(startUs: eventStart, endUs: eventEnd)

        // Intersect with each working interval
        for workingInterval in workingIntervals {
            if let intersection = eventInterval.intersection(with: workingInterval) {
                if let clipped = intersection.intersection(with: range), !clipped.isEmpty {
                    segments.append(WorkingSegment(
                        interval: clipped,
                        source: .raw,
                        appBundleId: event.appBundleId,
                        appName: event.appDisplayName,
                        windowTitle: event.windowTitle,
                        tags: [],
                        coverage: .observed,
                        supportingIds: [event.raeId]
                    ))
                }
            }
        }
    }

    return segments
}

// MARK: - Step 3a: Filter Active Edits (Undo handling)

/// Filter out edits that have been undone per SPEC.md Section 7.3
/// An edit is inactive if targeted by an undo_edit that is itself not undone
func filterActiveEdits(_ edits: [UserEditEvent]) -> [UserEditEvent] {
    // Build set of undone edit IDs
    // An undo is active if it's not itself undone
    var undoneIds = Set<Int64>()

    // First pass: find all undo_edit operations and their targets
    // If multiple undos target the same edit, most recent wins
    let undoEdits = edits.filter { $0.op == .undoEdit }
        .sorted { $0.createdTsUs > $1.createdTsUs }  // Most recent first

    // Track which undos are themselves undone
    var undoIsUndone = Set<Int64>()

    for undo in undoEdits {
        if let targetId = undo.targetUeeId {
            // Check if this undo targets another undo
            if undoEdits.contains(where: { $0.ueeId == targetId }) {
                undoIsUndone.insert(targetId)
            }
        }
    }

    // Now determine which edits are undone
    for undo in undoEdits {
        // Skip if this undo is itself undone
        if undoIsUndone.contains(undo.ueeId) {
            continue
        }
        if let targetId = undo.targetUeeId {
            undoneIds.insert(targetId)
        }
    }

    // Filter out undone edits and undo_edit operations themselves
    return edits.filter { edit in
        if edit.op == .undoEdit {
            return false  // Don't include undo operations in active edits
        }
        return !undoneIds.contains(edit.ueeId)
    }
}

// MARK: - Step 3b: Apply Delete Range

/// Apply delete_range edit - subtract time from segments
/// Per SPEC.md Section 7.4: Delete beats everything
func applyDeleteRange(_ edit: UserEditEvent, to segments: [WorkingSegment]) -> [WorkingSegment] {
    let deleteInterval = TimeInterval(startUs: edit.startTsUs, endUs: edit.endTsUs)

    var result: [WorkingSegment] = []

    for segment in segments {
        let remaining = segment.interval.subtracting(deleteInterval)
        for interval in remaining {
            if !interval.isEmpty {
                var newSegment = segment
                newSegment.interval = interval
                result.append(newSegment)
            }
        }
    }

    return result
}

// MARK: - Step 3c: Apply Add Range

/// Apply add_range edit - insert manual segment, overriding raw
/// Per SPEC.md Section 7.4: Manual add beats raw, but delete beats everything
func applyAddRange(
    _ edit: UserEditEvent,
    to segments: [WorkingSegment],
    clippedTo range: TimeInterval,
    deletedIntervals: [TimeInterval] = []
) -> [WorkingSegment] {
    let addInterval = TimeInterval(startUs: edit.startTsUs, endUs: edit.endTsUs)

    guard let clipped = addInterval.intersection(with: range), !clipped.isEmpty else {
        return segments
    }

    var result: [WorkingSegment] = []

    // First, subtract the add interval from all existing segments
    for segment in segments {
        let remaining = segment.interval.subtracting(clipped)
        for interval in remaining {
            if !interval.isEmpty {
                var newSegment = segment
                newSegment.interval = interval
                result.append(newSegment)
            }
        }
    }

    // Compute effective intervals for the manual segment after applying deletes
    // Per SPEC.md Section 7.4: Delete beats everything
    var manualIntervals = [clipped]
    for deleteInterval in deletedIntervals {
        var newIntervals: [TimeInterval] = []
        for interval in manualIntervals {
            newIntervals.append(contentsOf: interval.subtracting(deleteInterval))
        }
        manualIntervals = newIntervals
    }

    // Add manual segments for each remaining interval
    for interval in manualIntervals where !interval.isEmpty {
        let manualSegment = WorkingSegment(
            interval: interval,
            source: .manual,
            appBundleId: edit.manualAppBundleId ?? "unknown",
            appName: edit.manualAppName ?? "Unknown",
            windowTitle: edit.manualWindowTitle,
            tags: [],
            coverage: .observed,
            supportingIds: [edit.ueeId]
        )
        result.append(manualSegment)
    }

    return result
}

// MARK: - Step 3d: Apply Tag Edit

/// Apply tag_range or untag_range edit - add/remove tags from overlapping segments
/// Per SPEC.md Section 7.4: Tags are additive overlays, no duration changes
func applyTagEdit(_ edit: UserEditEvent, to segments: [WorkingSegment]) -> [WorkingSegment] {
    guard let tagName = edit.tagName else {
        return segments
    }

    let editInterval = TimeInterval(startUs: edit.startTsUs, endUs: edit.endTsUs)

    var result: [WorkingSegment] = []

    for segment in segments {
        var modifiedSegment = segment

        if segment.interval.overlaps(with: editInterval) {
            // This segment overlaps with the tag edit
            // For simplicity, we apply the tag to the entire segment if any part overlaps
            // A more precise implementation would split segments at tag boundaries
            switch edit.op {
            case .tagRange:
                modifiedSegment.tags.insert(tagName)
            case .untagRange:
                modifiedSegment.tags.remove(tagName)
            default:
                break
            }
        }

        result.append(modifiedSegment)
    }

    return result
}

