//
//  OpenQuicklyViewModel.swift
//  CodeEditModules/QuickOpen
//
//  Created by Marco Carnevali on 05/04/22.
//

import Combine
import Foundation
import CollectionConcurrencyKit

final class OpenQuicklyViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var searchResults: [SearchResult] = []

    let fileURL: URL
    var runningTask: Task<Void, Never>?

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// This is used to populate the ``OpenQuicklyListItemView`` view which shows the search results to the user.
    ///
    /// ``OpenQuicklyPreviewView`` also uses this to load the `fileUrl` for preview.
    struct SearchResult: Identifiable, Hashable {
        var id: String { fileURL.id }
        let fileURL: URL
        let matchedCharacters: [NSRange]

        // This custom Hashable implementation prevents the highlighted
        // selection from flickering when searching in 'Open Quickly'.
        //
        // See https://github.com/CodeEditApp/CodeEdit/pull/1790#issuecomment-2206832901
        // for flickering visuals.
        //
        // Before commit 0e28b382f59184b7ebe5a7c3295afa3655b7d4e7, only the fileURL
        // was retrieved from the search results and it worked as expected.
        //
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.fileURL == rhs.fileURL }
        func hash(into hasher: inout Hasher) { hasher.combine(fileURL) }
    }

    func fetchResults() {
        let startTime = Date()
        let searchQuery = query.trimmingCharacters(in: .whitespaces)
        runningTask?.cancel()
        guard !searchQuery.isEmpty else {
            searchResults = []
            return
        }

        // Read settings on the caller's actor; the detached task must not touch `Settings.shared`.
        let ignoredGlobPatterns = Settings[\.search].ignoreGlobPatterns

        runningTask = Task.detached(priority: .userInitiated) {
            let filteredFiles = Self.searchableFiles(
                in: self.fileURL,
                excluding: ignoredGlobPatterns
            )
            guard !Task.isCancelled else { return }

            let fuzzySearchResults = await filteredFiles.fuzzySearch(
                query: searchQuery
            ).concurrentMap {
                SearchResult(
                    fileURL: $0.item,
                    matchedCharacters: $0.result.matchedParts
                )
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                self.searchResults = fuzzySearchResults
                print("Duration: \(Date().timeIntervalSince(startTime))")
            }
        }
    }

    static func searchableFiles(in workspaceURL: URL, excluding patterns: [GlobPattern]) -> [URL] {
        let resourceKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey]
        let workspacePaths = workspacePathCandidates(for: workspaceURL)
        guard let enumerator = FileManager.default.enumerator(
            at: workspaceURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsPackageDescendants]
        ) else {
            return []
        }

        var files: [URL] = []
        while let url = enumerator.nextObject() as? URL {
            if Task.isCancelled {
                break
            }
            guard let values = try? url.resourceValues(forKeys: resourceKeys),
                  let relativePath = workspaceRelativePath(for: url, workspacePaths: workspacePaths) else {
                continue
            }

            if values.isDirectory == true {
                if patterns.contains(where: { $0.matches(relativePath: relativePath, isDirectory: true) }) {
                    enumerator.skipDescendants()
                }
            } else if values.isRegularFile == true,
                      !patterns.contains(where: { $0.matches(relativePath: relativePath) }) {
                files.append(url)
            }
        }
        return files
    }

    static func workspaceRelativePath(for fileURL: URL, in workspaceURL: URL) -> String? {
        workspaceRelativePath(
            for: fileURL,
            workspacePaths: workspacePathCandidates(for: workspaceURL)
        )
    }

    private static func workspacePathCandidates(for workspaceURL: URL) -> [String] {
        var workspacePaths = Set([
            workspaceURL.standardizedFileURL.path(percentEncoded: false)
        ])
        if let canonicalPath = try? workspaceURL.resourceValues(
            forKeys: [.canonicalPathKey]
        ).canonicalPath {
            workspacePaths.insert(canonicalPath)
        }
        return workspacePaths.sorted(by: { $0.count > $1.count })
    }

    private static func workspaceRelativePath(for fileURL: URL, workspacePaths: [String]) -> String? {
        let filePath = fileURL.standardizedFileURL.path(percentEncoded: false)
        for workspacePath in workspacePaths {
            let prefix = workspacePath == "/" || workspacePath.hasSuffix("/")
                ? workspacePath
                : workspacePath + "/"
            guard filePath.hasPrefix(prefix) else { continue }
            return String(filePath.dropFirst(prefix.count))
        }
        return nil
    }
}
