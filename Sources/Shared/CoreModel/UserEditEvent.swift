// SPDX-License-Identifier: MIT
// UserEditEvent.swift - In-memory representation of user_edit_events

import Foundation

// MARK: - User Edit Event

/// In-memory representation of a user_edit_events row
/// Used as input to timeline builder
public struct UserEditEvent: Sendable, Equatable {
    public let ueeId: Int64
    public let createdTsUs: Int64
    public let createdMonotonicNs: UInt64
    
    public let authorUsername: String
    public let authorUid: Int
    
    public let client: EditClient
    public let clientVersion: String
    
    public let op: EditOperation
    
    // Time range affected by this edit
    public let startTsUs: Int64
    public let endTsUs: Int64
    
    // Tag operations
    public let tagId: Int64?
    public let tagName: String?  // Denormalized for convenience
    
    // Manual add attribution (only for add_range)
    public let manualAppBundleId: String?
    public let manualAppName: String?
    public let manualWindowTitle: String?
    
    public let note: String?
    
    // Undo support - targets another edit
    public let targetUeeId: Int64?
    
    public let payloadJson: String?
    
    public init(
        ueeId: Int64,
        createdTsUs: Int64,
        createdMonotonicNs: UInt64,
        authorUsername: String,
        authorUid: Int,
        client: EditClient,
        clientVersion: String,
        op: EditOperation,
        startTsUs: Int64,
        endTsUs: Int64,
        tagId: Int64? = nil,
        tagName: String? = nil,
        manualAppBundleId: String? = nil,
        manualAppName: String? = nil,
        manualWindowTitle: String? = nil,
        note: String? = nil,
        targetUeeId: Int64? = nil,
        payloadJson: String? = nil
    ) {
        self.ueeId = ueeId
        self.createdTsUs = createdTsUs
        self.createdMonotonicNs = createdMonotonicNs
        self.authorUsername = authorUsername
        self.authorUid = authorUid
        self.client = client
        self.clientVersion = clientVersion
        self.op = op
        self.startTsUs = startTsUs
        self.endTsUs = endTsUs
        self.tagId = tagId
        self.tagName = tagName
        self.manualAppBundleId = manualAppBundleId
        self.manualAppName = manualAppName
        self.manualWindowTitle = manualWindowTitle
        self.note = note
        self.targetUeeId = targetUeeId
        self.payloadJson = payloadJson
    }
}

public enum EditClient: String, Sendable, Equatable {
    case ui = "ui"
    case cli = "cli"
}

public enum EditOperation: String, Sendable, Equatable {
    case deleteRange = "delete_range"
    case addRange = "add_range"
    case tagRange = "tag_range"
    case untagRange = "untag_range"
    case undoEdit = "undo_edit"
}

