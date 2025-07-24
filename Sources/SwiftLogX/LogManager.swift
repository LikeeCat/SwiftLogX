
import Combine
import Foundation


@objcMembers
public final class LogManager:@unchecked Sendable {
    public static let shared = LogManager()
    
    private init() {}
    
    private let queue = DispatchQueue(label: "com.logx.manager.queue", attributes: .concurrent)
    private var cancellables = Set<AnyCancellable>()
    
    private var logServer: LogServer?

    public func setup(port: in_port_t = 9000){
        #if DEBUG
        let loger = NSLogInterceptor.shared
        loger.start()
        
        self.logServer = LogServer(port: port)
        self.logServer?.start()

        loger.logDidChange.sink { message in
            self.logServer?.broadcastLog(message)
        }.store(in: &cancellables)
        #endif // DEB

    }

    
}
