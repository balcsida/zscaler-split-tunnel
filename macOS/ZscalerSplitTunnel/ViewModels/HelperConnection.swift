import Foundation

actor HelperConnection {
    private var connection: NSXPCConnection?
    private static let xpcTimeout: TimeInterval = 5

    private func connect() -> NSXPCConnection {
        if let existing = connection {
            return existing
        }
        let conn = NSXPCConnection(machServiceName: AppConstants.machServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)

        conn.interruptionHandler = { [weak self] in
            Task { await self?.resetConnection() }
        }
        conn.invalidationHandler = { [weak self] in
            Task { await self?.resetConnection() }
        }

        conn.resume()
        connection = conn
        return conn
    }

    func resetConnection() {
        connection?.invalidate()
        connection = nil
    }

    /// Executes a block with the XPC proxy, with a timeout to prevent hanging when the helper is unavailable.
    /// The body receives the proxy and a reply callback; it must call reply exactly once with the result.
    private func withProxy<T: Sendable>(
        _ body: @escaping @Sendable (HelperToolProtocol, @escaping @Sendable (Result<T, Error>) -> Void) -> Void
    ) async throws -> T {
        let conn = connect()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            let resumeOnce = ContinuationGuard(continuation: continuation)

            let timer = DispatchSource.makeTimerSource(queue: .global())
            timer.schedule(deadline: .now() + Self.xpcTimeout)
            timer.setEventHandler {
                resumeOnce.resume(throwing: HelperConnectionError.timeout)
            }
            timer.resume()

            let proxy = conn.remoteObjectProxyWithErrorHandler { error in
                timer.cancel()
                resumeOnce.resume(throwing: HelperConnectionError.connectionFailed(error))
            } as? HelperToolProtocol

            guard let proxy else {
                timer.cancel()
                resumeOnce.resume(throwing: HelperConnectionError.proxyUnavailable)
                return
            }

            body(proxy) { result in
                timer.cancel()
                resumeOnce.resume(with: result)
            }
        }
    }

    func removeBroadRoutes() async throws -> Int {
        try await withProxy { proxy, reply in
            proxy.removeBroadRoutes { count, error in
                if let error {
                    reply(.failure(HelperConnectionError.remote(error)))
                } else {
                    reply(.success(count))
                }
            }
        }
    }

    func startMonitoring(interval: Int) async throws {
        let _: Void = try await withProxy { proxy, reply in
            proxy.startMonitoring(intervalSeconds: interval) { _, error in
                if let error {
                    reply(.failure(HelperConnectionError.remote(error)))
                } else {
                    reply(.success(()))
                }
            }
        }
    }

    func stopMonitoring() async throws {
        let _: Void = try await withProxy { proxy, reply in
            proxy.stopMonitoring { _, error in
                if let error {
                    reply(.failure(HelperConnectionError.remote(error)))
                } else {
                    reply(.success(()))
                }
            }
        }
    }

    func triggerRefresh() async throws {
        let _: Void = try await withProxy { proxy, reply in
            proxy.triggerRefresh { _, error in
                if let error {
                    reply(.failure(HelperConnectionError.remote(error)))
                } else {
                    reply(.success(()))
                }
            }
        }
    }

    func flushDNSCache() async throws {
        let _: Void = try await withProxy { proxy, reply in
            proxy.flushDNSCache { _, error in
                if let error {
                    reply(.failure(HelperConnectionError.remote(error)))
                } else {
                    reply(.success(()))
                }
            }
        }
    }

    func startZscaler(consoleUser: String) async throws {
        let _: Void = try await withProxy { proxy, reply in
            proxy.startZscaler(consoleUser: consoleUser) { _, error in
                if let error {
                    reply(.failure(HelperConnectionError.remote(error)))
                } else {
                    reply(.success(()))
                }
            }
        }
    }

    func killZscaler(consoleUser: String) async throws {
        let _: Void = try await withProxy { proxy, reply in
            proxy.killZscaler(consoleUser: consoleUser) { _, error in
                if let error {
                    reply(.failure(HelperConnectionError.remote(error)))
                } else {
                    reply(.success(()))
                }
            }
        }
    }

    func getStatus() async throws -> HelperStatus {
        try await withProxy { proxy, reply in
            proxy.getStatus { statusJSON in
                do {
                    let status = try JSONDecoder().decode(HelperStatus.self, from: statusJSON)
                    reply(.success(status))
                } catch {
                    reply(.failure(error))
                }
            }
        }
    }

    func getVersion() async throws -> String {
        try await withProxy { proxy, reply in
            proxy.getVersion { version in
                reply(.success(version))
            }
        }
    }

    func enableAutostart() async throws {
        let _: Void = try await withProxy { proxy, reply in
            proxy.enableAutostart { _, error in
                if let error {
                    reply(.failure(HelperConnectionError.remote(error)))
                } else {
                    reply(.success(()))
                }
            }
        }
    }

    func disableAutostart() async throws {
        let _: Void = try await withProxy { proxy, reply in
            proxy.disableAutostart { _, error in
                if let error {
                    reply(.failure(HelperConnectionError.remote(error)))
                } else {
                    reply(.success(()))
                }
            }
        }
    }
}

/// Thread-safe wrapper ensuring a continuation is resumed exactly once.
private final class ContinuationGuard<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(returning: value)
    }

    func resume(throwing error: Error) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(throwing: error)
    }

    func resume(with result: Result<T, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }
}

enum HelperConnectionError: LocalizedError {
    case proxyUnavailable
    case remote(String)
    case connectionFailed(Error)
    case timeout

    var errorDescription: String? {
        switch self {
        case .proxyUnavailable:
            return "Could not connect to helper tool"
        case .remote(let message):
            return message
        case .connectionFailed(let error):
            return "XPC connection failed: \(error.localizedDescription)"
        case .timeout:
            return "Helper tool did not respond in time"
        }
    }
}
