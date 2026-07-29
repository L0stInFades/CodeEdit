//
//  GlobPatternTests.swift
//  CodeEditTests
//

import Foundation
import Testing
@testable import CodeEdit

@Suite
struct GlobPatternTests {
    @Test
    func matchesIssuePatternsWithLeadingAndTrailingSlashes() {
        let nodeModules = GlobPattern(value: "/ui/node_modules/*")
        let vendor = GlobPattern(value: "vendor/")

        #expect(nodeModules.matches(
            relativePath: "ui/node_modules/.pnpm/package/node_modules/package/README.md"
        ))
        #expect(vendor.matches(relativePath: "vendor/README.md"))
        #expect(vendor.matches(relativePath: "vendor", isDirectory: true))
        #expect(!vendor.matches(relativePath: "vendor", isDirectory: false))
    }

    @Test
    func recursiveDoubleStarMatchesZeroOrManyDirectories() {
        let swiftFiles = GlobPattern(value: "**/*.swift")
        let generated = GlobPattern(value: "Sources/**/Generated.swift")

        #expect(swiftFiles.matches(relativePath: "App.swift"))
        #expect(swiftFiles.matches(relativePath: "Sources/App.swift"))
        #expect(swiftFiles.matches(relativePath: "Sources/Feature/Nested/App.swift"))
        #expect(generated.matches(relativePath: "Sources/Generated.swift"))
        #expect(generated.matches(relativePath: "Sources/Feature/Nested/Generated.swift"))
    }

    @Test
    func leadingSlashAnchorsPatternToWorkspaceRoot() {
        let vendor = GlobPattern(value: "/vendor/")

        #expect(vendor.matches(relativePath: "vendor", isDirectory: true))
        #expect(!vendor.matches(relativePath: "Sources/vendor", isDirectory: true))
    }

    @Test
    func derivesRelativePathAcrossCanonicalWorkspaceAlias() throws {
        try withTempDir { workspaceURL in
            let canonicalPath = try #require(
                workspaceURL.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
            )
            let fileURL = URL(filePath: canonicalPath)
                .appending(path: "Sources/App.swift")
            let rawFileURL = workspaceURL.appending(path: "Sources/App.swift")

            let canonicalRelativePath = OpenQuicklyViewModel.workspaceRelativePath(
                for: fileURL,
                in: workspaceURL
            )
            let rawRelativePath = OpenQuicklyViewModel.workspaceRelativePath(
                for: rawFileURL,
                in: workspaceURL
            )

            #expect(canonicalRelativePath == "Sources/App.swift")
            #expect(rawRelativePath == "Sources/App.swift")
        }
    }

    @Test
    func searchableFilesPrunesExcludedDirectories() throws {
        try withTempDir { workspaceURL in
            try createFile(
                "ui/node_modules/.pnpm/package/node_modules/package/README.md",
                in: workspaceURL
            )
            try createFile("vendor/README.md", in: workspaceURL)
            try createFile("Sources/App.swift", in: workspaceURL)

            let files = OpenQuicklyViewModel.searchableFiles(
                in: workspaceURL,
                excluding: [
                    GlobPattern(value: "/ui/node_modules/*"),
                    GlobPattern(value: "vendor/")
                ]
            )
            let relativePaths = Set(files.compactMap { fileURL in
                OpenQuicklyViewModel.workspaceRelativePath(for: fileURL, in: workspaceURL)
            })

            #expect(relativePaths == Set(["Sources/App.swift"]))
        }
    }

    private func createFile(_ relativePath: String, in workspaceURL: URL) throws {
        let fileURL = workspaceURL.appending(path: relativePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "fixture\n".write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
