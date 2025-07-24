//
//  LogServer.swift
//  HttpLogService
//
//  Created by Mac on 2025/6/18.
//


import Foundation
import Swifter

final class LogServer: @unchecked Sendable {
    private let server = HttpServer()
    private var logClients = NSHashTable<WebSocketSession>.weakObjects()
    private var logBuffer: [String] = []
    private let logQueue = DispatchQueue(label: "com.logx.log.buffer")
    private var logBroadcastTimer: Timer? // Use a standard Timer
    private let port: in_port_t

    init(port: in_port_t) {
        self.port = port
        setupServer()
    }

    deinit {
        logBroadcastTimer?.invalidate()
    }

    private func setupServer() {
        server["/"] = { _ in
            guard
                let resourceBundleURL = Bundle(for: Self.self).url(forResource: "SwiftLogX_SwiftLogX", withExtension: "bundle"),
                let resourceBundle = Bundle(url: resourceBundleURL),
                let fileURL = resourceBundle.url(forResource: "index", withExtension: "html"),
                let html = try? String(contentsOf: fileURL, encoding: .utf8)
            else {
                return .internalServerError
            }
            return .ok(.html(html))
        }

        server["/logs/ws"] = websocket(
            text: { _, _ in },
            binary: { _, _ in },
            connected: { session in
                self.logClients.add(session)
                self.broadcastBaseLog()
            },
            disconnected: { session in
                self.logClients.remove(session)
            }
        )
    }

    func broadcastBaseLog() {
        var allLogs = ""
        if let home = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
            let fileName = "\(home)/nslog.txt"
            if let content = try? String(contentsOfFile: fileName) {
                allLogs = content
            }
        }

        let allLogsArray = allLogs.components(separatedBy: "<<<EOL>>>")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if let jsonData = try? JSONSerialization.data(withJSONObject: allLogsArray, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            for client in logClients.allObjects {
                (client as? WebSocketSession)?.writeText(jsonString)
            }
        } else {
            print("❌ JSON error in broadcastBaseLog")
        }
    }

    func broadcastLog(_ message: String) {
        logQueue.async {
            self.logBuffer.append(contentsOf: message.components(separatedBy: "<<<EOL>>>").filter { !$0.isEmpty })
        }
    }

    private func flushLogBuffer() {
        logQueue.async {
            if self.logBuffer.isEmpty { return }

            let logsToSend = self.logBuffer
            self.logBuffer.removeAll()

            let allLogsArray = logsToSend
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

            if allLogsArray.isEmpty { return }

            if let jsonData = try? JSONSerialization.data(withJSONObject: allLogsArray, options: []),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                let clients = self.logClients.allObjects
                DispatchQueue.main.async {
                    for client in clients {
                        (client as? WebSocketSession)?.writeText(jsonString)
                    }
                }
            } else {
                print("❌ JSON error in flushLogBuffer")
            }
        }
    }

    func start() {
        do {
            try server.start(port)
            DispatchQueue.main.async {
                self.logBroadcastTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                    self?.flushLogBuffer()
                }
            }
            if let ip = LogIPAddress().getLocalIPAddress() {
                print("Server started at: http://\(ip):\(port)")
            } else {
                print("Server started at http://localhost:\(port)")
            }
        } catch {
            print("Server start error: \(error.localizedDescription)")
        }
    }

    func stop() {
        server.stop()
        logBroadcastTimer?.invalidate()
        logBroadcastTimer = nil
    }
}



