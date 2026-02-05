// SPDX-License-Identifier: MIT
// ExportTests.swift - Tests for CSV/JSON export per SPEC.md Section 8.4

import Foundation
import Reporting
import Testing
import Timeline

@Suite("Export Tests")
struct ExportTests {

    // MARK: - Test Helpers

    /// Create an effective segment for testing
    func makeSegment(
        startTsUs: Int64,
        endTsUs: Int64,
        bundleId: String = "com.test.app",
        appName: String = "Test App",
        title: String? = "Window",
        tags: [String] = [],
        coverage: SegmentCoverage = .observed,
        source: SegmentSource = .raw
    ) -> EffectiveSegment {
        EffectiveSegment(
            startTsUs: startTsUs,
            endTsUs: endTsUs,
            source: source,
            appBundleId: bundleId,
            appName: appName,
            windowTitle: title,
            tags: tags,
            coverage: coverage,
            supportingIds: []
        )
    }

    let testIdentity = ReportIdentity(machineId: "test-machine", username: "testuser", uid: 501)

    // MARK: - Fixture 6: CSV export byte-for-byte

    @Test("CSV export has 13 columns including coverage")
    func testCSVColumns() {
        let segments = [
            makeSegment(
                startTsUs: 1738800000_000000,  // 2025-02-06 00:00:00 UTC
                endTsUs: 1738803600_000000,    // 2025-02-06 01:00:00 UTC
                bundleId: "com.apple.Safari",
                appName: "Safari",
                title: "GitHub",
                tags: ["work", "dev"],
                coverage: .observed
            ),
        ]

        let csv = CSVExporter.export(
            segments: segments,
            identity: testIdentity,
            includeTitles: true,
            tzOffsetSeconds: 0  // UTC for simplicity
        )

        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 2)  // header + 1 data row

        // Check header has 13 columns
        let headerCols = lines[0].split(separator: ",", omittingEmptySubsequences: false)
        #expect(headerCols.count == 13)
        #expect(headerCols[12] == "coverage")

        // Check data row has 13 columns
        let dataCols = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        #expect(dataCols.count == 13)
        #expect(dataCols[12] == "observed")
    }

    @Test("CSV export with semicolon-separated tags")
    func testCSVTags() {
        let segments = [
            makeSegment(startTsUs: 0, endTsUs: 3600_000000, tags: ["billable", "meeting", "client"]),
        ]

        let csv = CSVExporter.export(segments: segments, identity: testIdentity, includeTitles: true, tzOffsetSeconds: 0)
        #expect(csv.contains("billable;meeting;client"))
    }

    @Test("CSV export with null window title as empty string")
    func testCSVNullTitle() {
        let segments = [
            makeSegment(startTsUs: 0, endTsUs: 3600_000000, title: nil),
        ]

        let csv = CSVExporter.export(segments: segments, identity: testIdentity, includeTitles: true, tzOffsetSeconds: 0)
        let lines = csv.split(separator: "\n")
        let dataCols = lines[1].split(separator: ",", omittingEmptySubsequences: false)
        // window_title is column 10 (0-indexed)
        #expect(dataCols[10] == "")
    }

    @Test("CSV export deterministic ordering by start time")
    func testCSVOrdering() {
        // Create segments out of order
        let segments = [
            makeSegment(startTsUs: 200_000000, endTsUs: 300_000000, bundleId: "com.app2"),
            makeSegment(startTsUs: 0, endTsUs: 100_000000, bundleId: "com.app1"),
            makeSegment(startTsUs: 100_000000, endTsUs: 200_000000, bundleId: "com.app3"),
        ]

        let csv = CSVExporter.export(segments: segments, identity: testIdentity, includeTitles: true, tzOffsetSeconds: 0)
        let lines = csv.split(separator: "\n")

        // Should be sorted by start time
        #expect(lines[1].contains("com.app1"))
        #expect(lines[2].contains("com.app3"))
        #expect(lines[3].contains("com.app2"))
    }

    // MARK: - Fixture 7: JSON export structure

    @Test("JSON export has required structure")
    func testJSONStructure() {
        let segments = [
            makeSegment(
                startTsUs: 1738800000_000000,
                endTsUs: 1738803600_000000,
                bundleId: "com.apple.Safari",
                appName: "Safari",
                tags: ["work"],
                coverage: .observed
            ),
        ]

        let json = JSONExporter.export(
            segments: segments,
            identity: testIdentity,
            range: (startUs: 1738800000_000000, endUs: 1738803600_000000),
            includeTitles: true
        )

        // Parse JSON
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            Issue.record("Failed to parse JSON")
            return
        }

        // Check required top-level keys
        #expect(root["identity"] != nil)
        #expect(root["exported_at_utc"] != nil)
        #expect(root["range"] != nil)
        #expect(root["segments"] != nil)

        // Check identity structure
        let identity = root["identity"] as? [String: Any]
        #expect(identity?["machine_id"] as? String == "test-machine")
        #expect(identity?["username"] as? String == "testuser")
        #expect(identity?["uid"] as? Int == 501)

        // Check range structure
        let range = root["range"] as? [String: Any]
        #expect(range?["start_utc"] != nil)
        #expect(range?["end_utc"] != nil)

        // Check segments array
        let segmentsArray = root["segments"] as? [[String: Any]]
        #expect(segmentsArray?.count == 1)
        #expect(segmentsArray?[0]["coverage"] as? String == "observed")
        #expect(segmentsArray?[0]["app_bundle_id"] as? String == "com.apple.Safari")
    }
}

