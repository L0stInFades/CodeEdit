//
//  DirtyDiffCoordinator.swift
//  CodeEdit
//
//  Created by Abe Malla on 4/10/26.
//

import Foundation
import Combine
import CodeEditSourceEditor
import CodeEditTextView

/// A `TextViewCoordinator` that bridges the `DirtyDiffModel` with the source editor's `TextViewController`.
///
/// Responsibilities:
/// 1. Observes `DirtyDiffModel.gutterChanges` and pushes updates to `TextViewController.gutterChanges`.
/// 2. Forwards text change notifications from the editor to `DirtyDiffModel.documentDidChange()`.
///
/// Text changes are detected via `TextView.textDidChangeNotification` rather than
/// `textViewDidChangeText`, because TextFormation filters (e.g. auto-indent on Enter)
/// apply mutations through `textView.applyMutation()` which bypasses the delegate
/// callback chain. The notification is posted at the end of every `replaceCharacters`
/// call regardless of filter outcomes.
final class DirtyDiffCoordinator: TextViewCoordinator {
    private let dirtyDiffModel: DirtyDiffModel
    private weak var controller: TextViewController?
    private var cancellable: AnyCancellable?
    private var textChangeObserver: NSObjectProtocol?

    init(dirtyDiffModel: DirtyDiffModel) {
        self.dirtyDiffModel = dirtyDiffModel
    }

    func prepareCoordinator(controller: TextViewController) {
        self.controller = controller

        // Push any already-computed changes immediately so the gutter is populated
        // when switching back to this tab.
        controller.gutterChanges = dirtyDiffModel.gutterChanges

        // Observe the text view's textDidChangeNotification. This fires for ALL edits
        // including those applied by TextFormation filters (e.g. newline + auto-indent)
        // which bypass the TextViewDelegate callback chain.
        if let observer = textChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        textChangeObserver = NotificationCenter.default.addObserver(
            forName: TextView.textDidChangeNotification,
            object: controller.textView,
            queue: .main
        ) { [weak self, weak controller] _ in
            guard let self, let controller else { return }
            self.dirtyDiffModel.documentDidChange(controller.text)
        }

        // Observe model changes and forward to gutter
        cancellable = dirtyDiffModel.$gutterChanges
            .receive(on: DispatchQueue.main)
            .sink { [weak controller] changes in
                controller?.gutterChanges = changes
            }
    }

    func controllerDidAppear(controller: TextViewController) {
        // setTextStorage does NOT post textDidChangeNotification, so the notification
        // observer won't fire on initial load.
        let text = controller.text
        if !text.isEmpty {
            dirtyDiffModel.documentDidChange(text)
        }
    }

    func textViewDidChangeText(controller: TextViewController) {
        // Handled by textDidChangeNotification observer instead.
    }

    func destroy() {
        cancellable?.cancel()
        cancellable = nil
        if let observer = textChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            textChangeObserver = nil
        }
        controller = nil
    }
}
