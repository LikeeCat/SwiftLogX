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

    // MARK: - Dynamic Timer Configuration
    private var currentFlushInterval: TimeInterval = 0.25 // Default 250ms
    private let minFlushInterval: TimeInterval = 0.1     // Minimum 100ms for high activity
    private let maxFlushInterval: TimeInterval = 1.0     // Maximum 1s for low activity
    private var lastLogActivity = Date()
    private let activityTimeThreshold: TimeInterval = 2.0 // 2s without logs = low activity

    public init(port: in_port_t) {
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

        server["/app.js"] = { _ in
            guard
                let resourceBundleURL = Bundle(for: Self.self).url(forResource: "SwiftLogX_SwiftLogX", withExtension: "bundle"),
                let resourceBundle = Bundle(url: resourceBundleURL),
                let fileURL = resourceBundle.url(forResource: "app", withExtension: "js"),
                let js = try? String(contentsOf: fileURL, encoding: .utf8)
            else {
                return .internalServerError
            }
            return .ok(.data(js.data(using: .utf8)!, contentType: "application/javascript"))
        }

        server["/styles.css"] = { _ in
            guard
                let resourceBundleURL = Bundle(for: Self.self).url(forResource: "SwiftLogX_SwiftLogX", withExtension: "bundle"),
                let resourceBundle = Bundle(url: resourceBundleURL),
                let fileURL = resourceBundle.url(forResource: "styles", withExtension: "css"),
                let css = try? String(contentsOf: fileURL, encoding: .utf8)
            else {
                return .internalServerError
            }
            return .ok(.data(css.data(using: .utf8)!, contentType: "text/css"))
        }

        server["/logs/ws"] = websocket(
            text: { _, _ in },
            binary: { _, _ in },
            connected: { session in
                self.logClients.add(session)
            },
            disconnected: { session in
                self.logClients.remove(session)
            }
        )
        
        // 新增原始日志导出接口
        server["/api/export/raw"] = { request in
            return self.exportRawLogs(request: request)
        }
    }

    func broadcastBaseLog() {
        var allLogs = ""
        if let home = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first {
            let fileName = "\(home)/fix_log.txt"
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
        lastLogActivity = Date() // Update activity timestamp
        
        logQueue.async {
            self.logBuffer.append(contentsOf: message.components(separatedBy: "<<<EOL>>>").filter { !$0.isEmpty })
            
            // Adjust flush interval based on activity
            self.adjustFlushInterval()
            
            // If buffer is getting large, trigger immediate flush
            if self.logBuffer.count > 50 { // Threshold for immediate flush
                self.flushLogBuffer()
            }
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
            if let ip = LogIPAddress().getLocalIPAddress() {
                print("Server started at: http://\(ip):\(port)")
            } else {
                print("Server started at http://localhost:\(port)")
            }
            DispatchQueue.main.async {
                self.startDynamicFlushTimer()
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
    
    // MARK: - Dynamic Timer Management
    
    private func startDynamicFlushTimer() {
        logBroadcastTimer?.invalidate() // Stop existing timer
        
        logBroadcastTimer = Timer.scheduledTimer(withTimeInterval: currentFlushInterval, repeats: true) { [weak self] _ in
            self?.flushLogBuffer()
        }
    }
    
    private func adjustFlushInterval() {
        let timeSinceLastActivity = Date().timeIntervalSince(lastLogActivity)
        let newInterval: TimeInterval
        
        if timeSinceLastActivity > activityTimeThreshold {
            // Low activity - use longer interval to save resources
            newInterval = maxFlushInterval
        } else if logBuffer.count > 20 {
            // High buffer load - use shorter interval for responsiveness
            newInterval = minFlushInterval
        } else {
            // Normal activity - use default interval
            newInterval = 0.25
        }
        
        // Only restart timer if interval changed significantly
        if abs(newInterval - currentFlushInterval) > 0.05 {
            currentFlushInterval = newInterval
            
            DispatchQueue.main.async {
                self.startDynamicFlushTimer()
            }
        }
    }
    
    // MARK: - Public Methods
    
    /// Manually trigger immediate buffer flush
    /// Useful when you want to ensure all logs are sent immediately
    public func flushImmediately() {
        flushLogBuffer()
    }
    
    /// Set custom flush interval
    /// - Parameter interval: Time interval in seconds (will be clamped between min and max)
    public func setFlushInterval(_ interval: TimeInterval) {
        currentFlushInterval = max(minFlushInterval, min(maxFlushInterval, interval))
        
        DispatchQueue.main.async {
            self.startDynamicFlushTimer()
        }
    }
    
    // MARK: - 日志导出功能
    
    /// 导出原始日志数据
    /// - Parameter request: HTTP请求对象
    /// - Returns: HTTP响应，包含原始日志文件
    private func exportRawLogs(request: HttpRequest) -> HttpResponse {
        // 获取源文件路径
        guard let home = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first else {
            return .notFound
        }
        
        let sourceFilePath = "\(home)/fix_log.txt"
        
        // 检查文件是否存在
        guard FileManager.default.fileExists(atPath: sourceFilePath) else {
            return .notFound
        }
        
        // 生成文件名
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyyMMdd_HHmmss"
        let timestamp = dateFormatter.string(from: Date())
        let filename = "raw_logs_\(timestamp).txt"
        
        // 设置响应头
        let headers = [
            "Content-Type": "text/plain; charset=utf-8",
            "Content-Disposition": "attachment; filename=\"\(filename)\"",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "*",
            "Access-Control-Allow-Methods": "GET, POST, OPTIONS"
        ]
        
        // 读取和格式化文件内容
        do {
            let rawContent = try String(contentsOf: URL(fileURLWithPath: sourceFilePath), encoding: .utf8)
            
            // 将 <<<EOL>>> 分隔符替换为换行，提升可读性
            let formattedContent = rawContent
                .replacingOccurrences(of: "<<<EOL>>>", with: "\n")
                .replacingOccurrences(of: "\n\n\n", with: "\n\n") // 清理多余空行
                .trimmingCharacters(in: .whitespacesAndNewlines)
            
            // 添加文件头部信息
            let headerInfo = """
            =====================================
            SwiftLogService 原始日志文件
            导出时间: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))
            文件名: \(filename)
            =====================================
            
            """
            
            let finalContent = headerInfo + formattedContent + "\n"
            
            if let data = finalContent.data(using: .utf8) {
                return HttpResponse.raw(200, "OK", headers, { writer in
                    try writer.write(data)
                })
            } else {
                return .internalServerError
            }
        } catch {
            print("❌ Failed to read log file: \(error)")
            return .internalServerError
        }
    }
}



