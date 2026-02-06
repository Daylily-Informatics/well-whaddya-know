// SPDX-License-Identifier: MIT
// IPCServer.swift - Unix domain socket IPC server for the background agent

import Foundation
import XPCProtocol

/// Unix domain socket server for IPC communication
public final class IPCServer: @unchecked Sendable {
    
    private let socketPath: String
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let service: AgentService
    private var acceptTask: Task<Void, Never>?
    private let clientHandlers = ClientHandlerManager()
    
    public init(socketPath: String, service: AgentService) {
        self.socketPath = socketPath
        self.service = service
    }
    
    deinit {
        stop()
    }
    
    // MARK: - Lifecycle
    
    public func start() throws {
        // Remove existing socket file
        unlink(socketPath)
        
        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            throw IPCServerError.socketCreationFailed(errno: errno)
        }
        
        // Set socket options
        var reuseAddr: Int32 = 1
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))
        
        // Bind to path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy path into sun_path, avoiding overlapping access
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        socketPath.withCString { src in
            withUnsafeMutableBytes(of: &addr.sun_path) { dest in
                let count = min(strlen(src), pathSize - 1)
                memcpy(dest.baseAddress!, src, count)
                dest[count] = 0 // null terminate
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        
        guard bindResult == 0 else {
            close(serverSocket)
            throw IPCServerError.bindFailed(errno: errno)
        }
        
        // Set socket permissions (owner read/write only)
        chmod(socketPath, S_IRUSR | S_IWUSR)
        
        // Listen for connections
        guard listen(serverSocket, 5) == 0 else {
            close(serverSocket)
            unlink(socketPath)
            throw IPCServerError.listenFailed(errno: errno)
        }
        
        isRunning = true
        print("wwkd: IPC server listening on \(socketPath)")
        
        // Start accepting connections in background
        acceptTask = Task { [weak self] in
            await self?.acceptLoop()
        }
    }
    
    public func stop() {
        guard isRunning else { return }
        isRunning = false
        
        acceptTask?.cancel()
        acceptTask = nil
        
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }
        
        unlink(socketPath)
        clientHandlers.cancelAll()
        print("wwkd: IPC server stopped")
    }
    
    // MARK: - Accept Loop
    
    private func acceptLoop() async {
        while isRunning && !Task.isCancelled {
            let clientSocket = accept(serverSocket, nil, nil)
            guard clientSocket >= 0 else {
                if isRunning && errno != EINTR {
                    print("wwkd: Accept error: \(errno)")
                }
                continue
            }
            
            // Handle client in separate task
            let handler = ClientHandler(socket: clientSocket, service: service)
            clientHandlers.add(handler)
            
            Task {
                await handler.run()
                self.clientHandlers.remove(handler)
            }
        }
    }
}

// MARK: - Client Handler Manager

private final class ClientHandlerManager: @unchecked Sendable {
    private var handlers: [ObjectIdentifier: ClientHandler] = [:]
    private let lock = NSLock()
    
    func add(_ handler: ClientHandler) {
        lock.lock()
        handlers[ObjectIdentifier(handler)] = handler
        lock.unlock()
    }
    
    func remove(_ handler: ClientHandler) {
        lock.lock()
        handlers.removeValue(forKey: ObjectIdentifier(handler))
        lock.unlock()
    }
    
    func cancelAll() {
        lock.lock()
        let all = Array(handlers.values)
        handlers.removeAll()
        lock.unlock()
        for h in all {
            h.close()
        }
    }
}

// MARK: - Server Errors

public enum IPCServerError: Error, LocalizedError {
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    
    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let e): return "Socket creation failed: \(e)"
        case .bindFailed(let e): return "Bind failed: \(e)"
        case .listenFailed(let e): return "Listen failed: \(e)"
        }
    }
}

