//
//  DirtyDiffModel.swift
//  CodeEdit
//
//  Created by Abe Malla on 4/10/26.
//

import Foundation
import Combine
import CodeEditSourceEditor

/// Manages line-level diff state for a single open document.
///
/// This model computes the difference between the document's HEAD content (from git) and its current
/// buffer content, producing an array of `GutterChange` values that drive the gutter change indicators.
///
/// ## Design (following VSCode's QuickDiffModel architecture)
/// - Debounces diff computation with a 50ms delay on the main queue, then offloads to a background `Task`.
/// - Runs diff computation in a cancellable `Task.detached` to avoid blocking the main thread.
/// - Caches the original (HEAD) content and only refetches when the git index changes.
/// - Cancels in-flight fetch and diff tasks when superseded, preventing stale results from landing.
///
/// ## Thread Safety
/// All mutable state is accessed on the main thread only. The debounce pipeline is scheduled on
/// `DispatchQueue.main`, and diff computation captures values by copy before dispatching to background.
///
/// ## Lifecycle
/// One `DirtyDiffModel` per open editor tab. Created when a file is opened, destroyed when the tab closes.
final class DirtyDiffModel: ObservableObject {
    // MARK: - Published State

    /// The computed gutter changes for the current document state.
    @Published private(set) var gutterChanges: [GutterChange] = []

    // MARK: - Internal State (main-thread only)

    /// The file's original content from HEAD.
    private var originalContent: String?

    /// Whether we've attempted to fetch HEAD content at least once.
    private var hasFetchedOriginal = false

    /// The last document content received via ``documentDidChange(_:)``.
    /// Retained so the diff can be re-triggered after a late-arriving HEAD fetch.
    private var lastKnownContent: String?

    /// The git client used to fetch HEAD content.
    private weak var gitClient: GitClient?

    /// The relative path of the file in the repository.
    private let relativePath: String?

    /// Debounce subject for triggering diff computation. Scheduled on the main queue.
    private let diffTrigger = PassthroughSubject<String, Never>()

    /// In-flight diff computation task. Cancelled and replaced whenever a new computation starts.
    private var diffTask: Task<Void, Never>?

    /// In-flight HEAD content fetch task. Cancelled and replaced on index invalidation.
    private var fetchTask: Task<Void, Never>?

    private var cancellables = Set<AnyCancellable>()

    /// Observer token for git index change notifications.
    private var indexChangeObserver: NSObjectProtocol?

    // MARK: - Init

    /// Creates a dirty diff model for the given file.
    ///
    /// - Parameters:
    ///   - fileURL: The absolute URL of the file being edited.
    ///   - gitClient: The git client for the workspace.
    init(fileURL: URL, gitClient: GitClient?) {
        self.gitClient = gitClient
        self.relativePath = gitClient?.relativePath(for: fileURL.path)

        setupDiffDebounce()
        setupIndexChangeObserver()

        fetchTask = Task { [weak self] in
            await self?.fetchOriginalContent()
        }
    }

    deinit {
        if let observer = indexChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        diffTask?.cancel()
        fetchTask?.cancel()
    }

    // MARK: - Public API

    /// Call this when the document text changes.
    ///
    /// The diff computation is debounced — calling this rapidly will batch the calls.
    func documentDidChange(_ currentContent: String) {
        lastKnownContent = currentContent
        diffTrigger.send(currentContent)
    }

    /// Forces an immediate refetch of the HEAD content and recomputation of the diff.
    ///
    /// Call this when the git index changes (e.g., after a commit, checkout, or stage operation).
    /// Any in-flight fetch is cancelled before the new one starts.
    func invalidateOriginalContent() {
        hasFetchedOriginal = false
        fetchTask?.cancel()
        fetchTask = Task { [weak self] in
            await self?.fetchOriginalContent()
        }
    }

    // MARK: - Private

    /// Sets up the debounce pipeline. The debounce runs on the main queue so that `originalContent`
    /// and `hasFetchedOriginal` can be read safely before being captured by value into the background task.
    private func setupDiffDebounce() {
        diffTrigger
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .sink { [weak self] currentContent in
                self?.scheduleDiff(currentContent: currentContent)
            }
            .store(in: &cancellables)
    }

    /// Listens for git index change notifications on the main queue.
    private func setupIndexChangeObserver() {
        indexChangeObserver = NotificationCenter.default.addObserver(
            forName: .gitIndexDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.invalidateOriginalContent()
        }
    }

    /// Captures `originalContent` and `hasFetchedOriginal` by value on the main thread, then
    /// dispatches the CPU-bound diff computation to a background task. The previous task is
    /// cancelled so only the most recent computation can write to `gutterChanges`.
    private func scheduleDiff(currentContent: String) {
        let original = originalContent
        let fetched = hasFetchedOriginal

        diffTask?.cancel()
        diffTask = Task.detached(priority: .userInitiated) { [weak self] in
            let changes = DirtyDiffModel.computeChanges(original: original, fetched: fetched, current: currentContent)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.gutterChanges = changes
            }
        }
    }

    /// Pure, static diff computation — takes all inputs by value so it is safe to run on any thread.
    private static func computeChanges(original: String?, fetched: Bool, current: String) -> [GutterChange] {
        if let original {
            return LineDiffComputer.computeChanges(original: original, modified: current)
        } else if fetched {
            // File is new (not in HEAD) — all lines are "added".
            let lineCount = current.components(separatedBy: "\n").count
            return lineCount > 0 ? [GutterChange(type: .added, lineRange: 0..<lineCount)] : []
        } else {
            // Haven't fetched original yet — no changes to show.
            return []
        }
    }

    /// Fetches the file's content from HEAD asynchronously. On completion, schedules a diff
    /// using the latest known document content. No-ops if the task is cancelled.
    private func fetchOriginalContent() async {
        guard let gitClient, let relativePath, !relativePath.isEmpty else {
            await MainActor.run {
                self.originalContent = nil
                self.hasFetchedOriginal = true
            }
            return
        }

        do {
            let content = try await gitClient.getHeadFileContent(relativePath: relativePath)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.originalContent = content
                self.hasFetchedOriginal = true
                if let currentContent = self.lastKnownContent {
                    self.scheduleDiff(currentContent: currentContent)
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.originalContent = nil
                self.hasFetchedOriginal = true
                if let currentContent = self.lastKnownContent {
                    self.scheduleDiff(currentContent: currentContent)
                }
            }
        }
    }
}

// MARK: - Notification Name

extension Notification.Name {
    /// Posted when the git index changes and dirty diff models should refetch their original content.
    static let gitIndexDidChange = Notification.Name("CodeEdit.gitIndexDidChange")
}
