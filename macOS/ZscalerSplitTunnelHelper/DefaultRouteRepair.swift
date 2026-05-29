import Foundation
import os

enum DefaultRouteRepair {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "DefaultRouteRepair")

    struct NetworkService: Equatable, Sendable {
        let service: String
        let device: String

        init(service: String, device: String) {
            self.service = service
            self.device = device
        }

        init(_ activeService: RouteReset.ActiveService) {
            self.service = activeService.service
            self.device = activeService.device
        }
    }

    struct ServiceInfo: Equatable, Sendable {
        let router: String?
        let usesDHCP: Bool
    }

    enum RouteOperationResult: Equatable, Sendable {
        case success
        case alreadyExists
        case failure(String)
    }

    enum Result: Equatable, Sendable {
        case defaultPresent
        case noActiveServices
        case repairedByRouteChange(service: String, gateway: String)
        case repairedByRouteAdd(service: String, gateway: String)
        case repairedByDHCP(service: String, gateway: String)
        case failed(errors: [String])
    }

    static func restoreIfMissing() -> Result {
        restoreIfMissing(
            getDefaultGateway: { RouteEngine.getDefaultGateway() },
            activeServices: {
                RouteReset.activeNetworkServices().map(NetworkService.init)
            },
            serviceInfo: { service in
                let result = ShellRunner.runCapturingStderr("/usr/sbin/networksetup",
                    arguments: ["-getinfo", service.service])
                guard result.exitCode == 0 else {
                    logger.warning("networksetup -getinfo '\(service.service, privacy: .public)' failed: \(result.stderr, privacy: .public)")
                    return nil
                }
                return parseServiceInfo(result.stdout)
            },
            changeDefaultRoute: { gateway in
                runRouteCommand(["-n", "change", "default", gateway])
            },
            addDefaultRoute: { gateway in
                runRouteCommand(["-n", "add", "default", gateway])
            },
            renewDHCP: { service in
                let result = ShellRunner.runCapturingStderr("/usr/sbin/networksetup",
                    arguments: ["-setdhcp", service.service])
                if result.exitCode != 0 {
                    logger.warning("networksetup -setdhcp '\(service.service, privacy: .public)' failed: \(result.stderr, privacy: .public)")
                    return false
                }
                Thread.sleep(forTimeInterval: 0.3)
                return true
            }
        )
    }

    static func restoreIfMissing(
        getDefaultGateway: () -> String?,
        activeServices: () -> [NetworkService],
        serviceInfo: (NetworkService) -> ServiceInfo?,
        changeDefaultRoute: (String) -> RouteOperationResult,
        addDefaultRoute: (String) -> RouteOperationResult,
        renewDHCP: (NetworkService) -> Bool
    ) -> Result {
        if isUsableIPv4Gateway(getDefaultGateway()) {
            return .defaultPresent
        }

        let services = activeServices()
        if services.isEmpty {
            return .noActiveServices
        }

        var infos: [(service: NetworkService, info: ServiceInfo)] = []
        var errors: [String] = []

        for service in services {
            guard let info = serviceInfo(service) else {
                errors.append("\(service.service): network service info unavailable")
                continue
            }
            infos.append((service, info))

            guard let router = info.router else {
                errors.append("\(service.service): no IPv4 router available")
                continue
            }

            switch changeDefaultRoute(router) {
            case .success, .alreadyExists:
                if let gateway = validIPv4Gateway(from: getDefaultGateway) {
                    return .repairedByRouteChange(service: service.service, gateway: gateway)
                }
                errors.append("\(service.service): route change did not restore default gateway")
            case .failure(let message):
                errors.append("\(service.service): \(message)")
            }

            switch addDefaultRoute(router) {
            case .success, .alreadyExists:
                if let gateway = validIPv4Gateway(from: getDefaultGateway) {
                    return .repairedByRouteAdd(service: service.service, gateway: gateway)
                }
                errors.append("\(service.service): route add did not restore default gateway")
            case .failure(let message):
                errors.append("\(service.service): \(message)")
            }
        }

        for (service, info) in infos where info.usesDHCP {
            if renewDHCP(service), let gateway = validIPv4Gateway(from: getDefaultGateway) {
                return .repairedByDHCP(service: service.service, gateway: gateway)
            }
            errors.append("\(service.service): DHCP renewal did not restore default gateway")
        }

        return .failed(errors: errors)
    }

    static func parseServiceInfo(_ output: String) -> ServiceInfo {
        var router: String?
        var usesDHCP = false

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "DHCP Configuration" {
                usesDHCP = true
            } else if trimmed.hasPrefix("Router:") {
                let value = trimmed.dropFirst("Router:".count)
                    .trimmingCharacters(in: .whitespaces)
                if isIPv4Address(value) {
                    router = value
                }
            }
        }

        return ServiceInfo(router: router, usesDHCP: usesDHCP)
    }

    static func isUsableIPv4Gateway(_ gateway: String?) -> Bool {
        guard let gateway else { return false }
        return isIPv4Address(gateway)
    }

    private static func runRouteCommand(_ arguments: [String]) -> RouteOperationResult {
        let result = ShellRunner.runCapturingStderr("/sbin/route", arguments: arguments)
        if result.exitCode == 0 {
            return .success
        }

        let message = "\(result.stdout)\n\(result.stderr)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = message.lowercased()
        if lowercased.contains("file exists") || lowercased.contains("already in table") {
            return .alreadyExists
        }
        return .failure(message.isEmpty ? "route exited \(result.exitCode)" : message)
    }

    private static func validIPv4Gateway(from getDefaultGateway: () -> String?) -> String? {
        guard let gateway = getDefaultGateway(), isUsableIPv4Gateway(gateway) else { return nil }
        return gateway
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard let octet = Int(part) else { return false }
            return octet >= 0 && octet <= 255
        }
    }
}

enum IPv6DefaultRouteRepair {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "IPv6DefaultRouteRepair")

    struct DefaultRoute: Equatable, Sendable {
        let gateway: String
        let interface: String
    }

    struct Router: Equatable, Sendable {
        let gateway: String
        let interface: String
    }

    enum RouteOperationResult: Equatable, Sendable {
        case success
        case alreadyExists
        case failure(String)
    }

    enum Result: Equatable, Sendable {
        case defaultPresent
        case noDefaultRouters
        case repaired(gateway: String, interface: String)
        case failed(errors: [String])
    }

    static func restoreIfMissing() -> Result {
        restoreIfMissing(
            getDefaultRoute: {
                let result = ShellRunner.runCapturingStderr("/sbin/route",
                    arguments: ["-n", "get", "-inet6", "default"])
                guard result.exitCode == 0 else { return nil }
                return parseDefaultRoute(result.stdout)
            },
            defaultRouters: {
                let result = ShellRunner.runCapturingStderr("/usr/sbin/ndp", arguments: ["-rn"])
                guard result.exitCode == 0 else {
                    logger.warning("ndp -rn failed: \(result.stderr, privacy: .public)")
                    return []
                }
                return parseDefaultRouters(result.stdout)
            },
            addDefaultRoute: { gateway in
                runRouteCommand(["-n", "add", "-inet6", "default", gateway])
            }
        )
    }

    static func restoreIfMissing(
        getDefaultRoute: () -> DefaultRoute?,
        defaultRouters: () -> [Router],
        addDefaultRoute: (String) -> RouteOperationResult
    ) -> Result {
        if isUsableDefaultRoute(getDefaultRoute()) {
            return .defaultPresent
        }

        let candidates = defaultRouters().filter(isUsableDefaultRouter)
        guard !candidates.isEmpty else {
            return .noDefaultRouters
        }

        var errors: [String] = []
        for router in candidates {
            switch addDefaultRoute(router.gateway) {
            case .success, .alreadyExists:
                if let defaultRoute = getDefaultRoute(), isUsableDefaultRoute(defaultRoute) {
                    return .repaired(gateway: defaultRoute.gateway, interface: defaultRoute.interface)
                }
                errors.append("\(router.interface): route add did not restore IPv6 default")
            case .failure(let message):
                errors.append("\(router.interface): \(message)")
            }
        }

        return .failed(errors: errors)
    }

    static func parseDefaultRoute(_ output: String) -> DefaultRoute? {
        var gateway: String?
        var interface: String?

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("gateway:") {
                gateway = trimmed.dropFirst("gateway:".count)
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("interface:") {
                interface = trimmed.dropFirst("interface:".count)
                    .trimmingCharacters(in: .whitespaces)
            }
        }

        guard let gateway, !gateway.isEmpty else { return nil }
        let routeInterface = interface?.isEmpty == false
            ? interface!
            : scopedInterface(from: gateway)
        guard let routeInterface, !routeInterface.isEmpty else { return nil }
        return DefaultRoute(gateway: gateway, interface: routeInterface)
    }

    static func parseDefaultRouters(_ output: String) -> [Router] {
        output.components(separatedBy: "\n").compactMap { line in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let gateway = parts.first, gateway.contains(":") else { return nil }

            let explicitInterface = parts
                .first { $0.hasPrefix("if=") }
                .map { String($0.dropFirst("if=".count)).trimmingCharacters(in: CharacterSet(charactersIn: ",")) }
            let routerInterface = explicitInterface?.isEmpty == false
                ? explicitInterface!
                : scopedInterface(from: gateway)

            guard let routerInterface, !routerInterface.isEmpty else { return nil }
            return Router(gateway: gateway, interface: routerInterface)
        }
    }

    private static func isUsableDefaultRoute(_ route: DefaultRoute?) -> Bool {
        guard let route, route.gateway.contains(":") else { return false }
        return isPhysicalNetworkInterface(route.interface)
    }

    private static func isUsableDefaultRouter(_ router: Router) -> Bool {
        router.gateway.contains(":")
            && router.gateway.contains("%")
            && isPhysicalNetworkInterface(router.interface)
    }

    private static func isPhysicalNetworkInterface(_ interface: String) -> Bool {
        interface.hasPrefix("en") && interface.dropFirst(2).allSatisfy(\.isNumber)
    }

    private static func scopedInterface(from gateway: String) -> String? {
        guard let scopeStart = gateway.firstIndex(of: "%") else { return nil }
        let scope = gateway[gateway.index(after: scopeStart)...]
        return scope.isEmpty ? nil : String(scope)
    }

    private static func runRouteCommand(_ arguments: [String]) -> RouteOperationResult {
        let result = ShellRunner.runCapturingStderr("/sbin/route", arguments: arguments)
        if result.exitCode == 0 {
            return .success
        }

        let message = "\(result.stdout)\n\(result.stderr)"
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lowercased = message.lowercased()
        if lowercased.contains("file exists") || lowercased.contains("already in table") {
            return .alreadyExists
        }
        return .failure(message.isEmpty ? "route exited \(result.exitCode)" : message)
    }
}
