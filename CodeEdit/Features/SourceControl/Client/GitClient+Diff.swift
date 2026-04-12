//
//  GitClient+Diff.swift
//  CodeEdit
//
//  Created by Abe Malla on 4/10/26.
//

import Foundation

extension GitClient {
    /// Returns the file content from HEAD for the given relative path.
    ///
    /// Runs `git show --textconv HEAD:<path>` by spawning the git binary directly (not via an
    /// interactive login shell) so that `.zshrc`/`.zprofile` startup noise cannot pollute the output.
    /// Stdout and stderr are kept on separate pipes; a non-zero exit code means the file is not in HEAD
    /// (new/untracked file) and `nil` is returned.
    ///
    /// The blocking `waitUntilExit()` + `readDataToEndOfFile()` calls run on a `DispatchQueue.global`
    /// thread via `withCheckedThrowingContinuation` so the Swift concurrency cooperative pool is
    /// never stalled.
    ///
    /// - Parameter relativePath: The path of the file relative to the repository root.
    /// - Returns: The UTF-8 content of the file at HEAD, or `nil` if not tracked.
    func getHeadFileContent(relativePath: String) async throws -> String? {
        let repoURL = directoryURL
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = GitClient.gitExecutableURL
                process.arguments = ["show", "--textconv", "HEAD:" + relativePath]
                process.currentDirectoryURL = repoURL
                process.environment = GitClient.gitEnvironment

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                    // readDataToEndOfFile blocks until EOF — safe here because we're on a
                    // DispatchQueue.global worker thread, not in the cooperative pool.
                    let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    process.waitUntilExit()

                    if process.terminationStatus == 0 {
                        continuation.resume(returning: String(data: data, encoding: .utf8))
                    } else {
                        // Non-zero exit: file doesn't exist in HEAD (new/untracked)
                        continuation.resume(returning: nil)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Git Binary Discovery

    /// The git executable, discovered once at first use by checking common installation paths.
    ///
    /// Checked in order:
    /// 1. `/opt/homebrew/bin/git` — Homebrew on Apple Silicon
    /// 2. `/usr/local/bin/git`    — Homebrew on Intel
    /// 3. `/usr/bin/git`          — Xcode Command Line Tools (fallback)
    static let gitExecutableURL: URL = {
        let candidates = [
            "/opt/homebrew/bin/git",
            "/usr/local/bin/git",
            "/usr/bin/git",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return URL(fileURLWithPath: "/usr/bin/git")
    }()

    /// Environment variables forwarded to git subprocesses.
    ///
    /// Inherits the current process environment, then overrides git-specific vars:
    /// - `GIT_PAGER=cat`          — prevents git from spawning a pager (less/more) which would hang
    /// - `GIT_TERMINAL_PROMPT=0` — prevents git from prompting for credentials and stalling
    /// - `LANG` / `LC_ALL`       — ensures UTF-8 output regardless of system locale
    static let gitEnvironment: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        env["GIT_PAGER"] = "cat"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        env["LANGUAGE"] = "en"
        return env
    }()

    // MARK: - Path Utilities

    /// Returns the path of a file relative to the git repository root.
    ///
    /// - Parameter absolutePath: The absolute file path.
    /// - Returns: The relative path, or `nil` if the file is not within the repository.
    func relativePath(for absolutePath: String) -> String? {
        let repoRoot = directoryURL.path
        guard absolutePath.hasPrefix(repoRoot) else { return nil }
        var relative = String(absolutePath.dropFirst(repoRoot.count))
        if relative.hasPrefix("/") {
            relative = String(relative.dropFirst())
        }
        return relative
    }
}
