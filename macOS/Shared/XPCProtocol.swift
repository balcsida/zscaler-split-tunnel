import Foundation

@objc protocol HelperToolProtocol {
    func removeBroadRoutes(reply: @escaping (_ removedCount: Int, _ error: String?) -> Void)

    func addRoute(_ route: String, viaInterface: String, isIPv6: Bool,
                  reply: @escaping (_ success: Bool, _ error: String?) -> Void)

    func addBypassRoute(_ route: String, gateway: String, isIPv6: Bool,
                        reply: @escaping (_ success: Bool, _ error: String?) -> Void)

    func deleteRoute(_ route: String, isIPv6: Bool,
                     reply: @escaping (_ success: Bool, _ error: String?) -> Void)

    func startMonitoring(intervalSeconds: Int,
                         reply: @escaping (_ success: Bool, _ error: String?) -> Void)

    func stopMonitoring(reply: @escaping (_ success: Bool, _ error: String?) -> Void)

    func triggerRefresh(reply: @escaping (_ success: Bool, _ error: String?) -> Void)

    func flushDNSCache(reply: @escaping (_ success: Bool, _ error: String?) -> Void)

    func startZscaler(consoleUser: String,
                      reply: @escaping (_ success: Bool, _ error: String?) -> Void)

    func killZscaler(consoleUser: String,
                     reply: @escaping (_ success: Bool, _ error: String?) -> Void)

    func getStatus(reply: @escaping (_ statusJSON: Data) -> Void)

    func enableAutostart(reply: @escaping (_ success: Bool, _ error: String?) -> Void)

    func disableAutostart(reply: @escaping (_ success: Bool, _ error: String?) -> Void)

    func getVersion(reply: @escaping (_ version: String) -> Void)
}

@objc protocol HelperToolProgressProtocol {
    func logMessage(_ message: String)
}
