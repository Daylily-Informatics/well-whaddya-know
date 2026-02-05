// SPDX-License-Identifier: MIT
// Sensors.swift - Public API for the Sensors module

import Foundation

/// Sensors module for well-whaddya-know.
/// Provides wrappers around macOS system APIs for detecting:
/// - Session state (lock/console via CGSessionCopyCurrentDictionary)
/// - Sleep/wake events (via NSWorkspace notifications)
/// - Foreground app changes (via NSWorkspace notifications)
///
/// All sensors emit typed in-memory events via the SensorEventHandler protocol.
/// They do NOT write directly to the database - the agent handles persistence.
public enum Sensors {
    /// Module version for diagnostics
    public static let version = "1.0.0"
}

