//
//  ShellClient.swift
//  CodeEdit
//
//  Created by Matthijs Eikelenboom on 25/11/2022.
//

import Combine
import Foundation

/// Errors that can occur during shell operations
enum ShellClientError: LocalizedError {
    case failedToDecodeOutput
    case taskTerminated(code: Int, output: String)

    var errorDescription: String? {
        switch self {
        case .failedToDecodeOutput:
            return "Failed to decode shell command output."
        case .taskTerminated(let code, let output):
            let trimmedOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedOutput.isEmpty
                ? "Shell command exited with status code \(code)."
                : trimmedOutput
        }
    }
}

/// Shell Client
/// Run commands in shell
class ShellClient {
    typealias EnvironmentProvider = () -> [String: String]

    private static let cachedLoginShellEnvironment = resolveLoginShellEnvironment()
    private let nonLoginShellEnvironmentProvider: EnvironmentProvider

    init(
        nonLoginShellEnvironmentProvider: @escaping EnvironmentProvider = {
            ShellClient.cachedLoginShellEnvironment
        }
    ) {
        self.nonLoginShellEnvironmentProvider = nonLoginShellEnvironmentProvider
    }

    /// Resolves the environment produced by the user's interactive login shell while discarding any
    /// profile output. Markers make the environment payload unambiguous even when profile scripts print.
    static func resolveLoginShellEnvironment(
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        let startMarker = "\0CODEEDIT_ENVIRONMENT_START\0"
        let endMarker = "\0CODEEDIT_ENVIRONMENT_END\0"
        let command = """
        /usr/bin/printf '\\0CODEEDIT_ENVIRONMENT_START\\0'
        /usr/bin/env -0
        /usr/bin/printf '\\0CODEEDIT_ENVIRONMENT_END\\0'
        """
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lic", command]
        process.environment = baseEnvironment
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            let output = outputPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0,
                  let startData = startMarker.data(using: .utf8),
                  let endData = endMarker.data(using: .utf8),
                  let startRange = output.range(of: startData),
                  let endRange = output.range(
                    of: endData,
                    options: [],
                    in: startRange.upperBound..<output.endIndex
                  ) else {
                return baseEnvironment
            }

            var environment: [String: String] = [:]
            let payload = output[startRange.upperBound..<endRange.lowerBound]
            for item in payload.split(separator: 0) {
                guard let entry = String(data: Data(item), encoding: .utf8),
                      let separator = entry.firstIndex(of: "=") else {
                    continue
                }
                environment[String(entry[..<separator])] = String(entry[entry.index(after: separator)...])
            }
            return environment.isEmpty ? baseEnvironment : environment
        } catch {
            return baseEnvironment
        }
    }

    /// Generate a process and pipe to run commands
    /// - Parameters:
    ///   - args: commands to run
    ///   - useLoginShell: whether to run the command in an interactive login shell, sourcing
    ///                    the user's shell profile files. Defaults to `true`.
    /// - Returns: command output
    func generateProcessAndPipe(_ args: [String], useLoginShell: Bool = true) -> (Process, Pipe) {
        // With `useLoginShell`, run in an 'interactive' login shell. Because we're passing -c here
        // it won't actually be interactive but it will source the user's zshrc file as well as the
        // zshprofile. Otherwise pass only -c, so profile files are not sourced and any output they
        // echo cannot pollute the command's output (see #2151).
        var arguments = useLoginShell ? ["-lic"] : ["-c"]
        arguments.append(contentsOf: args)
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.arguments = arguments
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        if !useLoginShell {
            task.environment = nonLoginShellEnvironmentProvider()
        }
        return (task, pipe)
    }

    /// Cancellable tasks
    var cancellables: [UUID: AnyCancellable] = [:]

    /// Run a command
    /// - Parameters:
    ///   - args: command to run
    ///   - useLoginShell: whether to run the command in a login shell, sourcing the user's
    ///                    shell profile files. Defaults to `true`.
    ///   - requireSuccessfulExit: whether a non-zero process status should throw an error.
    /// - Returns: command output
    @discardableResult
    func run(
        _ args: String...,
        useLoginShell: Bool = true,
        requireSuccessfulExit: Bool = false
    ) throws -> String {
        let (task, pipe) = generateProcessAndPipe(args, useLoginShell: useLoginShell)
        try task.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let output = String(bytes: data, encoding: .utf8) else {
            throw ShellClientError.failedToDecodeOutput
        }
        if requireSuccessfulExit && task.terminationStatus != 0 {
            throw ShellClientError.taskTerminated(code: Int(task.terminationStatus), output: output)
        }
        return output
    }

    /// Run a command with Publisher
    /// - Parameter args: command to run
    /// - Returns: command output
    @discardableResult
    func runLive(_ args: String...) -> AnyPublisher<String, Never> {
        let subject = PassthroughSubject<String, Never>()
        let (task, pipe) = generateProcessAndPipe(args)
        let outputHandler = pipe.fileHandleForReading
        // wait for the data to come in and then notify
        // the Notification with Name: `NSFileHandleDataAvailable`
        outputHandler.waitForDataInBackgroundAndNotify()
        let id = UUID()
        self.cancellables[id] = NotificationCenter
            .default
            .publisher(for: .NSFileHandleDataAvailable, object: outputHandler)
            .sink { _ in
                let data = outputHandler.availableData
                guard !data.isEmpty else {
                    // if no data is available anymore
                    // we should cancel this cancellable
                    // and mark the subject as finished
                    self.cancellables.removeValue(forKey: id)
                    subject.send(completion: .finished)
                    return
                }
                guard let output = String(bytes: data, encoding: .utf8) else {
                    subject.send(completion: .finished)
                    return
                }
                output.split(whereSeparator: \.isNewline)
                    .forEach({ subject.send(String($0)) })
                outputHandler.waitForDataInBackgroundAndNotify()
            }
        task.launch()
        return subject.eraseToAnyPublisher()
    }

    /// Run a command with AsyncStream
    /// - Parameters:
    ///   - args: command to run
    ///   - useLoginShell: whether to run the command in a login shell, sourcing the user's
    ///                    shell profile files. Defaults to `true`.
    /// - Returns: async stream of command output
    func runAsync(_ args: String..., useLoginShell: Bool = true) -> AsyncThrowingStream<String, Error> {
        let (task, pipe) = generateProcessAndPipe(args, useLoginShell: useLoginShell)

        return AsyncThrowingStream { continuation in
            pipe.fileHandleForReading.readabilityHandler = { [unowned pipe] fileHandle in
                let data = fileHandle.availableData
                if !data.isEmpty {
                    guard let output = String(bytes: data, encoding: .utf8) else {
                        continuation.finish(throwing: ShellClientError.failedToDecodeOutput)
                        return
                    }
                    output.split(whereSeparator: \.isNewline)
                        .forEach({ continuation.yield(String($0)) })
                } else {
                    if !task.isRunning && task.terminationStatus != 0 {
                        continuation.finish(
                            throwing: ShellClientError.taskTerminated(
                                code: Int(task.terminationStatus),
                                output: ""
                            )
                        )
                    } else {
                        continuation.finish()
                    }

                    // Clean up the handler to prevent repeated calls and continuation finishes for the same
                    // process.
                    pipe.fileHandleForReading.readabilityHandler = nil
                }
            }

            do {
                try task.run()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Shell client
    /// - Returns: description
    static func live() -> ShellClient {
        return ShellClient()
    }
}
