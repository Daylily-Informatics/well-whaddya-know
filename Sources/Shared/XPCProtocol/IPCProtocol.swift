// SPDX-License-Identifier: MIT
// IPCProtocol.swift - Unix domain socket IPC protocol for agent communication

import Foundation

// MARK: - IPC Constants

/// Path for the Unix domain socket in the App Group container
public func getIPCSocketPath() -> String {
    let appGroupId = "group.com.daylily.wellwhaddyaknow"
    
    // Try App Group container first
    if let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupId
    ) {
        return containerURL.appendingPathComponent("wwk.sock").path
    }
    
    // Fallback for non-sandboxed tools
    let home = FileManager.default.homeDirectoryForCurrentUser
    let groupContainers = home.appendingPathComponent("Library/Group Containers", isDirectory: true)
    let appGroup = groupContainers.appendingPathComponent(appGroupId, isDirectory: true)
    return appGroup.appendingPathComponent("wwk.sock").path
}

// MARK: - IPC Message Types

/// IPC request envelope
public struct IPCRequest: Codable, Sendable {
    public let id: String
    public let method: String
    public let params: Data?
    
    public init(id: String = UUID().uuidString, method: String, params: Data? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
    
    public init<T: Encodable>(id: String = UUID().uuidString, method: String, params: T) throws {
        self.id = id
        self.method = method
        self.params = try JSONEncoder().encode(params)
    }
}

/// IPC response envelope
public struct IPCResponse: Codable, Sendable {
    public let id: String
    public let result: Data?
    public let error: IPCErrorResponse?
    
    public init(id: String, result: Data? = nil, error: IPCErrorResponse? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }
    
    public static func success<T: Encodable>(id: String, result: T) throws -> IPCResponse {
        IPCResponse(id: id, result: try JSONEncoder().encode(result), error: nil)
    }
    
    public static func error(id: String, code: Int, message: String) -> IPCResponse {
        IPCResponse(id: id, result: nil, error: IPCErrorResponse(code: code, message: message))
    }
    
    public func decode<T: Decodable>(_ type: T.Type) throws -> T {
        guard let data = result else {
            if let err = error {
                throw IPCClientError.serverError(code: err.code, message: err.message)
            }
            throw IPCClientError.emptyResponse
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

/// IPC error response
public struct IPCErrorResponse: Codable, Sendable {
    public let code: Int
    public let message: String
    
    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

// MARK: - IPC Error Codes

public enum IPCErrorCode {
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    public static let agentNotRunning = -32000
    public static let tagNotFound = -32001
    public static let tagAlreadyExists = -32002
    public static let undoTargetNotFound = -32003
    public static let undoTargetAlreadyUndone = -32004
    public static let invalidTimeRange = -32005
    public static let databaseError = -32006
    public static let exportFailed = -32007
    public static let permissionDenied = -32008
}

// MARK: - IPC Client Errors

public enum IPCClientError: Error, LocalizedError, Sendable {
    case connectionFailed(String)
    case serverError(code: Int, message: String)
    case emptyResponse
    case encodingError(String)
    case decodingError(String)
    case timeout
    case socketClosed
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .serverError(_, let msg): return msg
        case .emptyResponse: return "Empty response from server"
        case .encodingError(let msg): return "Encoding error: \(msg)"
        case .decodingError(let msg): return "Decoding error: \(msg)"
        case .timeout: return "Request timed out"
        case .socketClosed: return "Socket connection closed"
        }
    }
}

// MARK: - IPC Method Names

public enum IPCMethod {
    public static let getStatus = "getStatus"
    public static let submitDeleteRange = "submitDeleteRange"
    public static let submitAddRange = "submitAddRange"
    public static let submitUndoEdit = "submitUndoEdit"
    public static let applyTag = "applyTag"
    public static let removeTag = "removeTag"
    public static let listTags = "listTags"
    public static let createTag = "createTag"
    public static let retireTag = "retireTag"
    public static let exportTimeline = "exportTimeline"
    public static let getHealth = "getHealth"
    public static let verifyDatabase = "verifyDatabase"
}

