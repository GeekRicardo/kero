//
//  ShortcutHintView.swift
//  kero
//

import AppKit
import Combine
import SwiftUI

/// Which modifier keys are held right now.
///
/// One monitor for the whole app: the alternative is every row that wants to
/// reveal a hint installing its own event handler, which on a strip of tabs
/// and projects means a dozen handlers competing for the same event.
@MainActor
final class KeyboardModifierMonitor: nonisolated ObservableObject {
    static let shared = KeyboardModifierMonitor()

    @Published private(set) var flags: NSEvent.ModifierFlags = []

    private var monitor: Any?
    private var resignObserver: NSObjectProtocol?

    private init() {
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown, .keyUp]
        ) { event in
            // Structurally main-thread: AppKit dispatches this from its own
            // event loop. See `assumeMainActor`.
            assumeMainActor { KeyboardModifierMonitor.shared.update(event.modifierFlags) }
            return event
        }

        // Holding a modifier and switching apps never delivers the key-up, so
        // the hints would stay on screen over a window nobody is typing into.
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            assumeMainActor { KeyboardModifierMonitor.shared.update([]) }
        }
    }

    private func update(_ raw: NSEvent.ModifierFlags) {
        let next = raw.intersection([.command, .control, .option, .shift])
        guard next != flags else { return }
        flags = next
    }
}

/// The key equivalent for one command, shown only while its modifiers are held.
///
/// Kero's shortcuts are configurable, so a hint painted into the layout as a
/// literal goes stale the moment someone rebinds it — which is exactly what a
/// hint is for. This reads the live binding instead, and stays out of the way
/// until the user reaches for the modifier.
@MainActor
final class ShortcutHintView: NSView {
    private var action: KeyboardShortcutAction?
    private var index: Int?
    private var fontSize: CGFloat = 10
    private var label: String?
    private var cancellables: Set<AnyCancellable> = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // The view subscribes rather than being re-rendered from above: a
        // modifier press must not invalidate the whole sidebar or tab strip.
        KeyboardModifierMonitor.shared.$flags
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &cancellables)
        AppSettings.shared.$shortcuts
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            .store(in: &cancellables)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        action: KeyboardShortcutAction,
        index: Int?,
        fontSize: CGFloat
    ) {
        guard self.action != action || self.index != index
            || self.fontSize != fontSize else { return }
        self.action = action
        self.index = index
        self.fontSize = fontSize
        refresh()
    }

    override var isFlipped: Bool { true }

    override var intrinsicContentSize: NSSize {
        guard let label else { return NSSize(width: 0, height: 0) }
        return (label as NSString).size(withAttributes: attributes)
    }

    private var attributes: [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: fontSize),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
    }

    private func refresh() {
        let next = resolvedLabel()
        guard next != label else { return }
        label = next
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    /// The text to show, or nil when the command is unbound or its modifiers
    /// are not currently held.
    private func resolvedLabel() -> String? {
        guard let action,
              let binding = AppSettings.shared.shortcuts.binding(for: action),
              binding.isValid,
              KeyboardModifierMonitor.shared.flags == binding.modifiers
        else { return nil }

        switch binding.key {
        case .number:
            // A number family names one command per digit; this row is one of
            // them, and beyond the ninth there is no key to show.
            guard let index, (0..<9).contains(index) else { return nil }
            return binding.displayString.replacingOccurrences(
                of: String(localized: "1–9"), with: "\(index + 1)"
            )
        case .character, .special:
            return binding.displayString
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let label else { return }
        let text = label as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(
                x: bounds.width - size.width,
                y: (bounds.height - size.height) / 2
            ),
            withAttributes: attributes
        )
    }
}

/// SwiftUI only mounts the native hint; everything it reacts to is AppKit.
struct ShortcutHintRepresentable: NSViewRepresentable {
    let action: KeyboardShortcutAction
    /// Position within a 1–9 family, or nil for a single-key command.
    var index: Int?
    var fontSize: CGFloat = 10

    func makeNSView(context: Context) -> ShortcutHintView {
        let view = ShortcutHintView(frame: .zero)
        view.configure(action: action, index: index, fontSize: fontSize)
        return view
    }

    func updateNSView(_ view: ShortcutHintView, context: Context) {
        view.configure(action: action, index: index, fontSize: fontSize)
    }
}
