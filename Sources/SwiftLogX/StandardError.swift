//
//  StandardError.swift
//  Pods
//
//  Created by Mac on 2025/7/21.
//


import Foundation

import Foundation

struct LogStandardError: TextOutputStream, Sendable {
    private static let handle = FileHandle.standardError
    public static let shared = LogStandardError()

    // 可选：默认 Tag（比如模块名）

    public func write(_ string: String) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        let timestamp = dateFormatter.string(from: Date())

        let processName = ProcessInfo.processInfo.processName
        let processID = getpid()
        let threadID = pthread_mach_thread_np(pthread_self())
        
        let prefix = "\(timestamp) \(processName)[\(processID):\(threadID)] : "
        let finalLine = prefix + string + "\n"
        Self.handle.write(Data(finalLine.utf8))
            }
}


public actor SwiftLog{
    public static let logger = SwiftLog()
    public func log(_ string: String){
        LogStandardError.shared.write(string)
    }
}

