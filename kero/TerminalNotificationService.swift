//
//  TerminalNotificationService.swift
//  kero
//

import AppKit
import Foundation
import UserNotifications

/// Delivers terminal notification requests through macOS Notification Center.
/// Authorization is intentionally deferred until a terminal first asks to
/// notify, rather than prompting at app launch. Each request carries the
/// emitting session's id so a click can reveal that tab.
final class TerminalNotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TerminalNotificationService()

    /// `userInfo` key for the emitting `TerminalSession.id`.
    static let sessionIDKey = "sessionID"

    private let center = UNUserNotificationCenter.current()
    private let authorizationOptions: UNAuthorizationOptions = [.alert, .sound]
    private var isRequestingAuthorization = false
    private var pending: (message: String, title: String?, sessionID: UUID?)?

    /// Mirrors the "Play a sound" setting. Held here rather than read from
    /// `AppSettings` at delivery time because delivery happens inside
    /// Notification Center's own callbacks; the setting pushes changes in.
    var isSoundEnabled = true

    func configure() {
        center.delegate = self
        isSoundEnabled = AppSettings.shared.notificationSound
        // Existing installs may have been authorized for alerts only (before
        // sound support). Re-request so System Settings gains the sound toggle
        // and delivered notifications can play audio — no prompt when already
        // authorized.
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.upgradeSoundAuthorizationIfNeeded(settings)
            }
        }
    }

    /// `title` names what raised this — for an agent, the title its own UI is
    /// showing, which is how the user recognizes which of several panes it is.
    /// Falls back to Kero when a terminal has nothing useful to say.
    func post(message: String, title: String? = nil, sessionID: UUID? = nil) {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.checkAuthorization(for: message, title: title, sessionID: sessionID)
        }
    }

    private func checkAuthorization(
        for message: String, title: String?, sessionID: UUID?
    ) {
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                self?.handle(
                    settings,
                    message: message,
                    title: title,
                    sessionID: sessionID
                )
            }
        }
    }

    private func handle(
        _ settings: UNNotificationSettings,
        message: String,
        title: String?,
        sessionID: UUID?
    ) {
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            if settings.soundSetting == .notSupported {
                // Authorized without sound — upgrade options before delivering.
                requestAuthorization(message: message, title: title, sessionID: sessionID)
            } else {
                deliver(message, title: title, sessionID: sessionID)
            }
        case .notDetermined:
            // A terminal can emit OSC 9 repeatedly while the permission sheet
            // is open. Keep only the latest request so an untrusted process
            // cannot grow an unbounded queue or release a banner storm.
            requestAuthorization(message: message, title: title, sessionID: sessionID)
        case .denied:
            break
        @unknown default:
            break
        }
    }

    /// When already authorized for alerts only, `soundSetting` is
    /// `.notSupported` and Settings hides "Play sound for notifications".
    /// Requesting `.sound` again registers the type without a second prompt.
    private func upgradeSoundAuthorizationIfNeeded(_ settings: UNNotificationSettings) {
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            guard settings.soundSetting == .notSupported else { return }
            requestAuthorization(message: nil, title: nil, sessionID: nil)
        default:
            break
        }
    }

    private func requestAuthorization(
        message: String?, title: String?, sessionID: UUID?
    ) {
        if let message {
            pending = (message, title, sessionID)
        }
        guard !isRequestingAuthorization else { return }

        isRequestingAuthorization = true
        center.requestAuthorization(options: authorizationOptions) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRequestingAuthorization = false

                let pending = self.pending
                self.pending = nil

                if let error {
                    NSLog("Kero: notification authorization failed: %@", String(describing: error))
                }
                if granted, let pending {
                    self.deliver(
                        pending.message,
                        title: pending.title,
                        sessionID: pending.sessionID
                    )
                }
            }
        }
    }

    private func deliver(_ message: String, title: String?, sessionID: UUID?) {
        let content = UNMutableNotificationContent()
        let named = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        content.title = named?.isEmpty == false ? named! : "Kero"
        content.body = message
        content.sound = isSoundEnabled ? .default : nil
        if let sessionID {
            content.userInfo = [Self.sessionIDKey: sessionID.uuidString]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                NSLog("Kero: terminal notification failed: %@", String(describing: error))
            }
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Kero is frontmost here, so this is the path that decides whether a
        // finished agent is audible while the user is looking at another pane.
        completionHandler(isSoundEnabled ? [.banner, .list, .sound] : [.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionID = (userInfo[Self.sessionIDKey] as? String)
            .flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async {
            if let sessionID {
                TerminalManager.revealSession(id: sessionID)
            } else {
                NSApp.activate()
            }
            completionHandler()
        }
    }
}
