// SPDX-License-Identifier: MIT
// AgentCommand.swift - wwk agent subcommands for launchd-based agent management

import ArgumentParser
import Foundation

/// Agent command group - manage the wwkd background agent via launchd
struct Agent: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage the wwkd background agent",
        subcommands: [
            AgentInstall.self,
            AgentUninstall.self,
            AgentStart.self,
            AgentStop.self,
            AgentStatus.self,
        ],
        defaultSubcommand: AgentStatus.self
    )
}

// MARK: - Constants

private let launchdLabel = "com.daylily.wellwhaddyaknow.agent"

private var launchAgentDir: String {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents")
        .path
}

private var plistPath: String {
    "\(launchAgentDir)/\(launchdLabel).plist"
}

// MARK: - Helpers

/// Locate the wwkd binary: same dir as wwk → Homebrew paths → PATH
private func findWwkdPath() -> String? {
    let selfPath = CommandLine.arguments[0]
    let selfDir = (selfPath as NSString).deletingLastPathComponent
    let siblingPath = "\(selfDir)/wwkd"
    if FileManager.default.isExecutableFile(atPath: siblingPath) {
        return siblingPath
    }
    for candidate in ["/opt/homebrew/bin/wwkd", "/usr/local/bin/wwkd"] {
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
        for dir in pathEnv.split(separator: ":") {
            let candidate = "\(dir)/wwkd"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
    }
    return nil
}

/// Generate the launchd plist XML for standalone wwkd
private func generatePlistContent(wwkdPath: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" \
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Label</key>
        <string>\(launchdLabel)</string>
        <key>Program</key>
        <string>\(wwkdPath)</string>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <dict>
            <key>SuccessfulExit</key>
            <false/>
        </dict>
        <key>StandardOutPath</key>
        <string>/tmp/\(launchdLabel).stdout.log</string>
        <key>StandardErrorPath</key>
        <string>/tmp/\(launchdLabel).stderr.log</string>
        <key>ProcessType</key>
        <string>Background</string>
    </dict>
    </plist>
    """
}

/// Run a shell command and return (exitCode, stdout, stderr)
@discardableResult
private func shell(_ args: [String]) -> (Int32, String, String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = args
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe
    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (1, "", error.localizedDescription)
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    return (
        process.terminationStatus,
        String(data: outData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    )
}

// MARK: - Install

/// Install a launchd plist so wwkd starts at login
struct AgentInstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install",
        abstract: "Install wwkd as a login item (launchd)"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        guard let wwkdPath = findWwkdPath() else {
            printError("Cannot find wwkd binary. Is it installed?")
            throw ExitCode.generalError
        }
        try FileManager.default.createDirectory(
            atPath: launchAgentDir, withIntermediateDirectories: true
        )

        // Bootout any existing registration for the label — this clears both:
        //   1. A previously CLI-installed plist (bootout by plist path)
        //   2. An SMAppService-managed registration (bootout by label)
        // Either or both may exist; errors are non-fatal.
        if FileManager.default.fileExists(atPath: plistPath) {
            shell(["launchctl", "bootout", "gui/\(getuid())", plistPath])
        }
        // Also bootout by label to clear SMAppService-managed registration
        // that doesn't have a plist file in ~/Library/LaunchAgents/
        shell(["launchctl", "bootout", "gui/\(getuid())/\(launchdLabel)"])

        let content = generatePlistContent(wwkdPath: wwkdPath)
        try content.write(toFile: plistPath, atomically: true, encoding: .utf8)
        let (code, _, err) = shell(["launchctl", "bootstrap", "gui/\(getuid())", plistPath])
        if options.json {
            let result: [String: Any] = [
                "action": "install", "plist": plistPath,
                "wwkd": wwkdPath, "loaded": code == 0,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) { print(json) }
        } else {
            print("✓ Installed launchd plist: \(plistPath)")
            print("  Agent binary: \(wwkdPath)")
            if code == 0 {
                print("✓ Agent loaded and running")
            } else {
                printError("launchctl bootstrap returned \(code): \(err)")
            }
        }
    }
}

// MARK: - Uninstall

/// Remove the launchd plist and stop the agent
struct AgentUninstall: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "uninstall",
        abstract: "Remove wwkd login item and stop agent"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        var wasLoaded = false
        if FileManager.default.fileExists(atPath: plistPath) {
            let (code, _, _) = shell(["launchctl", "bootout", "gui/\(getuid())", plistPath])
            wasLoaded = (code == 0)
            try FileManager.default.removeItem(atPath: plistPath)
        }
        if options.json {
            let result: [String: Any] = [
                "action": "uninstall",
                "plist_removed": !FileManager.default.fileExists(atPath: plistPath),
                "was_loaded": wasLoaded,
            ]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) { print(json) }
        } else {
            if wasLoaded { print("✓ Agent stopped") }
            print("✓ Removed launchd plist: \(plistPath)")
        }
    }
}

// MARK: - Start

/// Start the agent via launchctl (plist must be installed)
struct AgentStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the wwkd agent"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        guard FileManager.default.fileExists(atPath: plistPath) else {
            printError("Agent not installed. Run: wwk agent install")
            throw ExitCode.generalError
        }
        let (code, _, err) = shell(["launchctl", "kickstart", "-k", "gui/\(getuid())/\(launchdLabel)"])
        if options.json {
            let result: [String: Any] = ["action": "start", "success": code == 0]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) { print(json) }
        } else {
            if code == 0 { print("✓ Agent started") }
            else { printError("launchctl kickstart returned \(code): \(err)") }
        }
    }
}

// MARK: - Stop

/// Stop the agent via launchctl
struct AgentStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the wwkd agent"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        let (code, _, err) = shell(["launchctl", "kill", "SIGTERM", "gui/\(getuid())/\(launchdLabel)"])
        if options.json {
            let result: [String: Any] = ["action": "stop", "success": code == 0]
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) { print(json) }
        } else {
            if code == 0 { print("✓ Agent stopped") }
            else { printError("launchctl kill returned \(code): \(err)") }
        }
    }
}

// MARK: - Status

/// Show agent status: launchd registration + IPC socket + process check
struct AgentStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show wwkd agent status"
    )

    @OptionGroup var options: GlobalOptions

    mutating func run() async throws {
        let plistInstalled = FileManager.default.fileExists(atPath: plistPath)

        // Check launchd service status
        let (listCode, listOut, _) = shell(["launchctl", "list", launchdLabel])
        let launchdLoaded = (listCode == 0)

        // Check IPC socket
        let socketPath = getIPCSocketPath()
        let socketExists = FileManager.default.fileExists(atPath: socketPath)

        // Check process
        let (pgrepCode, pgrepOut, _) = shell(["pgrep", "-x", "wwkd"])
        let pid = pgrepCode == 0 ? pgrepOut : nil

        if options.json {
            var result: [String: Any] = [
                "plist_installed": plistInstalled,
                "launchd_loaded": launchdLoaded,
                "socket_exists": socketExists,
                "running": pid != nil,
            ]
            if let p = pid { result["pid"] = p }
            result["plist_path"] = plistPath
            result["socket_path"] = socketPath
            if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]),
               let json = String(data: data, encoding: .utf8) { print(json) }
        } else {
            print("Agent Status:")
            print("  Plist installed: \(plistInstalled ? "✓" : "✗") (\(plistPath))")
            print("  launchd loaded:  \(launchdLoaded ? "✓" : "✗")")
            print("  Process running: \(pid != nil ? "✓ PID \(pid!)" : "✗")")
            print("  IPC socket:      \(socketExists ? "✓" : "✗") (\(socketPath))")
            if !plistInstalled {
                print("\n  Run: wwk agent install")
            }
            if launchdLoaded && !listOut.isEmpty {
                // Parse PID from launchctl list output
                let lines = listOut.split(separator: "\n")
                for line in lines where line.contains("PID") || line.contains("pid") {
                    print("  launchd info: \(line)")
                }
            }
        }
    }

    /// Get the IPC socket path (mirrors XPCProtocol.getIPCSocketPath)
    private func getIPCSocketPath() -> String {
        let appGroupId = "group.com.daylily.wellwhaddyaknow"
        if let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupId
        ) {
            return containerURL.appendingPathComponent("wwk.sock").path
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(appGroupId)
            .appendingPathComponent("wwk.sock")
            .path
    }
}

