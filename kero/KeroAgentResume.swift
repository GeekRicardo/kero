//
//  KeroAgentResume.swift
//  kero
//

import Foundation

/// Rebuilds the command that puts a coding agent back into the conversation a
/// pane was holding when Kero quit.
///
/// Restoring a terminal has always meant a fresh shell in the same directory.
/// For a pane that was mid-conversation with an agent that owns days of
/// context, that is the one thing the user does not want: the shell comes back
/// and the conversation does not. The agent's own resume flag fixes that, but
/// only if Kero knows which conversation — which is why this is written from a
/// provider lifecycle hook rather than guessed from the screen.
enum KeroAgentResume {
    /// Options worth carrying into the resumed session.
    ///
    /// An allowlist rather than "everything except `--resume`": the original
    /// argv can contain a prompt operand, a one-shot flag, or a path that would
    /// mean something different on the next launch. Permission mode and model
    /// are the choices a user would be annoyed to lose.
    private static let preservedFlags: Set<String> = [
        "--dangerously-skip-permissions",
        "--verbose",
        "--debug",
    ]

    private static let preservedFlagsWithValue: Set<String> = [
        "--permission-mode",
        "--model",
        "--settings",
        "--add-dir",
        "--mcp-config",
    ]

    /// `cd <directory> && claude <preserved flags> --resume <id>`.
    ///
    /// The `cd` is part of the command rather than the pane's restored working
    /// directory alone, because an agent that moved itself to another worktree
    /// must come back to the tree it was actually working in.
    static func claudeCommand(
        sessionID: String,
        directory: String,
        arguments: [String]
    ) -> String? {
        guard isSafeSessionID(sessionID), directory.hasPrefix("/") else { return nil }
        var parts = ["cd", shellQuote(directory), "&&", "claude"]
        parts.append(contentsOf: preserved(from: arguments).map(shellQuote))
        parts.append("--resume")
        parts.append(shellQuote(sessionID))
        return parts.joined(separator: " ")
    }

    /// A session id crosses a trust boundary — it arrives from a provider hook
    /// — and ends up inside a command line the shell will run.
    static func isSafeSessionID(_ value: String) -> Bool {
        guard (1...512).contains(value.utf8.count), !value.hasPrefix("-") else {
            return false
        }
        return value.unicodeScalars.allSatisfy {
            $0.value > 0x20 && $0.value != 0x7f && $0.value < 0x80
        }
    }

    private static func preserved(from arguments: [String]) -> [String] {
        var result: [String] = []
        var index = 1 // argv[0] is the executable.
        while index < arguments.count {
            let argument = arguments[index]
            if preservedFlags.contains(argument) {
                result.append(argument)
            } else if preservedFlagsWithValue.contains(argument),
                      index + 1 < arguments.count {
                result.append(argument)
                result.append(arguments[index + 1])
                index += 1
            } else if let separator = argument.firstIndex(of: "="),
                      preservedFlagsWithValue.contains(String(argument[..<separator])) {
                result.append(argument)
            }
            index += 1
        }
        return result
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

extension TerminalSession {
    /// The command that would restore this pane's agent conversation, or nil
    /// when there is nothing to restore.
    ///
    /// Deliberately narrow: the agent has to be the terminal's *live foreground
    /// process* right now. A conversation the user already exited is finished,
    /// and reviving it on the next launch would be Kero second-guessing them.
    var agentResumeCommand: String? {
        guard !hasExited,
              let sessionID = agentProviderSessionID,
              let foreground = surface.foregroundPid,
              foreground != shellPid,
              KeroAgentKind.recognize(processID: foreground) == .claude
        else { return nil }
        return KeroAgentResume.claudeCommand(
            sessionID: sessionID,
            directory: foregroundDirectoryPath ?? currentDirectoryPath,
            arguments: processArguments(pid: foreground) ?? []
        )
    }

    /// Replays a restored pane's resume command once its shell is ready.
    ///
    /// The shell is still being exec'd when a restored pane is built, and a
    /// restored pane may also be replaying scrollback, so this waits for the
    /// shell to actually be at a prompt instead of typing into a PTY that no
    /// one is reading yet.
    func scheduleAgentResume(_ command: String) {
        Task { @MainActor [weak self] in
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                guard let self, !self.hasExited else { return }
                if self.isShellAvailableForAutomation {
                    self.sendCommand(command + "\r")
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }
}
