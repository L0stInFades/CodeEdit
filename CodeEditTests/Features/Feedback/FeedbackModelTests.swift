//
//  FeedbackModelTests.swift
//  CodeEditTests
//

import Foundation
import Testing
@testable import CodeEdit

@MainActor
@Suite(.serialized)
struct FeedbackModelTests {
    @Test
    func browserFallbackReportsDraftInsteadOfSubmission() {
        var openedURL: URL?
        let model = FeedbackModel(
            accountsProvider: { [] },
            tokenProvider: { _ in nil },
            tokenStore: { _, _ in },
            openURL: { url in
                openedURL = url
                return true
            }
        )

        model.createIssue(
            title: "Example",
            description: "Description",
            steps: nil,
            expectation: nil,
            actuallyHappened: nil
        )

        #expect(model.didOpenIssueDraft)
        #expect(!model.isSubmitted)
        #expect(!model.failedToSubmit)
        #expect(openedURL?.host == "github.com")
        #expect(openedURL?.path == "/CodeEditApp/CodeEdit/issues/new")
    }

    @Test
    func browserFallbackReportsFailureWhenURLCannotOpen() {
        let model = FeedbackModel(
            accountsProvider: { [] },
            tokenProvider: { _ in nil },
            tokenStore: { _, _ in },
            openURL: { _ in false }
        )

        model.createIssue(
            title: "Example",
            description: "Description",
            steps: nil,
            expectation: nil,
            actuallyHappened: nil
        )

        #expect(!model.didOpenIssueDraft)
        #expect(!model.isSubmitted)
        #expect(model.failedToSubmit)
    }

    @Test
    func findsGitHubTokenAndMigratesLegacyKey() {
        let gitLabAccount = makeAccount(provider: .gitlab, name: "gitlab-user")
        let gitHubAccount = makeAccount(provider: .github, name: "octocat")
        let legacyKey = gitHubAccount.legacyKeychainKeys[0]
        var migratedToken: (token: String, key: String)?
        let model = FeedbackModel(
            accountsProvider: { [] },
            tokenProvider: { key in
                key == legacyKey ? " legacy-token " : nil
            },
            tokenStore: { token, key in
                migratedToken = (token, key)
            },
            openURL: { _ in true }
        )

        let token = model.configuredGitHubToken(in: [gitLabAccount, gitHubAccount])

        #expect(token == "legacy-token")
        #expect(migratedToken?.token == "legacy-token")
        #expect(migratedToken?.key == gitHubAccount.keychainKey)
    }

    @Test
    func githubTokenConfigurationUsesBearerAuthentication() {
        let configuration = GitHubTokenConfiguration("secret-token")
        let request = GitHubUserRouter.readAuthenticatedUser(configuration).request()

        #expect(configuration.accessToken == "secret-token")
        #expect(configuration.authorizationHeader == "Bearer")
        #expect(request?.value(forHTTPHeaderField: "Authorization") == "Bearer secret-token")
    }

    private func makeAccount(
        provider: SourceControlAccount.Provider,
        name: String
    ) -> SourceControlAccount {
        SourceControlAccount(
            id: "\(provider.id)_\(name)",
            name: name,
            description: provider.name,
            provider: provider,
            serverURL: provider.baseURL?.absoluteString ?? "https://git.example.com",
            urlProtocol: .https,
            sshKey: "",
            isTokenValid: true
        )
    }
}
