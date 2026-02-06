// SPDX-License-Identifier: MIT
// IPCClient.swift - IPC client for connecting to wwkd agent via Unix domain socket

import Foundation

// IPCClientError is defined in IPCProtocol.swift

/// IPC client for communicating with the wwkd agent
/// Thread-safe and can be used from any context
public final class IPCClient: @unchecked Sendable {
    private let socketPath: String
    private let timeout: TimeInterval
    
    /// Initialize with socket path
    /// - Parameters:
    ///   - socketPath: Path to the Unix domain socket (defaults to standard location)
    ///   - timeout: Timeout in seconds for operations (default 5 seconds)
    public init(socketPath: String? = nil, timeout: TimeInterval = 5.0) {
        self.socketPath = socketPath ?? getIPCSocketPath()
        self.timeout = timeout
    }
    
    /// Check if the agent socket exists
    public var isAgentAvailable: Bool {
        FileManager.default.fileExists(atPath: socketPath)
    }
    
    /// Send a request to the agent and receive a response
    public func send<T: Decodable>(_ request: IPCRequest) async throws -> T {
        // Check socket exists first
        guard isAgentAvailable else {
            throw IPCClientError.agentNotRunning
        }
        
        // Create socket
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            throw IPCClientError.connectionFailed("Failed to create socket: \(String(cString: strerror(errno)))")
        }
        defer { close(sock) }
        
        // Set timeout
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        
        // Connect to server
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        
        // Copy path into sun_path
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                let count = min(strlen(src), pathSize - 1)
                memcpy(dest.baseAddress!, src, count)
                dest[count] = 0
            }
        }
        
        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard connectResult == 0 else {
            if errno == ECONNREFUSED || errno == ENOENT {
                throw IPCClientError.agentNotRunning
            }
            throw IPCClientError.connectionFailed("Connect failed: \(String(cString: strerror(errno)))")
        }
        
        // Encode and send request
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let requestData = try encoder.encode(request)
        
        // Send length prefix (4 bytes, big-endian)
        var length = UInt32(requestData.count).bigEndian
        let lengthSent = Darwin.send(sock, &length, 4, 0)
        guard lengthSent == 4 else {
            throw IPCClientError.sendFailed("Failed to send length")
        }
        
        // Send message body
        let bodySent = requestData.withUnsafeBytes { ptr in
            Darwin.send(sock, ptr.baseAddress!, requestData.count, 0)
        }
        guard bodySent == requestData.count else {
            throw IPCClientError.sendFailed("Failed to send body")
        }
        
        // Receive response length
        var responseLength: UInt32 = 0
        let lengthReceived = Darwin.recv(sock, &responseLength, 4, 0)
        guard lengthReceived == 4 else {
            if lengthReceived == 0 {
                throw IPCClientError.agentNotRunning
            }
            throw IPCClientError.receiveFailed("Failed to receive length")
        }
        responseLength = UInt32(bigEndian: responseLength)
        
        // Receive response body
        var responseData = Data(count: Int(responseLength))
        let bodyReceived = responseData.withUnsafeMutableBytes { ptr in
            Darwin.recv(sock, ptr.baseAddress!, Int(responseLength), MSG_WAITALL)
        }
        guard bodyReceived == Int(responseLength) else {
            throw IPCClientError.receiveFailed("Failed to receive body")
        }
        
        // Decode response
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(IPCResponse.self, from: responseData)
        
        // Check for error
        if let error = response.error {
            throw IPCClientError.serverError(code: error.code, message: error.message)
        }
        
        // Decode result
        guard let resultData = response.result else {
            throw IPCClientError.invalidResponse("No result in response")
        }
        
        return try decoder.decode(T.self, from: resultData)
    }

    // MARK: - Convenience Methods

    /// Get agent status
    public func getStatus() async throws -> StatusResponse {
        let request = IPCRequest(method: IPCMethod.getStatus)
        return try await send(request)
    }

    /// Get agent health
    public func getHealth() async throws -> HealthStatus {
        let request = IPCRequest(method: IPCMethod.getHealth)
        return try await send(request)
    }

    /// Delete a time range
    public func deleteRange(_ deleteRequest: DeleteRangeRequest) async throws -> Int64 {
        let request = try IPCRequest(method: IPCMethod.submitDeleteRange, params: deleteRequest)
        let wrapper: [String: Int64] = try await send(request)
        guard let id = wrapper["uee_id"] else {
            throw IPCClientError.invalidResponse("Missing uee_id in response")
        }
        return id
    }

    /// Add a time range
    public func addRange(_ addRequest: AddRangeRequest) async throws -> Int64 {
        let request = try IPCRequest(method: IPCMethod.submitAddRange, params: addRequest)
        let wrapper: [String: Int64] = try await send(request)
        guard let id = wrapper["uee_id"] else {
            throw IPCClientError.invalidResponse("Missing uee_id in response")
        }
        return id
    }

    /// Undo an edit
    public func undoEdit(targetUeeId: Int64) async throws -> Int64 {
        let request = try IPCRequest(method: IPCMethod.submitUndoEdit, params: ["targetUeeId": targetUeeId])
        let wrapper: [String: Int64] = try await send(request)
        guard let id = wrapper["uee_id"] else {
            throw IPCClientError.invalidResponse("Missing uee_id in response")
        }
        return id
    }

    /// Apply a tag to a range
    public func applyTag(_ tagRequest: TagRangeRequest) async throws -> Int64 {
        let request = try IPCRequest(method: IPCMethod.applyTag, params: tagRequest)
        let wrapper: [String: Int64] = try await send(request)
        guard let id = wrapper["uee_id"] else {
            throw IPCClientError.invalidResponse("Missing uee_id in response")
        }
        return id
    }

    /// Remove a tag from a range
    public func removeTag(_ tagRequest: TagRangeRequest) async throws -> Int64 {
        let request = try IPCRequest(method: IPCMethod.removeTag, params: tagRequest)
        let wrapper: [String: Int64] = try await send(request)
        guard let id = wrapper["uee_id"] else {
            throw IPCClientError.invalidResponse("Missing uee_id in response")
        }
        return id
    }

    /// List all tags
    public func listTags() async throws -> [TagInfo] {
        let request = IPCRequest(method: IPCMethod.listTags)
        return try await send(request)
    }

    /// Create a new tag
    public func createTag(name: String) async throws -> Int64 {
        let request = try IPCRequest(method: IPCMethod.createTag, params: ["name": name])
        let wrapper: [String: Int64] = try await send(request)
        guard let id = wrapper["tag_id"] else {
            throw IPCClientError.invalidResponse("Missing tag_id in response")
        }
        return id
    }

    /// Retire a tag
    public func retireTag(name: String) async throws {
        let request = try IPCRequest(method: IPCMethod.retireTag, params: ["name": name])
        let _: [String: Bool] = try await send(request)
    }

    /// Export timeline
    public func exportTimeline(_ exportRequest: ExportRequest) async throws {
        let request = try IPCRequest(method: IPCMethod.exportTimeline, params: exportRequest)
        let _: [String: Bool] = try await send(request)
    }

    /// Pause tracking
    public func pauseTracking() async throws {
        let request = IPCRequest(method: IPCMethod.pauseTracking)
        let _: [String: Bool] = try await send(request)
    }

    /// Resume tracking
    public func resumeTracking() async throws {
        let request = IPCRequest(method: IPCMethod.resumeTracking)
        let _: [String: Bool] = try await send(request)
    }

    /// Verify database integrity
    public func verifyDatabase() async throws {
        let request = IPCRequest(method: IPCMethod.verifyDatabase)
        let _: [String: Bool] = try await send(request)
    }
}

