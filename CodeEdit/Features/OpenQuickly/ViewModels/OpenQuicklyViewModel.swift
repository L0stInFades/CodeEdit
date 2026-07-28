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
        guard query != "" else {
            searchResults = []
            return
        }

        // Read settings on the caller's actor; the detached task must not touch `Settings.shared`.
        let ignoredGlobPatterns = Settings[\.search].ignoreGlobPatterns
        let workspacePath = fileURL.path

        runningTask?.cancel()
        runningTask = Task.detached(priority: .userInitiated) {
            let enumerator = FileManager.default.enumerator(
                at: self.fileURL,
                includingPropertiesForKeys: [
                    .isRegularFileKey
                ],
                options: [
                    .skipsPackageDescendants
                ]
            )
            if let filePaths = enumerator?.allObjects as? [URL] {
                guard !Task.isCancelled else { return }
                /// removes all filePaths which aren't regular files or match an ignored glob pattern
                let filteredFiles = filePaths.filter { url in
                    do {
                        let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                        guard values.isRegularFile ?? false else {
                            return false
                        }
                    } catch {
                        return false
                    }
                    var relativePath = url.path
                    if relativePath.hasPrefix(workspacePath) {
                        relativePath = String(relativePath.dropFirst(workspacePath.count))
                    }
                    while relativePath.hasPrefix("/") {
                        relativePath = String(relativePath.dropFirst())
                    }
                    return !ignoredGlobPatterns.contains { $0.matches(relativePath: relativePath) }
                }

                let fuzzySearchResults = await filteredFiles.fuzzySearch(
                    query: self.query.trimmingCharacters(in: .whitespaces)
                ).concurrentMap {
                    SearchResult(
                        fileURL: $0.item,
                        matchedCharacters: $0.result.matchedParts
                    )
                }

                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self.searchResults = fuzzySearchResults
                    print("Duration: \(Date().timeIntervalSince(startTime))")
                }
            }
        }
    }
}
