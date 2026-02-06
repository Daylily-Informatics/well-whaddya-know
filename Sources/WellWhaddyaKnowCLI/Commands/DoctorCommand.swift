// SPDX-License-Identifier: MIT
// DoctorCommand.swift - wwk doctor command per SPEC.md Section 10.2

import ArgumentParser
import Foundation
import XPCProtocol

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

        // Check 2: Agent running via IPC socket
        var agentCheck: [String: Any] = ["check": "agent"]
        var axCheck: [String: Any] = ["check": "accessibility"]

        let ipcClient = CLIIPCClient()
        if !ipcClient.isAgentAvailable {
            agentCheck["status"] = "warning"
            agentCheck["message"] = "Agent not running (socket not found)"
            allPassed = false
            axCheck["status"] = "unknown"
            axCheck["message"] = "Cannot check accessibility — agent not running"
        } else {
            do {
                let status = try await ipcClient.getStatus()
                agentCheck["status"] = "ok"
                agentCheck["message"] = "Agent is running (v\(status.agentVersion), uptime \(Int(status.agentUptime))s)"

                // Check 3: Accessibility permissions from agent status
                switch status.accessibilityStatus {
                case .granted:
                    axCheck["status"] = "ok"
                    axCheck["message"] = "Accessibility permission granted"
                case .denied:
                    axCheck["status"] = "warning"
                    axCheck["message"] = "Accessibility permission denied — window titles will not be captured"
                    allPassed = false
                case .unknown:
                    axCheck["status"] = "unknown"
                    axCheck["message"] = "Accessibility permission status unknown"
                }
            } catch {
                agentCheck["status"] = "warning"
                agentCheck["message"] = "Agent not responding (\(error.localizedDescription))"
                allPassed = false
                axCheck["status"] = "unknown"
                axCheck["message"] = "Cannot check accessibility — agent not responding"
            }
        }
        checks.append(agentCheck)
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

