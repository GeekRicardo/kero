//
//  KeroAutomationRouter.swift
//  kero
//

import AppKit
import Foundation

/// Main-actor command router behind the authenticated Unix socket. A caller's
/// capability resolves to one terminal and therefore one project. Targets are
/// searched only inside that project; no request can reach another window or
/// project by guessing a UUID.
@MainActor
enum KeroAutomationRouter {
    private struct PaneContext {
        let manager: TerminalManager
        let project: Project
        let tab: PaneTab
        let pane: Pane

        var session: TerminalSession? {
            guard case .session(let session) = pane.content else { return nil }
            return session
        }
    }

    static func route(
        _ request: KeroAutomationRequest,
        callerTerminalID: UUID
    ) async -> KeroAutomationResponse {
        guard let caller = context(forSession: callerTerminalID) else {
            return failure(
                request, "caller_closed",
                "The terminal that owned this capability is no longer open."
            )
        }

        switch request.method {
        case "protocol.info":
            return success(request, .object([
                "version": .number(1),
                "scope": .string("project"),
                "current_terminal_id": .string(callerTerminalID.uuidString),
                "reads_mark_seen": .bool(false),
                "split_focus_default": .bool(false),
                "cursor_reads": .bool(true),
                "line_numbered_history": .bool(true),
                "exit_codes": .bool(true),
                "default_history_lines": .number(Double(KeroAutomationDefaults.historyLines)),
                "max_read_lines": .number(Double(KeroAutomationDefaults.readLines)),
                "keys": .array(KeroAutomationKey.names.map(KeroJSONValue.string)),
            ]))

        case "pane.current":
            return success(request, paneSnapshot(caller, caller: caller))

        case "pane.list":
            return success(
                request,
                .array(projectContexts(caller.project, manager: caller.manager).map {
                    paneSnapshot($0, caller: caller)
                })
            )

        case "pane.get":
            guard let target = targetPane(request, caller: caller) else {
                return failure(request, "pane_not_found", "No matching pane exists in this project.")
            }
            return success(request, paneSnapshot(target, caller: caller))

        case "pane.split":
            return splitPane(request, caller: caller)

        case "pane.run":
            return runInPane(request, caller: caller)

        case "pane.send":
            return sendToPane(request, caller: caller)

        case "pane.read":
            return await readPane(request, caller: caller)

        case "pane.new":
            return newPane(request, caller: caller)

        case "pane.close":
            return closePane(request, caller: caller)

        case "term.list":
            return success(
                request,
                .array(
                    projectContexts(caller.project, manager: caller.manager)
                        .filter { $0.session != nil }
                        .map { paneSnapshot($0, caller: caller) }
                )
            )

        case "term.rename":
            return renameTerminal(request, caller: caller)

        case "term.write":
            return writeToTerminal(request, caller: caller)

        case "term.read":
            return readTerminal(request, caller: caller)

        case "term.history":
            return readTerminalHistory(request, caller: caller)

        case "term.wait":
            return await waitOnTerminal(request, caller: caller)

        case "term.exec":
            return await execInTerminal(request, caller: caller)

        case "term.result":
            return await collectTerminalResult(request, caller: caller)

        case "tab.get":
            return success(request, tabSnapshot(caller))

        case "tab.rename":
            return renameTab(request, caller: caller)

        case "agent.session":
            return recordAgentSession(request, caller: caller)

        case "agent.list":
            let agents = projectContexts(caller.project, manager: caller.manager)
                .compactMap { context -> KeroJSONValue? in
                    guard context.session?.agentStatus != nil else { return nil }
                    return paneSnapshot(context, caller: caller)
                }
            return success(request, .array(agents))

        case "agent.get":
            guard let target = targetAgent(request, caller: caller) else {
                return failure(request, "agent_not_found", "No matching agent exists in this project.")
            }
            return success(request, paneSnapshot(target, caller: caller))

        case "agent.start":
            return startAgent(request, caller: caller)

        case "agent.prompt":
            return promptAgent(request, caller: caller)

        case "agent.report":
            return reportAgent(request, caller: caller)

        default:
            return failure(
                request, "method_not_found",
                "Unknown automation method \(request.method)."
            )
        }
    }

    private static func splitPane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let target = targetPane(request, caller: caller) else {
            return failure(request, "pane_not_found", "No matching pane exists in this project.")
        }
        guard !target.pane.content.isDiff else {
            return failure(request, "pane_not_splittable", "Diff panes cannot be split.")
        }
        guard let edgeName = request.params["edge"]?.stringValue,
              let edge = paneEdge(edgeName)
        else {
            return failure(
                request, "invalid_params",
                "edge must be one of left, right, top, or bottom."
            )
        }
        let focus = request.params["focus"]?.boolValue ?? false
        let directory = request.params["cwd"]?.stringValue
        if let directory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: directory, isDirectory: &isDirectory
            ), isDirectory.boolValue else {
                return failure(
                    request, "invalid_directory",
                    "The requested working directory does not exist."
                )
            }
        }

        guard let created = caller.project.automationSplitTerminal(
            beside: target.pane.id,
            toward: edge,
            directory: directory,
            focus: focus
        ) else {
            return failure(request, "pane_not_splittable", "The target pane could not be split.")
        }
        if focus { TerminalManager.revealSession(id: created.session.id) }
        let context = PaneContext(
            manager: caller.manager,
            project: caller.project,
            tab: created.tab,
            pane: created.pane
        )
        return success(request, paneSnapshot(context, caller: caller))
    }

    private static func runInPane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let target = targetPane(request, caller: caller),
              let session = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        guard session.isShellAvailableForAutomation else {
            return failure(
                request, "shell_busy",
                "The target terminal does not have an available foreground shell."
            )
        }
        guard let argv = stringArray(request.params["argv"]),
              !argv.isEmpty, argv.count <= 256,
              !argv[0].isEmpty,
              argv.allSatisfy({
                  $0.utf8.count <= 16_384 && isSafeShellArgument($0)
              })
        else {
            return failure(
                request, "invalid_params",
                "argv must contain 1 to 256 control-free arguments with a non-empty executable."
            )
        }
        let command = argv.map(shellQuote).joined(separator: " ")
        session.sendCommand(command + "\r")
        return success(request, paneSnapshot(target, caller: caller))
    }

    private static func sendToPane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let target = targetPane(request, caller: caller),
              let session = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        guard let text = request.params["text"]?.stringValue,
              text.utf8.count <= 262_144 else {
            return failure(
                request, "invalid_params",
                "text is required and is limited to 256 KiB."
            )
        }
        session.sendCommand(text)
        if request.params["enter"]?.boolValue == true {
            session.sendCommand("\r")
        }
        return success(request, paneSnapshot(target, caller: caller))
    }

    private static func readPane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) async -> KeroAutomationResponse {
        guard let target = targetPane(request, caller: caller),
              let session = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        let lines = min(max(request.params["lines"]?.intValue ?? 80, 1), 500)
        let columns = min(max(request.params["columns"]?.intValue ?? 400, 1), 2_000)
        do {
            let text = try await session.automationReadText(
                maxLines: lines,
                maxColumns: columns,
                requireIdleAgentForHistory:
                    request.params["require_idle_agent"]?.boolValue == true
            )
            return success(request, .object([
                "pane": paneSnapshot(target, caller: caller),
                "text": .string(text),
                "lines": .number(Double(lines)),
                "columns": .number(Double(columns)),
            ]))
        } catch KeroAutomationReadError.agentNotIdle {
            return failure(
                request,
                "agent_not_idle",
                "Alternate-screen transcript history is available only after the agent settles. Wait for idle or done, then read again."
            )
        } catch {
            return failure(
                request,
                "read_failed",
                "Kero could not read the terminal transcript."
            )
        }
    }

    // MARK: - Layout

    private static func newPane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        let directory = request.params["cwd"]?.stringValue
        if let directory, !isExistingDirectory(directory) {
            return failure(
                request, "invalid_directory",
                "The requested working directory does not exist."
            )
        }
        var alias: String?
        if let requested = request.params["alias"]?.stringValue {
            guard isValidAlias(requested) else {
                return failure(
                    request, "invalid_alias",
                    "alias must be 1 to 64 ASCII letters, numbers, dots, underscores, or hyphens."
                )
            }
            guard !isAliasTaken(requested, in: caller.project, excluding: nil) else {
                return failure(
                    request, "alias_in_use",
                    "Another terminal or agent in this project already uses alias \(requested)."
                )
            }
            alias = requested
        }
        let focus = request.params["focus"]?.boolValue ?? false

        let created: (tab: PaneTab, pane: Pane, session: TerminalSession)?
        if let edgeName = request.params["edge"]?.stringValue {
            guard let edge = paneEdge(edgeName) else {
                return failure(
                    request, "invalid_params",
                    "edge must be one of left, right, top, or bottom."
                )
            }
            switch resolve(request, caller: caller) {
            case .failure(let code, let message):
                return failure(request, code, message)
            case .found(let target):
                guard !target.pane.content.isDiff else {
                    return failure(request, "pane_not_splittable", "Diff panes cannot be split.")
                }
                created = caller.project.automationSplitTerminal(
                    beside: target.pane.id,
                    toward: edge,
                    directory: directory,
                    focus: focus
                )
            }
        } else {
            created = caller.project.automationNewTerminalTab(
                directory: directory,
                focus: focus
            )
        }

        guard let created else {
            return failure(
                request, "pane_not_created",
                "Kero could not create the terminal."
            )
        }
        created.session.automationAlias = alias
        if focus { TerminalManager.revealSession(id: created.session.id) }
        return success(request, paneSnapshot(
            PaneContext(
                manager: caller.manager,
                project: caller.project,
                tab: created.tab,
                pane: created.pane
            ),
            caller: caller
        ))
    }

    private static func closePane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        let resolved = resolve(request, caller: caller)
        guard case .found(let target) = resolved else {
            return resolved.response(to: request)
        }
        // The caller's own shell is the parent of this `kero` process. Closing
        // it would kill the request mid-flight and leave the client with a
        // transport error instead of an answer.
        guard target.pane.id != caller.pane.id else {
            return failure(
                request, "cannot_close_caller",
                "A terminal cannot close the pane it is running in."
            )
        }
        let closesTab = request.params["tab"]?.boolValue == true
        let snapshot = paneSnapshot(target, caller: caller)
        if closesTab {
            caller.project.close(target.tab)
        } else {
            caller.project.closeContent(target.pane.content)
        }
        return success(request, .object([
            "closed": .bool(true),
            "scope": .string(closesTab ? "tab" : "pane"),
            "pane": snapshot,
        ]))
    }

    private static func renameTerminal(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        let resolved = resolveTerminal(request, caller: caller)
        guard case .found(let target, let session) = resolved else {
            return resolved.response(to: request)
        }
        guard let alias = request.params["alias"]?.stringValue else {
            return failure(request, "invalid_params", "alias is required.")
        }
        guard isValidAlias(alias) else {
            return failure(
                request, "invalid_alias",
                "alias must be 1 to 64 ASCII letters, numbers, dots, underscores, or hyphens."
            )
        }
        guard !isAliasTaken(alias, in: caller.project, excluding: session.id) else {
            return failure(
                request, "alias_in_use",
                "Another terminal or agent in this project already uses alias \(alias)."
            )
        }
        session.automationAlias = alias
        return success(request, paneSnapshot(target, caller: caller))
    }

    // MARK: - Terminal input and output

    private static func writeToTerminal(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        let resolved = resolveTerminal(request, caller: caller)
        guard case .found(let target, let session) = resolved else {
            return resolved.response(to: request)
        }
        guard !session.hasExited else {
            return failure(
                request, "terminal_exited",
                "That terminal's process has exited. Its output is still readable."
            )
        }

        var payload = ""
        if let text = request.params["text"]?.stringValue {
            guard text.utf8.count <= 262_144 else {
                return failure(request, "invalid_params", "text is limited to 256 KiB.")
            }
            payload += text
        }
        if let names = stringArray(request.params["keys"]) {
            guard names.count <= 64 else {
                return failure(request, "invalid_params", "At most 64 keys can be sent at once.")
            }
            for name in names {
                guard let sequence = KeroAutomationKey.sequence(for: name) else {
                    return failure(
                        request, "unknown_key",
                        "Unknown key \(name.debugDescription). Known keys: \(KeroAutomationKey.names.joined(separator: ", "))."
                    )
                }
                payload += sequence
            }
        }
        if request.params["enter"]?.boolValue == true {
            payload += "\r"
        }
        guard !payload.isEmpty else {
            return failure(
                request, "invalid_params",
                "Send text, one or more keys, or --enter."
            )
        }

        KeroTranscriptRecorder.shared.activate(session)
        session.sendCommand(payload)
        return success(request, paneSnapshot(target, caller: caller))
    }

    private static func readTerminal(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        let resolved = resolveTerminal(request, caller: caller)
        guard case .found(let target, let session) = resolved else {
            return resolved.response(to: request)
        }
        let cursor = request.params["cursor"]?.stringValue ?? "agent"
        guard (1...64).contains(cursor.utf8.count) else {
            return failure(request, "invalid_params", "cursor must be 1 to 64 characters.")
        }
        let maxLines = min(
            max(request.params["max_lines"]?.intValue ?? KeroAutomationDefaults.readLines, 1),
            2_000
        )

        KeroTranscriptRecorder.shared.activate(session)
        if request.params["rewind"]?.boolValue == true {
            session.transcript.resetCursor(cursor, toStart: true)
        }
        let slice = session.transcript.read(cursor: cursor, maxLines: maxLines)
        return success(request, transcriptResult(
            slice,
            target: target,
            caller: caller,
            session: session,
            hint: slice.omitted > 0
                ? "\(slice.omitted) earlier lines were skipped to stay within \(maxLines) lines. They are still readable by line number with `kero +term history`."
                : nil
        ))
    }

    private static func readTerminalHistory(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        let resolved = resolveTerminal(request, caller: caller)
        guard case .found(let target, let session) = resolved else {
            return resolved.response(to: request)
        }
        let startLine = request.params["start_line"]?.intValue
        let endLine = request.params["end_line"]?.intValue
        if let startLine, startLine < 1 {
            return failure(request, "invalid_params", "start_line must be 1 or greater.")
        }
        if let startLine, let endLine, endLine < startLine {
            return failure(request, "invalid_params", "end_line must not precede start_line.")
        }
        // No arguments means the last 100 lines, deliberately: this is the call
        // to reach for when looking at what happened, so it has to stay safe on
        // a terminal that printed fifty thousand lines.
        let requested = request.params["lines"]?.intValue
            ?? (startLine != nil || endLine != nil
                ? 2_000
                : KeroAutomationDefaults.historyLines)
        let maxLines = min(max(requested, 1), 2_000)

        KeroTranscriptRecorder.shared.activate(session)
        let slice = session.transcript.history(
            startLine: startLine, endLine: endLine, maxLines: maxLines
        )
        let total = session.transcript.totalLines
        return success(request, transcriptResult(
            slice,
            target: target,
            caller: caller,
            session: session,
            hint: slice.omitted > 0 || slice.firstLine > session.transcript.firstLineNumber
                ? "Showing lines \(slice.firstLine)–\(slice.lastLine) of \(total) recorded. Ask for more with --lines, or an exact window with --start/--end."
                : nil
        ))
    }

    private static func waitOnTerminal(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) async -> KeroAutomationResponse {
        let resolved = resolveTerminal(request, caller: caller)
        guard case .found(let target, let session) = resolved else {
            return resolved.response(to: request)
        }
        var pattern: NSRegularExpression?
        if let source = request.params["match"]?.stringValue {
            guard source.utf8.count <= 4_096,
                  let compiled = try? NSRegularExpression(pattern: source) else {
                return failure(
                    request, "invalid_params",
                    "match must be a valid regular expression of at most 4 KiB."
                )
            }
            pattern = compiled
        }
        let waitForExit = request.params["exit"]?.boolValue == true
        let explicitIdle = request.params["idle_ms"]?.intValue
        // A match or an exit wait turns the idle rule off unless the caller
        // asked for both: otherwise the marker they are waiting for would lose
        // every race against a quiet moment.
        let idle = explicitIdle
            ?? (pattern == nil && !waitForExit
                ? KeroAutomationDefaults.idleMilliseconds
                : nil)
        let timeout = min(
            max(
                request.params["timeout_ms"]?.intValue
                    ?? KeroAutomationDefaults.waitTimeoutMilliseconds,
                100
            ),
            3_600_000
        )

        let cursor = request.params["cursor"]?.stringValue
        KeroTranscriptRecorder.shared.activate(session)
        let searchFrom = cursor.map { session.transcript.peek(cursor: $0) }
            ?? session.transcript.nextLineNumber
        let outcome = await KeroAutomationWait.run(
            session: session,
            idleMilliseconds: idle,
            pattern: pattern,
            waitForExit: waitForExit,
            timeoutMilliseconds: timeout,
            fromLine: searchFrom
        )

        var object: [String: KeroJSONValue] = [
            "pane": paneSnapshot(target, caller: caller),
            "reason": .string(outcome.reason.rawValue),
            "exited": .bool(session.hasExited),
        ]
        if let line = outcome.matchedLine {
            object["matched_line"] = .number(Double(line))
        }
        if let text = outcome.matchedText {
            object["matched_text"] = .string(text)
        }
        if let cursor {
            // One call replaces write + sleep + read: the caller gets the new
            // output and the cursor moves past it.
            let slice = session.transcript.read(
                cursor: cursor, maxLines: KeroAutomationDefaults.readLines
            )
            object["text"] = .string(slice.lines.joined(separator: "\n"))
            object["first_line"] = .number(Double(slice.firstLine))
            object["last_line"] = .number(Double(slice.lastLine))
            object["omitted_lines"] = .number(Double(slice.omitted))
        }
        return success(request, .object(object))
    }

    private static func execInTerminal(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) async -> KeroAutomationResponse {
        let resolved = resolveTerminal(request, caller: caller)
        guard case .found(let target, let session) = resolved else {
            return resolved.response(to: request)
        }
        guard let command = request.params["command"]?.stringValue else {
            return failure(request, "invalid_params", "command is required.")
        }
        guard command.utf8.count <= 16_384 else {
            return failure(request, "invalid_params", "command is limited to 16 KiB.")
        }
        let silent = min(
            max(
                request.params["silent_ms"]?.intValue
                    ?? KeroAutomationDefaults.silentMilliseconds,
                0
            ),
            3_600_000
        )
        let timeout = min(
            max(
                request.params["timeout_ms"]?.intValue
                    ?? KeroAutomationDefaults.execTimeoutMilliseconds,
                100
            ),
            3_600_000
        )

        do {
            let outcome = try await session.shellCommand.start(
                session: session,
                command: command,
                background: request.params["background"]?.boolValue ?? false,
                silentMilliseconds: silent,
                timeoutMilliseconds: timeout,
                replace: request.params["replace"]?.boolValue ?? false
            )
            return success(request, execResult(outcome, target: target, caller: caller))
        } catch {
            return execFailure(request, error: error)
        }
    }

    private static func collectTerminalResult(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) async -> KeroAutomationResponse {
        let resolved = resolveTerminal(request, caller: caller)
        guard case .found(let target, let session) = resolved else {
            return resolved.response(to: request)
        }
        let timeout = min(
            max(
                request.params["timeout_ms"]?.intValue
                    ?? KeroAutomationDefaults.collectTimeoutMilliseconds,
                100
            ),
            3_600_000
        )
        do {
            let outcome = try await session.shellCommand.collect(
                session: session,
                timeoutMilliseconds: timeout,
                abandon: request.params["abandon"]?.boolValue ?? false,
                interrupt: request.params["interrupt"]?.boolValue ?? false
            )
            return success(request, execResult(outcome, target: target, caller: caller))
        } catch {
            return execFailure(request, error: error)
        }
    }

    private static func execFailure(
        _ request: KeroAutomationRequest,
        error: Error
    ) -> KeroAutomationResponse {
        guard let reason = error as? KeroAutomationShellCommand.Failure else {
            return failure(request, "exec_failed", "Kero could not run the command.")
        }
        switch reason {
        case .busy(let command):
            return failure(
                request, "command_pending",
                "This terminal is still tracking \(command.debugDescription). Collect it with `kero +term result`, release it with --abandon or --interrupt, or re-run with --replace."
            )
        case .notTracking:
            return failure(
                request, "no_pending_command",
                "This terminal is not tracking a command."
            )
        case .shellUnavailable:
            return failure(
                request, "shell_busy",
                "The target terminal does not have an available foreground shell. `exec` instruments the shell's command line, so it cannot run inside a full-screen program."
            )
        case .invalidCommand:
            return failure(
                request, "invalid_params",
                "command must be a single non-empty line."
            )
        }
    }

    private static func execResult(
        _ outcome: KeroAutomationShellCommand.Outcome,
        target: PaneContext,
        caller: PaneContext
    ) -> KeroJSONValue {
        var object: [String: KeroJSONValue] = [
            "pane": paneSnapshot(target, caller: caller),
            "status": .string(outcome.status.rawValue),
            "command": .string(outcome.command),
            "output": .string(outcome.lines.joined(separator: "\n")),
            "first_line": .number(Double(outcome.firstLine)),
            "last_line": .number(Double(outcome.lastLine)),
            "omitted_lines": .number(Double(outcome.omitted)),
            "exit_code": outcome.exitCode.map { .number(Double($0)) } ?? .null,
        ]
        if let reason = outcome.backgroundedBecause {
            object["backgrounded_because"] = .string(reason.rawValue)
        }
        if let hint = outcome.hint {
            object["hint"] = .string(hint)
        }
        return .object(object)
    }

    private static func transcriptResult(
        _ slice: KeroTerminalTranscript.Slice,
        target: PaneContext,
        caller: PaneContext,
        session: TerminalSession,
        hint: String?
    ) -> KeroJSONValue {
        var object: [String: KeroJSONValue] = [
            "pane": paneSnapshot(target, caller: caller),
            "text": .string(slice.lines.joined(separator: "\n")),
            "first_line": .number(Double(slice.firstLine)),
            "last_line": .number(Double(slice.lastLine)),
            "omitted_lines": .number(Double(slice.omitted)),
            "total_lines": .number(Double(session.transcript.totalLines)),
            "oldest_line": .number(Double(session.transcript.firstLineNumber)),
            "newest_line": .number(Double(session.transcript.lastLineNumber)),
        ]
        if session.transcript.gapCount > 0 {
            object["gaps"] = .number(Double(session.transcript.gapCount))
        }
        if let hint {
            object["hint"] = .string(hint)
        }
        return .object(object)
    }

    private static func startAgent(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let target = targetPane(request, caller: caller),
              let session = target.session else {
            return failure(request, "terminal_required", "The target pane is not a terminal.")
        }
        guard session.isShellAvailableForAutomation else {
            return failure(
                request, "shell_busy",
                "Agents can start only in an existing terminal with an available shell."
            )
        }
        guard session.agentStatus == nil else {
            return failure(
                request, "agent_already_declared",
                "This terminal already has an active or pending agent."
            )
        }
        guard let alias = request.params["alias"]?.stringValue,
              isValidAlias(alias) else {
            return failure(
                request, "invalid_alias",
                "alias must be 1 to 64 ASCII letters, numbers, dots, underscores, or hyphens."
            )
        }
        guard let kindName = request.params["kind"]?.stringValue,
              let kind = KeroAgentKind(rawValue: kindName) else {
            return failure(
                request, "invalid_agent_kind",
                "Supported kinds: \(KeroAgentKind.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        guard !isAliasTaken(alias, in: caller.project, excluding: session.id) else {
            return failure(
                request, "alias_in_use",
                "Another terminal or agent in this project already uses alias \(alias)."
            )
        }
        let extra = stringArray(request.params["argv"]) ?? []
        guard extra.count <= 128,
              extra.allSatisfy({
                  $0.utf8.count <= 16_384 && isSafeShellArgument($0)
              }) else {
            return failure(
                request, "invalid_params",
                "Agent arguments exceed the protocol limits or contain terminal control characters."
            )
        }

        session.declareAutomationAgent(alias: alias, kind: kind)
        let command = ([kind.executable] + extra).map(shellQuote).joined(separator: " ")
        session.sendCommand(command + "\r")
        if request.params["focus"]?.boolValue == true {
            TerminalManager.revealSession(id: session.id)
        }
        return success(request, paneSnapshot(target, caller: caller))
    }

    private static func promptAgent(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let target = targetAgent(request, caller: caller),
              let session = target.session,
              let status = session.agentStatus else {
            return failure(request, "agent_not_found", "No matching agent exists in this project.")
        }
        guard status.phase == .created
                || status.phase == .working
                || status.phase == .idle
                || status.phase == .done else {
            return failure(
                request, "agent_not_ready",
                "\(status.alias) is \(status.phase.rawValue); guarded prompts require created, working, idle, or done. Use +pane send for explicit raw input."
            )
        }
        guard session.isAutomationAgentRunning(kind: status.kind) else {
            return failure(
                request, "agent_not_running",
                "\(status.alias) has exited; start it again before sending a guarded prompt."
            )
        }
        guard let prompt = request.params["text"]?.stringValue,
              !prompt.isEmpty, prompt.utf8.count <= 262_144,
              isSafePromptText(prompt) else {
            return failure(
                request, "invalid_prompt",
                "Prompt text must be non-empty, contain no terminal control characters, and fit within 256 KiB."
            )
        }

        let normalized = prompt
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if normalized.contains("\n") {
            session.sendCommand("\u{1b}[200~" + normalized + "\u{1b}[201~")
        } else {
            session.sendCommand(normalized)
        }
        session.sendCommand("\r")
        session.markAutomationAgentPrompted()
        return success(request, paneSnapshot(target, caller: caller))
    }

    /// Renames the tab the caller is running in.
    ///
    /// Scoped to the caller's own tab rather than any target: this exists so an
    /// agent can label the tab it lives in — Claude Code's `/rename` reaches
    /// it — and a command that could rename someone else's tab is a different,
    /// larger permission.
    private static func renameTab(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let value = request.params["name"] else {
            return failure(request, "invalid_params", "name is required, or null to clear it.")
        }
        if case .null = value {
            caller.tab.customName = nil
            return success(request, tabSnapshot(caller))
        }
        guard let raw = value.stringValue else {
            return failure(request, "invalid_params", "name must be a string or null.")
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256 else {
            return failure(
                request, "invalid_params",
                "name must be 1 to 256 bytes, or null to restore the automatic title."
            )
        }
        // A tab title is chrome the user reads at a glance; control characters
        // in it would corrupt the strip rather than name anything.
        guard name.unicodeScalars.allSatisfy({
            $0.value >= 0x20 && !(0x7f...0x9f).contains($0.value)
        }) else {
            return failure(
                request, "invalid_params",
                "name must not contain control characters."
            )
        }
        caller.tab.customName = name
        return success(request, tabSnapshot(caller))
    }

    private static func tabSnapshot(_ context: PaneContext) -> KeroJSONValue {
        .object([
            "tab_id": .string(context.tab.id.uuidString),
            "project_id": .string(context.project.id.uuidString),
            "custom_name": context.tab.customName.map(KeroJSONValue.string) ?? .null,
            "title": .string(context.tab.displayTitle ?? context.pane.content.title),
        ])
    }

    /// Records the provider conversation running in the caller's terminal, so
    /// a relaunch can offer to resume it. Only the caller's own terminal can be
    /// named: the hook that reports this runs inside it.
    private static func recordAgentSession(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let session = caller.session else {
            return failure(request, "terminal_required", "The caller is not a terminal pane.")
        }
        guard let kindName = request.params["kind"]?.stringValue,
              KeroAgentKind(rawValue: kindName) != nil else {
            return failure(
                request, "invalid_agent_kind",
                "Supported kinds: \(KeroAgentKind.allCases.map(\.rawValue).joined(separator: ", "))."
            )
        }
        guard let sessionID = request.params["session_id"]?.stringValue,
              KeroAgentResume.isSafeSessionID(sessionID) else {
            return failure(
                request, "invalid_params",
                "session_id must be printable ASCII of at most 512 bytes."
            )
        }
        session.agentProviderSessionID = sessionID
        return success(request, .object([
            "terminal_id": .string(session.id.uuidString),
            "session_id": .string(sessionID),
        ]))
    }

    private static func reportAgent(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> KeroAutomationResponse {
        guard let session = caller.session else {
            return failure(request, "terminal_required", "The caller is not a terminal pane.")
        }
        guard let name = request.params["state"]?.stringValue,
              let phase = KeroAgentPhase(rawValue: name),
              phase != .created else {
            return failure(
                request, "invalid_params",
                "state must be working, blocked, done, idle, or unknown."
            )
        }
        let reason = request.params["reason"]?.stringValue
        guard reason?.utf8.count ?? 0 <= 4_096 else {
            return failure(request, "invalid_params", "reason is limited to 4 KiB.")
        }
        guard session.reportAutomationAgent(phase: phase, reason: reason) else {
            return failure(
                request, "agent_not_recognized",
                "Declare or start an agent in this terminal before reporting its state."
            )
        }
        return success(request, paneSnapshot(caller, caller: caller))
    }

    // MARK: - Targeting

    private enum Resolution {
        case found(PaneContext)
        case failure(code: String, message: String)

        func response(to request: KeroAutomationRequest) -> KeroAutomationResponse {
            guard case .failure(let code, let message) = self else {
                return .failure(
                    id: request.id, code: "pane_not_found",
                    message: "No matching pane exists in this project."
                )
            }
            return .failure(id: request.id, code: code, message: message)
        }
    }

    private enum TerminalResolution {
        case found(PaneContext, TerminalSession)
        case failure(code: String, message: String)

        func response(to request: KeroAutomationRequest) -> KeroAutomationResponse {
            guard case .failure(let code, let message) = self else {
                return .failure(
                    id: request.id, code: "terminal_required",
                    message: "The target pane is not a terminal."
                )
            }
            return .failure(id: request.id, code: code, message: message)
        }
    }

    /// Resolves the pane a request is about.
    ///
    /// A caller that just created a pane has its exact `pane_id`, but one
    /// reading a list wants to say `build` or the first few characters of an
    /// id. Both are accepted; an ambiguous prefix is refused rather than
    /// resolved to whichever pane happened to sort first, because the target of
    /// a write is not a good place for a guess.
    private static func resolve(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> Resolution {
        if let value = request.params["pane_id"] {
            guard let string = value.stringValue, let id = UUID(uuidString: string),
                  let context = projectContexts(caller.project, manager: caller.manager)
                      .first(where: { $0.pane.id == id })
            else {
                return .failure(
                    code: "pane_not_found",
                    message: "No pane with that id exists in this project."
                )
            }
            return .found(context)
        }
        guard let raw = request.params["target"]?.stringValue,
              !raw.isEmpty else {
            return .found(caller)
        }
        let target = raw.lowercased()
        let contexts = projectContexts(caller.project, manager: caller.manager)

        let named = contexts.filter {
            $0.session?.automationAlias?.lowercased() == target
                || $0.session?.agentStatus?.alias.lowercased() == target
        }
        if named.count == 1 { return .found(named[0]) }
        if named.count > 1 {
            return .failure(
                code: "ambiguous_target",
                message: "More than one terminal in this project answers to \(raw.debugDescription)."
            )
        }

        guard target.count >= 4 else {
            return .failure(
                code: "target_too_short",
                message: "An id prefix must be at least 4 characters. Use an alias for anything shorter."
            )
        }
        let matched = contexts.filter {
            $0.pane.id.uuidString.lowercased().hasPrefix(target)
                || $0.session?.id.uuidString.lowercased().hasPrefix(target) == true
        }
        switch matched.count {
        case 1:
            return .found(matched[0])
        case 0:
            return .failure(
                code: "pane_not_found",
                message: "No pane in this project matches \(raw.debugDescription). List them with `kero +term list`."
            )
        default:
            return .failure(
                code: "ambiguous_target",
                message: "\(matched.count) panes match the prefix \(raw.debugDescription). Use more characters or an alias."
            )
        }
    }

    private static func resolveTerminal(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> TerminalResolution {
        switch resolve(request, caller: caller) {
        case .failure(let code, let message):
            return .failure(code: code, message: message)
        case .found(let context):
            guard let session = context.session else {
                return .failure(
                    code: "terminal_required",
                    message: "The target pane is not a terminal."
                )
            }
            return .found(context, session)
        }
    }

    private static func isExistingDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }

    /// Aliases share one project-local namespace with agent aliases, so a
    /// target never means two different things depending on the command used.
    private static func isAliasTaken(
        _ alias: String,
        in project: Project,
        excluding sessionID: UUID?
    ) -> Bool {
        project.sessions.contains {
            $0.id != sessionID
                && ($0.automationAlias?.caseInsensitiveCompare(alias) == .orderedSame
                    || $0.agentStatus?.alias.caseInsensitiveCompare(alias) == .orderedSame)
        }
    }

    private static func targetPane(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> PaneContext? {
        guard case .found(let context) = resolve(request, caller: caller) else {
            return nil
        }
        return context
    }

    private static func targetAgent(
        _ request: KeroAutomationRequest,
        caller: PaneContext
    ) -> PaneContext? {
        if request.params["pane_id"] != nil || request.params["target"] != nil {
            guard let pane = targetPane(request, caller: caller),
                  pane.session?.agentStatus != nil else { return nil }
            return pane
        }
        if let alias = request.params["alias"]?.stringValue {
            return projectContexts(caller.project, manager: caller.manager).first {
                $0.session?.agentStatus?.alias == alias
            }
        }
        return caller.session?.agentStatus == nil ? nil : caller
    }

    private static func context(forSession id: UUID) -> PaneContext? {
        for manager in TerminalManager.automationManagers {
            for project in manager.projects {
                for tab in project.tabs {
                    for pane in tab.allPanes {
                        guard case .session(let session) = pane.content,
                              session.id == id else { continue }
                        return PaneContext(
                            manager: manager, project: project, tab: tab, pane: pane
                        )
                    }
                }
            }
        }
        return nil
    }

    private static func projectContexts(
        _ project: Project,
        manager: TerminalManager
    ) -> [PaneContext] {
        project.tabs.flatMap { tab in
            tab.allPanes.map {
                PaneContext(manager: manager, project: project, tab: tab, pane: $0)
            }
        }
    }

    private static func paneSnapshot(
        _ context: PaneContext,
        caller: PaneContext
    ) -> KeroJSONValue {
        let contentKind: String = switch context.pane.content {
        case .session: "terminal"
        case .file: "file"
        case .browser: "browser"
        case .diff: "diff"
        }
        var object: [String: KeroJSONValue] = [
            "project_id": .string(context.project.id.uuidString),
            "project_name": .string(context.project.name),
            "tab_id": .string(context.tab.id.uuidString),
            "pane_id": .string(context.pane.id.uuidString),
            "content": .string(contentKind),
            "title": .string(context.pane.content.title),
            "is_caller": .bool(context.pane.id == caller.pane.id),
            "is_focused": .bool(
                context.manager.selectedProjectID == context.project.id
                    && context.project.selectedTabID == context.tab.id
                    && context.tab.focusedPaneID == context.pane.id
            ),
        ]
        if let session = context.session {
            object["terminal_id"] = .string(session.id.uuidString)
            object["cwd"] = .string(session.currentDirectoryPath)
            object["shell_available"] = .bool(session.isShellAvailableForAutomation)
            object["exited"] = .bool(session.hasExited)
            object["agent"] = session.agentStatus.map(agentSnapshot) ?? .null
            object["alias"] = session.automationAlias.map(KeroJSONValue.string) ?? .null
            if session.transcript.isSeeded {
                object["oldest_line"] = .number(Double(session.transcript.firstLineNumber))
                object["newest_line"] = .number(Double(session.transcript.lastLineNumber))
            }
            // A terminal still tracking a command cannot take another one, so
            // say so in every snapshot rather than only in an error.
            object["pending_command"] = session.shellCommand.trackedCommand
                .map(KeroJSONValue.string) ?? .null
        }
        return .object(object)
    }

    private static func agentSnapshot(_ status: KeroAgentStatus) -> KeroJSONValue {
        .object([
            "alias": .string(status.alias),
            "kind": .string(status.kind.rawValue),
            "state": .string(status.phase.rawValue),
            "authority": .string(status.authority.rawValue),
            "reason": .string(status.reason),
            "updated_at": .string(ISO8601DateFormatter().string(from: status.updatedAt)),
            "process_id": status.processID.map { .number(Double($0)) } ?? .null,
            "unseen": .bool(status.unseen),
        ])
    }

    private static func paneEdge(_ value: String) -> PaneDropEdge? {
        switch value {
        case "left": return .left
        case "right": return .right
        case "top", "up": return .top
        case "bottom", "down": return .bottom
        default: return nil
        }
    }

    private static func stringArray(_ value: KeroJSONValue?) -> [String]? {
        guard let values = value?.arrayValue else { return nil }
        let strings = values.compactMap(\.stringValue)
        return strings.count == values.count ? strings : nil
    }

    private static func isValidAlias(_ value: String) -> Bool {
        guard (1...64).contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0)
                || (97...122).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
        }
    }

    private static func isSafePromptText(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x20 && !(0x7F...0x9F).contains(scalar.value))
                || scalar.value == 0x0A
                || scalar.value == 0x0D
                || scalar.value == 0x09
        }
    }

    private static func isSafeShellArgument(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && !(0x7F...0x9F).contains($0.value)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func success(
        _ request: KeroAutomationRequest,
        _ result: KeroJSONValue
    ) -> KeroAutomationResponse {
        .success(id: request.id, result: result)
    }

    private static func failure(
        _ request: KeroAutomationRequest,
        _ code: String,
        _ message: String
    ) -> KeroAutomationResponse {
        .failure(id: request.id, code: code, message: message)
    }
}
