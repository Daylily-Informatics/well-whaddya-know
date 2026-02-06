// SPDX-License-Identifier: MIT
// IPCClientHandler.swift - Handles individual IPC client connections

import Foundation
import XPCProtocol

/// Handles a single IPC client connection
final class ClientHandler: @unchecked Sendable {
    
    private let socket: Int32
    private let service: AgentService
    private var isClosed = false
    
    init(socket: Int32, service: AgentService) {
        self.socket = socket
        self.service = service
    }
    
    func close() {
        guard !isClosed else { return }
        isClosed = true
        Darwin.close(socket)
    }
    
    func run() async {
        defer { close() }
        
        while !isClosed && !Task.isCancelled {
            // Read message length (4 bytes, big-endian)
            var lengthBytes = [UInt8](repeating: 0, count: 4)
            let lenRead = recv(socket, &lengthBytes, 4, MSG_WAITALL)
            guard lenRead == 4 else { break }
            
            let length = Int(UInt32(bigEndian: Data(lengthBytes).withUnsafeBytes { $0.load(as: UInt32.self) }))
            guard length > 0 && length < 10_000_000 else { break } // Max 10MB
            
            // Read message body
            var messageBytes = [UInt8](repeating: 0, count: length)
            let msgRead = recv(socket, &messageBytes, length, MSG_WAITALL)
            guard msgRead == length else { break }
            
            // Parse and handle request
            let response = await handleRequest(Data(messageBytes))
            
            // Send response
            guard let responseData = try? JSONEncoder().encode(response) else { continue }
            var respLength = UInt32(responseData.count).bigEndian
            let lengthData = withUnsafeBytes(of: &respLength) { Data($0) }
            
            _ = lengthData.withUnsafeBytes { send(socket, $0.baseAddress, 4, 0) }
            _ = responseData.withUnsafeBytes { send(socket, $0.baseAddress, responseData.count, 0) }
        }
    }
    
    private func handleRequest(_ data: Data) async -> IPCResponse {
        guard let request = try? JSONDecoder().decode(IPCRequest.self, from: data) else {
            return .error(id: "", code: IPCErrorCode.invalidRequest, message: "Invalid request format")
        }
        
        do {
            let result = try await dispatch(request)
            return IPCResponse(id: request.id, result: result, error: nil)
        } catch let error as XPCError {
            return .error(id: request.id, code: errorCode(for: error), message: error.localizedDescription)
        } catch {
            return .error(id: request.id, code: IPCErrorCode.internalError, message: error.localizedDescription)
        }
    }
    
    private func dispatch(_ request: IPCRequest) async throws -> Data? {
        let encoder = JSONEncoder()
        
        switch request.method {
        case IPCMethod.getStatus:
            let status = try await service.getStatus()
            return try encoder.encode(status)
            
        case IPCMethod.submitDeleteRange:
            let req = try decode(DeleteRangeRequest.self, from: request.params)
            let id = try await service.submitDeleteRange(req)
            return try encoder.encode(["uee_id": id])
            
        case IPCMethod.submitAddRange:
            let req = try decode(AddRangeRequest.self, from: request.params)
            let id = try await service.submitAddRange(req)
            return try encoder.encode(["uee_id": id])
            
        case IPCMethod.submitUndoEdit:
            let req = try decode(UndoEditParams.self, from: request.params)
            let id = try await service.submitUndoEdit(targetUeeId: req.targetUeeId)
            return try encoder.encode(["uee_id": id])
            
        case IPCMethod.applyTag:
            let req = try decode(TagRangeRequest.self, from: request.params)
            let id = try await service.applyTag(req)
            return try encoder.encode(["uee_id": id])
            
        case IPCMethod.removeTag:
            let req = try decode(TagRangeRequest.self, from: request.params)
            let id = try await service.removeTag(req)
            return try encoder.encode(["uee_id": id])
            
        case IPCMethod.listTags:
            let tags = try await service.listTags()
            return try encoder.encode(tags)
            
        case IPCMethod.createTag:
            let req = try decode(CreateTagParams.self, from: request.params)
            let id = try await service.createTag(name: req.name)
            return try encoder.encode(["tag_id": id])
            
        case IPCMethod.retireTag:
            let req = try decode(RetireTagParams.self, from: request.params)
            try await service.retireTag(name: req.name)
            return try encoder.encode(["success": true])
            
        case IPCMethod.exportTimeline:
            let req = try decode(ExportRequest.self, from: request.params)
            try await service.exportTimeline(req)
            return try encoder.encode(["success": true])
            
        case IPCMethod.getHealth:
            let health = try await service.getHealth()
            return try encoder.encode(health)
            
        case IPCMethod.verifyDatabase:
            try await service.verifyDatabase()
            return try encoder.encode(["success": true])

        case IPCMethod.pauseTracking:
            try await service.pauseTracking()
            return try encoder.encode(["success": true])

        case IPCMethod.resumeTracking:
            try await service.resumeTracking()
            return try encoder.encode(["success": true])

        default:
            throw IPCClientError.serverError(code: IPCErrorCode.methodNotFound, message: "Unknown method: \(request.method)")
        }
    }
    
    private func decode<T: Decodable>(_ type: T.Type, from data: Data?) throws -> T {
        guard let data = data else {
            throw XPCError.invalidInput(message: "Missing parameters")
        }
        return try JSONDecoder().decode(type, from: data)
    }
    
    private func errorCode(for error: XPCError) -> Int {
        switch error {
        case .invalidTimeRange: return IPCErrorCode.invalidTimeRange
        case .agentNotRunning: return IPCErrorCode.agentNotRunning
        case .tagNotFound: return IPCErrorCode.tagNotFound
        case .tagAlreadyExists: return IPCErrorCode.tagAlreadyExists
        case .undoTargetNotFound: return IPCErrorCode.undoTargetNotFound
        case .undoTargetAlreadyUndone: return IPCErrorCode.undoTargetAlreadyUndone
        case .databaseError: return IPCErrorCode.databaseError
        case .invalidInput: return IPCErrorCode.invalidParams
        case .exportFailed: return IPCErrorCode.exportFailed
        case .permissionDenied: return IPCErrorCode.permissionDenied
        }
    }
}

// Parameter types for methods that need custom params
private struct UndoEditParams: Codable { let targetUeeId: Int64 }
private struct CreateTagParams: Codable { let name: String }
private struct RetireTagParams: Codable { let name: String }

