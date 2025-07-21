
import Combine
import Foundation


@objcMembers
public final class LogXManager: Sendable {
    public static let shared = LogXManager()
    
    private init() {}
    
    private let queue = DispatchQueue(label: "com.yourapp.LogXManager.queue", attributes: .concurrent)
    private var _cancellables = Set<AnyCancellable>()
    
    public func setup() async {
        #if DEBUG
        NSLogInterceptor.shared.setup()
        let server = LogServer.shared

        NSLogInterceptor.shared.logDidChange
            .sink { [weak server] message in
                Task {
                    server?.broadcastLog(message)
                }
            }.store(in: &self.cancellables)
        #endif
    }
    
    private var cancellables: Set<AnyCancellable> {
        get { queue.sync { _cancellables } }
        set { queue.async(flags: .barrier) { self._cancellables = newValue } }
    }
}
