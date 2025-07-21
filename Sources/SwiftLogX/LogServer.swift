//
//  LogServer.swift
//  HttpLogService
//
//  Created by Mac on 2025/6/18.
//


import Foundation
import Swifter

final class LogServer: @unchecked Sendable {
    static let shared = LogServer()

    private let server = HttpServer()
    var logClients = NSHashTable<WebSocketSession>.weakObjects() // 自动去除断开的连接
    
    private init() {
        setupServer()
        start()
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
            text: { session, text in
                
            }, binary: { _, _ in }, connected: { session in
                self.logClients.add(session)
                self.broadcastBaseLog()
            },
            disconnected: { session in
                self.logClients.remove(session)
            }
        )
        
    }
    
    func broadcastBaseLog(){
        var allLogs = ""
        if let home = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
            let fileName = "\(home)/nslog.txt"
            if let content = try? String(contentsOfFile: fileName) {
                allLogs += content + "\n"
            }
        }
        
        
        let allLogsArray = allLogs.components(separatedBy: "<<<EOL>>>").map { "💻\($0)✨" }
        
        // 转成 JSON 字符串
        if let jsonData = try? JSONSerialization.data(withJSONObject: allLogsArray, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            for client in logClients.allObjects {
                client.writeText(jsonString)
            }
        } else {
            print("❌ JSON error")
        }

    }
    
    func broadcastLog(_ message: String) {
        let allLogsArray = message.components(separatedBy: "<<<EOL>>>").map { "💻\($0)✨" }
        
        // 转成 JSON 字符串
        if let jsonData = try? JSONSerialization.data(withJSONObject: allLogsArray, options: []),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            for client in logClients.allObjects {
                client.writeText(jsonString)
            }
        } else {
            print("❌ JSON error")
        }
    }
    
    func start(port: in_port_t = 9000)  {
        do {
            try server.start(port)
            // 使用示例
            if let ip = LogIPAddress().getLocalIPAddress() {
                print("Server started at：http://\(ip):9000")
            } else {
                print("Server started at http://localhost:\(port)")
            }
        }catch {
            print("error is \(error.localizedDescription)")
        }
        
    }
    
    func stop() {
        server.stop()
    }
}
