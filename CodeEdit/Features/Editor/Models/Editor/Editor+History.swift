//
//  Editor+History.swift
//  CodeEdit
//
//  Created by Khan Winter on 7/9/24.
//

import Foundation

/// Methods for modifying the history list on the editor.
extension Editor {
    /// Add the tab to the history list.
    /// - Parameter tab: The tab to add to the history.
    func addToHistory(_ tab: Tab) {
        if history.first != tab.file {
            history.prepend(tab.file)
        }
    }

    /// Clear any tabs in the "future" on the history list. Resets the history offset and removes any tabs that were
    /// available to navigate forwards to.
    /// - Note: This sets historyOffset directly without triggering ``historyOffsetDidChange()`` to avoid
    ///         cascading @Published modifications.
    func clearFuture() {
        guard historyOffset > 0 else { return } // nothing to clear, avoid an out of bounds error
        history.removeFirst(historyOffset)
        historyOffset = 0
    }

    /// Move backwards in the history list by one place.
    func goBackInHistory() {
        if canGoBackInHistory {
            setHistoryOffset(historyOffset + 1)
        }
    }

    /// Move forwards in the history list by one place.
    func goForwardInHistory() {
        if canGoForwardInHistory {
            setHistoryOffset(historyOffset - 1)
        }
    }

    /// Sets the history offset and triggers the associated side effects.
    /// - Parameter newOffset: The new history offset value.
    func setHistoryOffset(_ newOffset: Int) {
        historyOffset = newOffset
        historyOffsetDidChange()
    }

    // TODO: move to @Observable so this works better
    /// Warning: NOT published!
    var canGoBackInHistory: Bool {
        historyOffset != history.count - 1 && !history.isEmpty
    }

    // TODO: move to @Observable so this works better
    /// Warning: NOT published!
    var canGoForwardInHistory: Bool {
        historyOffset != 0
    }

    /// Called when the history offset is changed via ``setHistoryOffset(_:)``.
    ///
    /// This method updates the selected tab to the current tab in the history offset.
    /// If the tab is not opened, it is opened without modifying the history list.
    /// - Warning: Do not use directly. Use ``setHistoryOffset(_:)`` instead.
    func historyOffsetDidChange() {
        let file = history[historyOffset]

        if !tabs.contains(where: { $0.file == file }) {
            if let temporaryTab, tabs.contains(temporaryTab) {
                closeTab(file: temporaryTab.file, fromHistory: true)
            }
            openTab(file: file, fromHistory: true)
            if let tab = tabs.first(where: { $0.file.id == file.id }) {
                temporaryTab = tab
            }
        }
        setSelectedTab(file)
    }
}
