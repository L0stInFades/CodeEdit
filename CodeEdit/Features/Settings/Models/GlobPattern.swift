//
//  GlobPattern.swift
//  CodeEdit
//
//  Created by Austin Condiff on 11/2/24.
//

import Foundation

/// A simple model that associates a UUID with a glob pattern string.
///
/// This type does not validate the glob pattern itself.
/// It is an identifier (`id`) and the glob pattern string (`value`) associated with it,
/// with ``matches(relativePath:)`` for testing paths against the pattern.
struct GlobPattern: Identifiable, Hashable, Decodable, Encodable {
    /// Ephemeral UUID used to uniquely identify this instance in the UI
    var id = UUID()

    /// The Glob Pattern string
    var value: String

    /// Determines whether the pattern matches a workspace-relative path.
    ///
    /// A leading `/` anchors the pattern to the workspace root, a trailing `/` restricts it to
    /// directories, and a `**` path segment matches zero or more directory levels. Slash-free,
    /// unanchored patterns match any path component. Matching a directory also excludes its subtree.
    /// - Parameters:
    ///   - relativePath: A file or directory path relative to the workspace root.
    ///   - isDirectory: Whether `relativePath` itself represents a directory.
    func matches(relativePath: String, isDirectory: Bool = false) -> Bool {
        var pattern = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return false }

        let isAnchored = pattern.hasPrefix("/")
        let isDirectoryOnly = pattern.hasSuffix("/")
        while pattern.hasPrefix("/") {
            pattern.removeFirst()
        }
        while pattern.hasSuffix("/") {
            pattern.removeLast()
        }
        while pattern.hasPrefix("./") {
            pattern.removeFirst(2)
        }
        guard !pattern.isEmpty else { return false }

        let patternSegments = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let pathSegments = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard !patternSegments.isEmpty, !pathSegments.isEmpty else { return false }

        let candidateLength = isDirectory || !isDirectoryOnly
            ? pathSegments.count
            : pathSegments.count - 1
        guard candidateLength > 0 else { return false }

        if !isAnchored, patternSegments.count == 1, patternSegments[0] != "**" {
            return pathSegments.prefix(candidateLength).contains { component in
                fnmatch(patternSegments[0], component, FNM_PATHNAME) == 0
            }
        }

        for length in 1...candidateLength
        where Self.segmentsMatch(patternSegments, Array(pathSegments.prefix(length))) {
            return true
        }
        return false
    }

    private static func segmentsMatch(_ pattern: [String], _ path: [String]) -> Bool {
        var matches = Array(
            repeating: Array(repeating: false, count: path.count + 1),
            count: pattern.count + 1
        )
        matches[0][0] = true

        for patternIndex in pattern.indices {
            for pathIndex in 0...path.count where matches[patternIndex][pathIndex] {
                if pattern[patternIndex] == "**" {
                    matches[patternIndex + 1][pathIndex] = true
                    if pathIndex < path.count {
                        matches[patternIndex][pathIndex + 1] = true
                    }
                } else if pathIndex < path.count,
                          fnmatch(pattern[patternIndex], path[pathIndex], FNM_PATHNAME) == 0 {
                    matches[patternIndex + 1][pathIndex + 1] = true
                }
            }
        }
        return matches[pattern.count][path.count]
    }
}
