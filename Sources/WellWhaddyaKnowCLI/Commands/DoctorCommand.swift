// SPDX-License-Identifier: MIT
// DoctorCommand.swift - wwk doctor command per SPEC.md Section 10.2

import ArgumentParser
import Foundation

/// Doctor command - check system health
struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check system health"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        var checks: [[String: Any]] = []
        var allPassed = true

        // Check 1: Database exists and is readable
        let path = options.db ?? getDefaultDatabasePath()
        var dbCheck: [String: Any] = ["check": "database"]

        dbCheck["path"] = path
        if FileManager.default.fileExists(atPath: path) {
            do {
                let reader = try DatabaseReader(path: path)
                let isValid = try reader.verifyIntegrity()
                if isValid {
                    dbCheck["status"] = "ok"
                    dbCheck["message"] = "Database exists and passes integrity check"
                } else {
                    dbCheck["status"] = "error"
                    dbCheck["message"] = "Database integrity check failed"
                    allPassed = false
                }
            } catch {
                dbCheck["status"] = "error"
                dbCheck["message"] = "Cannot open database: \(error.localizedDescription)"
                allPassed = false
            }
        } else {
            dbCheck["status"] = "warning"
            dbCheck["message"] = "Database file does not exist (may not be initialized yet)"
        }
        checks.append(dbCheck)

        // Check 2: Agent running (we can't easily check this without XPC)
        var agentCheck: [String: Any] = ["check": "agent"]
        agentCheck["status"] = "unknown"
        agentCheck["message"] = "Agent status check requires XPC connection (not implemented in CLI yet)"
        checks.append(agentCheck)

        // Check 3: Accessibility permissions
        var axCheck: [String: Any] = ["check": "accessibility"]
        axCheck["status"] = "unknown"
        axCheck["message"] = "Accessibility check requires agent query"
        checks.append(axCheck)

        // Output results
        if options.json {
            let output: [String: Any] = [
                "checks": checks,
                "all_passed": allPassed
            ]
            if let data = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } else {
            print("System Health Check")
            print("===================")
            print("")
            for check in checks {
                let name = check["check"] as? String ?? "unknown"
                let status = check["status"] as? String ?? "unknown"
                let message = check["message"] as? String ?? ""
                
                let icon: String
                switch status {
                case "ok": icon = "✓"
                case "warning": icon = "⚠"
                case "error": icon = "✗"
                default: icon = "?"
                }
                
                print("\(icon) \(name.capitalized): \(message)")
            }
            print("")
            if allPassed {
                print("All checks passed.")
            } else {
                print("Some checks failed. See above for details.")
            }
        }

        if !allPassed {
            throw ExitCode.generalError
        }
    }
}

