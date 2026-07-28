//
//  WorkspaceDocument+CommandListeners.swift
//  CodeEdit
//
//  Created by Khan Winter on 6/5/22.
//

import Foundation
import Combine

class WorkspaceNotificationModel: ObservableObject {

    @Published var highlightedFileItem: CEWorkspaceFile?

    /// The file item the project navigator should begin an inline rename for.
    ///
    /// Set this after creating a new file or folder so the user can immediately type its name.
    @Published var fileItemToRename: CEWorkspaceFile?

    init() {
        highlightedFileItem = nil
    }

}
