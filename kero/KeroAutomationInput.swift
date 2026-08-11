//
//  KeroAutomationInput.swift
//  kero
//

import Foundation

/// Budgets shared by the app-side implementation and the bundled CLI.
///
/// They live outside both so the CLI, which runs before AppKit exists and off
/// the main actor, can print and validate the same numbers the app enforces.
enum KeroAutomationDefaults {
    /// How long output must stop for an idle wait to resolve.
    static let idleMilliseconds = 500
    static let waitTimeoutMilliseconds = 30_000
    /// A command that has printed nothing for this long is handed back as a
    /// background handle: there is nothing to wait for, so waiting only costs.
    static let silentMilliseconds = 10_000
    /// A command that is still printing is kept in the foreground until here.
    static let execTimeoutMilliseconds = 60_000
    static let collectTimeoutMilliseconds = 120_000
    /// Cap on one incremental read. Anything beyond it is reported, not hidden.
    static let readLines = 500
    /// A history read with no arguments. Small enough to be always safe.
    static let historyLines = 100
}

/// Named keys an automation client can send to a terminal.
///
/// Raw text alone cannot answer a TUI prompt, interrupt a job, or walk shell
/// history, and asking a caller to spell out `\u{1b}[A` invites mistakes that
/// land in a shell the user shares. Names are the interface; the byte sequences
/// stay here.
enum KeroAutomationKey {
    /// The sequence `name` sends, or nil when the name is not a key.
    static func sequence(for name: String) -> String? {
        let key = name.lowercased().replacingOccurrences(of: "_", with: "-")
        if let simple = simpleKeys[key] { return simple }
        if key.hasPrefix("ctrl-"), key.count == 6,
           let scalar = key.unicodeScalars.last {
            // Ctrl-A…Ctrl-Z are 0x01…0x1a; the shell control characters agents
            // actually reach for (Ctrl-C, Ctrl-D, Ctrl-Z, Ctrl-U) are in there.
            switch scalar.value {
            case 0x61...0x7a:
                return String(UnicodeScalar(scalar.value - 0x60)!)
            case 0x5b: return "\u{1b}"       // ctrl-[
            case 0x5c: return "\u{1c}"       // ctrl-\
            case 0x5d: return "\u{1d}"       // ctrl-]
            default: return nil
            }
        }
        if key.hasPrefix("f"), let number = Int(key.dropFirst()),
           (1...12).contains(number) {
            return functionKeys[number - 1]
        }
        return nil
    }

    static var names: [String] {
        simpleKeys.keys.sorted()
            + (1...12).map { "f\($0)" }
            + ["ctrl-a … ctrl-z"]
    }

    private static let simpleKeys: [String: String] = [
        "enter": "\r",
        "return": "\r",
        "newline": "\n",
        "tab": "\t",
        "backtab": "\u{1b}[Z",
        "esc": "\u{1b}",
        "escape": "\u{1b}",
        "space": " ",
        "backspace": "\u{7f}",
        "delete": "\u{1b}[3~",
        "up": "\u{1b}[A",
        "down": "\u{1b}[B",
        "right": "\u{1b}[C",
        "left": "\u{1b}[D",
        "home": "\u{1b}[H",
        "end": "\u{1b}[F",
        "pageup": "\u{1b}[5~",
        "pagedown": "\u{1b}[6~",
        "insert": "\u{1b}[2~",
    ]

    private static let functionKeys = [
        "\u{1b}OP", "\u{1b}OQ", "\u{1b}OR", "\u{1b}OS",
        "\u{1b}[15~", "\u{1b}[17~", "\u{1b}[18~", "\u{1b}[19~",
        "\u{1b}[20~", "\u{1b}[21~", "\u{1b}[23~", "\u{1b}[24~",
    ]
}

/// Why a wait stopped. A wait always returns one of these; a timeout is an
/// outcome, not an error, and the terminal keeps running either way.
enum KeroAutomationWaitReason: String {
    case idle
    case match
    case exit
    case timeout
}

/// The wait primitive behind `kero +term wait`.
///
/// Guessing a delay after sending input is the main source of flaky terminal
/// automation: too short reads half a screen, too long makes everything crawl.
/// This replaces the guess with a condition, and always says which condition
/// ended the wait.
@MainActor
enum KeroAutomationWait {
    struct Outcome {
        let reason: KeroAutomationWaitReason
        let matchedLine: Int?
        let matchedText: String?
    }

    static func run(
        session: TerminalSession,
        idleMilliseconds: Int?,
        pattern: NSRegularExpression?,
        waitForExit: Bool,
        timeoutMilliseconds: Int,
        fromLine: Int
    ) async -> Outcome {
        KeroTranscriptRecorder.shared.activate(session)
        let started = Date()
        let deadline = started.addingTimeInterval(Double(timeoutMilliseconds) / 1_000)
        let idle = idleMilliseconds.map { Double($0) / 1_000 }
        var searchFrom = fromLine

        while true {
            if let pattern {
                let transcript = session.transcript
                while searchFrom <= transcript.lastLineNumber {
                    if let text = transcript.line(searchFrom),
                       matches(pattern, text) {
                        return Outcome(
                            reason: .match, matchedLine: searchFrom, matchedText: text
                        )
                    }
                    searchFrom += 1
                }
            }
            if session.hasExited {
                return Outcome(reason: .exit, matchedLine: nil, matchedText: nil)
            }

            let now = Date()
            if let idle, !waitForExit {
                // Measured from the later of the last output and the start of
                // the wait, so a terminal that is already quiet still gets the
                // full idle window — that window is what absorbs the round trip
                // between sending input and the shell echoing it.
                let quietSince = max(session.transcript.lastChange, started)
                if now.timeIntervalSince(quietSince) >= idle {
                    return Outcome(reason: .idle, matchedLine: nil, matchedText: nil)
                }
            }
            if now >= deadline {
                return Outcome(reason: .timeout, matchedLine: nil, matchedText: nil)
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(
            in: text,
            options: [],
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        ) != nil
    }
}
