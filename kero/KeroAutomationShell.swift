//
//  KeroAutomationShell.swift
//  kero
//

import Foundation

/// Runs one command in an existing interactive shell and reports *that
/// command's* exit code.
///
/// The shell is a live session shared with the user, so there is no separate
/// process to wait on: the exit status has to come back through the same
/// terminal everything else does. The command line is instrumented with a
/// sentinel that prints `$?`, and the transcript is scanned for it.
///
/// Two rules make this usable by an agent rather than merely correct:
///
/// * it never blocks indefinitely — a command that goes quiet, or simply runs
///   long, is handed back as a background handle instead of holding the caller;
/// * a backgrounded command is still collectable, because the sentinel is
///   still coming. Only an interrupt destroys the exit code, which is why
///   interrupting and abandoning are the same operation.
@MainActor
final class KeroAutomationShellCommand {
    enum Status: String {
        case completed
        case running
        case abandoned
    }

    enum Reason: String {
        case requested
        case silent
        case timeout
    }

    struct Outcome {
        let status: Status
        let exitCode: Int?
        let command: String
        let lines: [String]
        let firstLine: Int
        let lastLine: Int
        let omitted: Int
        let backgroundedBecause: Reason?
        let hint: String?
    }

    enum Failure: Error {
        case busy(String)
        case notTracking
        case shellUnavailable
        case invalidCommand
    }

    private struct Pending {
        let token: String
        let command: String
        /// First line number that can belong to this command.
        let startLine: Int
        var echoLine: Int?
        var echoSeenAt: Date?

        /// Output starts after the echoed command line, when it has been seen.
        var outputStart: Int { echoLine.map { $0 + 1 } ?? startLine }
    }

    private static let maximumOutputLines = KeroAutomationDefaults.readLines

    private var pending: Pending?

    var isTracking: Bool { pending != nil }
    var trackedCommand: String? { pending?.command }

    // MARK: - Running

    func start(
        session: TerminalSession,
        command: String,
        background: Bool,
        silentMilliseconds: Int,
        timeoutMilliseconds: Int,
        replace: Bool
    ) async throws -> Outcome {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), !trimmed.contains("\r") else {
            throw Failure.invalidCommand
        }
        if let pending {
            guard replace else { throw Failure.busy(pending.command) }
            self.pending = nil
        }
        // A terminal created moments ago has not finished exec'ing its login
        // shell. That is a race, not a busy shell, so give it a moment before
        // refusing — otherwise `new` followed immediately by `exec` fails for
        // no reason a caller could act on.
        guard await waitForShell(session: session) else {
            throw Failure.shellUnavailable
        }

        KeroTranscriptRecorder.shared.activate(session)
        let token = Self.makeToken()
        pending = Pending(
            token: token,
            command: trimmed,
            startLine: session.transcript.nextLineNumber,
            echoLine: nil,
            echoSeenAt: nil
        )
        session.sendCommand(Self.instrumented(trimmed, token: token) + "\r")

        if background {
            return backgroundHandle(session: session, reason: .requested)
        }
        return await wait(
            session: session,
            silentMilliseconds: silentMilliseconds,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    /// Collects a backgrounded command, or releases one whose exit code can
    /// never arrive.
    func collect(
        session: TerminalSession,
        timeoutMilliseconds: Int,
        abandon: Bool,
        interrupt: Bool
    ) async throws -> Outcome {
        guard let current = pending else { throw Failure.notTracking }

        if interrupt {
            session.sendCommand("\u{03}")
            await settleAfterInterrupt(session: session)
            pending = nil
            return released(
                session: session,
                current: current,
                hint: "Interrupted. An interrupted command never prints the marker Kero waits for, so its exit code is gone for good; the shell is free for the next command."
            )
        }
        if abandon {
            pending = nil
            return released(
                session: session,
                current: current,
                hint: "Stopped tracking. The command may still be running; Kero is simply no longer waiting for its exit code."
            )
        }

        KeroTranscriptRecorder.shared.activate(session)
        return await wait(
            session: session,
            silentMilliseconds: 0,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    // MARK: - Waiting

    private func wait(
        session: TerminalSession,
        silentMilliseconds: Int,
        timeoutMilliseconds: Int
    ) async -> Outcome {
        let deadline = Date().addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        let silent = Double(silentMilliseconds) / 1_000

        while true {
            noteEcho(session: session)
            if let outcome = completedOutcome(session: session) { return outcome }
            if let outcome = sessionEndedOutcome(session: session) { return outcome }

            let now = Date()
            if silent > 0, let current = pending, let seen = current.echoSeenAt {
                // The shell echoes the command line immediately, so "printed
                // nothing" only counts from after that echo.
                let quietSince = max(seen, session.transcript.lastChange)
                if now.timeIntervalSince(quietSince) >= silent {
                    return backgroundHandle(session: session, reason: .silent)
                }
            }
            if now >= deadline {
                return backgroundHandle(session: session, reason: .timeout)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func waitForShell(session: TerminalSession) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while true {
            if session.isShellAvailableForAutomation { return true }
            if session.hasExited || Date() >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Waits for the shell to finish redrawing its prompt after Ctrl-C.
    /// Without this the next command's first character is swallowed mid-redraw.
    private func settleAfterInterrupt(session: TerminalSession) async {
        let deadline = Date().addingTimeInterval(2.5)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(120))
            KeroTranscriptRecorder.shared.sample(session)
            if Date().timeIntervalSince(session.transcript.lastChange) >= 0.3 { return }
        }
    }

    private func noteEcho(session: TerminalSession) {
        guard var current = pending, current.echoLine == nil else { return }
        let needle = Self.echoNeedle(token: current.token)
        guard let line = session.transcript.search(
            from: current.startLine, where: { $0.contains(needle) }
        ) else { return }
        current.echoLine = line
        current.echoSeenAt = Date()
        pending = current
    }

    private func completedOutcome(session: TerminalSession) -> Outcome? {
        guard let current = pending else { return nil }
        let sentinel = Self.sentinelPrefix(token: current.token)
        guard let line = session.transcript.search(
            from: current.outputStart, where: { $0.contains(sentinel) }
        ), let text = session.transcript.line(line) else { return nil }

        pending = nil
        let output = outputSlice(session: session, current: current, end: line - 1)
        return Outcome(
            status: .completed,
            exitCode: Self.exitCode(in: text, sentinel: sentinel),
            command: current.command,
            lines: output.lines,
            firstLine: output.firstLine,
            lastLine: output.lastLine,
            omitted: output.omitted,
            backgroundedBecause: nil,
            hint: output.omitted > 0
                ? "\(output.omitted) earlier lines were left out; read them by line number with `kero +term history`."
                : nil
        )
    }

    /// `exit`, or an ssh that dropped: the shell that would have printed the
    /// marker is gone, so report the terminal's own end rather than wait for a
    /// sentinel that can never arrive.
    private func sessionEndedOutcome(session: TerminalSession) -> Outcome? {
        guard session.hasExited, let current = pending else { return nil }
        pending = nil
        let output = outputSlice(
            session: session, current: current, end: session.transcript.lastLineNumber
        )
        return Outcome(
            status: .completed,
            exitCode: nil,
            command: current.command,
            lines: output.lines,
            firstLine: output.firstLine,
            lastLine: output.lastLine,
            omitted: output.omitted,
            backgroundedBecause: nil,
            hint: "The command ended the terminal session, so no exit code was reported."
        )
    }

    private func backgroundHandle(
        session: TerminalSession, reason: Reason
    ) -> Outcome {
        let current = pending
        return Outcome(
            status: .running,
            exitCode: nil,
            command: current?.command ?? "",
            lines: [],
            firstLine: current?.outputStart ?? session.transcript.nextLineNumber,
            lastLine: session.transcript.lastLineNumber,
            omitted: 0,
            backgroundedBecause: reason,
            hint: reason == .requested
                ? "Running in the background. Collect its exit code with `kero +term result`."
                : "Still running after its \(reason == .silent ? "silence" : "time") budget, so Kero handed it back instead of blocking. The exit code is not lost — collect it with `kero +term result`, watch progress with `kero +term history`, or stop it with `kero +term result --interrupt`."
        )
    }

    private func released(
        session: TerminalSession, current: Pending, hint: String
    ) -> Outcome {
        Outcome(
            status: .abandoned,
            exitCode: nil,
            command: current.command,
            lines: [],
            firstLine: current.outputStart,
            lastLine: session.transcript.lastLineNumber,
            omitted: 0,
            backgroundedBecause: nil,
            hint: hint
        )
    }

    private func outputSlice(
        session: TerminalSession, current: Pending, end: Int
    ) -> KeroTerminalTranscript.Slice {
        let start = current.outputStart
        guard end >= start else {
            return KeroTerminalTranscript.Slice(
                lines: [], firstLine: start, lastLine: end, omitted: 0
            )
        }
        return session.transcript.history(
            startLine: start, endLine: end, maxLines: Self.maximumOutputLines
        )
    }

    // MARK: - Sentinel

    private static func makeToken() -> String {
        String(
            UUID().uuidString
                .replacingOccurrences(of: "-", with: "")
                .prefix(16)
                .lowercased()
        )
    }

    /// The marker is assembled from two separately quoted pieces on purpose.
    /// The shell echoes the command line it was given, so a marker written as
    /// one literal would appear in that echo and be mistaken for the result.
    /// Split, the echo contains `'KERO' 'EXEC-…'` and only the printed output
    /// ever contains the joined string.
    private static func instrumented(_ command: String, token: String) -> String {
        "\(command); printf '\\n%s%s%d\\n' 'KERO' 'EXEC-\(token)-' $?"
    }

    private static func sentinelPrefix(token: String) -> String {
        "KEROEXEC-\(token)-"
    }

    private static func echoNeedle(token: String) -> String {
        "'EXEC-\(token)-'"
    }

    private static func exitCode(in line: String, sentinel: String) -> Int? {
        guard let range = line.range(of: sentinel) else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
