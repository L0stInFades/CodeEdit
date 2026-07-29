//
//  FeedbackModel.swift
//  CodeEditModules/Feedback
//
//  Created by Nanashi Li on 2022/04/14.
//

import AppKit
import SwiftUI

@MainActor
public class FeedbackModel: ObservableObject {

    public static let shared: FeedbackModel = .init()

    private let accountsProvider: () -> [SourceControlAccount]
    private let tokenProvider: (String) -> String?
    private let tokenStore: (_ token: String, _ key: String) -> Void
    private let openURL: (URL) -> Bool

    @Published var isSubmitted: Bool = false
    @Published var didOpenIssueDraft: Bool = false
    @Published var failedToSubmit: Bool = false
    @Published var feedbackTitle: String = ""
    @Published var issueDescription: String = ""
    @Published var stepsReproduceDescription: String = ""
    @Published var expectationDescription: String = ""
    @Published var whatHappenedDescription: String = ""
    @Published var issueAreaListSelection: FeedbackIssueArea.ID = "none"
    @Published var feedbackTypeListSelection: FeedbackType.ID = "none"

    @Published var feedbackTypeList = [
        FeedbackType(name: "Choose...", id: "none"),
        FeedbackType(name: "Incorrect/Unexpected Behaviour", id: "behaviour"),
        FeedbackType(name: "Application Crash", id: "crash"),
        FeedbackType(name: "Application Slow/Unresponsive", id: "unresponsive"),
        FeedbackType(name: "Suggestion", id: "suggestions"),
        FeedbackType(name: "Other", id: "other")
    ]

    @Published var issueAreaList = [
        FeedbackIssueArea(name: "Please select the problem area", id: "none"),
        FeedbackIssueArea(name: "Project Navigator", id: "projectNavigator"),
        FeedbackIssueArea(name: "Extensions", id: "extensions"),
        FeedbackIssueArea(name: "Git", id: "git"),
        FeedbackIssueArea(name: "Debugger", id: "debugger"),
        FeedbackIssueArea(name: "Editor", id: "editor"),
        FeedbackIssueArea(name: "Other", id: "other")
    ]

    init(
        accountsProvider: @escaping () -> [SourceControlAccount] = {
            Settings[\.accounts].sourceControlAccounts.gitAccounts
        },
        tokenProvider: ((String) -> String?)? = nil,
        tokenStore: ((_ token: String, _ key: String) -> Void)? = nil,
        openURL: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) {
        let keychain = CodeEditKeychain()
        self.accountsProvider = accountsProvider
        self.tokenProvider = tokenProvider ?? { keychain.get($0) }
        self.tokenStore = tokenStore ?? { token, key in
            keychain.set(token, forKey: key)
        }
        self.openURL = openURL
    }

    /// Gets the ID of the selected issue type and then
    /// cross references it to select the right Label based on the type
    private func getIssueLabel() -> String {
        switch issueAreaListSelection {
        case "projectNavigator":
            return "Project Navigator"
        case "extensions":
            return "Extensions"
        case "git":
            return "Git"
        case "debugger":
            return "Debugger"
        case "editor":
            return "Editor"
        case "other":
            return "Other"
        default:
            return "Other"
        }
    }

    /// This is just temporary till we have bot that will handle this
    private func getFeedbackTypeTitle() -> String {
        switch feedbackTypeListSelection {
        case "behaviour":
            return "🐞"
        case "crash":
            return "🐞"
        case "unresponsive":
            return "🐞"
        case "suggestions":
            return "✨"
        case "other":
            return "📬"
        default:
            return "Other"
        }
    }

    /// Gets the ID of the selected feedback type and then
    /// cross references it to select the right Label based on the type
    private func getFeedbackTypeLabel() -> String {
        switch feedbackTypeListSelection {
        case "behaviour":
            return "Bug"
        case "crash":
            return "Bug"
        case "unresponsive":
            return "Bug"
        case "suggestions":
            return "Suggestion"
        case "other":
            return "Feedback"
        default:
            return "Other"
        }
    }

    /// The format for the issue body is how it will be displayed on
    /// repos issues. If any changes are made use markdown format
    /// because the text gets converted when created.
    private func createIssueBody(
        description: String,
        steps: String?,
        expectation: String?,
        actuallyHappened: String?
    ) -> String {
        """
        **Description**

        \(description)

        **Steps to Reproduce**

        \(steps ?? "N/A")

        **What did you expect to happen?**

        \(expectation ?? "N/A")

        **What actually happened?**

        \(actuallyHappened ?? "N/A")
        """
    }

    public func createIssue(
        title: String,
        description: String,
        steps: String?,
        expectation: String?,
        actuallyHappened: String?
    ) {
        resetSubmissionState()
        let gitAccounts = accountsProvider()
        let issueTitle = "\(getFeedbackTypeTitle()) \(title)"
        let issueBody = createIssueBody(
            description: description,
            steps: steps,
            expectation: expectation,
            actuallyHappened: actuallyHappened
        )

        guard let token = configuredGitHubToken(in: gitAccounts) else {
            openNewIssueInBrowser(title: issueTitle, body: issueBody)
            return
        }

        let config = GitHubTokenConfiguration(token)
        GitHubAccount(config).postIssue(
            owner: "CodeEditApp",
            repository: "CodeEdit",
            title: issueTitle,
            body: issueBody,
            assignee: "",
            labels: [getFeedbackTypeLabel(), getIssueLabel()]
        ) { [weak self] response in
            Task { @MainActor in
                guard let self else { return }
                switch response {
                case .success(let issue):
                    if Settings[\.sourceControl].general.openFeedbackInBrowser {
                        _ = self.openURL(
                            issue.htmlURL ?? URL(string: "https://github.com/CodeEditApp/CodeEdit/issues")!
                        )
                    }
                    self.isSubmitted = true
                    print(issue)
                case .failure(let error):
                    print(error)
                    self.openNewIssueInBrowser(title: issueTitle, body: issueBody)
                }
            }
        }
    }

    func configuredGitHubToken(in accounts: [SourceControlAccount]) -> String? {
        for account in accounts where account.isTokenValid {
            guard case .github = account.provider else { continue }
            for key in [account.keychainKey] + account.legacyKeychainKeys {
                guard let token = tokenProvider(key)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !token.isEmpty else {
                    continue
                }
                if key != account.keychainKey {
                    tokenStore(token, account.keychainKey)
                }
                return token
            }
        }
        return nil
    }

    private func resetSubmissionState() {
        isSubmitted = false
        didOpenIssueDraft = false
        failedToSubmit = false
    }

    /// Opens a pre-filled GitHub issue draft in the browser when API submission is unavailable.
    @discardableResult
    func openNewIssueInBrowser(title: String, body: String) -> Bool {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/CodeEditApp/CodeEdit/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: body),
            URLQueryItem(name: "labels", value: [getFeedbackTypeLabel(), getIssueLabel()].joined(separator: ","))
        ]
        guard let url = components.url else {
            failedToSubmit = true
            return false
        }
        let didOpen = openURL(url)
        didOpenIssueDraft = didOpen
        failedToSubmit = !didOpen
        return didOpen
    }
}
