//
//  KeroTransferOverlayView.swift
//  kero
//

import AppKit

/// The "something is happening to this pane" affordance, floated in the
/// pane's bottom-right corner.
///
/// An upload over someone's SSH connection can take seconds, and during those
/// seconds the paste has visibly done nothing. Two things are owed: that it is
/// working, and a way out — a transfer the user cannot stop is worse than one
/// that never started.
@MainActor
final class KeroTransferOverlayView: NSView {
    private let spinner = NSProgressIndicator()
    private let cancelButton = NSButton()
    private let messageLabel = NSTextField(labelWithString: "")
    private let background = NSVisualEffectView()

    var onCancel: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        background.material = .hudWindow
        background.blendingMode = .withinWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 15
        background.layer?.cornerCurve = .continuous
        background.translatesAutoresizingMaskIntoConstraints = false

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .circular
        cancelButton.isBordered = false
        cancelButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: String(localized: "Cancel")
        )
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.toolTip = String(localized: "Cancel")
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(background)
        addSubview(spinner)
        addSubview(messageLabel)
        addSubview(cancelButton)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            spinner.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),

            messageLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            messageLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            cancelButton.leadingAnchor.constraint(
                equalTo: messageLabel.trailingAnchor, constant: 8
            ),
            cancelButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            cancelButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            cancelButton.widthAnchor.constraint(equalToConstant: 16),
            cancelButton.heightAnchor.constraint(equalToConstant: 16),

            heightAnchor.constraint(equalToConstant: 30),
            widthAnchor.constraint(lessThanOrEqualToConstant: 320),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Shows the overlay in `host`'s bottom-right corner.
    func present(in host: NSView, message: String) {
        messageLabel.stringValue = message
        if superview !== host {
            removeFromSuperview()
            host.addSubview(self)
            NSLayoutConstraint.activate([
                trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -16),
                bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -16),
                leadingAnchor.constraint(
                    greaterThanOrEqualTo: host.leadingAnchor, constant: 16
                ),
            ])
        }
        isHidden = false
        spinner.startAnimation(nil)
    }

    /// Replaces the spinner with a message that stays put long enough to read.
    /// Failures are the only thing worth interrupting for; success is visible
    /// in the pane itself, where the path just arrived.
    func showFailure(_ message: String) {
        spinner.stopAnimation(nil)
        messageLabel.stringValue = message
        messageLabel.textColor = .systemOrange
        cancelButton.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: String(localized: "Dismiss")
        )
        cancelButton.toolTip = String(localized: "Dismiss")
    }

    func dismiss() {
        spinner.stopAnimation(nil)
        removeFromSuperview()
    }

    @objc private func cancelPressed() {
        onCancel?()
    }

    /// The pane underneath owns every click that is not on this control.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self || hit === background || hit === messageLabel ? nil : hit
    }
}
