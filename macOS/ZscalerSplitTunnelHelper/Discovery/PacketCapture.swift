import Foundation
import os

// MARK: - Ethernet constants

private let ethernetHeaderLength = 14
private let etherTypeLLDP: UInt16 = 0x88CC
private let cdpDestMAC: [UInt8] = [0x01, 0x00, 0x0C, 0xCC, 0xCC, 0xCC]

// MARK: - PacketCapture

/// Captures CDP and LLDP packets on a given network interface using libpcap.
final class PacketCapture: @unchecked Sendable {
    private static let logger = Logger(subsystem: AppConstants.helperBundleID, category: "PacketCapture")

    private var handle: OpaquePointer?
    private var captureThread: Thread?
    private let interfaceName: String
    private var isRunning = false
    private let lock = NSLock()
    private let callbackQueue: DispatchQueue

    var onDeviceDiscovered: ((DiscoveredDevice) -> Void)?
    var onError: ((String) -> Void)?

    init(interfaceName: String, callbackQueue: DispatchQueue = .global(qos: .utility)) {
        self.interfaceName = interfaceName
        self.callbackQueue = callbackQueue
    }

    deinit {
        stop()
    }

    func start() {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            return
        }
        isRunning = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.captureLoop()
        }
        thread.name = "PacketCapture-\(interfaceName)"
        thread.qualityOfService = .utility
        captureThread = thread
        thread.start()
    }

    func stop() {
        lock.lock()
        isRunning = false
        if let h = handle {
            pcap_breakloop(h)
        }
        lock.unlock()
    }

    // MARK: - Capture Loop

    private func captureLoop() {
        var errbuf = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))

        guard let h = pcap_open_live(interfaceName, 65535, 1, 1000, &errbuf) else {
            let errMsg = String(cString: errbuf)
            reportError("Failed to open \(interfaceName): \(errMsg)")
            return
        }

        lock.lock()
        handle = h
        lock.unlock()

        let linkType = pcap_datalink(h)
        guard linkType == DLT_EN10MB else {
            reportError("\(interfaceName) is not an Ethernet interface (DLT=\(linkType))")
            pcap_close(h)
            lock.lock()
            handle = nil
            lock.unlock()
            return
        }

        var fp = bpf_program()
        let filterExpr = "ether dst 01:00:0c:cc:cc:cc or ether proto 0x88cc"
        if pcap_compile(h, &fp, filterExpr, 1, UInt32(PCAP_NETMASK_UNKNOWN)) == 0 {
            pcap_setfilter(h, &fp)
            pcap_freecode(&fp)
        }

        Self.logger.info("Started capture on \(self.interfaceName)")

        while true {
            lock.lock()
            let running = isRunning
            lock.unlock()
            guard running else { break }

            var headerPtr: UnsafeMutablePointer<pcap_pkthdr>?
            var dataPtr: UnsafePointer<UInt8>?

            let result = pcap_next_ex(h, &headerPtr, &dataPtr)

            switch result {
            case 1:
                if let header = headerPtr, let data = dataPtr {
                    let len = Int(header.pointee.caplen)
                    processPacket(data: data, length: len)
                }
            case 0:
                continue
            case -1:
                let errStr = String(cString: pcap_geterr(h))
                reportError("pcap error: \(errStr)")
                break
            case -2:
                break
            default:
                break
            }

            if result == -1 || result == -2 {
                break
            }
        }

        pcap_close(h)
        lock.lock()
        handle = nil
        lock.unlock()
        Self.logger.info("Stopped capture on \(self.interfaceName)")
    }

    // MARK: - Packet Processing

    private func processPacket(data: UnsafePointer<UInt8>, length: Int) {
        guard length > ethernetHeaderLength else { return }

        let destMAC = Array(UnsafeBufferPointer(start: data, count: 6))
        let srcMAC = Array(UnsafeBufferPointer(start: data + 6, count: 6))
        let srcMACStr = srcMAC.map { String(format: "%02x", $0) }.joined(separator: ":")
        let etherType = UInt16(data[12]) << 8 | UInt16(data[13])
        let payload = Data(bytes: data + ethernetHeaderLength, count: length - ethernetHeaderLength)

        var device: DiscoveredDevice?

        if etherType == etherTypeLLDP {
            device = LLDPParser.parse(data: payload, sourceInterface: interfaceName, sourceMac: srcMACStr)
        } else if destMAC == cdpDestMAC {
            device = CDPParser.parse(data: payload, sourceInterface: interfaceName, sourceMac: srcMACStr)
        }

        if let device {
            callbackQueue.async { [weak self] in
                self?.onDeviceDiscovered?(device)
            }
        }
    }

    private func reportError(_ message: String) {
        callbackQueue.async { [weak self] in
            self?.onError?(message)
        }
    }

    // MARK: - Interface Enumeration

    /// Returns names of active Ethernet interfaces suitable for CDP/LLDP capture.
    static func listEthernetInterfaces() -> [String] {
        var errbuf = [CChar](repeating: 0, count: Int(PCAP_ERRBUF_SIZE))
        var alldevs: UnsafeMutablePointer<pcap_if_t>?

        guard pcap_findalldevs(&alldevs, &errbuf) == 0, let firstDev = alldevs else {
            return []
        }
        defer { pcap_freealldevs(firstDev) }

        var names: [String] = []
        var dev: UnsafeMutablePointer<pcap_if_t>? = firstDev

        while let d = dev {
            let name = String(cString: d.pointee.name)
            let flags = d.pointee.flags
            let isUp = flags & UInt32(PCAP_IF_UP) != 0
            let isLoopback = flags & UInt32(PCAP_IF_LOOPBACK) != 0

            if !isLoopback && isUp && name.hasPrefix("en") {
                names.append(name)
            }
            dev = d.pointee.next
        }

        return names
    }
}
