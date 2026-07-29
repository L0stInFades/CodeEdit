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
            guard let values = try? url.resourceValues(forKeys: resourceKeys) else {
                continue
            }
            let relativePath = url.path(percentEncoded: false)
                .dropWorkspacePrefix(workspaceURL.path(percentEncoded: false))

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
}

private extension String {
    func dropWorkspacePrefix(_ workspacePath: String) -> String {
        var relativePath = self
        if relativePath.hasPrefix(workspacePath) {
            relativePath.removeFirst(workspacePath.count)
        }
        while relativePath.hasPrefix("/") {
            relativePath.removeFirst()
        }
        return relativePath
    }
}
