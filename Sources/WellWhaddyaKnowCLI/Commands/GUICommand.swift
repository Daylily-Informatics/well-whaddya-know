// SPDX-License-Identifier: MIT
// GUICommand.swift - wwk gui subcommand to launch WellWhaddyaKnow.app

import ArgumentParser
import Foundation

/// Launch the WellWhaddyaKnow GUI application.
struct GUI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "gui",
        abstract: "Launch the WellWhaddyaKnow menu bar app"
    )

    @Option(name: .long, help: "Path to WellWhaddyaKnow.app (auto-detected if omitted)")
    var appPath: String?

    func run() throws {
        let appBundle: String
        if let explicit = appPath {
            appBundle = explicit
        } else if let found = findAppBundle() {
            appBundle = found
        } else {
            throw CleanExit.message(
                """
                Could not locate WellWhaddyaKnow.app.

                If installed via Homebrew:
                  open "$(brew --prefix)/opt/wwk/WellWhaddyaKnow.app"

                Or specify the path explicitly:
                  wwk gui --app-path /path/to/WellWhaddyaKnow.app
                """
            )
        }

        guard FileManager.default.fileExists(atPath: appBundle) else {
            throw CleanExit.message("App bundle not found at: \(appBundle)")
        }

        // Use /usr/bin/open which handles .app bundles correctly
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", appBundle]
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            throw CleanExit.message(
                "Failed to open WellWhaddyaKnow.app (exit code \(process.terminationStatus))"
            )
        }
    }
}

// MARK: - App Bundle Discovery

/// Search for WellWhaddyaKnow.app in known locations.
private func findAppBundle() -> String? {
    // 1. Sibling to wwk binary (Homebrew Cellar layout)
    let selfPath = CommandLine.arguments[0]
    let selfDir = (selfPath as NSString).deletingLastPathComponent
    // Homebrew installs wwk to bin/ and .app to the prefix root:
    //   /opt/homebrew/Cellar/wwk/<ver>/bin/wwk
    //   /opt/homebrew/Cellar/wwk/<ver>/WellWhaddyaKnow.app
    let cellarApp = ((selfDir as NSString).deletingLastPathComponent as NSString)
        .appendingPathComponent("WellWhaddyaKnow.app")
    if isAppBundle(cellarApp) { return cellarApp }

    // 2. Homebrew opt symlink (stable path)
    for prefix in ["/opt/homebrew", "/usr/local"] {
        let optApp = "\(prefix)/opt/wwk/WellWhaddyaKnow.app"
        if isAppBundle(optApp) { return optApp }
    }

    // 3. ~/Applications (user install)
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let userApp = "\(home)/Applications/WellWhaddyaKnow.app"
    if isAppBundle(userApp) { return userApp }

    // 4. /Applications (system-wide)
    let sysApp = "/Applications/WellWhaddyaKnow.app"
    if isAppBundle(sysApp) { return sysApp }

    // 5. Development builds (relative to project root)
    for config in ["release", "debug"] {
        let devApp = ".build/\(config)/WellWhaddyaKnow.app"
        if isAppBundle(devApp) { return devApp }
    }

    return nil
}

/// Check if a path looks like a valid .app bundle (has Contents/MacOS/).
private func isAppBundle(_ path: String) -> Bool {
    var isDir: ObjCBool = false
    let macosDir = (path as NSString).appendingPathComponent("Contents/MacOS")
    return FileManager.default.fileExists(atPath: macosDir, isDirectory: &isDir)
        && isDir.boolValue
}

