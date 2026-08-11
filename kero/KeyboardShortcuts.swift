//
//  KeyboardShortcuts.swift
//  kero
//

import AppKit
import SwiftUI

/// One rebindable command.
///
/// Every window, workspace, tab, and pane action Kero puts on the menu bar is
/// here, so the settings screen is the whole story rather than a sampler.
/// Actions that belong to macOS itself — Quit, Hide, Minimize — stay where
/// macOS puts them.
enum KeyboardShortcutAction: String, CaseIterable, Identifiable, Sendable {
    case newProject
    case newSession
    case newBrowserTab
    case newWindow
    case closePane
    case commandPalette
    case nextProject
    case previousProject
    case selectWorkspaceNumber

    case nextTab
    case previousTab
    case selectTabNumber

    case splitRight
    case splitDown
    case splitLeft
    case splitUp
    case focusPaneLeft
    case focusPaneRight
    case focusPaneUp
    case focusPaneDown
    case focusPreviousPane
    case focusNextPane
    case togglePaneZoom
    case equalizePanes
    case resizePaneUp
    case resizePaneDown
    case resizePaneLeft
    case resizePaneRight

    case toggleLeftSidebar
    case toggleRightSidebar
    case toggleFilesPanel
    case toggleGitPanel
    case toggleInfoPanel

    case saveFile
    case clearTerminal
    case find
    case findAndReplace
    case findNext
    case useSelectionForFind

    case focusAddressBar
    case reloadPage
    case nextAgentAttention

    var id: String { rawValue }

    enum Group: String, CaseIterable, Identifiable, Sendable {
        case workspaces
        case tabs
        case panes
        case view
        case editing
        case browser

        var id: String { rawValue }

        var title: String {
            switch self {
            case .workspaces: String(localized: "Windows & Workspaces")
            case .tabs: String(localized: "Tabs")
            case .panes: String(localized: "Panes")
            case .view: String(localized: "View")
            case .editing: String(localized: "Terminal & Editing")
            case .browser: String(localized: "Browser & Agents")
            }
        }
    }

    var group: Group {
        switch self {
        case .newProject, .newSession, .newBrowserTab, .newWindow, .closePane,
             .commandPalette, .nextProject, .previousProject, .selectWorkspaceNumber:
            return .workspaces
        case .nextTab, .previousTab, .selectTabNumber:
            return .tabs
        case .splitRight, .splitDown, .splitLeft, .splitUp,
             .focusPaneLeft, .focusPaneRight, .focusPaneUp, .focusPaneDown,
             .focusPreviousPane, .focusNextPane, .togglePaneZoom, .equalizePanes,
             .resizePaneUp, .resizePaneDown, .resizePaneLeft, .resizePaneRight:
            return .panes
        case .toggleLeftSidebar, .toggleRightSidebar, .toggleFilesPanel,
             .toggleGitPanel, .toggleInfoPanel:
            return .view
        case .saveFile, .clearTerminal, .find, .findAndReplace, .findNext,
             .useSelectionForFind:
            return .editing
        case .focusAddressBar, .reloadPage, .nextAgentAttention:
            return .browser
        }
    }

    var title: String {
        switch self {
        case .newProject: String(localized: "New Project")
        case .newSession: String(localized: "New Session")
        case .newBrowserTab: String(localized: "New Browser Tab")
        case .newWindow: String(localized: "New Window")
        case .closePane: String(localized: "Close Pane")
        case .commandPalette: String(localized: "Command Palette")
        case .nextProject: String(localized: "Next Workspace")
        case .previousProject: String(localized: "Previous Workspace")
        case .selectWorkspaceNumber: String(localized: "Select Workspace 1–9")
        case .nextTab: String(localized: "Next Tab")
        case .previousTab: String(localized: "Previous Tab")
        case .selectTabNumber: String(localized: "Select Tab 1–9")
        case .splitRight: String(localized: "Split Right")
        case .splitDown: String(localized: "Split Down")
        case .splitLeft: String(localized: "Split Left")
        case .splitUp: String(localized: "Split Up")
        case .focusPaneLeft: String(localized: "Focus Pane Left")
        case .focusPaneRight: String(localized: "Focus Pane Right")
        case .focusPaneUp: String(localized: "Focus Pane Up")
        case .focusPaneDown: String(localized: "Focus Pane Down")
        case .focusPreviousPane: String(localized: "Focus Previous Pane")
        case .focusNextPane: String(localized: "Focus Next Pane")
        case .togglePaneZoom: String(localized: "Toggle Pane Zoom")
        case .equalizePanes: String(localized: "Equalize Panes")
        case .resizePaneUp: String(localized: "Resize Pane Up")
        case .resizePaneDown: String(localized: "Resize Pane Down")
        case .resizePaneLeft: String(localized: "Resize Pane Left")
        case .resizePaneRight: String(localized: "Resize Pane Right")
        case .toggleLeftSidebar: String(localized: "Toggle Left Sidebar")
        case .toggleRightSidebar: String(localized: "Toggle Right Sidebar")
        case .toggleFilesPanel: String(localized: "Toggle Files Panel")
        case .toggleGitPanel: String(localized: "Toggle Git Panel")
        case .toggleInfoPanel: String(localized: "Toggle Info Panel")
        case .saveFile: String(localized: "Save")
        case .clearTerminal: String(localized: "Clear Terminal")
        case .find: String(localized: "Find…")
        case .findAndReplace: String(localized: "Find and Replace…")
        case .findNext: String(localized: "Find Next")
        case .useSelectionForFind: String(localized: "Use Selection for Find")
        case .focusAddressBar: String(localized: "Focus Address Bar")
        case .reloadPage: String(localized: "Reload Page")
        case .nextAgentAttention: String(localized: "Next Agent Needing Attention")
        }
    }

    /// True for the two 1…9 families. Their key is the digit itself, so only
    /// the modifiers are bindable — which is exactly the choice worth having:
    /// whether ⌘1 reaches the workspace list or the tab strip.
    var isNumberFamily: Bool {
        self == .selectWorkspaceNumber || self == .selectTabNumber
    }

    var defaultBinding: KeyboardShortcutBinding? {
        typealias Binding = KeyboardShortcutBinding
        switch self {
        case .newProject: return Binding(key: .character("n"), modifiers: .command)
        case .newSession: return Binding(key: .character("t"), modifiers: .command)
        case .newBrowserTab: return nil
        case .newWindow: return Binding(key: .character("n"), modifiers: [.command, .shift])
        case .closePane: return Binding(key: .character("w"), modifiers: .command)
        case .commandPalette: return Binding(key: .character("p"), modifiers: .command)
        case .nextProject: return Binding(key: .character("]"), modifiers: [.command, .option])
        case .previousProject: return Binding(key: .character("["), modifiers: [.command, .option])
        case .selectWorkspaceNumber: return Binding(key: .number, modifiers: .command)
        case .nextTab: return Binding(key: .character("]"), modifiers: [.command, .shift])
        case .previousTab: return Binding(key: .character("["), modifiers: [.command, .shift])
        case .selectTabNumber: return Binding(key: .number, modifiers: .control)
        case .splitRight: return Binding(key: .character("d"), modifiers: .command)
        case .splitDown: return Binding(key: .character("d"), modifiers: [.command, .shift])
        case .splitLeft: return nil
        case .splitUp: return nil
        case .focusPaneLeft: return Binding(key: .special(.leftArrow), modifiers: [.command, .option])
        case .focusPaneRight: return Binding(key: .special(.rightArrow), modifiers: [.command, .option])
        case .focusPaneUp: return Binding(key: .special(.upArrow), modifiers: [.command, .option])
        case .focusPaneDown: return Binding(key: .special(.downArrow), modifiers: [.command, .option])
        case .focusPreviousPane: return Binding(key: .character("["), modifiers: .command)
        case .focusNextPane: return Binding(key: .character("]"), modifiers: .command)
        case .togglePaneZoom: return Binding(key: .special(.return), modifiers: [.command, .shift])
        case .equalizePanes: return Binding(key: .character("="), modifiers: [.command, .control])
        case .resizePaneUp: return Binding(key: .special(.upArrow), modifiers: [.command, .control])
        case .resizePaneDown: return Binding(key: .special(.downArrow), modifiers: [.command, .control])
        case .resizePaneLeft: return Binding(key: .special(.leftArrow), modifiers: [.command, .control])
        case .resizePaneRight: return Binding(key: .special(.rightArrow), modifiers: [.command, .control])
        case .toggleLeftSidebar: return Binding(key: .character("b"), modifiers: .command)
        case .toggleRightSidebar: return Binding(key: .character("b"), modifiers: [.command, .shift])
        case .toggleFilesPanel: return Binding(key: .character("e"), modifiers: [.command, .shift])
        case .toggleGitPanel: return Binding(key: .character("g"), modifiers: [.command, .shift])
        case .toggleInfoPanel: return Binding(key: .character("i"), modifiers: [.command, .shift])
        case .saveFile: return Binding(key: .character("s"), modifiers: .command)
        case .clearTerminal: return Binding(key: .character("k"), modifiers: .command)
        case .find: return Binding(key: .character("f"), modifiers: .command)
        case .findAndReplace: return Binding(key: .character("f"), modifiers: [.command, .option])
        case .findNext: return Binding(key: .character("g"), modifiers: .command)
        case .useSelectionForFind: return Binding(key: .character("e"), modifiers: .command)
        case .focusAddressBar: return Binding(key: .character("l"), modifiers: .command)
        case .reloadPage: return Binding(key: .character("r"), modifiers: .command)
        case .nextAgentAttention: return Binding(key: .character("a"), modifiers: [.command, .shift])
        }
    }
}

/// A key plus its modifiers, in a form that survives the config file and can be
/// handed to both AppKit and the SwiftUI menu bar.
struct KeyboardShortcutBinding: Hashable {
    /// Named keys Kero can bind. Deliberately limited to what a menu item can
    /// actually display and trigger: a shortcut the menu bar cannot express
    /// would be a setting that silently does nothing.
    enum Special: String, CaseIterable, Sendable {
        case leftArrow
        case rightArrow
        case upArrow
        case downArrow
        case `return`
        case tab
        case space
        case delete
        case escape
        case home
        case end
        case pageUp
        case pageDown

        var symbol: String {
            switch self {
            case .leftArrow: "←"
            case .rightArrow: "→"
            case .upArrow: "↑"
            case .downArrow: "↓"
            case .return: "↩"
            case .tab: "⇥"
            case .space: "Space"
            case .delete: "⌫"
            case .escape: "⎋"
            case .home: "↖"
            case .end: "↘"
            case .pageUp: "⇞"
            case .pageDown: "⇟"
            }
        }
    }

    enum Key: Equatable, Hashable, Sendable {
        case character(Character)
        case special(Special)
        /// The digit families: the key is 1…9, chosen by which item is invoked.
        case number
    }

    var key: Key
    var modifiers: NSEvent.ModifierFlags

    // `NSEvent.ModifierFlags` is an imported option set, so spell out the two
    // conformances rather than rely on synthesis over it.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.key == rhs.key && lhs.modifiers == rhs.modifiers
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.rawValue)
    }

    /// macOS reserves an unmodified key for typing. Command, Control, and
    /// Option are the ones a chord can start with; Shift alone is not enough.
    var isValid: Bool {
        !modifiers.intersection([.command, .control, .option]).isEmpty
    }

    // MARK: - Display

    var displayString: String {
        modifierSymbols + keySymbol
    }

    private var modifierSymbols: String {
        var result = ""
        if modifiers.contains(.control) { result += "⌃" }
        if modifiers.contains(.option) { result += "⌥" }
        if modifiers.contains(.shift) { result += "⇧" }
        if modifiers.contains(.command) { result += "⌘" }
        return result
    }

    private var keySymbol: String {
        switch key {
        case .character(let character): String(character).uppercased()
        case .special(let special): special.symbol
        case .number: String(localized: "1–9")
        }
    }

    // MARK: - Persistence

    /// `cmd+shift+d`, `ctrl+number`, `cmd+opt+left`.
    var storageString: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("cmd") }
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        switch key {
        case .character(let character): parts.append(String(character).lowercased())
        case .special(let special): parts.append(special.rawValue.lowercased())
        case .number: parts.append("number")
        }
        return parts.joined(separator: "+")
    }

    init(key: Key, modifiers: NSEvent.ModifierFlags) {
        self.key = key
        self.modifiers = modifiers
    }

    init?(storageString: String) {
        let parts = storageString
            .lowercased()
            .split(separator: "+")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard let name = parts.last else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command", "meta": modifiers.insert(.command)
            case "ctrl", "control": modifiers.insert(.control)
            case "opt", "option", "alt": modifiers.insert(.option)
            case "shift": modifiers.insert(.shift)
            default: return nil
            }
        }

        if name == "number" {
            key = .number
        } else if let special = Special.allCases.first(
            where: { $0.rawValue.lowercased() == name }
        ) {
            key = .special(special)
        } else if name.count == 1, let character = name.first {
            key = .character(character)
        } else {
            return nil
        }
        self.modifiers = modifiers
    }

    // MARK: - AppKit input

    /// Builds a binding from a recorded key event, or nil when the event is
    /// not a usable shortcut.
    init?(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(
            [.command, .control, .option, .shift]
        )
        guard !modifiers.intersection([.command, .control, .option]).isEmpty else {
            return nil
        }

        if let special = Self.special(forKeyCode: event.keyCode) {
            key = .special(special)
            self.modifiers = modifiers
            return
        }
        // `charactersIgnoringModifiers` is what makes ⌥ chords readable: with
        // Option applied, `characters` is whatever glyph the layout composes.
        guard let raw = event.charactersIgnoringModifiers?.lowercased(),
              raw.count == 1, let character = raw.first,
              character.isLetter || character.isNumber
                  || "-=[]\\;',./`".contains(character)
        else { return nil }
        key = .character(character)
        self.modifiers = modifiers
    }

    private static func special(forKeyCode code: UInt16) -> Special? {
        switch code {
        case 123: .leftArrow
        case 124: .rightArrow
        case 126: .upArrow
        case 125: .downArrow
        case 36, 76: .return
        case 48: .tab
        case 49: .space
        case 51, 117: .delete
        case 53: .escape
        case 115: .home
        case 119: .end
        case 116: .pageUp
        case 121: .pageDown
        default: nil
        }
    }

    // MARK: - SwiftUI menu bar

    /// SwiftUI's spelling of this key, or nil for the digit families, whose
    /// key comes from the item being built.
    var keyEquivalent: KeyEquivalent? {
        switch key {
        case .character(let character):
            return KeyEquivalent(character)
        case .number:
            return nil
        case .special(let special):
            switch special {
            case .leftArrow: return .leftArrow
            case .rightArrow: return .rightArrow
            case .upArrow: return .upArrow
            case .downArrow: return .downArrow
            case .return: return .return
            case .tab: return .tab
            case .space: return .space
            case .delete: return .delete
            case .escape: return .escape
            case .home: return .home
            case .end: return .end
            case .pageUp: return .pageUp
            case .pageDown: return .pageDown
            }
        }
    }

    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if modifiers.contains(.command) { result.insert(.command) }
        if modifiers.contains(.control) { result.insert(.control) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.shift) { result.insert(.shift) }
        return result
    }
}

/// The bindings in force, and the rules for changing them.
///
/// Kept separate from the menu bar so both the settings screen and the menus
/// read one answer, and so a conflict is a fact about the set rather than
/// something each menu discovers for itself.
struct KeyboardShortcutMap {
    /// Overrides only. An action absent here uses its default, which is what
    /// keeps a future change of default from being silently pinned by a config
    /// file the user never edited.
    private(set) var overrides: [KeyboardShortcutAction: KeyboardShortcutBinding?] = [:]

    init(overrides: [KeyboardShortcutAction: KeyboardShortcutBinding?] = [:]) {
        self.overrides = overrides
    }

    func binding(for action: KeyboardShortcutAction) -> KeyboardShortcutBinding? {
        if let override = overrides[action] { return override }
        return action.defaultBinding
    }

    func isDefault(_ action: KeyboardShortcutAction) -> Bool {
        overrides[action] == nil
    }

    var hasCustomBindings: Bool { !overrides.isEmpty }

    mutating func setBinding(
        _ binding: KeyboardShortcutBinding?, for action: KeyboardShortcutAction
    ) {
        if binding == action.defaultBinding {
            overrides[action] = nil
        } else {
            overrides[action] = .some(binding)
        }
    }

    mutating func reset(_ action: KeyboardShortcutAction) {
        overrides[action] = nil
    }

    mutating func resetAll() {
        overrides = [:]
    }

    /// Actions that share a binding with `action`.
    ///
    /// Two commands on one chord is not an error Kero can resolve for the user
    /// — only one of them will ever run — so it is surfaced rather than
    /// rejected, and the user decides which one to move.
    func conflicts(with action: KeyboardShortcutAction) -> [KeyboardShortcutAction] {
        guard let target = binding(for: action) else { return [] }
        return KeyboardShortcutAction.allCases.filter {
            $0 != action && binding(for: $0) == target
        }
    }

    var conflictingActions: Set<KeyboardShortcutAction> {
        var seen: [KeyboardShortcutBinding: [KeyboardShortcutAction]] = [:]
        for action in KeyboardShortcutAction.allCases {
            guard let binding = binding(for: action) else { continue }
            seen[binding, default: []].append(action)
        }
        return Set(seen.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    // MARK: - Persistence

    static let configPrefix = "keybind."

    static func load(from toml: [String: TOML.Value]) -> KeyboardShortcutMap {
        var overrides: [KeyboardShortcutAction: KeyboardShortcutBinding?] = [:]
        for action in KeyboardShortcutAction.allCases {
            guard let raw = toml[configPrefix + action.rawValue]?.string else { continue }
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.lowercased() == "none" {
                overrides[action] = .some(nil)
                continue
            }
            guard let binding = KeyboardShortcutBinding(storageString: trimmed) else {
                NSLog("kero: ignoring unreadable keybind \(action.rawValue) = \(raw)")
                continue
            }
            // A number family's key is fixed; a config that names another key
            // for it would produce a shortcut the menus cannot build.
            if action.isNumberFamily, binding.key != .number { continue }
            overrides[action] = .some(binding)
        }
        return KeyboardShortcutMap(overrides: overrides)
    }

    /// Only the differences from the defaults, so the file stays readable and
    /// tracks Kero's defaults as they change.
    var configLines: [String] {
        KeyboardShortcutAction.allCases.compactMap { action in
            guard let override = overrides[action] else { return nil }
            let value = override?.storageString ?? ""
            return "\(Self.configPrefix)\(action.rawValue) = \(TOML.quote(value))"
        }
    }
}

/// Applies a configured binding to a menu command.
///
/// Kero's menu bar is SwiftUI-owned, so this is where a configurable shortcut
/// has to land; the editor for these bindings is AppKit, like all new UI. An
/// unbound action keeps its menu item and simply has no key equivalent.
/// The map is passed in rather than read from `AppSettings` here, so the menu
/// bar's dependency on it is explicit and rebinding a key redraws the menus.
extension View {
    @ViewBuilder
    func keroShortcut(
        _ action: KeyboardShortcutAction, in map: KeyboardShortcutMap
    ) -> some View {
        if let binding = map.binding(for: action),
           let equivalent = binding.keyEquivalent {
            keyboardShortcut(equivalent, modifiers: binding.eventModifiers)
        } else {
            self
        }
    }

    /// The 1…9 families: same modifiers for every item, key from the index.
    @ViewBuilder
    func keroNumberShortcut(
        _ action: KeyboardShortcutAction, index: Int, in map: KeyboardShortcutMap
    ) -> some View {
        if let binding = map.binding(for: action),
           binding.key == .number, index >= 0, index < 9 {
            keyboardShortcut(
                KeyEquivalent(Character("\(index + 1)")),
                modifiers: binding.eventModifiers
            )
        } else {
            self
        }
    }
}
