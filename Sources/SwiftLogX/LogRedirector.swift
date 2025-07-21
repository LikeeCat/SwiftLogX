import Foundation
import Combine

final class NSLogInterceptor: @unchecked Sendable {
    static let shared = NSLogInterceptor()

    // MARK: - Pipe and File Descriptors
    private var pipeFD: [Int32] = [0, 0]
    private var originalStderr: Int32 = -1

    private var pipeStdoutFD: [Int32] = [0, 0]
    private var originalStdout: Int32 = -1

    // MARK: - Log File Handling
    private var logFileHandle: FileHandle?

    // MARK: - Dispatch Queues
    private let fileWriteQueue = DispatchQueue(label: "com.lk.log.filewrite")
    private let stderrQueue = DispatchQueue(label: "com.lk.stderr.capture")
    private let stdoutQueue = DispatchQueue(label: "com.lk.stdout.capture")
    private let bufferQueue = DispatchQueue(label: "com.lk.stderr.buffer.queue", attributes: .concurrent)

    // MARK: - Combine Publisher
    public var logDidChange = PassthroughSubject<String, Never>()

    // MARK: - Buffers and Timers
    private var stderrBuffer = Data()
    private var stderrTimer: DispatchSourceTimer?
    private let flushDelay: TimeInterval = 0.1

    private init() {}

    // MARK: - Setup
    func setup() {
        let logPath = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("nslog.txt")

        start(captureTo: logPath)
    }

    func start(captureTo logFileURL: URL) {
        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                try FileManager.default.removeItem(at: logFileURL)
            }
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil, attributes: nil)
        } catch {
            print("❌ Failed to handle log file: \(error.localizedDescription)")
            return
        }

        guard let handle = try? FileHandle(forWritingTo: logFileURL) else {
            print("❌ Unable to open log file for writing")
            return
        }

        handle.seekToEndOfFile()
        logFileHandle = handle

        Task { await self.redirect(pipeline: &self.pipeFD, isError: true) }
        Task { await self.redirect(pipeline: &self.pipeStdoutFD, isError: false) }
    }

    private func redirect(pipeline: inout [Int32], isError: Bool) async {
        guard pipe(&pipeline) == 0 else {
            print("❌  pipe create error ：\(isError ? "stderr" : "stdout")")
            return
        }

        let pipeReadFD = pipeline[0]
        let pipeWriteFD = pipeline[1]

        if isError {
            originalStderr = dup(STDERR_FILENO)
            dup2(pipeWriteFD, STDERR_FILENO)
        } else {
            originalStdout = dup(STDOUT_FILENO)
            dup2(pipeWriteFD, STDOUT_FILENO)
        }

        let queue = isError ? stderrQueue : stdoutQueue
        let source = DispatchSource.makeReadSource(fileDescriptor: pipeReadFD, queue: queue)
        source.resume()
        
        for await _ in AsyncStream<Void> { continuation in
            source.setEventHandler { continuation.yield() }
            source.setCancelHandler { continuation.finish() }
        } {
            var buffer = [UInt8](repeating: 0, count: 1024)
            let readCount = read(pipeReadFD, &buffer, buffer.count)

            if readCount > 0 {
                let newData = Data(buffer.prefix(readCount))
                self.writeToOriginal(newData, isError: isError)

                if isError {
                    bufferQueue.async(flags: .barrier) {
                        self.stderrBuffer.append(newData)
                    }
                    self.scheduleFlush(isError: isError)
                } else {
                    guard let bufferString = String(data: newData, encoding: .utf8) else { return }
                    let writeString = bufferString.replacingOccurrences(of: "\n", with: "<<<EOL>>>\n")
                    fileWriteQueue.async {
                        self.logFileHandle?.write(Data(writeString.utf8))
                    }
                    self.logDidChange.send(bufferString)
                }

            } else if readCount == 0 {
                print("EOF reached on \(isError ? "stderr" : "stdout")")
                break
            } else {
                perror("read")
                break
            }
        }
    }

    private func writeToOriginal(_ data: Data, isError: Bool) {
        let fd = isError ? originalStderr : originalStdout
        _ = data.withUnsafeBytes {
            write(fd, $0.baseAddress!, data.count)
        }
    }

    private func scheduleFlush(isError: Bool) {
        stderrTimer?.cancel()

        var bufferToProcessData = Data()
        bufferQueue.sync {
            bufferToProcessData = self.stderrBuffer
        }

        guard !bufferToProcessData.isEmpty else { return }

        let timer = DispatchSource.makeTimerSource(queue: fileWriteQueue)
        timer.schedule(deadline: .now() + flushDelay)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }

            var bufferCopy = Data()
            self.bufferQueue.sync {
                bufferCopy = self.stderrBuffer
            }

            guard !bufferCopy.isEmpty else {
                self.stderrTimer = nil
                return
            }

            guard let bufferString = String(data: bufferCopy, encoding: .utf8) else {
                print("⚠️  stderr cache error")
                self.stderrTimer = nil
                return
            }

            var parsedLogEntries: [String] = []
            var lastProcessedCharIndex = 0

//            let logStartPattern = #"(?m)^\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\.\d{6}[+-]\d{4}"#
            let logStartPattern = #"""
            (?m)^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}[+-]\d{4}|OSLOG-[A-F0-9\-]{36} \d+ \d+ L \d+ \{t:\d+\.\d+,tid:0x[0-9a-f]+\}\t)
            """#

            let regex: NSRegularExpression
            do {
                regex = try NSRegularExpression(pattern: logStartPattern)
            } catch {
                print("❌ reg error：\(error)")
                self.stderrTimer = nil
                return
            }

            let matches = regex.matches(in: bufferString, options: [], range: NSRange(bufferString.startIndex..., in: bufferString))

            for i in 0..<matches.count {
                let currentMatchRange = matches[i].range
                let endLocation = (i + 1 < matches.count) ? matches[i + 1].range.location : bufferString.count
                let logEntryRange = NSRange(location: currentMatchRange.location, length: endLocation - currentMatchRange.location)

                if let swiftRange = Range(logEntryRange, in: bufferString) {
                    var entry = String(bufferString[swiftRange])
                    if entry.hasSuffix("\n") {
                        entry = String(entry.dropLast()) + "<<<EOL>>>"
                    } else {
                        entry += "<<<EOL>>>"
                    }
                    parsedLogEntries.append(entry)
                    lastProcessedCharIndex = logEntryRange.upperBound
                }
            }

            if lastProcessedCharIndex > 0 {
                if let remainingRange = Range(NSRange(location: lastProcessedCharIndex, length: bufferString.count - lastProcessedCharIndex), in: bufferString) {
                    let remaining = Data(bufferString[remainingRange].utf8)
                    self.bufferQueue.async(flags: .barrier) {
                        self.stderrBuffer = remaining
                    }
                } else {
                    self.bufferQueue.async(flags: .barrier) {
                        self.stderrBuffer = Data()
                    }
                }
            }

            if !parsedLogEntries.isEmpty {
                let fileContent = parsedLogEntries.joined(separator: "\n") + "\n"
                self.logFileHandle?.write(Data(fileContent.utf8))
                parsedLogEntries.forEach { self.logDidChange.send($0) }
            }

            self.stderrTimer = nil
        }
        timer.resume()
        stderrTimer = timer
    }

    func flushRemainingLogs() {
        var bufferToFlush = Data()
        bufferQueue.sync {
            bufferToFlush = self.stderrBuffer
        }

        guard !bufferToFlush.isEmpty else { return }

        if let flushedString = String(data: bufferToFlush, encoding: .utf8) {
            fileWriteQueue.sync {
                self.logFileHandle?.write(Data((flushedString + "\n").utf8))
            }
            logDidChange.send(flushedString)

            bufferQueue.async(flags: .barrier) {
                self.stderrBuffer = Data()
            }
        }
    }

    func stop() {
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

        close(pipeFD[0])
        close(pipeFD[1])
        close(pipeStdoutFD[0])
        close(pipeStdoutFD[1])

        flushRemainingLogs()

        fileWriteQueue.sync {
            try? logFileHandle?.close()
            logFileHandle = nil
        }

        stderrTimer?.cancel()
        stderrTimer = nil
    }
}

