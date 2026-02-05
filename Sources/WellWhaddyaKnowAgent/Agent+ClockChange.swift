// SPDX-License-Identifier: MIT
// Agent+ClockChange.swift - Clock change detection per SPEC.md Section 5.5.F

import Foundation
import Sensors

extension Agent {
    
    /// Threshold in seconds for detecting clock changes
    /// Per SPEC.md 5.5.F: emit clock_change if wall-clock delta deviates from monotonic delta by > 120 seconds
    static let clockChangeThresholdSeconds: Int64 = 120
    
    /// Check for clock changes and emit clock_change event if detected.
    /// Per SPEC.md 5.5.F:
    /// - Compare wall-clock delta to monotonic delta
    /// - If deviation exceeds 120 seconds, emit clock_change event
    ///
    /// - Parameters:
    ///   - currentTimestampUs: Current wall-clock time in microseconds
    ///   - currentMonotonicNs: Current monotonic time in nanoseconds
    ///   - previousTimestampUs: Previous wall-clock time in microseconds
    ///   - previousMonotonicNs: Previous monotonic time in nanoseconds
    /// - Returns: True if clock change was detected and event emitted
    func checkAndEmitClockChange(
        currentTimestampUs: Int64,
        currentMonotonicNs: UInt64,
        previousTimestampUs: Int64,
        previousMonotonicNs: UInt64
    ) throws -> Bool {
        // Calculate wall-clock delta in seconds
        let wallDeltaUs = currentTimestampUs - previousTimestampUs
        let wallDeltaSeconds = wallDeltaUs / 1_000_000
        
        // Calculate monotonic delta in seconds
        // Handle potential overflow by checking order
        let monotonicDeltaNs: UInt64
        if currentMonotonicNs >= previousMonotonicNs {
            monotonicDeltaNs = currentMonotonicNs - previousMonotonicNs
        } else {
            // Monotonic time wrapped (unlikely but handle it)
            return false
        }
        let monotonicDeltaSeconds = Int64(monotonicDeltaNs / 1_000_000_000)
        
        // Calculate deviation
        let deviation = abs(wallDeltaSeconds - monotonicDeltaSeconds)
        
        if deviation > Self.clockChangeThresholdSeconds {
            // Clock change detected - emit event
            let payload = """
                {"wall_delta_s": \(wallDeltaSeconds), "mono_delta_s": \(monotonicDeltaSeconds), "deviation_s": \(deviation)}
                """
            
            try eventWriter.insertSystemStateEvent(
                eventTsUs: currentTimestampUs,
                eventMonotonicNs: currentMonotonicNs,
                state: state,
                eventKind: .clockChange,
                source: .timerPoll,
                tzIdentifier: TimeZone.current.identifier,
                tzOffsetSeconds: TimeZone.current.secondsFromGMT(),
                payloadJson: payload
            )
            
            return true
        }
        
        return false
    }
}

