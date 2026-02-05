// SPDX-License-Identifier: MIT
// Reporting.swift - CSV and JSON export per SPEC.md Section 8.4

import Foundation
import CoreModel
import Timeline

// MARK: - Export Identity

/// Identity information for export headers
public struct ReportIdentity: Sendable, Codable, Equatable {
    public let machineId: String
    public let username: String
    public let uid: Int

    public init(machineId: String, username: String, uid: Int) {
        self.machineId = machineId
        self.username = username
        self.uid = uid
    }
}

// MARK: - CSV Export

/// CSV exporter for effective segments per SPEC.md Section 8.4
public enum CSVExporter {
    
    /// CSV header row per SPEC.md Section 8.4
    public static let header = [
        "machine_id",
        "username",
        "segment_start_local",
        "segment_end_local",
        "segment_start_utc",
        "segment_end_utc",
        "duration_seconds",
        "source",
        "app_bundle_id",
        "app_name",
        "window_title",
        "tags"
    ].joined(separator: ",")

    /// Export segments to CSV string
    /// - Parameters:
    ///   - segments: The effective segments to export
    ///   - identity: Identity information for machine_id and username columns
    ///   - includeTitles: Whether to include window titles (privacy option)
    ///   - tzOffsetSeconds: Timezone offset for local time conversion
    /// - Returns: Complete CSV string with header and data rows
    public static func export(
        segments: [EffectiveSegment],
        identity: ReportIdentity,
        includeTitles: Bool,
        tzOffsetSeconds: Int = TimeZone.current.secondsFromGMT()
    ) -> String {
        var lines: [String] = [header]

        for segment in segments {
            let row = formatRow(
                segment: segment,
                identity: identity,
                includeTitles: includeTitles,
                tzOffsetSeconds: tzOffsetSeconds
            )
            lines.append(row)
        }

        return lines.joined(separator: "\n")
    }

    private static func formatRow(
        segment: EffectiveSegment,
        identity: ReportIdentity,
        includeTitles: Bool,
        tzOffsetSeconds: Int
    ) -> String {
        let startLocal = formatLocalTimestamp(segment.startTsUs, tzOffsetSeconds: tzOffsetSeconds)
        let endLocal = formatLocalTimestamp(segment.endTsUs, tzOffsetSeconds: tzOffsetSeconds)
        let startUtc = formatUtcTimestamp(segment.startTsUs)
        let endUtc = formatUtcTimestamp(segment.endTsUs)
        let title = includeTitles ? (segment.windowTitle ?? "") : ""
        let tagsStr = segment.tags.joined(separator: ";")

        let fields = [
            escapeCSV(identity.machineId),
            escapeCSV(identity.username),
            startLocal,
            endLocal,
            startUtc,
            endUtc,
            String(format: "%.3f", segment.durationSeconds),
            segment.source.rawValue,
            escapeCSV(segment.appBundleId),
            escapeCSV(segment.appName),
            escapeCSV(title),
            escapeCSV(tagsStr)
        ]

        return fields.joined(separator: ",")
    }

    private static func escapeCSV(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func formatLocalTimestamp(_ tsUs: Int64, tzOffsetSeconds: Int) -> String {
        let date = Date(timeIntervalSince1970: Double(tsUs) / 1_000_000.0)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: tzOffsetSeconds)
        return formatter.string(from: date)
    }

    private static func formatUtcTimestamp(_ tsUs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(tsUs) / 1_000_000.0)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}

// MARK: - JSON Export

/// JSON exporter for effective segments per SPEC.md Section 8.4
public enum JSONExporter {

    /// Export segments to JSON string
    /// - Parameters:
    ///   - segments: The effective segments to export
    ///   - identity: Identity information
    ///   - range: The exported time range (startUs, endUs)
    ///   - includeTitles: Whether to include window titles (privacy option)
    /// - Returns: Complete JSON string
    public static func export(
        segments: [EffectiveSegment],
        identity: ReportIdentity,
        range: (startUs: Int64, endUs: Int64),
        includeTitles: Bool
    ) -> String {
        let exportedAt = formatUtcTimestamp(getCurrentTimestampUs())

        let segmentDicts = segments.map { segment in
            segmentToDict(segment, includeTitles: includeTitles)
        }

        let root: [String: Any] = [
            "identity": [
                "machine_id": identity.machineId,
                "username": identity.username,
                "uid": identity.uid
            ],
            "exported_at_utc": exportedAt,
            "range": [
                "start_utc": formatUtcTimestamp(range.startUs),
                "end_utc": formatUtcTimestamp(range.endUs)
            ],
            "segments": segmentDicts
        ]

        // Use JSONSerialization for pretty printing
        if let jsonData = try? JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            return String(data: jsonData, encoding: .utf8) ?? "{}"
        }
        return "{}"
    }

    private static func segmentToDict(_ segment: EffectiveSegment, includeTitles: Bool) -> [String: Any] {
        var dict: [String: Any] = [
            "start_ts_us": segment.startTsUs,
            "end_ts_us": segment.endTsUs,
            "start_utc": formatUtcTimestamp(segment.startTsUs),
            "end_utc": formatUtcTimestamp(segment.endTsUs),
            "duration_seconds": segment.durationSeconds,
            "source": segment.source.rawValue,
            "app_bundle_id": segment.appBundleId,
            "app_name": segment.appName,
            "coverage": segment.coverage.rawValue,
            "tags": segment.tags
        ]

        if includeTitles, let title = segment.windowTitle {
            dict["window_title"] = title
        }

        if !segment.supportingIds.isEmpty {
            dict["supporting_ids"] = segment.supportingIds
        }

        return dict
    }

    private static func formatUtcTimestamp(_ tsUs: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(tsUs) / 1_000_000.0)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    private static func getCurrentTimestampUs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000_000)
    }
}

