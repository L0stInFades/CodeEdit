//
//  ShellClientTests.swift
//  CodeEditTests
//

import Foundation
import Testing
@testable import CodeEdit

@Suite(.serialized)
struct ShellClientTests {
    @Test
    func resolvesLoginEnvironmentWithoutProfileNoise() throws {
        try withTempDir { directoryURL in
            let zdotDirectory = directoryURL.appending(path: "zdot", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: zdotDirectory, withIntermediateDirectories: true)
            try """
            export CODEEDIT_PROFILE_TOKEN='from-profile'
            printf 'profile noise\n'
            """.write(
                to: zdotDirectory.appending(path: ".zprofile"),
                atomically: true,
                encoding: .utf8
            )
            try "printf 'interactive noise\n'\n".write(
                to: zdotDirectory.appending(path: ".zshrc"),
                atomically: true,
                encoding: .utf8
            )

            var baseEnvironment = ProcessInfo.processInfo.environment
            baseEnvironment["ZDOTDIR"] = zdotDirectory.path(percentEncoded: false)
            let resolvedEnvironment = ShellClient.resolveLoginShellEnvironment(
                baseEnvironment: baseEnvironment
            )

            #expect(resolvedEnvironment["CODEEDIT_PROFILE_TOKEN"] == "from-profile")

            let client = ShellClient(
                nonLoginShellEnvironmentProvider: { resolvedEnvironment }
            )
            let output = try client.run(
                "printf '%s' \"$CODEEDIT_PROFILE_TOKEN\"",
                useLoginShell: false,
                requireSuccessfulExit: true
            )
            #expect(output == "from-profile")
        }
    }

    @Test
    func strictRunThrowsWithExitCodeAndOutput() throws {
        let client = ShellClient(
            nonLoginShellEnvironmentProvider: { ProcessInfo.processInfo.environment }
        )

        do {
            _ = try client.run(
                "printf 'command failed'; exit 7",
                useLoginShell: false,
                requireSuccessfulExit: true
            )
            Issue.record("Expected a non-zero command to throw.")
        } catch ShellClientError.taskTerminated(let code, let output) {
            #expect(code == 7)
            #expect(output == "command failed")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func shellEscapedPreservesSpecialCharacters() throws {
        let client = ShellClient(
            nonLoginShellEnvironmentProvider: { ProcessInfo.processInfo.environment }
        )
        let value = "folder with ' quotes and $HOME"
        let output = try client.run(
            "printf '%s' \(value.shellEscaped())",
            useLoginShell: false,
            requireSuccessfulExit: true
        )
        #expect(output == value)
    }
}
