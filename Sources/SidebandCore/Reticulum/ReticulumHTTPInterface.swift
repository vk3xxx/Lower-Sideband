import Foundation

/// Reticulum-over-HTTP client compatible with MeshChatX's HTTPInterface.
///
/// Outbound packets are HDLC framed and batched into POST bodies. The server
/// returns zero or more HDLC-framed packets in the response body. Empty polls
/// keep the inbound path live through restrictive proxies and mobile networks.
public actor ReticulumHTTPInterface {
    public enum State: Equatable, Sendable {
        case stopped
        case connecting
        case ready
        case failed(String)
    }

    public static let defaultUserAgent = "RNS-HTTP-Tunnel/1.0"
    public static let defaultMTU = 4_096

    public private(set) var state: State = .stopped
    public private(set) var requestCount: UInt64 = 0
    public private(set) var receivedBytes: UInt64 = 0
    public private(set) var sentBytes: UInt64 = 0

    private let url: URL
    private let session: URLSession
    private let pollInterval: TimeInterval
    private let maximumBackoff: TimeInterval
    private let mtu: Int
    private let userAgent: String
    private let ifac: ReticulumIFAC?
    private let packetHandler: @Sendable (ReticulumPacket) async -> Void
    private let stateHandler: @Sendable (State) async -> Void
    private var decoder: HDLCDecoder
    private var outbound: [Data] = []
    private var loopTask: Task<Void, Never>?
    private var intentionallyStopped = false

    public init(
        url: URL,
        pollInterval: TimeInterval = 0.1,
        maximumBackoff: TimeInterval = 30,
        mtu: Int = defaultMTU,
        userAgent: String = defaultUserAgent,
        ifac: ReticulumIFAC? = nil,
        session: URLSession = .shared,
        packetHandler: @escaping @Sendable (ReticulumPacket) async -> Void,
        stateHandler: @escaping @Sendable (State) async -> Void = { _ in }
    ) {
        self.url = url
        self.pollInterval = max(0.05, pollInterval)
        self.maximumBackoff = max(1, maximumBackoff)
        self.mtu = mtu
        self.userAgent = userAgent
        self.ifac = ifac
        self.session = session
        self.packetHandler = packetHandler
        self.stateHandler = stateHandler
        decoder = HDLCDecoder(maximumFrameSize: mtu)
    }

    public func start() async {
        guard loopTask == nil else { return }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
            await setState(.failed("Invalid HTTP tunnel URL"))
            return
        }
        intentionallyStopped = false
        await setState(.connecting)
        loopTask = Task { [weak self] in await self?.exchangeLoop() }
    }

    public func stop() async {
        intentionallyStopped = true
        loopTask?.cancel()
        loopTask = nil
        outbound.removeAll()
        decoder = HDLCDecoder(maximumFrameSize: mtu)
        await setState(.stopped)
    }

    public func send(rawPacket: Data) throws {
        guard !intentionallyStopped, loopTask != nil else { throw InterfaceError.notConnected }
        let packet = try ifac?.protect(rawPacket) ?? rawPacket
        guard packet.count <= mtu else { throw InterfaceError.payloadTooLarge(maximum: mtu) }
        outbound.append(HDLC.frame(packet))
        sentBytes += UInt64(packet.count)
    }

    private func exchangeLoop() async {
        var failures = 0
        while !Task.isCancelled, !intentionallyStopped {
            let body = drainOutbound()
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "POST"
                request.httpBody = body
                request.timeoutInterval = 5
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let (responseData, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    throw InterfaceError.invalidResponse
                }
                requestCount += 1
                failures = 0
                await setState(.ready)
                if !responseData.isEmpty { await consume(responseData) }
            } catch {
                // Requeue the body as individual frames. Reticulum packet
                // de-duplication makes a possible replay safer than silently
                // losing a batch whose HTTP response was interrupted.
                if !body.isEmpty { outbound.insert(body, at: 0) }
                failures += 1
                await setState(.failed(error.localizedDescription))
            }

            let delay = failures == 0
                ? pollInterval
                : min(maximumBackoff, pollInterval * pow(2, Double(min(failures - 1, 5))))
            try? await Task.sleep(for: .seconds(delay))
        }
        loopTask = nil
    }

    private func drainOutbound() -> Data {
        guard !outbound.isEmpty else { return Data() }
        let data = outbound.reduce(into: Data()) { $0.append($1) }
        outbound.removeAll(keepingCapacity: true)
        return data
    }

    private func consume(_ bytes: Data) async {
        receivedBytes += UInt64(bytes.count)
        for frame in decoder.consume(bytes) {
            do {
                let raw = try ifac?.unprotect(frame) ?? frame
                await packetHandler(try ReticulumPacket(raw: raw))
            } catch {
                // Drop malformed or unauthenticated frames.
            }
        }
    }

    private func setState(_ value: State) async {
        guard state != value else { return }
        state = value
        await stateHandler(value)
    }

    public enum InterfaceError: LocalizedError {
        case notConnected
        case payloadTooLarge(maximum: Int)
        case invalidResponse

        public var errorDescription: String? {
            switch self {
            case .notConnected: "The HTTP tunnel is not running."
            case let .payloadTooLarge(maximum): "The packet exceeds the HTTP tunnel MTU of \(maximum) bytes."
            case .invalidResponse: "The HTTP tunnel returned an invalid response."
            }
        }
    }
}
