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

    /// Determines whether the pattern matches a workspace-relative file path.
    ///
    /// Patterns without a `/` match any single path component, so a pattern like
    /// `node_modules` or `*.log` applies at any depth and excludes an entire matched
    /// subtree. Patterns containing a `/` are anchored to the workspace root and are
    /// tested against the path itself and each of its ancestor directories.
    /// Empty patterns never match, since the settings UI appends empty-value patterns
    /// while the user is editing the list.
    /// - Parameter relativePath: A file path relative to the workspace root.
    /// - Returns: `true` if the pattern matches the path, one of its ancestor
    ///            directories, or - for slash-free patterns - any path component.
    func matches(relativePath: String) -> Bool {
        guard !value.isEmpty else { return false }
        guard value.contains("/") else {
            // Unanchored: a match on any component excludes the file or its subtree.
            return relativePath.split(separator: "/").contains { component in
                fnmatch(value, String(component), FNM_PATHNAME) == 0
            }
        }
        var path = relativePath
        while !path.isEmpty {
            if fnmatch(value, path, FNM_PATHNAME) == 0 {
                return true
            }
            // Test each ancestor directory so a matched folder excludes its entire subtree.
            guard let lastSeparator = path.lastIndex(of: "/") else { break }
            path = String(path[..<lastSeparator])
        }
        return false
    }
}
