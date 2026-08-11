//
//  KeroTerminalTranscript.swift
//  kero
//

import Foundation

/// Plain-text normalization for every byte Kero hands to an automation client.
///
/// Kero reads a rendered grid rather than the raw PTY stream, so most escape
/// sequences are already resolved by the emulator. This still runs on every
/// automation read: a backend that hands back styled rows, an OSC a backend
/// chose to preserve, or a `\r`-overwritten row would otherwise reach an agent
/// as noise, and noise costs the caller context it cannot get back.
enum KeroTerminalText {
    /// Sanitized lines, with carriage-return overwrites applied per row and
    /// trailing whitespace trimmed. Trailing blank rows are dropped: a screen
    /// export pads the viewport, and those blanks are not output.
    static func lines(_ input: String) -> [String] {
        var result = strippingEscapes(input)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { applyCarriageReturns(String($0)) }
        while let last = result.last, last.isEmpty {
            result.removeLast()
        }
        return result
    }

    /// A row a program rewrote in place — a progress bar, a spinner — arrives
    /// as `10%\r20%\r30%`. The terminal shows only the final overwrite, so an
    /// automation read must too, and a shorter overwrite leaves the tail of the
    /// longer text behind exactly as the grid would.
    private static func applyCarriageReturns(_ line: String) -> String {
        guard line.contains("\r") else { return trimmingTrailingBlanks(line) }
        var row: [Character] = []
        var column = 0
        for character in line {
            if character == "\r" {
                column = 0
                continue
            }
            if column < row.count {
                row[column] = character
            } else {
                row.append(character)
            }
            column += 1
        }
        return trimmingTrailingBlanks(String(row))
    }

    private static func trimmingTrailingBlanks(_ line: String) -> String {
        var result = line
        while let last = result.last, last == " " || last == "\t" {
            result.removeLast()
        }
        return result
    }

    /// The branch order below is load-bearing. OSC, DCS, APC, and PM carry a
    /// payload terminated by ST, and their introducers are themselves ESC plus
    /// one character in the same range the generic two-character escape branch
    /// accepts. Testing the generic branch first consumes `ESC ]` alone and
    /// leaves the payload — for shell integration, several hundred characters
    /// of UUID — sitting in the text of every single read.
    private static func strippingEscapes(_ input: String) -> String {
        let scalars = Array(input.unicodeScalars)
        var output = String.UnicodeScalarView()
        output.reserveCapacity(scalars.count)
        var index = 0

        while index < scalars.count {
            let value = scalars[index].value

            if let end = payloadSequenceEnd(scalars, at: index) {
                index = end
                continue
            }
            if let end = controlSequenceEnd(scalars, at: index) {
                index = end
                continue
            }
            // Generic two-character escape (charset selection, RIS, DECSC…).
            if value == 0x1b, index + 1 < scalars.count,
               (0x20...0x7e).contains(scalars[index + 1].value) {
                index += 2
                continue
            }
            if value == 0x1b {
                index += 1
                continue
            }
            // Remaining C0/C1 controls carry no text. Tab, newline, and
            // carriage return survive; the caller resolves the last two.
            if value < 0x20 || (0x7f...0x9f).contains(value) {
                if value == 0x09 || value == 0x0a || value == 0x0d {
                    output.append(scalars[index])
                }
                index += 1
                continue
            }
            output.append(scalars[index])
            index += 1
        }
        return String(output)
    }

    /// OSC / DCS / APC / PM, in both their ESC-introduced and C1 forms, through
    /// BEL, ESC \\, or the C1 ST.
    private static func payloadSequenceEnd(
        _ scalars: [Unicode.Scalar], at index: Int
    ) -> Int? {
        let payloadStart: Int
        switch scalars[index].value {
        case 0x90, 0x9d, 0x9e, 0x9f:
            payloadStart = index + 1
        case 0x1b where index + 1 < scalars.count:
            switch scalars[index + 1].value {
            case 0x50, 0x5d, 0x5e, 0x5f: payloadStart = index + 2
            default: return nil
            }
        default:
            return nil
        }

        var cursor = payloadStart
        while cursor < scalars.count {
            switch scalars[cursor].value {
            case 0x07, 0x9c:
                return cursor + 1
            case 0x1b where cursor + 1 < scalars.count
                && scalars[cursor + 1].value == 0x5c:
                return cursor + 2
            default:
                cursor += 1
            }
        }
        // Unterminated payload: consume the rest rather than emit it.
        return scalars.count
    }

    private static func controlSequenceEnd(
        _ scalars: [Unicode.Scalar], at index: Int
    ) -> Int? {
        let parameterStart: Int
        if scalars[index].value == 0x9b {
            parameterStart = index + 1
        } else if scalars[index].value == 0x1b,
                  index + 1 < scalars.count,
                  scalars[index + 1].value == 0x5b {
            parameterStart = index + 2
        } else {
            return nil
        }

        var cursor = parameterStart
        while cursor < scalars.count {
            if (0x40...0x7e).contains(scalars[cursor].value) {
                return cursor + 1
            }
            cursor += 1
        }
        return scalars.count
    }
}

/// An append-only line log for one terminal, with absolute line numbers and
/// named cursors.
///
/// Kero's backends expose a rendered grid, not the PTY byte stream, so this is
/// built by repeatedly reading the bounded screen-plus-scrollback export and
/// splicing each snapshot onto what was already recorded. Line numbers stay
/// absolute and stable for the life of the session, which is what makes
/// `start_line`/`end_line` safe for a caller to compute once and reuse.
///
/// The cost of that design is honest and bounded: output that scrolls past a
/// whole snapshot between two samples is reported as a gap rather than silently
/// stitched into a plausible-looking transcript.
@MainActor
final class KeroTerminalTranscript {
    struct Slice {
        let lines: [String]
        let firstLine: Int
        let lastLine: Int
        /// Lines that existed but were left out of this response.
        let omitted: Int
    }

    /// How much recorded history one terminal keeps. Beyond this the oldest
    /// lines are dropped; their line numbers are never reused.
    private static let capacity = 20_000

    /// Rows requested from the backend per sample. Larger snapshots tolerate
    /// more output between samples before a gap is unavoidable.
    static let snapshotLines = 400
    static let snapshotColumns = 1_000

    private var lines: [String] = []
    /// Absolute number of `lines[0]`. Line numbers start at 1.
    private(set) var firstLineNumber = 1
    private var cursors: [String: Int] = [:]

    /// Number of splices that could not be anchored to recorded output.
    private(set) var gapCount = 0
    /// When recorded content last changed — the basis of idle waits.
    private(set) var lastChange = Date()
    private(set) var isSeeded = false

    var nextLineNumber: Int { firstLineNumber + lines.count }
    var lastLineNumber: Int { nextLineNumber - 1 }
    var totalLines: Int { lines.count }

    // MARK: - Recording

    /// Splices one snapshot of the terminal's rendered text onto the log.
    func ingest(_ snapshot: [String]) {
        guard !snapshot.isEmpty else { return }
        isSeeded = true

        guard !lines.isEmpty else {
            append(snapshot)
            return
        }
        if spliceAnchored(snapshot) { return }
        if spliceRedraw(snapshot) { return }

        // Nothing in the snapshot lines up with what was recorded: output
        // outran the sampler, or the screen was cleared. Say so instead of
        // presenting the join as continuous history.
        gapCount += 1
        append(snapshot)
    }

    /// How many trailing recorded rows may be treated as not yet settled while
    /// looking for an anchor. One covers the row output was still being written
    /// into. A few more cover prompts that redraw themselves when a command
    /// starts — zsh's transient prompt rewrites the line above the one being
    /// typed — which would otherwise look like a discontinuity every time.
    private static let unsettledTailRows = 8

    /// Finds where the snapshot overlaps the tail of the log and appends only
    /// what is new, replacing any trailing rows the terminal has since redrawn.
    private func spliceAnchored(_ snapshot: [String]) -> Bool {
        let limit = min(Self.unsettledTailRows, lines.count - 1)
        guard limit >= 0 else { return false }
        for dropped in 0...limit {
            let settled = dropped == 0 ? lines : Array(lines.dropLast(dropped))
            guard let overlap = overlapStart(in: settled, snapshot: snapshot) else {
                continue
            }
            if dropped > 0 { lines.removeLast(dropped) }
            append(Array(snapshot.dropFirst(settled.count - overlap)))
            return true
        }
        return false
    }

    /// Index into `recorded` where `snapshot` begins, preferring the longest
    /// overlap. Candidates are located by first line rather than by testing
    /// every offset, so a large snapshot does not cost a quadratic scan.
    private func overlapStart(in recorded: [String], snapshot: [String]) -> Int? {
        guard let head = snapshot.first else { return nil }
        let lowerBound = max(0, recorded.count - snapshot.count)
        var checked = 0
        var index = lowerBound
        while index < recorded.count {
            defer { index += 1 }
            guard recorded[index] == head else { continue }
            // A blank or repeated row can match many positions. Verifying the
            // most promising handful keeps a pathological screen cheap.
            checked += 1
            if checked > 64 { return nil }
            let length = recorded.count - index
            guard length <= snapshot.count else { continue }
            var matches = true
            for offset in 0..<length where recorded[index + offset] != snapshot[offset] {
                matches = false
                break
            }
            if matches { return index }
        }
        return nil
    }

    /// A full-screen program repaints the same rows in place. Recognizing that
    /// keeps `top` or an agent's TUI from appending a fresh copy of its screen
    /// several times a second.
    private func spliceRedraw(_ snapshot: [String]) -> Bool {
        let width = min(snapshot.count, lines.count)
        guard width >= 4 else { return false }
        let tail = Array(lines.suffix(width))
        let head = Array(snapshot.prefix(width))
        var identical = 0
        for index in 0..<width where tail[index] == head[index] {
            identical += 1
        }
        guard identical * 5 >= width * 3 else { return false }
        guard tail != head || snapshot.count > width else {
            // An unchanged screen is not a change; leave `lastChange` alone so
            // idle waits can settle.
            return true
        }
        lines.removeLast(width)
        append(snapshot)
        return true
    }

    private func append(_ newLines: [String]) {
        guard !newLines.isEmpty else { return }
        lines.append(contentsOf: newLines)
        if lines.count > Self.capacity {
            let excess = lines.count - Self.capacity
            lines.removeFirst(excess)
            firstLineNumber += excess
        }
        lastChange = Date()
    }

    // MARK: - Reading

    /// Incremental read for `cursor`, advancing it past what is returned. An
    /// unknown cursor starts at the live end, so a watcher never inherits a
    /// backlog it did not ask for.
    func read(cursor: String, maxLines: Int) -> Slice {
        let start = cursors[cursor] ?? nextLineNumber
        let slice = window(from: start, to: lastLineNumber, maxLines: maxLines)
        cursors[cursor] = nextLineNumber
        return slice
    }

    /// Rewinds a cursor to the oldest line still recorded.
    func resetCursor(_ cursor: String, toStart: Bool) {
        cursors[cursor] = toStart ? firstLineNumber : nextLineNumber
    }

    func peek(cursor: String) -> Int {
        cursors[cursor] ?? nextLineNumber
    }

    /// Scrollback by absolute line number. With no explicit range this returns
    /// the last `maxLines` lines, which is what makes it safe to call on a
    /// session that printed 50,000 of them.
    func history(startLine: Int?, endLine: Int?, maxLines: Int) -> Slice {
        let last = min(endLine ?? lastLineNumber, lastLineNumber)
        let first = startLine ?? max(firstLineNumber, last - maxLines + 1)
        return window(from: first, to: last, maxLines: maxLines)
    }

    private func window(from requested: Int, to end: Int, maxLines: Int) -> Slice {
        let bound = max(1, maxLines)
        let start = max(requested, firstLineNumber)
        guard end >= start, !lines.isEmpty else {
            return Slice(lines: [], firstLine: nextLineNumber, lastLine: lastLineNumber, omitted: 0)
        }
        let available = end - start + 1
        // Keep the newest rows: the tail is what a caller polling for progress
        // actually needs, and the skipped range stays reachable by line number.
        let effectiveStart = available > bound ? end - bound + 1 : start
        let omitted = max(0, available - bound)
        let lower = effectiveStart - firstLineNumber
        let upper = end - firstLineNumber
        return Slice(
            lines: Array(lines[lower...upper]),
            firstLine: effectiveStart,
            lastLine: end,
            omitted: omitted
        )
    }

    /// Text of every recorded line from `line` onward, for sentinel scanning.
    func line(_ number: Int) -> String? {
        let index = number - firstLineNumber
        guard index >= 0, index < lines.count else { return nil }
        return lines[index]
    }

    func search(from startLine: Int, where predicate: (String) -> Bool) -> Int? {
        var number = max(startLine, firstLineNumber)
        while number <= lastLineNumber {
            if let text = line(number), predicate(text) { return number }
            number += 1
        }
        return nil
    }
}

/// Samples the terminals that automation is currently watching.
///
/// Sampling is not free — the Ghostty surface answers a text read by exporting
/// its screen — so a terminal is polled only while a client is actually reading
/// it, and drops back out as soon as that interest expires.
@MainActor
final class KeroTranscriptRecorder {
    static let shared = KeroTranscriptRecorder()

    /// How long a terminal keeps being sampled after the last automation call
    /// that touched it. Long enough that a read/wait/read sequence never has to
    /// re-seed, short enough that an abandoned session stops costing anything.
    private static let interestWindow: TimeInterval = 90

    /// A terminal is followed closely for this long after the last automation
    /// call that touched it, and while it is tracking a command. Outside that
    /// window it is still sampled, just rarely enough to cost nothing.
    private static let activeWindow: TimeInterval = 10
    private static let activeInterval: TimeInterval = 0.2
    private static let idleInterval: TimeInterval = 1

    private let sessions = NSHashTable<TerminalSession>.weakObjects()
    private var interest: [UUID: Date] = [:]
    private var lastSampled: [UUID: Date] = [:]
    private var timer: Timer?

    private init() {}

    /// Marks a terminal as watched and takes an immediate sample, so the very
    /// first read reflects the screen as it is now rather than as it was one
    /// tick ago.
    func activate(_ session: TerminalSession) {
        interest[session.id] = Date()
        if !sessions.contains(session) { sessions.add(session) }
        sample(session)
        startTimer()
    }

    /// One synchronous sample, for a caller that is about to inspect the log.
    ///
    /// Not cheap: the Ghostty surface answers a text read by exporting its
    /// screen and scrollback to a file. That is why the timer below rations
    /// this rather than running flat out on every watched terminal.
    func sample(_ session: TerminalSession) {
        guard !session.hasExited else { return }
        lastSampled[session.id] = Date()
        let text = session.automationRecentText(
            maxLines: KeroTerminalTranscript.snapshotLines,
            maxColumns: KeroTerminalTranscript.snapshotColumns
        )
        session.transcript.ingest(KeroTerminalText.lines(text))
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(
            timeInterval: Self.activeInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        let now = Date()
        var watching = false
        for session in sessions.allObjects {
            guard let since = interest[session.id] else { continue }
            let isTracking = session.shellCommand.isTracking
            guard !session.hasExited,
                  isTracking || now.timeIntervalSince(since) < Self.interestWindow
            else {
                interest[session.id] = nil
                lastSampled[session.id] = nil
                sessions.remove(session)
                continue
            }
            watching = true

            // Close attention while a command is being tracked or a client is
            // actively reading; a slow heartbeat once that dies down, so a
            // terminal left open does not keep exporting its scrollback.
            let isActive = isTracking
                || now.timeIntervalSince(since) < Self.activeWindow
            let interval = isActive ? Self.activeInterval : Self.idleInterval
            let last = lastSampled[session.id] ?? .distantPast
            guard now.timeIntervalSince(last) >= interval - 0.01 else { continue }
            sample(session)
        }
        if !watching {
            timer?.invalidate()
            timer = nil
        }
    }
}
