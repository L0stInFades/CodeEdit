//
//  GitClientTests.swift
//  CodeEditTests
//
//  Created by Khan Winter on 9/11/25.
//

import Foundation
import Testing
@testable import CodeEdit

@Suite(.serialized)
struct GitClientTests {
    @Test
    func statusParseNullAtEnd() throws {
        try withTempDir { dirURL in
            // swiftlint:disable:next line_length
            let string = "1 .M N... 100644 100644 100644 eaef31cfa2a22418c00d7477da0b7151d122681e eaef31cfa2a22418c00d7477da0b7151d122681e CodeEdit/Features/SourceControl/Client/GitClient+Status.swift\01 AM N... 000000 100644 100644 0000000000000000000000000000000000000000 e0f5ce250b32cf6610a284b7a33ac114079f5159 CodeEditTests/Features/SourceControl/GitClientTests.swift\0"
            let client = GitClient(directoryURL: dirURL, shellClient: .live())
            let status = try client.parseStatusString(string)

            #expect(status.changedFiles.count == 2)
            // No null string at the end
            #expect(status.changedFiles[0].fileURL.lastPathComponent == "GitClient+Status.swift")
            #expect(status.changedFiles[1].fileURL.lastPathComponent == "GitClientTests.swift")
        }
    }

    @Test
    func discardStagedAdditionMovesFileOutAndCleansIndex() async throws {
        try await withTempDir { repositoryURL in
            try initializeRepository(at: repositoryURL)
            let addedFile = repositoryURL.appending(path: "it's new.txt")
            try "new\n".write(to: addedFile, atomically: true, encoding: .utf8)
            try runGit(["add", addedFile.lastPathComponent], in: repositoryURL)

            var trashedFiles: [URL] = []
            let client = makeClient(in: repositoryURL) { url in
                trashedFiles.append(url)
                try FileManager.default.removeItem(at: url)
            }
            try await client.discardChanges(for: addedFile)

            #expect(!FileManager.default.fileExists(atPath: addedFile.path))
            #expect(try gitStatus(in: repositoryURL).isEmpty)
            #expect(trashedFiles.map(\.lastPathComponent) == [addedFile.lastPathComponent])
        }
    }

    @Test
    func discardStagedRenameRestoresOriginalPathAndContents() async throws {
        try await withTempDir { repositoryURL in
            try initializeRepository(at: repositoryURL)
            let originalFile = repositoryURL.appending(path: "base.txt")
            let renamedFile = repositoryURL.appending(path: "renamed file.txt")
            try runGit(["mv", originalFile.lastPathComponent, renamedFile.lastPathComponent], in: repositoryURL)
            try "changed after rename\n".write(to: renamedFile, atomically: true, encoding: .utf8)

            let client = makeClient(in: repositoryURL)
            try await client.discardChanges(for: renamedFile)

            #expect(FileManager.default.fileExists(atPath: originalFile.path))
            #expect(!FileManager.default.fileExists(atPath: renamedFile.path))
            #expect(try String(contentsOf: originalFile, encoding: .utf8) == "base\n")
            #expect(try gitStatus(in: repositoryURL).isEmpty)
        }
    }

    @Test
    func discardTrackedStagedModificationRestoresHead() async throws {
        try await withTempDir { repositoryURL in
            try initializeRepository(at: repositoryURL)
            let file = repositoryURL.appending(path: "base.txt")
            try "changed\n".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["add", file.lastPathComponent], in: repositoryURL)

            let client = makeClient(in: repositoryURL)
            try await client.discardChanges(for: file)

            #expect(try String(contentsOf: file, encoding: .utf8) == "base\n")
            #expect(try gitStatus(in: repositoryURL).isEmpty)
        }
    }

    @Test
    func discardUntrackedFileUsesRecoverableDisposal() async throws {
        try await withTempDir { repositoryURL in
            try initializeRepository(at: repositoryURL)
            let file = repositoryURL.appending(path: "untracked.txt")
            try "untracked\n".write(to: file, atomically: true, encoding: .utf8)

            var trashedFiles: [URL] = []
            let client = makeClient(in: repositoryURL) { url in
                trashedFiles.append(url)
                try FileManager.default.removeItem(at: url)
            }
            try await client.discardChanges(for: file)

            #expect(!FileManager.default.fileExists(atPath: file.path))
            #expect(try gitStatus(in: repositoryURL).isEmpty)
            #expect(trashedFiles.map(\.lastPathComponent) == [file.lastPathComponent])
        }
    }

    @Test
    func discardAllHandlesTrackedStagedAndUntrackedChanges() async throws {
        try await withTempDir { repositoryURL in
            try initializeRepository(at: repositoryURL)
            let trackedFile = repositoryURL.appending(path: "base.txt")
            let addedFile = repositoryURL.appending(path: "added.txt")
            let untrackedFile = repositoryURL.appending(path: "untracked.txt")
            try "changed\n".write(to: trackedFile, atomically: true, encoding: .utf8)
            try "added\n".write(to: addedFile, atomically: true, encoding: .utf8)
            try "untracked\n".write(to: untrackedFile, atomically: true, encoding: .utf8)
            try runGit(["add", trackedFile.lastPathComponent, addedFile.lastPathComponent], in: repositoryURL)

            var trashedFiles: [URL] = []
            let client = makeClient(in: repositoryURL) { url in
                trashedFiles.append(url)
                try FileManager.default.removeItem(at: url)
            }
            try await client.discardAllChanges()

            #expect(try String(contentsOf: trackedFile, encoding: .utf8) == "base\n")
            #expect(!FileManager.default.fileExists(atPath: addedFile.path))
            #expect(!FileManager.default.fileExists(atPath: untrackedFile.path))
            #expect(try gitStatus(in: repositoryURL).isEmpty)
            #expect(Set(trashedFiles.map(\.lastPathComponent)) == Set(["added.txt", "untracked.txt"]))
        }
    }

    @Test
    func discardAllWorksBeforeFirstCommit() async throws {
        try await withTempDir { repositoryURL in
            try initializeRepository(at: repositoryURL, createCommit: false)
            let stagedFile = repositoryURL.appending(path: "staged.txt")
            let untrackedFile = repositoryURL.appending(path: "untracked.txt")
            try "staged\n".write(to: stagedFile, atomically: true, encoding: .utf8)
            try "untracked\n".write(to: untrackedFile, atomically: true, encoding: .utf8)
            try runGit(["add", stagedFile.lastPathComponent], in: repositoryURL)

            var trashedFiles: [URL] = []
            let client = makeClient(in: repositoryURL) { url in
                trashedFiles.append(url)
                try FileManager.default.removeItem(at: url)
            }
            try await client.discardAllChanges()

            #expect(!FileManager.default.fileExists(atPath: stagedFile.path))
            #expect(!FileManager.default.fileExists(atPath: untrackedFile.path))
            #expect(try gitStatus(in: repositoryURL).isEmpty)
            #expect(Set(trashedFiles.map(\.lastPathComponent)) == Set(["staged.txt", "untracked.txt"]))
        }
    }

    @Test
    func missingGitConfigValueReturnsNil() async throws {
        try await withTempDir { repositoryURL in
            try initializeRepository(at: repositoryURL)
            let client = GitConfigClient(
                projectURL: repositoryURL,
                shellClient: makeShellClient()
            )

            let value: String? = try await client.get(key: "codeedit.missing")

            #expect(value == nil)
        }
    }

    @Test
    func gitConfigValuePreservesShellSpecialCharacters() async throws {
        try await withTempDir { repositoryURL in
            try initializeRepository(at: repositoryURL)
            let client = GitConfigClient(
                projectURL: repositoryURL,
                shellClient: makeShellClient()
            )
            let expected = "folder with ' quote, \"double quote\", and $HOME"

            await client.set(key: "codeedit.special", value: expected)
            let value: String? = try await client.get(key: "codeedit.special")

            #expect(value == expected)
        }
    }

    private func makeShellClient() -> ShellClient {
        ShellClient(
            nonLoginShellEnvironmentProvider: { ProcessInfo.processInfo.environment }
        )
    }

    private func makeClient(
        in repositoryURL: URL,
        trashItem: @escaping (URL) throws -> Void = { _ in }
    ) -> GitClient {
        GitClient(
            directoryURL: repositoryURL,
            shellClient: makeShellClient(),
            trashItem: trashItem
        )
    }

    private func initializeRepository(at repositoryURL: URL, createCommit: Bool = true) throws {
        try runGit(["init", "--quiet"], in: repositoryURL)
        try runGit(["config", "user.name", "CodeEdit Tests"], in: repositoryURL)
        try runGit(["config", "user.email", "tests@example.invalid"], in: repositoryURL)
        try runGit(["config", "commit.gpgsign", "false"], in: repositoryURL)
        guard createCommit else { return }

        let baseFile = repositoryURL.appending(path: "base.txt")
        try "base\n".write(to: baseFile, atomically: true, encoding: .utf8)
        try runGit(["add", baseFile.lastPathComponent], in: repositoryURL)
        try runGit(["commit", "--quiet", "--no-gpg-sign", "-m", "base"], in: repositoryURL)
    }

    private func gitStatus(in repositoryURL: URL) throws -> String {
        try runGit(["status", "--porcelain=v1"], in: repositoryURL)
    }

    @discardableResult
    private func runGit(_ arguments: [String], in repositoryURL: URL) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = repositoryURL
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw GitTestError.commandFailed(arguments: arguments, output: output)
        }
        return output
    }

    private struct GitTestError: Error {
        let arguments: [String]
        let output: String
    }
}
