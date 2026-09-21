import AppKit
import Foundation

/// Runs the bundled installer. The Python script is the single implementation
/// of the merge logic, shared between `make install-hooks` and the app's
/// "Reinstall hooks" menu item, so the two can never drift apart.
enum HookInstaller {
    /// True when our handlers are present in the user's settings.
    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: Paths.claudeSettings),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains("claude-watch-status.sh")
    }

    /// The exact JSON the installer will merge, for showing before the write
    /// and as the manual fallback if the write fails.
    static func configPreview() -> String {
        run(["print"]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    static func install() -> Bool {
        if case .success = installDetailed() { return true }
        return false
    }

    /// Install, returning the installer's own explanation on failure — the
    /// message the Python script printed, not a generic "could not install".
    static func installDetailed() -> Result<Void, InstallError> {
        let result = run([])
        if result.status == 0 && isInstalled { return .success(()) }
        let reason = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failure(InstallError(reason: reason.isEmpty ? result.fallbackReason : reason))
    }

    struct InstallError: Error, Equatable {
        let reason: String
    }

    private struct RunResult {
        var status: Int32 = -1
        var stdout = ""
        var stderr = ""
        var fallbackReason = "The installer could not be run."
    }

    private static func run(_ arguments: [String]) -> RunResult {
        var result = RunResult()
        guard let script = Bundle.main.url(forResource: "install-hooks", withExtension: "py") else {
            result.fallbackReason = "The installer script is missing from the app bundle."
            return result
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", script.path] + arguments
        // The installer resolves the status script relative to its own parent
        // directory, which inside the bundle is Resources/. Both files ship
        // side by side there, so the layout it expects holds.
        process.currentDirectoryURL = script.deletingLastPathComponent()
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do {
            try process.run()
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            let errData = err.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            result.status = process.terminationStatus
            result.stdout = String(decoding: outData, as: UTF8.self)
            result.stderr = String(decoding: errData, as: UTF8.self)
            if result.status != 0 && result.stderr.isEmpty {
                result.fallbackReason = "The installer exited with status \(result.status)."
            }
        } catch {
            result.fallbackReason = "python3 could not be launched: \(error.localizedDescription)"
        }
        return result
    }

    /// Reveal the settings file for anyone who wants to see what changed.
    static func openSettingsFile() {
        NSWorkspace.shared.open(Paths.claudeSettings)
    }
}
