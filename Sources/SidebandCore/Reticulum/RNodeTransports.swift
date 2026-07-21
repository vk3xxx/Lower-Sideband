import Foundation
import Network
@preconcurrency import CoreBluetooth

public enum RNodeByteTransportState: Equatable, Sendable {
    case stopped
    case searching
    case connecting
    case ready
    case failed(String)
}

public protocol RNodeByteTransport: AnyObject, Sendable {
    var kind: RNodeTransportKind { get }
    func start(
        receive: @escaping @Sendable (Data) async -> Void,
        state: @escaping @Sendable (RNodeByteTransportState) async -> Void
    ) async
    func stop() async
    func write(_ data: Data) async throws
}

public actor RNodeTCPTransport: RNodeByteTransport {
    public let kind = RNodeTransportKind.tcp
    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let queue = DispatchQueue(label: "sideband.rnode.tcp")
    private var connection: NWConnection?
    private var receiveHandler: (@Sendable (Data) async -> Void)?
    private var stateHandler: (@Sendable (RNodeByteTransportState) async -> Void)?
    private var isReady = false

    public init(host: String, port: UInt16 = 7_633) {
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
    }

    public func start(receive: @escaping @Sendable (Data) async -> Void, state: @escaping @Sendable (RNodeByteTransportState) async -> Void) async {
        guard connection == nil else { return }
        receiveHandler = receive
        stateHandler = state
        await state(.connecting)
        let options = NWProtocolTCP.Options()
        options.noDelay = true
        options.enableKeepalive = true
        options.keepaliveIdle = 5
        options.keepaliveInterval = 2
        options.connectionTimeout = 5
        let connection = NWConnection(host: host, port: port, using: NWParameters(tls: nil, tcp: options))
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] value in Task { await self?.update(value) } }
        connection.start(queue: queue)
    }

    public func stop() async {
        connection?.cancel()
        connection = nil
        isReady = false
        await stateHandler?(.stopped)
    }

    public func write(_ data: Data) async throws {
        guard let connection, isReady else { throw RNodeError.notConnected }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            })
        }
    }

    private func update(_ state: NWConnection.State) async {
        switch state {
        case .ready:
            isReady = true
            await stateHandler?(.ready)
            if let connection { receiveNext(connection) }
        case .failed(let error):
            isReady = false
            connection = nil
            await stateHandler?(.failed(error.localizedDescription))
        case .cancelled:
            isReady = false
            await stateHandler?(.stopped)
        default: break
        }
    }

    private func receiveNext(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, complete, error in
            Task {
                guard let self else { return }
                if let data, !data.isEmpty { await self.deliver(data) }
                if let error { await self.update(.failed(error)) }
                else if complete { await self.remoteClosed() }
                else { await self.receiveNext(connection) }
            }
        }
    }

    private func deliver(_ data: Data) async { await receiveHandler?(data) }
    private func remoteClosed() async {
        isReady = false
        connection = nil
        await stateHandler?(.failed("RNode closed the TCP connection."))
    }
}

/// CoreBluetooth Nordic-UART transport used by current BLE-capable RNodes.
public final class RNodeBLETransport: NSObject, RNodeByteTransport, CBCentralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    public let kind = RNodeTransportKind.bluetoothLE
    public static let serviceUUIDString = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    public static let receiveUUIDString = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
    public static let transmitUUIDString = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
    private var serviceUUID: CBUUID { CBUUID(string: Self.serviceUUIDString) }
    private var receiveUUID: CBUUID { CBUUID(string: Self.receiveUUIDString) }
    private var transmitUUID: CBUUID { CBUUID(string: Self.transmitUUIDString) }

    private let target: String
    private let queue = DispatchQueue(label: "sideband.rnode.ble")
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var receiveCharacteristic: CBCharacteristic?
    private var transmitCharacteristic: CBCharacteristic?
    private var receiveHandler: (@Sendable (Data) async -> Void)?
    private var stateHandler: (@Sendable (RNodeByteTransportState) async -> Void)?
    private var pendingWrites: [Data] = []
    private var explicitlyStopped = false
    private var restorationIdentifier: String

    public init(target: String = "", restorationIdentifier: String = "com.supes.MacSideband.rnode") {
        self.target = target
        self.restorationIdentifier = restorationIdentifier
        super.init()
    }

    public func start(receive: @escaping @Sendable (Data) async -> Void, state: @escaping @Sendable (RNodeByteTransportState) async -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                self.receiveHandler = receive
                self.stateHandler = state
                self.explicitlyStopped = false
                if self.central == nil {
                    self.central = CBCentralManager(
                        delegate: self,
                        queue: self.queue,
                        options: [CBCentralManagerOptionRestoreIdentifierKey: self.restorationIdentifier,
                                  CBCentralManagerOptionShowPowerAlertKey: true]
                    )
                } else { self.scanIfPossible() }
                continuation.resume()
            }
        }
    }

    public func stop() async {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self else { continuation.resume(); return }
                self.explicitlyStopped = true
                self.central?.stopScan()
                if let peripheral = self.peripheral { self.central?.cancelPeripheralConnection(peripheral) }
                self.peripheral = nil
                self.receiveCharacteristic = nil
                self.transmitCharacteristic = nil
                self.pendingWrites.removeAll()
                self.publish(.stopped)
                continuation.resume()
            }
        }
    }

    public func write(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [weak self] in
                guard let self, self.peripheral != nil, self.receiveCharacteristic != nil else {
                    continuation.resume(throwing: RNodeError.notConnected); return
                }
                self.pendingWrites.append(data)
                self.drainWrites()
                continuation.resume()
            }
        }
    }

    private func scanIfPossible() {
        guard !explicitlyStopped, central?.state == .poweredOn else { return }
        publish(.searching)
        if let uuid = UUID(uuidString: target), let restored = central?.retrievePeripherals(withIdentifiers: [uuid]).first {
            connect(restored); return
        }
        central?.scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connect(_ peripheral: CBPeripheral) {
        central?.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        publish(.connecting)
        central?.connect(peripheral, options: [
            CBConnectPeripheralOptionNotifyOnConnectionKey: true,
            CBConnectPeripheralOptionNotifyOnDisconnectionKey: true,
            CBConnectPeripheralOptionNotifyOnNotificationKey: true
        ])
    }

    private func targetMatches(_ peripheral: CBPeripheral) -> Bool {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return peripheral.name?.hasPrefix("RNode ") == true || peripheral.name == "RNode" }
        if peripheral.identifier.uuidString.caseInsensitiveCompare(trimmed) == .orderedSame { return true }
        return peripheral.name?.caseInsensitiveCompare(trimmed) == .orderedSame
    }

    private func drainWrites() {
        guard let peripheral, let characteristic = receiveCharacteristic else { return }
        let maximum = max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        while !pendingWrites.isEmpty, peripheral.canSendWriteWithoutResponse {
            var current = pendingWrites.removeFirst()
            let chunk = current.prefix(maximum)
            peripheral.writeValue(Data(chunk), for: characteristic, type: .withoutResponse)
            current.removeFirst(chunk.count)
            if !current.isEmpty { pendingWrites.insert(current, at: 0) }
        }
    }

    private func publish(_ state: RNodeByteTransportState) {
        let handler = stateHandler
        Task { await handler?(state) }
    }

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: scanIfPossible()
        case .poweredOff: publish(.failed("Bluetooth is turned off."))
        case .unauthorized: publish(.failed("Bluetooth access is not authorized."))
        case .unsupported: publish(.failed("Bluetooth LE is not supported on this device."))
        case .resetting: publish(.connecting)
        default: break
        }
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        guard !explicitlyStopped else { return }
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral], let first = peripherals.first {
            connect(first)
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard targetMatches(peripheral) else { return }
        connect(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        self.peripheral = nil
        publish(.failed(error?.localizedDescription ?? "Could not connect to RNode over Bluetooth."))
        if !explicitlyStopped { scanIfPossible() }
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        receiveCharacteristic = nil
        transmitCharacteristic = nil
        self.peripheral = nil
        publish(explicitlyStopped ? .stopped : .failed(error?.localizedDescription ?? "RNode Bluetooth connection ended."))
        if !explicitlyStopped { scanIfPossible() }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error { publish(.failed(error.localizedDescription)); return }
        peripheral.services?.filter { $0.uuid == serviceUUID }.forEach {
            peripheral.discoverCharacteristics([receiveUUID, transmitUUID], for: $0)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error { publish(.failed(error.localizedDescription)); return }
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == receiveUUID { receiveCharacteristic = characteristic }
            if characteristic.uuid == transmitUUID { transmitCharacteristic = characteristic }
        }
        guard let transmitCharacteristic else { publish(.failed("RNode BLE UART characteristics are incomplete.")); return }
        peripheral.setNotifyValue(true, for: transmitCharacteristic)
        if receiveCharacteristic != nil { publish(.ready); drainWrites() }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil, characteristic.uuid == transmitUUID, let data = characteristic.value else { return }
        let handler = receiveHandler
        Task { await handler?(data) }
    }

    public func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) { drainWrites() }
}

#if os(macOS)
import Darwin

public actor RNodeSerialTransport: RNodeByteTransport {
    public let kind = RNodeTransportKind.serial
    private let path: String
    private let baudRate: speed_t
    private var fileHandle: FileHandle?
    private var receiveHandler: (@Sendable (Data) async -> Void)?
    private var stateHandler: (@Sendable (RNodeByteTransportState) async -> Void)?

    public init(path: String, baudRate: speed_t = speed_t(B115200)) {
        self.path = path
        self.baudRate = baudRate
    }

    public func start(receive: @escaping @Sendable (Data) async -> Void, state: @escaping @Sendable (RNodeByteTransportState) async -> Void) async {
        guard fileHandle == nil else { return }
        receiveHandler = receive
        stateHandler = state
        await state(.connecting)
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { await state(.failed(String(cString: strerror(errno)))); return }
        var options = termios()
        guard tcgetattr(descriptor, &options) == 0 else {
            Darwin.close(descriptor); await state(.failed("Could not read serial-port settings.")); return
        }
        cfmakeraw(&options)
        cfsetispeed(&options, baudRate)
        cfsetospeed(&options, baudRate)
        options.c_cflag |= tcflag_t(CLOCAL | CREAD)
        guard tcsetattr(descriptor, TCSANOW, &options) == 0 else {
            Darwin.close(descriptor); await state(.failed("Could not configure serial port.")); return
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        fileHandle = handle
        handle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { await self?.deliver(data) }
        }
        await state(.ready)
    }

    public func stop() async {
        fileHandle?.readabilityHandler = nil
        try? fileHandle?.close()
        fileHandle = nil
        await stateHandler?(.stopped)
    }

    public func write(_ data: Data) async throws {
        guard let fileHandle else { throw RNodeError.notConnected }
        try fileHandle.write(contentsOf: data)
    }

    private func deliver(_ data: Data) async { await receiveHandler?(data) }
}
#endif

/// Deterministic in-memory RNode used by unit tests and the app's radio self-test.
public actor SimulatedRNodeTransport: RNodeByteTransport {
    public let kind = RNodeTransportKind.simulated
    public var loopbackPackets: Bool
    public var responseChunkSize: Int
    private var decoder = RNodeKISSDecoder()
    private var receiveHandler: (@Sendable (Data) async -> Void)?
    private var stateHandler: (@Sendable (RNodeByteTransportState) async -> Void)?
    private var started = false
    private var firmware: (UInt8, UInt8)
    public private(set) var transmittedPackets: [Data] = []

    public init(loopbackPackets: Bool = true, responseChunkSize: Int = 7, firmware: (UInt8, UInt8) = (1, 80)) {
        self.loopbackPackets = loopbackPackets
        self.responseChunkSize = max(1, responseChunkSize)
        self.firmware = firmware
    }

    public func start(receive: @escaping @Sendable (Data) async -> Void, state: @escaping @Sendable (RNodeByteTransportState) async -> Void) async {
        receiveHandler = receive
        stateHandler = state
        started = true
        await state(.ready)
    }

    public func stop() async { started = false; await stateHandler?(.stopped) }

    public func write(_ data: Data) async throws {
        guard started else { throw RNodeError.notConnected }
        for frame in decoder.consume(data) {
            switch frame.command {
            case .detect: await respond(.detect, Data([RNodeProtocolEngine.detectResponse]))
            case .firmwareVersion: await respond(.firmwareVersion, Data([firmware.0, firmware.1]))
            case .platform: await respond(.platform, Data([0x80]))
            case .mcu: await respond(.mcu, Data([0x01]))
            case .frequency, .bandwidth, .txPower, .spreadingFactor, .codingRate,
                 .shortTermAirtimeLock, .longTermAirtimeLock, .radioState:
                await respond(frame.command, frame.payload)
            case .data:
                transmittedPackets.append(frame.payload)
                if loopbackPackets { await respond(.data, frame.payload) }
            case .blink: await respond(.ready, Data([0x01]))
            default: break
            }
        }
    }

    public func inject(packet: Data, rssi: Int = -80, snr: Double = 5) async {
        await respond(.rssi, Data([UInt8(clamping: rssi + RNodeProtocolEngine.rssiOffset)]))
        await respond(.snr, Data([UInt8(bitPattern: Int8(clamping: Int((snr * 4).rounded())))]))
        await respond(.data, packet)
    }

    private func respond(_ command: RNodeKISS.Command, _ payload: Data) async {
        let framed = RNodeKISS.frame(command: command, payload: payload)
        var offset = 0
        while offset < framed.count {
            let end = min(framed.count, offset + responseChunkSize)
            await receiveHandler?(framed.subdata(in: offset..<end))
            offset = end
        }
    }
}
