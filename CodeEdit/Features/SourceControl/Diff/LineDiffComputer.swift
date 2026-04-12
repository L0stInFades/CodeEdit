//
//  LineDiffComputer.swift
//  CodeEdit
//
//  Created by Abe Malla on 4/10/26.
//

import Foundation
import CodeEditSourceEditor

/// Computes line-level diffs between an original and modified document.
///
/// Uses Swift's `CollectionDifference` (which implements the Myers diff algorithm internally)
/// to identify inserted, removed, and modified line ranges, then converts them into
/// `GutterChange` values suitable for gutter rendering.
///
/// ## Performance
/// - Uses `[String]` lines with CRLF normalization for cross-platform safety.
/// - Supports a maximum line count cutoff to skip very large files.
/// - Designed to run on a background queue.
enum LineDiffComputer {
    /// Maximum number of lines before we skip diff computation entirely.
    static let maxLineCount = 50_000

    /// Computes gutter changes between original and modified text content.
    ///
    /// - Parameters:
    ///   - original: The original (HEAD) file content.
    ///   - modified: The current (buffer) file content.
    /// - Returns: An array of `GutterChange` values representing the differences, or an empty array
    ///   if the files are identical or too large to process.
    static func computeChanges(original: String, modified: String) -> [GutterChange] {
        let originalLines = splitLines(original)
        let modifiedLines = splitLines(modified)

        // Skip very large files
        guard originalLines.count <= maxLineCount, modifiedLines.count <= maxLineCount else {
            return []
        }

        // Fast path: identical content
        guard originalLines != modifiedLines else {
            return []
        }

        // Use CollectionDifference (Myers diff) to find the minimal edit script
        let diff: CollectionDifference<String> = modifiedLines.difference(from: originalLines)

        return convertToGutterChanges(diff: diff, originalCount: originalLines.count, modifiedCount: modifiedLines.count)
    }

    /// Splits text into lines, preserving empty trailing lines.
    ///
    /// Handles both `\n` (LF) and `\r\n` (CRLF) line endings by stripping any
    /// trailing `\r` from each line. This prevents false diffs when git returns
    /// content with different line endings than the editor uses.
    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var start = text.startIndex
        let end = text.endIndex

        while start < end {
            guard let newlineIndex = text[start...].firstIndex(of: "\n") else {
                // Last line without trailing newline — strip \r if present
                var line = text[start..<end]
                if line.hasSuffix("\r") { line = line.dropLast() }
                lines.append(String(line))
                break
            }
            // Strip trailing \r for CRLF support
            var lineEnd = newlineIndex
            if lineEnd > start && text[text.index(before: lineEnd)] == "\r" {
                lineEnd = text.index(before: lineEnd)
            }
            lines.append(String(text[start..<lineEnd]))
            start = text.index(after: newlineIndex)
        }

        // If the text ends with a newline, there's an implied empty line after it
        if text.hasSuffix("\n") {
            lines.append("")
        }

        return lines
    }

    /// Converts a `CollectionDifference` into contiguous `GutterChange` regions.
    ///
    /// The algorithm builds sets of removed (original) and inserted (modified) line indices from the diff,
    /// then walks through both documents in lockstep. Unchanged lines advance both cursors.
    /// When a change point is reached, all contiguous removed and inserted lines at that point
    /// are collected into an edit region:
    /// - Both removals and insertions → `.modified`
    /// - Only insertions → `.added`
    /// - Only removals → `.deleted` (positioned in the modified document at the gap between surrounding lines)
    private static func convertToGutterChanges(
        diff: CollectionDifference<String>,
        originalCount: Int,
        modifiedCount: Int
    ) -> [GutterChange] {
        // Build sets for O(1) lookup
        var removedSet = Set<Int>()
        var insertedSet = Set<Int>()

        for change in diff {
            switch change {
            case .remove(let offset, _, _):
                removedSet.insert(offset)
            case .insert(let offset, _, _):
                insertedSet.insert(offset)
            }
        }

        var changes: [GutterChange] = []
        var origIdx = 0
        var modIdx = 0

        while origIdx < originalCount || modIdx < modifiedCount {
            // Skip unchanged lines (not removed from original, not inserted in modified)
            while origIdx < originalCount && modIdx < modifiedCount
                    && !removedSet.contains(origIdx) && !insertedSet.contains(modIdx) {
                origIdx += 1
                modIdx += 1
            }

            if origIdx >= originalCount && modIdx >= modifiedCount { break }

            // We've hit a change point. Collect contiguous removed and inserted lines here.
            let modStart = modIdx

            // Gather all contiguous removals from original at this point
            var removals = 0
            while origIdx < originalCount && removedSet.contains(origIdx) {
                origIdx += 1
                removals += 1
            }

            // Gather all contiguous insertions into modified at this point
            var insertions = 0
            while modIdx < modifiedCount && insertedSet.contains(modIdx) {
                modIdx += 1
                insertions += 1
            }

            // Classify the edit region
            if removals > 0 && insertions > 0 {
                // Lines were both removed and inserted at this position → modification
                changes.append(GutterChange(type: .modified, lineRange: modStart..<(modStart + insertions)))
            } else if insertions > 0 {
                // Only insertions → addition
                changes.append(GutterChange(type: .added, lineRange: modStart..<(modStart + insertions)))
            } else if removals > 0 {
                // Only removals → deletion indicator.
                // Position it at the line in the modified document where the gap is.
                // `modStart` points to the first unchanged line after the deletion,
                // or equals `modifiedCount` if deleted at the end.
                let pos = min(max(modStart, 0), max(modifiedCount - 1, 0))
                changes.append(GutterChange(type: .deleted, lineRange: pos..<(pos + 1)))
            }
        }

        return changes
    }
}
