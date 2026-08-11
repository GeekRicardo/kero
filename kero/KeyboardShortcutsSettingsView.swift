//
//  KeyboardShortcutsSettingsView.swift
//  kero
//

import AppKit
import SwiftUI

/// Records one key combination.
///
/// Command chords never arrive as `keyDown` while a menu bar is installed —
/// `NSMenu` claims them first — so the capture happens in
/// `performKeyEquivalent(with:)`, which runs before that. Nothing is captured
/// until the field is deliberately armed, so arming is the whole consent story:
/// while it is off, ⌘W still closes the pane.
@MainActor
final class ShortcutRecorderView: NSView {
    var binding: KeyboardShortcutBinding? {
        didSet { needsDisplay = true }
    }

    /// Number families bind modifiers only; the key is the digit pressed.
    var acceptsModifiersOnly = false

    var onChange: ((KeyboardShortcutBinding?) -> Void)?

    private(set) var isRecording = false {
        didSet { needsDisplay = true }
    }

    private let cornerRadius: CGFloat = 6

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 120, height: 22)
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: cornerRadius,
            yRadius: cornerRadius
        )
        (isRecording
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.controlColor).setFill()
        path.fill()
        (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isRecording ? 2 : 1
        path.stroke()

        let text: String
        let color: NSColor
        if isRecording {
            text = String(localized: "Type shortcut…")
            color = .secondaryLabelColor
        } else if let binding {
            text = binding.displayString
            color = .labelColor
        } else {
            text = String(localized: "None")
            color = .tertiaryLabelColor
        }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        (text as NSString).draw(
            at: NSPoint(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2
            ),
            withAttributes: attributes
        )
    }

    override func mouseDown(with event: NSEvent) {
        guard !isRecording else {
            endRecording()
            return
        }
        window?.makeFirstResponder(self)
        isRecording = true
    }

    override func resignFirstResponder() -> Bool {
        endRecording()
        return true
    }

    /// Runs ahead of the menu bar, which is the only way ⌘-chords can be
    /// recorded at all.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        return consume(event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, consume(event) else {
            super.keyDown(with: event)
            return
        }
    }

    private func consume(_ event: NSEvent) -> Bool {
        // Escape leaves the existing binding alone; Delete clears it. Both are
        // editor gestures, so neither can be bound here.
        if event.keyCode == 53 {
            endRecording()
            return true
        }
        if event.keyCode == 51 || event.keyCode == 117,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            apply(nil)
            return true
        }
        if acceptsModifiersOnly {
            let modifiers = event.modifierFlags.intersection(
                [.command, .control, .option, .shift]
            )
            guard !modifiers.intersection([.command, .control, .option]).isEmpty else {
                NSSound.beep()
                return true
            }
            apply(KeyboardShortcutBinding(key: .number, modifiers: modifiers))
            return true
        }
        guard let recorded = KeyboardShortcutBinding(event: event) else {
            // An unmodified key belongs to whatever has focus, so refuse it
            // rather than quietly bind something that can never fire.
            NSSound.beep()
            return true
        }
        apply(recorded)
        return true
    }

    private func apply(_ value: KeyboardShortcutBinding?) {
        binding = value
        endRecording()
        onChange?(value)
    }

    private func endRecording() {
        guard isRecording else { return }
        isRecording = false
    }
}

/// The Keyboard settings page: every rebindable command, grouped the way the
/// menus are, with its current key equivalent, a revert control, and a plain
/// statement whenever two commands would answer to the same chord.
@MainActor
final class KeyboardShortcutsSettingsView: NSView {
    private struct Row {
        let action: KeyboardShortcutAction
        let recorder: ShortcutRecorderView
        let revert: NSButton
        let conflict: NSTextField
    }

    private let scrollView = NSScrollView()
    private let contentStack = NSStackView()
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let restoreButton = NSButton(
        title: String(localized: "Restore Defaults"),
        target: nil,
        action: nil
    )
    private var rows: [Row] = []

    var map = KeyboardShortcutMap() {
        didSet { refresh() }
    }

    /// Called with the whole map so the caller persists one coherent state.
    var onChange: ((KeyboardShortcutMap) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 6
        contentStack.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        buildRows()

        let documentView = NSView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(contentStack)

        scrollView.documentView = documentView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        restoreButton.bezelStyle = .rounded
        restoreButton.controlSize = .small
        restoreButton.target = self
        restoreButton.action = #selector(restoreDefaults)
        restoreButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(summaryLabel)
        addSubview(restoreButton)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: 320),

            contentStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            contentStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            contentStack.topAnchor.constraint(equalTo: documentView.topAnchor),
            contentStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            documentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            summaryLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: restoreButton.leadingAnchor, constant: -12
            ),

            restoreButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            restoreButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 4),
            restoreButton.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            summaryLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 372)
    }

    private func buildRows() {
        for group in KeyboardShortcutAction.Group.allCases {
            let actions = KeyboardShortcutAction.allCases.filter { $0.group == group }
            guard !actions.isEmpty else { continue }

            let header = NSTextField(labelWithString: group.title)
            header.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
            header.textColor = .secondaryLabelColor
            contentStack.addArrangedSubview(header)
            contentStack.setCustomSpacing(4, after: header)

            for action in actions {
                let row = makeRow(for: action)
                contentStack.addArrangedSubview(row.container)
                row.container.widthAnchor.constraint(
                    equalTo: contentStack.widthAnchor,
                    constant: -(contentStack.edgeInsets.left + contentStack.edgeInsets.right)
                ).isActive = true
                rows.append(row.model)
            }
            if let last = contentStack.arrangedSubviews.last {
                contentStack.setCustomSpacing(14, after: last)
            }
        }
    }

    private func makeRow(
        for action: KeyboardShortcutAction
    ) -> (container: NSView, model: Row) {
        let title = NSTextField(labelWithString: action.title)
        title.font = .systemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let conflict = NSTextField(labelWithString: "")
        conflict.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        conflict.textColor = .systemOrange
        conflict.lineBreakMode = .byTruncatingTail
        conflict.isHidden = true
        conflict.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [title, conflict])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.detachesHiddenViews = true

        let recorder = ShortcutRecorderView(frame: .zero)
        recorder.acceptsModifiersOnly = action.isNumberFamily
        recorder.onChange = { [weak self] value in
            self?.updateBinding(value, for: action)
        }
        recorder.translatesAutoresizingMaskIntoConstraints = false
        recorder.setAccessibilityLabel(action.title)

        let revert = NSButton(
            image: NSImage(
                systemSymbolName: "arrow.uturn.backward",
                accessibilityDescription: String(localized: "Restore Default")
            ) ?? NSImage(),
            target: self,
            action: #selector(revertRow(_:))
        )
        revert.bezelStyle = .accessoryBarAction
        revert.isBordered = false
        revert.controlSize = .small
        revert.toolTip = String(localized: "Restore Default")

        let container = NSStackView(views: [labels, recorder, revert])
        container.orientation = .horizontal
        container.alignment = .centerY
        container.spacing = 8
        container.distribution = .fill
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            recorder.widthAnchor.constraint(equalToConstant: 120),
            recorder.heightAnchor.constraint(equalToConstant: 22),
        ])

        let model = Row(action: action, recorder: recorder, revert: revert, conflict: conflict)
        revert.tag = KeyboardShortcutAction.allCases.firstIndex(of: action) ?? 0
        return (container, model)
    }

    @objc private func revertRow(_ sender: NSButton) {
        let all = KeyboardShortcutAction.allCases
        guard all.indices.contains(sender.tag) else { return }
        var updated = map
        updated.reset(all[sender.tag])
        map = updated
        onChange?(updated)
    }

    @objc private func restoreDefaults() {
        var updated = map
        updated.resetAll()
        map = updated
        onChange?(updated)
    }

    private func updateBinding(
        _ binding: KeyboardShortcutBinding?,
        for action: KeyboardShortcutAction
    ) {
        var updated = map
        updated.setBinding(binding, for: action)
        map = updated
        onChange?(updated)
    }

    private func refresh() {
        let conflicting = map.conflictingActions
        for row in rows {
            row.recorder.binding = map.binding(for: row.action)
            row.revert.isHidden = map.isDefault(row.action)

            let others = conflicting.contains(row.action)
                ? map.conflicts(with: row.action)
                : []
            if others.isEmpty {
                row.conflict.isHidden = true
            } else {
                row.conflict.stringValue = String(
                    localized: "Also assigned to \(others.map(\.title).joined(separator: ", "))",
                    comment: "Warning shown when two commands share one keyboard shortcut."
                )
                row.conflict.isHidden = false
            }
        }

        if conflicting.isEmpty {
            summaryLabel.stringValue = String(
                localized: "Number shortcuts use the digits 1 through 9."
            )
            summaryLabel.textColor = .secondaryLabelColor
        } else {
            // Only one command can win a chord, and Kero cannot know which one
            // was meant — so say it plainly instead of silently picking.
            summaryLabel.stringValue = String(
                localized: "\(conflicting.count) commands share a shortcut with another command. Only one of each pair will run."
            )
            summaryLabel.textColor = .systemOrange
        }
    }
}

/// SwiftUI only mounts the native page inside the pre-existing Settings form.
struct KeyboardShortcutsSettingsSection: NSViewRepresentable {
    let map: KeyboardShortcutMap
    let onChange: (KeyboardShortcutMap) -> Void

    func makeNSView(context: Context) -> KeyboardShortcutsSettingsView {
        let view = KeyboardShortcutsSettingsView(frame: .zero)
        view.onChange = onChange
        view.map = map
        return view
    }

    func updateNSView(_ view: KeyboardShortcutsSettingsView, context: Context) {
        view.onChange = onChange
        if view.map.overrides != map.overrides {
            view.map = map
        }
    }
}
