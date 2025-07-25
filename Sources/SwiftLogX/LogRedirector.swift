import Foundation
import Combine

final class NSLogInterceptor: @unchecked  Sendable {
    static let shared = NSLogInterceptor()

    // MARK: - Pipes and Original File Descriptors
    private var stderrPipe = Pipe()
    private var stdoutPipe = Pipe()
    private var originalStderr: Int32 = -1
    private var originalStdout: Int32 = -1

    // MARK: - Log File Handling
    private var logFileHandle: FileHandle?
    private let fileWriteQueue = DispatchQueue(label: "com.logx.log.filewrite")

    // MARK: - Combine Publisher
    public let logDidChange = PassthroughSubject<String, Never>()

    // MARK: - Buffers and Processing Queues
    private let stdoutProcessingQueue = DispatchQueue(label: "com.logx.log.stdoutprocessing")
    private var stdoutBuffer: String = ""

    private let stderrProcessingQueue = DispatchQueue(label: "com.logx.log.stderrprocessing")
    private var stderrBuffer: String = ""
    private var flushTimer: Timer?
    
    private let logStartPattern = #"(?m)^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d{6}[+-]\d{4}\s[^\[]+\[\d+:\d+\]|^OSLOG-[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}"#
    private lazy var regex = try! NSRegularExpression(pattern: logStartPattern)


    // MARK: - Constants
    private enum Constants {
        static let logFileName = "nslog.txt"
    }

    private init() {}

    // MARK: - Setup and Teardown
    func start() {
        guard let logFileURL = setupLogFile() else { return }

        do {
            self.logFileHandle = try FileHandle(forWritingTo: logFileURL)
            self.logFileHandle?.seekToEndOfFile()
        } catch {
            print("❌ Failed to open log file for writing: \(error)")
            return
        }

        // Redirect outputs and start capturing
        redirectAndCaptureStdout()
        redirectAndCaptureStderr()
        
        flushTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.flushBuffers()
        }
    }

    func stop() {
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
        flushTimer?.invalidate()
        flushTimer = nil
        try? stderrPipe.fileHandleForReading.close()
        try? stderrPipe.fileHandleForWriting.close()
        try? stdoutPipe.fileHandleForReading.close()
        try? stdoutPipe.fileHandleForWriting.close()

        // Ensure any pending writes are finished before closing the file handle
        fileWriteQueue.sync {
            try? self.logFileHandle?.close()
            self.logFileHandle = nil
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

    private func processComplexLogChunk(_ chunk: String) {
        stderrProcessingQueue.async {
            self.stderrBuffer.append(chunk)
            let buffer = self.stderrBuffer
            let fullRange = NSRange(buffer.startIndex..., in: buffer)
            let matches = self.regex.matches(in: buffer, range: fullRange)

            if matches.isEmpty { return }

            var logsToProcess: [String] = []
            var lastCutIndex: String.Index

            let firstMatchRange = Range(matches[0].range, in: buffer)!
            if firstMatchRange.lowerBound != buffer.startIndex {
                // If the buffer doesn't start with a pattern, we assume the content
                // before it is a log. This handles cases where the first log entry
                // might not have a timestamp.
                logsToProcess.append(String(buffer[..<firstMatchRange.lowerBound]))
            }
            
            lastCutIndex = firstMatchRange.lowerBound

            for i in 0..<(matches.count - 1) {
                let start = Range(matches[i].range, in: buffer)!.lowerBound
                let end = Range(matches[i+1].range, in: buffer)!.lowerBound
                logsToProcess.append(String(buffer[start..<end]))
            }
            
            lastCutIndex = Range(matches.last!.range, in: buffer)!.lowerBound
            self.stderrBuffer = String(buffer[lastCutIndex...])

            for log in logsToProcess {
                self.processAndBroadcast(chunk: log)
            }
        }
    }

    private func processSimpleLogChunk(_ chunk: String) {
        stdoutProcessingQueue.async {
            self.stdoutBuffer.append(chunk)
            var components = self.stdoutBuffer.components(separatedBy: "\n")
            
            self.stdoutBuffer = components.popLast() ?? ""
            
            for line in components {
                self.processAndBroadcast(chunk: line)
            }
        }
    }

    private func processAndBroadcast(chunk: String) {
        let trimmedChunk = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedChunk.isEmpty { return }
        
        let formattedChunk = trimmedChunk + "<<<EOL>>>"
        
        fileWriteQueue.async {
            self.logFileHandle?.write(Data(formattedChunk.utf8))
        }
        
        logDidChange.send(formattedChunk)
    }
    
    private func flushBuffers() {
        // Flush stderr buffer using its specific regex logic
        stderrProcessingQueue.async {
            if self.stderrBuffer.isEmpty { return }

            let buffer = self.stderrBuffer
            self.stderrBuffer = "" // Clear buffer immediately

            let fullRange = NSRange(buffer.startIndex..., in: buffer)
            let matches = self.regex.matches(in: buffer, range: fullRange)

            if matches.isEmpty {
                self.processAndBroadcast(chunk: buffer)
                return
            }

            var logsToProcess: [String] = []

            let firstMatchRange = Range(matches[0].range, in: buffer)!
            if firstMatchRange.lowerBound != buffer.startIndex {
                logsToProcess.append(String(buffer[..<firstMatchRange.lowerBound]))
            }

            for i in 0..<(matches.count - 1) {
                let start = Range(matches[i].range, in: buffer)!.lowerBound
                let end = Range(matches[i+1].range, in: buffer)!.lowerBound
                logsToProcess.append(String(buffer[start..<end]))
            }
            
            let lastMatchStart = Range(matches.last!.range, in: buffer)!.lowerBound
            logsToProcess.append(String(buffer[lastMatchStart...]))

            for log in logsToProcess {
                self.processAndBroadcast(chunk: log)
            }
        }
        
        // Flush stdout buffer
        stdoutProcessingQueue.async {
            if !self.stdoutBuffer.isEmpty {
                self.processAndBroadcast(chunk: self.stdoutBuffer)
                self.stdoutBuffer = ""
            }
        }
    }
}


