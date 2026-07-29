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

    /// Emits after creating a file or folder so the project navigator can begin an inline rename.
    let fileItemToRename = PassthroughSubject<CEWorkspaceFile, Never>()

    init() {
        highlightedFileItem = nil
    }

}
