//
//  IPAddress.swift
//  HttpLogService
//
//  Created by Mac on 2025/7/15.
//


import Foundation
import SystemConfiguration


class LogIPAddress{
    
    func getLocalIPAddress() -> String? {
        var address: String?
        
        // 获取网络接口列表
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let firstAddr = ifaddrPointer else {
            return nil
        }
        
        // 遍历接口
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            
            // 只处理 IPv4 类型
            let addrFamily = interface.ifa_addr.pointee.sa_family
            if addrFamily == UInt8(AF_INET) {
                // 获取接口名
                let name = String(cString: interface.ifa_name)
                // 排除回环接口
                if name == "lo0" { continue }
                
                // 转换地址为字符串
                var addr = interface.ifa_addr.pointee
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if (getnameinfo(&addr, socklen_t(interface.ifa_addr.pointee.sa_len),
                                &hostname, socklen_t(hostname.count),
                                nil, 0, NI_NUMERICHOST) == 0) {
                    address = String(cString: hostname)
                    break
                }
            }
        }
        freeifaddrs(ifaddrPointer)
        return address
    }
    
    
}
