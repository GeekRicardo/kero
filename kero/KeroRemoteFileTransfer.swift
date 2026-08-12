//
//  KeroRemoteFileTransfer.swift
//  kero
//

import AppKit
import Darwin
import Foundation

/// The `ssh` session a pane is currently sitting in, reconstructed from the
/// running client's own command line.
///
/// A program on the far side of an SSH connection cannot see the Mac's
/// clipboard, so pasting an image into it fails no matter how the terminal
/// encodes the paste. The only thing that helps is putting the bytes on the
/// remote host and handing over a path — which means Kero has to reach that
/// host the same way the user already did: same destination, same port, same
/// key, same jump host, same config.
struct KeroSSHSession: Equatable {
    let destination: String
    let port: Int?
    let identityFile: String?
    let configFile: String?
    let jumpHost: String?
    let controlPath: String?
    let loginName: String?
    let options: [String]
    let useIPv4: Bool
    let useIPv6: Bool

    /// Recognizes an `ssh` client running as the pane's foreground job.
    ///
    /// Deliberately only the foreground process: that is the connection the
    /// user is typing into. A background `ssh` tunnel elsewhere in the tree is
    /// not where this paste is going.
    static func detect(foregroundPID: pid_t?) -> KeroSSHSession? {
        guard let foregroundPID, foregroundPID > 1,
              let arguments = processArguments(pid: foregroundPID),
              let first = arguments.first
        else { return nil }
        let executable = processExecutablePath(pid: foregroundPID)
        let names = [first, executable]
            .compactMap { $0 }
            .map { ($0 as NSString).lastPathComponent }
        guard names.contains("ssh") else { return nil }
        return parse(arguments: Array(arguments.dropFirst()))
    }

    /// Options that take a separate value. Anything here consumes the next
    /// argument, so the destination is not mistaken for one of their values.
    private static let valueOptions: Set<Character> = [
        "B", "b", "c", "D", "E", "e", "F", "I", "i", "J", "L", "l",
        "m", "O", "o", "P", "p", "Q", "R", "S", "W", "w",
    ]

    static func parse(arguments: [String]) -> KeroSSHSession? {
        var destination: String?
        var port: Int?
        var identityFile: String?
        var configFile: String?
        var jumpHost: String?
        var controlPath: String?
        var loginName: String?
        var options: [String] = []
        var useIPv4 = false
        var useIPv6 = false

        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard argument.hasPrefix("-"), argument.count > 1 else {
                // The first bare word is the destination; everything after it
                // is a command for the remote host, not for us.
                destination = argument
                break
            }
            if argument == "--" {
                index += 1
                if index < arguments.count { destination = arguments[index] }
                break
            }

            // Short options cluster (`-4tv`), and the last one may take a
            // value either attached (`-p22`) or separate (`-p 22`).
            var characters = Array(argument.dropFirst())
            var consumedNext = false
            while let flag = characters.first {
                characters.removeFirst()
                guard valueOptions.contains(flag) else {
                    switch flag {
                    case "4": useIPv4 = true
                    case "6": useIPv6 = true
                    default: break
                    }
                    continue
                }
                let value: String?
                if !characters.isEmpty {
                    value = String(characters)
                    characters.removeAll()
                } else if index + 1 < arguments.count {
                    value = arguments[index + 1]
                    consumedNext = true
                } else {
                    value = nil
                }
                guard let value else { break }
                switch flag {
                case "p": port = Int(value)
                case "i": identityFile = value
                case "F": configFile = value
                case "J": jumpHost = value
                case "l": loginName = value
                case "o":
                    options.append(value)
                    let lowered = value.lowercased()
                    if lowered.hasPrefix("controlpath=") {
                        controlPath = String(value.dropFirst("ControlPath=".count))
                    }
                default:
                    break
                }
                break
            }
            index += consumedNext ? 2 : 1
        }

        guard let destination, !destination.isEmpty,
              !destination.hasPrefix("-")
        else { return nil }
        return KeroSSHSession(
            destination: destination,
            port: port,
            identityFile: identityFile,
            configFile: configFile,
            jumpHost: jumpHost,
            controlPath: controlPath,
            loginName: loginName,
            options: options,
            useIPv4: useIPv4,
            useIPv6: useIPv6
        )
    }

    /// `scp` spelled with this session's connection settings.
    ///
    /// `BatchMode=yes` is not optional here. Kero has no way to answer a
    /// password or MFA prompt — the prompt would appear on a pipe nobody is
    /// reading — so an authentication that cannot complete unattended must
    /// fail immediately and say so, rather than hang holding a spinner.
    func scpArguments(localPath: String, remotePath: String) -> [String] {
        var arguments = ["-q", "-o", "BatchMode=yes"]
        if let port { arguments += ["-P", String(port)] }
        if let identityFile { arguments += ["-i", identityFile] }
        if let configFile { arguments += ["-F", configFile] }
        if let jumpHost { arguments += ["-J", jumpHost] }
        if useIPv4 { arguments.append("-4") }
        if useIPv6 { arguments.append("-6") }
        for option in options { arguments += ["-o", option] }
        arguments.append(localPath)
        arguments.append("\(hostSpecifier):\(remotePath)")
        return arguments
    }

    /// `-l user` and a bare host mean the same thing as `user@host`, and scp's
    /// target argument only understands the second spelling.
    private var hostSpecifier: String {
        guard let loginName, !destination.contains("@") else { return destination }
        return "\(loginName)@\(destination)"
    }

}

/// One in-flight upload. Held by the pane so the user can cancel it.
@MainActor
final class KeroRemoteUpload {
    enum Failure: Error, LocalizedError {
        case cancelled
        case tooLarge
        case unreadableClipboard
        case authenticationRequired
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled:
                String(localized: "Upload cancelled.")
            case .tooLarge:
                String(localized: "That image is larger than Kero will upload.")
            case .unreadableClipboard:
                String(localized: "The clipboard image could not be read.")
            case .authenticationRequired:
                String(
                    localized: "The remote host asked for a password, which Kero cannot answer. Reconnect with a key or an SSH ControlMaster connection and try again."
                )
            case .failed(let message):
                message
            }
        }
    }

    /// Beyond this, uploading over someone's SSH connection stops being a
    /// paste and starts being a file transfer they did not ask for.
    static let maximumBytes = 10 * 1024 * 1024

    /// Beyond this the connection is not slow, it is wrong.
    private static let timeout: TimeInterval = 60

    private var process: Process?
    private var errorPipe: Pipe?
    private var poll: Timer?
    private var deadline: Date?
    private var localURL: URL?
    private var remotePath: String?
    private var completion: ((Result<String, Failure>) -> Void)?
    private(set) var isCancelled = false

    /// Writes the clipboard image to a temporary file, uploads it, and returns
    /// the path it now has on the remote host.
    func start(
        session: KeroSSHSession,
        imageData: Data,
        fileExtension: String,
        completion: @escaping @MainActor (Result<String, Failure>) -> Void
    ) {
        guard imageData.count <= Self.maximumBytes else {
            completion(.failure(.tooLarge))
            return
        }
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kero-paste-\(UUID().uuidString).\(fileExtension)")
        do {
            try imageData.write(to: localURL, options: .atomic)
        } catch {
            completion(.failure(.failed(error.localizedDescription)))
            return
        }

        // `/tmp` is the one directory that reliably exists and is writable on
        // an arbitrary host; scp cannot create one.
        let remotePath = "/tmp/kero-paste-\(UUID().uuidString).\(fileExtension)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/scp")
        process.arguments = session.scpArguments(
            localPath: localURL.path, remotePath: remotePath
        )
        let errorPipe = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: localURL)
            completion(.failure(.failed(error.localizedDescription)))
            return
        }

        self.process = process
        self.errorPipe = errorPipe
        self.localURL = localURL
        self.remotePath = remotePath
        self.completion = completion
        deadline = Date().addingTimeInterval(Self.timeout)

        // Polled on the main actor rather than waited on a background queue:
        // everything this has to touch afterwards — the pane, its overlay, the
        // paste itself — is main-actor state, and a file upload does not care
        // about a tenth of a second either way.
        let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else {
                    timer.invalidate()
                    return
                }
                self.checkProgress()
            }
        }
        RunLoop.main.add(poll, forMode: .common)
        self.poll = poll
    }

    private func checkProgress() {
        guard let process else {
            finish(.failure(.cancelled))
            return
        }
        if process.isRunning {
            guard let deadline, Date() >= deadline else { return }
            isCancelled = true
            process.terminate()
            finish(.failure(.failed(
                String(localized: "The upload timed out.")
            )))
            return
        }

        let status = process.terminationStatus
        // `scp -q` is nearly silent, so this stays small; the process has
        // already exited, so nothing can be blocked on the pipe.
        let errorText = String(
            decoding: errorPipe?.fileHandleForReading.availableData ?? Data(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        if isCancelled {
            finish(.failure(.cancelled))
        } else if status == 0, let remotePath {
            finish(.success(remotePath))
        } else if errorText.localizedCaseInsensitiveContains("permission denied")
            || errorText.localizedCaseInsensitiveContains("batch mode")
            || errorText.localizedCaseInsensitiveContains("publickey") {
            finish(.failure(.authenticationRequired))
        } else {
            finish(.failure(.failed(
                errorText.isEmpty
                    ? String(localized: "The upload failed.")
                    : errorText
            )))
        }
    }

    private func finish(_ result: Result<String, Failure>) {
        poll?.invalidate()
        poll = nil
        if let localURL { try? FileManager.default.removeItem(at: localURL) }
        localURL = nil
        process = nil
        errorPipe = nil
        let completion = self.completion
        self.completion = nil
        completion?(result)
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        process?.terminate()
        // The poll reports it; terminate is asynchronous and the exit status
        // is still worth reading before the temporary file goes away.
    }
}

/// Pulls a pasteable image out of the clipboard as PNG bytes.
enum KeroClipboardImage {
    /// PNG data and the extension to give it, or nil when the clipboard holds
    /// no image Kero can decode.
    static func pngData(from pasteboard: NSPasteboard) -> (data: Data, fileExtension: String)? {
        if let data = pasteboard.data(forType: .png) {
            return (data, "png")
        }
        // Screenshots and many apps put TIFF on the pasteboard; re-encode so
        // the remote side gets something every tool reads.
        guard let tiff = pasteboard.data(forType: .tiff),
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:])
        else { return nil }
        return (png, "png")
    }

    static func hasImage(_ pasteboard: NSPasteboard) -> Bool {
        pasteboard.canReadObject(forClasses: [NSImage.self], options: nil)
    }
}
