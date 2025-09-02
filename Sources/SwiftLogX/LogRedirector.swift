import Foundation
import Combine
import UIKit

final class NSLogInterceptor {
    @MainActor static let shared = NSLogInterceptor()

    // MARK: - Pipes and Original File Descriptors
    private var stderrPipe = Pipe()
    private var stdoutPipe = Pipe()
    private var originalStderr: Int32 = -1
    private var originalStdout: Int32 = -1

    // MARK: - Log File Handling
    private var logFileHandle: FileHandle?
    private var fixLogFileHandle: FileHandle?     // 新增的处理后日志文件 fix_log.txt

    private let fileWriteQueue = DispatchQueue(label: "com.dgloservice.log.filewrite")

    // MARK: - Combine Publisher
    public let logDidChange = PassthroughSubject<String, Never>()

    // MARK: - Buffers and Processing Queues
    private let stdoutProcessingQueue = DispatchQueue(label: "com.dgloservice.log.stdoutprocessing")
    private var stdoutBuffer: String = ""
    private var stdoutLastActivity = Date()

    private let stderrProcessingQueue = DispatchQueue(label: "com.dgloservice.log.stderrprocessing")
    private var stderrBuffer: String = ""
    private var stderrLastActivity = Date()
    
    // MARK: - Buffer Flush Timers
    private var bufferFlushTimer: Timer?
    private let bufferFlushInterval: TimeInterval = 0.5 // 500ms 强制刷新间隔
    private let bufferSizeThreshold = 512 // 缓冲区大小阈值（字符数）
    private let bufferTimeThreshold: TimeInterval = 0.2 // 200ms 无活动后刷新
    
    // iOS版本适配的日志格式模式（基于真实日志样例）
    private let ios13to16Pattern = #"(?m)^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d{6}[+-]\d{4}\s[^\[]+\[\d+:\d+\]"#
    private let ios17TraditionalPattern = #"(?m)^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d{3}\s[^\[]+\[\d+:\d+\]"#
    private let ios17NewOSLogPattern = #"(?m)^OSLOG-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}\s\d+\s\d+\s[A-Z]\s\d+\s\{t:[\d\.]+\}"#
    private let oslogPattern = #"(?m)^OSLOG-[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}"#
    private let fallbackPattern = #"(?m)^[\d\-\s\:\.]+.*\[\d+:.*\]|^OSLOG-[0-9A-F\-]+.*"#
    
    private lazy var logStartPattern: String = {
        if #available(iOS 17.0, *) {
            // iOS 17+ 支持新的OSLOG格式和传统格式
            return "\(ios17NewOSLogPattern)|\(ios17TraditionalPattern)|\(oslogPattern)|\(ios13to16Pattern)|\(fallbackPattern)"
        } else {
            return "\(ios13to16Pattern)|\(oslogPattern)|\(fallbackPattern)"
        }
    }()
    
    private lazy var regex = try! NSRegularExpression(pattern: logStartPattern)


    // MARK: - Constants
    private enum Constants {
        static let logFileName = "nslog.txt"
        static let fixLogFileName = "fix_log.txt"
    }


    
    private func setupLogFiles() -> (URL, URL)? {
        guard let logDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not access document directory.")
            return nil
        }
        let logFileURL = logDir.appendingPathComponent(Constants.logFileName)
        let fixLogURL = logDir.appendingPathComponent(Constants.fixLogFileName)

        do {
            [logFileURL, fixLogURL].forEach { url in
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            print("✅ Log files created: \(logFileURL.lastPathComponent), \(fixLogURL.lastPathComponent)")
            return (logFileURL, fixLogURL)
        } catch {
            print("❌ Failed to handle log files: \(error.localizedDescription)")
            return nil
        }
    }
    
    private init() {}

    // MARK: - Setup and Teardown
    func start() {
  
        
        guard let (logFileURL, fixLogURL) = setupLogFiles() else { return }

        do {
            self.logFileHandle = try FileHandle(forWritingTo: logFileURL)
            self.logFileHandle?.seekToEndOfFile()
            
            self.fixLogFileHandle = try FileHandle(forWritingTo: fixLogURL)
            self.fixLogFileHandle?.seekToEndOfFile()

        } catch {
            print("❌ Failed to open log file for writing: \(error)")
            return
        }

        // Redirect outputs and start capturing
        redirectAndCaptureStdout()
        redirectAndCaptureStderr()
        
        // Start buffer flush timer
        startBufferFlushTimer()
    }

    func stop() {
        // Stop buffer flush timer
        stopBufferFlushTimer()
        
        // Flush any remaining buffer content before stopping
        forceFlushAllBuffers()
        
        // Restore original file descriptors
        if originalStderr != -1 {
            dup2(originalStderr, STDERR_FILENO)
            close(originalStderr)
            originalStderr = -1
        }
        if originalStdout != -1 {
            dup2(originalStdout, STDOUT_FILENO)
            close(originalStdout)
            originalStdout = -1
        }

        // Close pipe ends to terminate the async loops
        try? stderrPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()

        // Ensure any pending writes are finished before closing the file handle
        fileWriteQueue.sync {
            try? self.logFileHandle?.close()
            try? self.fixLogFileHandle?.close()
            self.logFileHandle = nil
            self.fixLogFileHandle = nil
        }
    }

    // MARK: - Private Implementation
    private func setupLogFile() -> URL? {
        guard let logDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Could not access document directory.")
            return nil
        }
        let logFileURL = logDir.appendingPathComponent(Constants.logFileName)

        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                try FileManager.default.removeItem(at: logFileURL)
                print("✅ Old log file removed: \(logFileURL.lastPathComponent)")
            }
            if !FileManager.default.createFile(atPath: logFileURL.path, contents: nil) {
                print("❌ Failed to create log file: \(logFileURL.lastPathComponent)")
                return nil
            }
            print("✅ Log file created: \(logFileURL.lastPathComponent)")
            return logFileURL
        } catch {
            print("❌ Failed to handle log file: \(error.localizedDescription)")
            return nil
        }
    }

    private func redirectAndCaptureStdout() {
        originalStdout = dup(STDOUT_FILENO)
        dup2(stdoutPipe.fileHandleForWriting.fileDescriptor, STDOUT_FILENO)

        Task(priority: .utility) {
            await self.captureOutput(from: self.stdoutPipe.fileHandleForReading, writingTo: self.originalStdout, isStdErr: false)
        }
    }

    private func redirectAndCaptureStderr() {
        originalStderr = dup(STDERR_FILENO)
        dup2(stderrPipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        Task(priority: .utility) {
            await self.captureOutput(from: self.stderrPipe.fileHandleForReading, writingTo: self.originalStderr, isStdErr: true)
        }
    }
    
    private func captureOutput(from readHandle: FileHandle, writingTo originalFD: Int32, isStdErr: Bool) async {
        let originalWriteHandle = FileHandle(fileDescriptor: originalFD, closeOnDealloc: false)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            readHandle.readabilityHandler = { [weak self] handle in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                
                let data = handle.availableData
                if data.isEmpty {
                    // Process remaining buffer content if any
                    if isStdErr {
                        self.stderrProcessingQueue.async {
                            if !self.stderrBuffer.isEmpty {
                                self.processAndBroadcast(chunk: self.stderrBuffer)
                                self.stderrBuffer = ""
                            }
                        }
                    } else {
                        self.stdoutProcessingQueue.async {
                            if !self.stdoutBuffer.isEmpty {
                                self.processAndBroadcast(chunk: self.stdoutBuffer)
                                self.stdoutBuffer = ""
                            }
                        }
                    }
                    handle.readabilityHandler = nil
                    continuation.resume()
                    return
                }
                
                if #available(iOS 13.4, *) {
                    try? originalWriteHandle.write(contentsOf: data)
                } else {
                    originalWriteHandle.write(data)
                }
                if let chunk = String(data: data, encoding: .utf8) {
                    if isStdErr {
                        self.processComplexLogChunk(chunk)
                    } else {
                        self.processSimpleLogChunk(chunk)
                    }
                }
            }
        }
    }

    // ====== 修改后的复杂日志处理 ======
    private func processComplexLogChunk(_ chunk: String) {
        stderrProcessingQueue.async {
            self.stderrBuffer.append(chunk)
            self.stderrLastActivity = Date()
            
            let buffer = self.stderrBuffer
            let fullRange = NSRange(buffer.startIndex..., in: buffer)
            let matches = self.regex.matches(in: buffer, range: fullRange)

            guard !matches.isEmpty else {
                if self.stderrBuffer.count > self.bufferSizeThreshold {
                    self.processFallbackLogChunk(self.stderrBuffer)
                    self.stderrBuffer = ""
                }
                return
            }

            var logsToProcess: [String] = []
            var lastIndex = buffer.startIndex

            for match in matches {
                let matchRange = Range(match.range, in: buffer)!
                if matchRange.lowerBound > lastIndex {
                    let logEntry = String(buffer[lastIndex..<matchRange.lowerBound])
                    if !logEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        logsToProcess.append(logEntry)
                    }
                }
                lastIndex = matchRange.lowerBound
            }

            // 最后一段可能还不完整，留在 buffer
            self.stderrBuffer = String(buffer[lastIndex...])

            // 广播完整日志
            for log in logsToProcess {
                self.processAndBroadcast(chunk: log)
            }

            if self.stderrBuffer.count > self.bufferSizeThreshold {
                self.flushStderrBuffer()
            }
        }
    }
    
    // 备用处理策略，用于处理不符合模式的日志
    private func processFallbackLogChunk(_ buffer: String) {
        let lineBreaks = ["\n", "\r\n", "\r"]
        var lines: [String] = []
        
        for lineBreak in lineBreaks {
            if buffer.contains(lineBreak) {
                lines = buffer.components(separatedBy: lineBreak)
                break
            }
        }
        
        if lines.isEmpty {
            let hasOSLOGFeature = buffer.contains("OSLOG-") || buffer.contains("{t:")
            let hasTimestampFeature = buffer.range(of: #"\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}"#, options: .regularExpression) != nil
            
            if hasOSLOGFeature || hasTimestampFeature {
                if buffer.count > 10 && buffer.count < 3000 {
                    self.processAndBroadcast(chunk: buffer)
                    self.stderrBuffer = ""
                    return
                }
            }
            
            if buffer.count > 10 && buffer.count < 2000 {
                self.processAndBroadcast(chunk: buffer)
                self.stderrBuffer = ""
            }
            return
        }
        
        self.stderrBuffer = lines.popLast() ?? ""
        
        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedLine.isEmpty {
                self.processAndBroadcast(chunk: trimmedLine)
            }
        }
    }

    private func processSimpleLogChunk(_ chunk: String) {
        stdoutProcessingQueue.async {
            self.stdoutBuffer.append(chunk)
            self.stdoutLastActivity = Date()
            
            
            // Support multiple line break formats
            let lineBreaks = ["\n", "\r\n", "\r"]
            var components: [String] = []
            
            for lineBreak in lineBreaks {
                if self.stdoutBuffer.contains(lineBreak) {
                    components = self.stdoutBuffer.components(separatedBy: lineBreak)
                    break
                }
            }
            
            if components.isEmpty {
                // No line breaks, check if it exceeds a certain length limit
                if self.stdoutBuffer.count > 1000 {
                    // Possibly a very long log line, process directly
                    self.processAndBroadcast(chunk: self.stdoutBuffer)
                    self.stdoutBuffer = ""
                }
                return
            }
            
            // Keep the last part (possibly incomplete)
            self.stdoutBuffer = components.popLast() ?? ""
            
            // Process complete lines
            for line in components {
                if !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.processAndBroadcast(chunk: line)
                }
            }
            
            // After processing lines, check if remaining buffer is still too large
            if self.stdoutBuffer.count > self.bufferSizeThreshold {
                self.flushStdoutBuffer()
            }
        }
    }

    private func processAndBroadcast(chunk: String) {
        let trimmedChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedChunk.isEmpty { return }

        // === 原始日志 ===
        let rawLine = trimmedChunk + "<<<EOL>>>"
        
        // === 处理后的日志 ===
        let cleaned = regex.stringByReplacingMatches(
            in: trimmedChunk,
            options: [],
            range: NSRange(trimmedChunk.startIndex..., in: trimmedChunk),
            withTemplate: ""
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        
        let fixedLine = "[\(timestamp())] \(cleaned)" + "<<<EOL>>>"

        fileWriteQueue.async {
            // 原始日志写 nslog.txt
            if let data = rawLine.data(using: .utf8) {
                self.logFileHandle?.write(data)
            }
            // 处理后的日志写 fix_log.txt
            if let data = fixedLine.data(using: .utf8) {
                self.fixLogFileHandle?.write(data)
            }
        }

        // 广播处理后的内容
        logDidChange.send(fixedLine)
    }
    
    private func timestamp() -> String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            return formatter.string(from: Date())
        }
    
    // MARK: - Buffer Management Methods
    
    private func startBufferFlushTimer() {
        stopBufferFlushTimer()
        
        DispatchQueue.main.async {
            self.bufferFlushTimer = Timer.scheduledTimer(withTimeInterval: self.bufferFlushInterval, repeats: true) { [weak self] _ in
                self?.checkAndFlushBuffers()
            }
        }
    }
    
    private func stopBufferFlushTimer() {
        bufferFlushTimer?.invalidate()
        bufferFlushTimer = nil
    }
    
    private func checkAndFlushBuffers() {
        let now = Date()
        
        stdoutProcessingQueue.async {
            if !self.stdoutBuffer.isEmpty &&
               now.timeIntervalSince(self.stdoutLastActivity) > self.bufferTimeThreshold {
                self.flushStdoutBuffer()
            }
        }
        
        stderrProcessingQueue.async {
            if !self.stderrBuffer.isEmpty &&
               now.timeIntervalSince(self.stderrLastActivity) > self.bufferTimeThreshold {
                self.flushStderrBuffer()
            }
        }
    }
    
    private func flushStdoutBuffer() {
        if !stdoutBuffer.isEmpty {
            let bufferContent = stdoutBuffer
            stdoutBuffer = ""
            let trimmedContent = bufferContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedContent.isEmpty {
                processAndBroadcast(chunk: trimmedContent)
            }
        }
    }
    
    private func flushStderrBuffer() {
        if !stderrBuffer.isEmpty {
            let bufferContent = stderrBuffer
            stderrBuffer = ""
            let trimmedContent = bufferContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedContent.isEmpty {
                processAndBroadcast(chunk: trimmedContent)
            }
        }
    }
    
    private func forceFlushAllBuffers() {
        stdoutProcessingQueue.sync {
            flushStdoutBuffer()
        }
        
        stderrProcessingQueue.sync {
            flushStderrBuffer()
        }
    }
    
    // MARK: - Public Methods for Manual Flush
    public func flushBuffers() {
        forceFlushAllBuffers()
    }
}

