//
//  GitClient+Status.swift
//  CodeEdit
//
//  Created by Albert Vinizhanau on 10/20/23.
//

import Foundation

/// Methods for parsing git's porcelain v2 format and returning the info in a ``GitClient/Status`` struct.
///
/// Git defines five types of changes to parse in the v2 format:
/// - Ordinary
/// - Renamed/Copied
/// - Unmerged
/// - Untracked
/// - Ignored
///
/// These are documented here: https://git-scm.com/docs/git-status.
///
/// There is one method for each change type that can be returned with the exception of ignored which is, well, ignored.
///
/// # TODO:
/// In the future, this method should return information about push/pull status and stash status, as that
/// information can be included in the same call.

extension GitClient {
    struct Status {
        var changedFiles: [GitChangedFile]
        var unmergedChanges: [GitChangedFile]
        var untrackedFiles: [GitChangedFile]
    }

    /// Fetches and parses the git repository's status.
    /// - Returns: A ``GitClient/Status`` struct with information about the changed files in the repository.
    /// - Throws: Can throw ``GitClient/GitClientError`` errors if it finds unexpected output.
    func getStatus() async throws -> Status {
        let output = try await run("status -z --porcelain=2 -u")
        return try parseStatusString(output)
    }

    /// Parses a status string from ``getStatus()`` and returns a ``Status`` object if possible.
    /// - Parameter output: The git output from running `status`. Expects a porcelain v2 string.
    /// - Returns: A status object if parseable.
    func parseStatusString(_ output: borrowing String) throws -> Status {
        let endsInNull = output.last == Character(UnicodeScalar(0))
        let endIndex: String.Index
        if endsInNull && output.count > 1 {
            endIndex = output.index(before: output.endIndex)
        } else {
            endIndex = output.endIndex
        }

        var status = Status(changedFiles: [], unmergedChanges: [], untrackedFiles: [])

        var index = output.startIndex
        while index < endIndex {
            let typeIndex = index

            // Move ahead no matter what.
            guard let nextIndex = output.safeOffset(index, offsetBy: 2) else {
                throw GitClientError.statusParseEarlyEnd
            }
            index = nextIndex

            switch output[typeIndex] {
            case "1": // Ordinary changes
                status.changedFiles.append(try parseOrdinary(index: &index, output: output))
            case "2": // Renamed or copied changes
                status.changedFiles.append(try parseRenamed(index: &index, output: output))
            case "u": // Unmerged changes
                status.unmergedChanges.append(try parseUnmerged(index: &index, output: output))
            case "?": // Untracked files
                status.untrackedFiles.append(try parseUntracked(index: &index, output: output))
            case "!", "#": // Ignored files or Header
                try substringToNextNull(from: &index, output: output) // move the index to the next line.
            default:
                throw GitClientError.statusInvalidChangeType(output[typeIndex])
            }
        }

        return status
    }

    /// Discard changes for file
    ///
    /// Restores tracked state to `HEAD`. Files that have no version in `HEAD` are moved to the Trash so
    /// their contents remain recoverable.
    func discardChanges(for file: URL) async throws {
        let entries = try await discardStatusEntries()
        guard let entry = entries.first(where: { $0.represents(file, in: directoryURL) }) else {
            return
        }

        let hasHead = try await hasHeadCommit()
        if entry.isUntracked || entry.isAdded || !hasHead {
            try trashFileIfPresent(entry.fileURL(in: directoryURL))
            if entry.isUntracked {
                return
            }
        }

        if hasHead {
            let pathspec = entry.pathsToRestore.map { $0.shellEscaped() }.joined(separator: " ")
            _ = try await run("restore --source=HEAD --staged --worktree -- \(pathspec)")
        } else {
            _ = try await run("rm --cached -f --ignore-unmatch -- \(entry.path.shellEscaped())")
        }
    }

    /// Discard all changes in the repository.
    ///
    /// Restores tracked files and the index to `HEAD`. Untracked files and staged additions are moved to
    /// the Trash first. In a repository without a first commit, the index is cleared instead of resolving
    /// the nonexistent `HEAD`.
    func discardAllChanges() async throws {
        let entries = try await discardStatusEntries()
        guard !entries.isEmpty else { return }

        let hasHead = try await hasHeadCommit()
        let disposablePaths = Set(
            entries
                .filter { $0.isUntracked || $0.isAdded || !hasHead }
                .map(\.path)
        )
        var failedFiles: [String] = []
        for path in disposablePaths {
            do {
                try trashFileIfPresent(directoryURL.appending(path: path))
            } catch {
                failedFiles.append(path)
            }
        }
        guard failedFiles.isEmpty else {
            throw GitClientError.outputError(
                "Failed to move files to the Trash: \(failedFiles.sorted().joined(separator: ", "))"
            )
        }

        if hasHead {
            _ = try await run("restore --source=HEAD --staged --worktree .")
        } else {
            _ = try await run("rm --cached -r -f --ignore-unmatch -- .")
        }
    }

    private struct DiscardStatusEntry {
        let status: String
        let path: String
        let originalPath: String?

        var isUntracked: Bool { status == "??" }
        var isAdded: Bool { status.contains("A") }
        var pathsToRestore: [String] {
            if let originalPath {
                return [originalPath, path]
            }
            return [path]
        }

        func fileURL(in repositoryURL: URL) -> URL {
            repositoryURL.appending(path: path)
        }

        func represents(_ file: URL, in repositoryURL: URL) -> Bool {
            let targetURL = file.standardizedFileURL
            if fileURL(in: repositoryURL).standardizedFileURL == targetURL {
                return true
            }
            guard let originalPath else { return false }
            return repositoryURL.appending(path: originalPath).standardizedFileURL == targetURL
        }
    }

    private func discardStatusEntries() async throws -> [DiscardStatusEntry] {
        let output = try await run("status --porcelain=v1 -z --untracked-files=all")
        let fields = output.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [DiscardStatusEntry] = []
        var index = 0

        while index < fields.count {
            let record = fields[index]
            guard record.count >= 3 else {
                throw GitClientError.outputError("Invalid porcelain status record: \(record)")
            }
            let status = String(record.prefix(2))
            let path = String(record.dropFirst(3))
            index += 1

            var originalPath: String?
            if status.contains("R") || status.contains("C") {
                guard index < fields.count else {
                    throw GitClientError.outputError("Missing original path for renamed file: \(path)")
                }
                originalPath = fields[index]
                index += 1
            }
            entries.append(DiscardStatusEntry(status: status, path: path, originalPath: originalPath))
        }
        return entries
    }

    private func hasHeadCommit() async throws -> Bool {
        do {
            _ = try await run("rev-parse --verify HEAD")
            return true
        } catch GitClientError.outputError(let output) where
            output.contains("Needed a single revision") ||
            output.contains("unknown revision") ||
            output.contains("ambiguous argument 'HEAD'") ||
            output.contains("bad revision 'HEAD'") {
            return false
        }
    }

    private func trashFileIfPresent(_ fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) else {
            return
        }
        try trashItem(fileURL)
    }

    // MARK: - Parsing Helpers

    // Note for the following methods we make extensive use of the `borrowing` parameter modifier to avoid
    // ever copying the output. If changes are made to these methods, ensure this invariant is maintained for
    // performance.

    /// Finds the substring up until the next null character. Does not include the null char.
    /// - Parameters:
    ///   - index: The current index. Modified to be after the null char.
    ///   - output: The string from the git command, borrowed.
    /// - Returns: A substring with the contents of the string up until a null char.
    /// - Throws: Throws a `GitClientError` if the end of the string is found early.
    @discardableResult
    fileprivate func substringToNextNull(from index: inout String.Index, output: borrowing String) throws -> Substring {
        let startIndex = index
        while output[index] != Character(UnicodeScalar(0)) {
            let newIndex = output.index(after: index)
            guard newIndex < output.endIndex else {
                throw GitClientError.statusParseEarlyEnd
            }
            index = newIndex
        }
        defer {
            if index < output.index(before: output.endIndex) {
                index = output.index(after: index)
            }
        }
        return output[startIndex..<index]
    }

    /// Move the index to the next space char.
    /// - Throws: Throws a `GitClientError` if the end of the string is found early.
    fileprivate func moveToNextSpace(from index: inout String.Index, output: borrowing String) throws {
        repeat {
            try moveOneChar(from: &index, output: output)
        }
        while output[index] != " "
    }

    /// Move the index one character.
    /// - Throws: Throws a `GitClientError` if the end of the string is found early.
    fileprivate func moveOneChar(from index: inout String.Index, output: borrowing String) throws {
        index = output.index(after: index)
        guard index != output.endIndex else {
            throw GitClientError.statusParseEarlyEnd
        }
    }

    /// Parse a status character at the current index.
    /// - Returns: The status, if any.
    /// - Throws: Throws a `GitClientError` if an invalid status character is found.
    fileprivate func parseStatus(index: inout String.Index, output: borrowing String) throws -> GitStatus {
        guard let status = GitStatus(rawValue: String(output[index])) else {
            throw GitClientError.invalidStatus(output[index])
        }
        index = output.index(after: index)
        return status
    }

    // MARK: - Change Type Parsers

    /// Parses an ordinary change.
    /// ```
    /// 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
    /// ```
    fileprivate func parseOrdinary(index: inout String.Index, output: borrowing String) throws -> GitChangedFile {
        let stagedStatus = try parseStatus(index: &index, output: output)
        let status = try parseStatus(index: &index, output: output)
        // don't care about fields
        for _ in 0..<6 {
            try moveToNextSpace(from: &index, output: output)
        }
        try moveOneChar(from: &index, output: output)
        let substring = try substringToNextNull(from: &index, output: output)
        let filename = String(substring)
        return GitChangedFile(
            status: status,
            stagedStatus: stagedStatus,
            fileURL: URL(filePath: filename, relativeTo: directoryURL),
            originalFilename: nil
        )
    }

    /// Parses a renamed or copied change.
    /// ```
    /// 2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path><sep><origPath>
    /// ```
    fileprivate func parseRenamed(index: inout String.Index, output: borrowing String) throws -> GitChangedFile {
        let stagedStatus = try parseStatus(index: &index, output: output)
        let status = try parseStatus(index: &index, output: output)
        // don't care about fields
        for _ in 0..<7 {
            try moveToNextSpace(from: &index, output: output)
        }
        try moveOneChar(from: &index, output: output)
        let filename = String(try substringToNextNull(from: &index, output: output))
        let originalFilename = String(try substringToNextNull(from: &index, output: output))
        return GitChangedFile(
            status: status,
            stagedStatus: stagedStatus,
            fileURL: URL(filePath: filename, relativeTo: directoryURL),
            originalFilename: originalFilename
        )
    }

    /// Parses an unmerged change.
    /// ```
    /// u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
    /// ```
    fileprivate func parseUnmerged(index: inout String.Index, output: borrowing String) throws -> GitChangedFile {
        let stagedStatus = try parseStatus(index: &index, output: output)
        let status = try parseStatus(index: &index, output: output)
        // don't care about fields
        for _ in 0..<8 {
            try moveToNextSpace(from: &index, output: output)
        }
        try moveOneChar(from: &index, output: output)
        let filename = String(try substringToNextNull(from: &index, output: output))
        return GitChangedFile(
            status: status,
            stagedStatus: stagedStatus,
            fileURL: URL(filePath: filename, relativeTo: directoryURL),
            originalFilename: nil
        )
    }

    /// Parses an untracked change.
    /// ```
    /// ? <path>
    /// ```
    fileprivate func parseUntracked(index: inout String.Index, output: borrowing String) throws -> GitChangedFile {
        let filename = String(try substringToNextNull(from: &index, output: output))
        return GitChangedFile(
            status: .untracked,
            stagedStatus: .none,
            fileURL: URL(filePath: filename, relativeTo: directoryURL),
            originalFilename: nil
        )
    }
}
