//
//  RepositoryAction.swift
//  FSNotes
//
//  Created by Oleksandr Hlushchenko on 13.03.2023.
//  Copyright © 2023 Oleksandr Hlushchenko. All rights reserved.
//

import Foundation

public enum RepositoryAction: Int, CaseIterable {
    case initCommit
    case commit

    var title: String {
        switch self {
        case .initCommit: return "Enable Local History"
        case .commit: return "Save Local Snapshot"
        }
    }
}
