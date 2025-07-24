//
//  StandardError.swift
//  Pods
//
//  Created by Mac on 2025/7/21.
//

import Foundation
import os.log

public final class SwiftLog: Sendable{
    public static let logger = SwiftLog()
    public func log(_ string: String){
        os_log("%@",string)
    }
}

