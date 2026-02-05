// SPDX-License-Identifier: MIT
// Agent+GapDetection.swift - Crash recovery and gap detection per SPEC.md Section 5.5.E

import Foundation
import Sensors

extension Agent {
    
    /// Detect gaps from crashed/killed previous runs and emit gap_detected events.
    /// Per SPEC.md Section 5.5.E:
    /// - If the agent is not running, there is no tracking (observability gap)
    /// - On next start, detect last agent_start without matching agent_stop
    /// - Emit gap_detected event with gap_start_ts_us and gap_end_ts_us
    /// - Gap time must be treated as not working / unobserved
    func detectAndEmitGaps(currentTimestampUs: Int64, currentMonotonicNs: UInt64) async throws {
        // Find previous run
        guard let previousRun = try eventWriter.findPreviousRun() else {
            // No previous run exists, nothing to check
            return
        }
        
        // Check if previous run has an agent_stop event
        let hasStop = try eventWriter.hasAgentStopEvent(forRunId: previousRun.runId)
        
        if !hasStop {
            // Previous run crashed - emit gap_detected
            // The gap is from the last event of the crashed run to now
            let gapPayload = """
                {"gap_start_ts_us": \(previousRun.lastEventTsUs), "gap_end_ts_us": \(currentTimestampUs), "previous_run_id": "\(previousRun.runId)"}
                """
            
            try eventWriter.insertSystemStateEvent(
                eventTsUs: currentTimestampUs,
                eventMonotonicNs: currentMonotonicNs,
                state: state,
                eventKind: SystemStateEventKind.gapDetected,
                source: SensorSource.startupProbe,
                tzIdentifier: TimeZone.current.identifier,
                tzOffsetSeconds: TimeZone.current.secondsFromGMT(),
                payloadJson: gapPayload
            )
        }
    }
}

