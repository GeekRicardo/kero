//
//  KeroClaudeIntegration.swift
//  kero
//

import Foundation

/// Claude Code's lifecycle hooks and Kero's `/rename` command.
///
/// The other providers Kero integrates with read a drop-in file, so
/// `KeroAgentIntegrations` can manage them as a symlink into the app bundle.
/// Claude Code has no hooks directory: its hooks live inside the user's
/// `~/.claude/settings.json`, alongside settings Kero has no business
/// touching. So this one merges — it adds and removes only entries carrying
/// Kero's marker, and refuses to write at all if it cannot first parse what is
/// already there.
///
/// What the hooks buy: authoritative turn boundaries for Claude Code (rather
/// than Kero's debounced screen classifier), and the conversation id that makes
/// resuming a pane after a relaunch possible at all.
enum KeroClaudeIntegration {
    static let marker = "KERO_INTEGRATION_ID=claude"

    /// Phase names the bundled hooks pass to `kero +agent _integration claude`.
    enum Event: String, CaseIterable {
        /// A new conversation; carries the id Kero stores for resuming.
        case sessionStart = "SessionStart"
        case userPromptSubmit = "UserPromptSubmit"
        case stop = "Stop"
        case notification = "Notification"
        /// The conversation is over — drop the record rather than let a
        /// relaunch reopen something the user deliberately closed.
        case sessionEnd = "SessionEnd"

        var phase: String {
            switch self {
            case .sessionStart: "session"
            case .userPromptSubmit: "working"
            case .stop: "idle"
            case .notification: "blocked"
            case .sessionEnd: "ended"
            }
        }

        var command: String {
            // Silent no-ops outside Kero, and outside a Kero build that still
            // has this CLI, so a stale hook can never break the user's agent.
            "[ \"$KERO_AUTOMATION\" = \"1\" ] || exit 0; "
                + "command -v kero >/dev/null 2>&1 || exit 0; "
                + "exec kero +agent _integration claude \(phase) # \(marker)"
        }
    }

    enum IntegrationError: Error, LocalizedError, CustomStringConvertible {
        case message(String)

        var description: String {
            switch self {
            case .message(let message): message
            }
        }

        var errorDescription: String? { description }
    }

    private static let timeoutSeconds = 5

    static func configurationRoot(homeURL: URL) -> URL {
        homeURL.appendingPathComponent(".claude", isDirectory: true)
    }

    private static func settingsURL(homeURL: URL) -> URL {
        configurationRoot(homeURL: homeURL)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    private static func renameCommandURL(homeURL: URL) -> URL {
        configurationRoot(homeURL: homeURL)
            .appendingPathComponent("commands/rename.md", isDirectory: false)
    }

    // MARK: - Install

    /// Checks everything that could fail before anything is written. Claude
    /// Code not being installed is not a failure: enabling AI must never
    /// create provider configuration for a provider the user does not use.
    static func preflightInstall(
        bundle: Bundle = .main,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard isDirectory(configurationRoot(homeURL: homeURL)) else { return }
        _ = try loadSettings(homeURL: homeURL)
        _ = try renameCommandSource(bundle: bundle)

        let command = renameCommandURL(homeURL: homeURL)
        if itemType(at: command) != nil, !isManagedRenameCommand(command) {
            throw IntegrationError.message(
                "\(command.path) already exists and is not managed by Kero. "
                    + "Rename or remove it, then enable AI again."
            )
        }
    }

    static func install(
        bundle: Bundle = .main,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard isDirectory(configurationRoot(homeURL: homeURL)) else { return }
        try preflightInstall(bundle: bundle, homeURL: homeURL)

        var settings = try loadSettings(homeURL: homeURL)
        var hooks = (settings["hooks"] as? [String: Any]) ?? [:]
        for event in Event.allCases {
            var groups = strippingKeroEntries(from: hooks[event.rawValue])
            let entry: [String: Any] = [
                "type": "command",
                "command": event.command,
                "timeout": timeoutSeconds,
            ]
            let group: [String: Any] = ["hooks": [entry]]
            groups.append(group)
            hooks[event.rawValue] = groups
        }
        settings["hooks"] = hooks
        try writeSettings(settings, homeURL: homeURL)
        try linkRenameCommand(bundle: bundle, homeURL: homeURL)
    }

    // MARK: - Uninstall

    static func preflightUninstall(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard isDirectory(configurationRoot(homeURL: homeURL)) else { return }
        _ = try loadSettings(homeURL: homeURL)

        let command = renameCommandURL(homeURL: homeURL)
        if itemType(at: command) != nil, !isManagedRenameCommand(command) {
            throw IntegrationError.message(
                "\(command.path) is not managed by Kero, so Kero will not remove it."
            )
        }
    }

    static func uninstall(
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws {
        guard isDirectory(configurationRoot(homeURL: homeURL)) else { return }
        try preflightUninstall(homeURL: homeURL)

        var settings = try loadSettings(homeURL: homeURL)
        if var hooks = settings["hooks"] as? [String: Any] {
            for event in Event.allCases {
                guard hooks[event.rawValue] != nil else { continue }
                let groups = strippingKeroEntries(from: hooks[event.rawValue])
                // Leave the file the way Kero found it: an event Kero emptied
                // should not linger as `"Stop": []`.
                if groups.isEmpty {
                    hooks.removeValue(forKey: event.rawValue)
                } else {
                    hooks[event.rawValue] = groups
                }
            }
            if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
            try writeSettings(settings, homeURL: homeURL)
        }

        let command = renameCommandURL(homeURL: homeURL)
        if itemType(at: command) != nil {
            try FileManager.default.removeItem(at: command)
        }
    }

    // MARK: - settings.json

    private static func loadSettings(homeURL: URL) throws -> [String: Any] {
        let url = settingsURL(homeURL: homeURL)
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any] else {
            throw IntegrationError.message(
                "\(url.path) is not a JSON object Kero can safely edit. "
                    + "Fix or move it, then try again."
            )
        }
        return settings
    }

    private static func writeSettings(
        _ settings: [String: Any],
        homeURL: URL
    ) throws {
        let url = settingsURL(homeURL: homeURL)
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path
        )
    }

    /// Drops every hook group Kero owns, leaving the user's own untouched.
    /// A group is Kero's when any command inside it carries the marker; such a
    /// group is always one Kero wrote, because Kero writes a group per hook.
    private static func strippingKeroEntries(from value: Any?) -> [[String: Any]] {
        guard let groups = value as? [[String: Any]] else { return [] }
        return groups.filter { group in
            guard let entries = group["hooks"] as? [[String: Any]] else { return true }
            return !entries.contains { entry in
                (entry["command"] as? String)?.contains(marker) == true
            }
        }
    }

    // MARK: - /rename

    private static func renameCommandSource(bundle: Bundle) throws -> URL {
        for directory in ["AgentIntegrations/claude", "claude", nil] {
            guard let url = bundle.url(
                forResource: "rename",
                withExtension: "md",
                subdirectory: directory
            ), let text = try? String(contentsOf: url, encoding: .utf8),
               text.contains(marker) else { continue }
            return url.standardizedFileURL
        }
        throw IntegrationError.message(
            "Kero's bundled Claude Code /rename command is missing."
        )
    }

    private static func linkRenameCommand(bundle: Bundle, homeURL: URL) throws {
        let source = try renameCommandSource(bundle: bundle)
        let destination = renameCommandURL(homeURL: homeURL)
        if let target = symbolicLinkTarget(at: destination),
           target.standardizedFileURL.path == source.path {
            return
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        if itemType(at: destination) != nil {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.createSymbolicLink(
            atPath: destination.path,
            withDestinationPath: source.path
        )
    }

    private static func isManagedRenameCommand(_ url: URL) -> Bool {
        if let text = try? String(contentsOf: url, encoding: .utf8),
           text.contains(marker) {
            return true
        }
        // A moved app leaves the link dangling; recognize Kero's own resource
        // so launch reconciliation can repair it instead of refusing.
        guard itemType(at: url) == .typeSymbolicLink,
              let target = symbolicLinkTarget(at: url)
        else { return false }
        return target.lastPathComponent == "rename.md"
            && target.path.contains(".app/Contents/Resources/")
    }

    private static func symbolicLinkTarget(at url: URL) -> URL? {
        guard let path = try? FileManager.default.destinationOfSymbolicLink(
            atPath: url.path
        ) else { return nil }
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return url.deletingLastPathComponent().appendingPathComponent(path)
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(
            atPath: url.path, isDirectory: &isDirectory
        ) && isDirectory.boolValue
    }

    private static func itemType(at url: URL) -> FileAttributeType? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.type] as? FileAttributeType
    }
}
