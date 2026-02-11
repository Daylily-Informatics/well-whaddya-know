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
    
    /// CSV header row per SPEC.md Section 8.4 (13 columns including coverage)
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
        "tags",
        "coverage"
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

        // Sort by start time for deterministic output
        let sortedSegments = segments.sorted { $0.startTsUs < $1.startTsUs }

        for segment in sortedSegments {
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
            escapeCSV(tagsStr),
            segment.coverage.rawValue
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

// MARK: - Markdown Invoice Export

/// Exports a Markdown-formatted invoice of tasks in a time range.
public enum InvoiceExporter {

    /// Generate a Markdown invoice aggregated by app (and optionally window title).
    /// - Parameters:
    ///   - segments: Effective segments for the invoice period
    ///   - identity: Machine / user identity
    ///   - rangeStart: Invoice period start (Date)
    ///   - rangeEnd: Invoice period end (Date)
    ///   - includeTitles: Whether to break down by window title
    ///   - tzOffsetSeconds: Timezone offset for display
    /// - Returns: Complete Markdown string
    public static func export(
        segments: [EffectiveSegment],
        identity: ReportIdentity,
        rangeStart: Date,
        rangeEnd: Date,
        includeTitles: Bool = true,
        tzOffsetSeconds: Int = TimeZone.current.secondsFromGMT()
    ) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .medium
        dateFmt.timeStyle = .short
        dateFmt.timeZone = TimeZone(secondsFromGMT: tzOffsetSeconds)

        let observed = segments.filter { $0.coverage == .observed }
        let totalSeconds = observed.reduce(0.0) { $0 + $1.durationSeconds }

        var md = "# Invoice\n\n"
        md += "| Field | Value |\n|-------|-------|\n"
        md += "| **Date Range** | \(dateFmt.string(from: rangeStart)) — \(dateFmt.string(from: rangeEnd)) |\n"
        md += "| **Machine** | \(identity.machineId) |\n"
        md += "| **User** | \(identity.username) |\n"
        md += "| **Generated** | \(dateFmt.string(from: Date())) |\n\n"

        // Aggregate by app
        var byApp: [String: Double] = [:]
        var byAppWindow: [String: [String: Double]] = [:]
        for seg in observed {
            let app = seg.appName.isEmpty ? "(unknown)" : seg.appName
            byApp[app, default: 0] += seg.durationSeconds
            if includeTitles {
                let title = seg.windowTitle ?? "(no title)"
                byAppWindow[app, default: [:]][title, default: 0] += seg.durationSeconds
            }
        }

        let sortedApps = byApp.sorted { $0.value > $1.value }

        md += "## Tasks\n\n"

        if includeTitles {
            md += "| Application | Window / Task | Duration | % of Total |\n"
            md += "|-------------|---------------|----------|------------|\n"
            for (app, _) in sortedApps {
                let windows = (byAppWindow[app] ?? [:]).sorted { $0.value > $1.value }
                for (title, secs) in windows {
                    let pct = totalSeconds > 0 ? secs / totalSeconds * 100 : 0
                    md += "| \(app) | \(title) | \(formatDuration(secs)) | \(String(format: "%.1f%%", pct)) |\n"
                }
            }
        } else {
            md += "| Application | Duration | % of Total |\n"
            md += "|-------------|----------|------------|\n"
            for (app, secs) in sortedApps {
                let pct = totalSeconds > 0 ? secs / totalSeconds * 100 : 0
                md += "| \(app) | \(formatDuration(secs)) | \(String(format: "%.1f%%", pct)) |\n"
            }
        }

        md += "\n## Summary\n\n"
        md += "| Metric | Value |\n|--------|-------|\n"
        md += "| **Total Tracked Time** | \(formatDuration(totalSeconds)) |\n"
        md += "| **Total Hours** | \(String(format: "%.2f", totalSeconds / 3600.0)) |\n"
        md += "| **Unique Applications** | \(byApp.count) |\n"
        md += "| **Segments** | \(observed.count) |\n"

        return md
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}

