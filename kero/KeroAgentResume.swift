//
//  KeroAgentResume.swift
//  kero
//

import Darwin
import Foundation

/// What a terminal needs to reopen the agent conversation it was holding.
///
/// Written when the provider says a conversation started, refreshed on every
/// later event, and cleared when the provider says it ended. Deliberately not
/// derived from what the terminal looked like at quit: the foreground process
/// at that instant may be a child the agent spawned, and a conversation worth
/// days of context is not something to lose to a sampling accident.
struct KeroAgentResumeRecord {
    let kind: KeroAgentKind
    /// The provider's own conversation id.
    let sessionID: String
    /// Where the conversation is working, as the provider reports it — an
    /// agent that moved itself to another worktree must come back to that one.
    let directory: String
    /// The agent process as last observed. Only used to tell a conversation
    /// that is still open from one the user has already left.
    let processID: pid_t?
    let updatedAt: Date
}

/// Rebuilds the command that puts a coding agent back into a recorded
/// conversation.
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
    static func command(for record: KeroAgentResumeRecord) -> String? {
        guard record.kind == .claude,
              isSafeSessionID(record.sessionID),
              record.directory.hasPrefix("/")
        else { return nil }
        let arguments = record.processID.flatMap { processArguments(pid: $0) } ?? []
        var parts = ["cd", shellQuote(record.directory), "&&", record.kind.executable]
        parts.append(contentsOf: preserved(from: arguments).map(shellQuote))
        parts.append("--resume")
        parts.append(shellQuote(record.sessionID))
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

    static func isSafeDirectory(_ value: String) -> Bool {
        guard value.hasPrefix("/"), value.utf8.count <= 4_096 else { return false }
        return value.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value)
        }
    }

    /// Whether the recorded conversation is still open.
    ///
    /// `SessionEnd` clears the record for every ordinary exit, so this only
    /// covers the cases where no event could be delivered — the agent was
    /// killed, or the machine went down. Liveness, not foreground: an agent
    /// running a tool is still mid-conversation.
    static func isLive(_ record: KeroAgentResumeRecord) -> Bool {
        guard let processID = record.processID, processID > 1 else { return false }
        guard Darwin.kill(processID, 0) == 0 || errno == EPERM else { return false }
        // A pid can be reused; requiring the reused one to also be this agent
        // keeps a recycled pid from resurrecting a finished conversation.
        return KeroAgentKind.recognize(processID: processID) == record.kind
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
    /// Records or refreshes the conversation running in this terminal.
    ///
    /// Every provider event carries the conversation id, so this runs
    /// repeatedly across a conversation's life. That is what keeps the working
    /// directory current when an agent moves itself, and gives Kero repeated
    /// chances to observe the agent's own pid rather than depending on one
    /// lucky moment.
    func recordAgentSession(
        kind: KeroAgentKind,
        sessionID: String,
        directory: String?
    ) {
        let observed = surface.foregroundPid.flatMap { pid -> pid_t? in
            KeroAgentKind.recognize(processID: pid) == kind ? pid : nil
        }
        let resolved = directory.flatMap {
            KeroAgentResume.isSafeDirectory($0) ? $0 : nil
        }
        agentResumeRecord = KeroAgentResumeRecord(
            kind: kind,
            sessionID: sessionID,
            // Keep the last known good values when this event carries neither:
            // a hook that omits `cwd` must not downgrade the record.
            directory: resolved
                ?? agentResumeRecord?.directory
                ?? currentDirectoryPath,
            processID: observed ?? agentResumeRecord?.processID,
            updatedAt: Date()
        )
    }

    /// The provider says the conversation ended. There is nothing to resume,
    /// and leaving the record would reopen a conversation the user closed.
    func clearAgentSession(kind: KeroAgentKind) {
        guard agentResumeRecord?.kind == kind else { return }
        agentResumeRecord = nil
    }

    /// The command that would restore this pane's agent conversation, or nil
    /// when there is nothing to restore.
    var agentResumeCommand: String? {
        guard !hasExited,
              let record = agentResumeRecord,
              KeroAgentResume.isLive(record)
        else { return nil }
        return KeroAgentResume.command(for: record)
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
