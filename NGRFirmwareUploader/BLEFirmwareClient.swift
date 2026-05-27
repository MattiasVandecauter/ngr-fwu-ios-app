import CoreBluetooth
import Foundation

@MainActor
final class BLEFirmwareClient: NSObject, ObservableObject {
    static let fwuWriteUUID = CBUUID(string: "3CE06519-BC5C-432C-AD3A-8801B224EE2C")
    static let capabilityUUID = CBUUID(string: "3CE06519-BC5C-432C-AD3A-8801B224EE2D")
    static let smpUUID = CBUUID(string: "DA2E7828-FBCE-4E01-AE9E-261174997C48")

    @Published var isBluetoothReady = false
    @Published var discoveredDevices: [CBPeripheral] = []
    @Published var connectedName = ""

    var logHandler: ((String) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var fwuWrite: CBCharacteristic?
    private var capability: CBCharacteristic?
    private var smp: CBCharacteristic?

    private var scanContinuation: CheckedContinuation<[CBPeripheral], Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var discoverContinuation: CheckedContinuation<Void, Error>?
    private var pendingCharacteristicServices = Set<CBUUID>()
    private var readContinuation: CheckedContinuation<Data, Error>?
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var notifyContinuation: CheckedContinuation<Void, Error>?
    private var smpResponses: [Data] = []
    private var smpResponseError: Error?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func scan(prefix: String, seconds: TimeInterval = 5) async throws -> [CBPeripheral] {
        self.log("Bluetooth state before scan: \(self.central.state.description)")
        guard self.central.state == .poweredOn else {
            throw BLEError.remoteError("Bluetooth is not powered on: \(self.central.state.description)")
        }
        self.discoveredDevices = []
        self.log("Starting scan for \(seconds)s, prefix='\(prefix)'")
        return try await withCheckedThrowingContinuation { continuation in
            self.scanContinuation = continuation
            self.central.scanForPeripherals(withServices: nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self.central.stopScan()
                let filtered = self.discoveredDevices.filter { ($0.name ?? "").hasPrefix(prefix) }
                self.log("Scan stopped. Discovered \(self.discoveredDevices.count), matching prefix \(filtered.count)")
                self.scanContinuation?.resume(returning: filtered)
                self.scanContinuation = nil
            }
        }
    }

    func connect(_ peripheral: CBPeripheral) async throws {
        self.peripheral = peripheral
        self.fwuWrite = nil
        self.capability = nil
        self.smp = nil
        peripheral.delegate = self
        self.log("Connecting to \(peripheral.debugName)")
        try await withCheckedThrowingContinuation { continuation in
            self.connectContinuation = continuation
            self.central.connect(peripheral)
        }
        self.connectedName = peripheral.name ?? peripheral.identifier.uuidString
        self.log("Connected. Discovering services and characteristics")
        try await self.discoverRequiredCharacteristics()
        self.logRequiredCharacteristics()
    }

    func enterFirmwareUpdateMode() async throws {
        log("Sending FWU mode JSON")
        try await writeJSON(["fwuMode": true])
        log("FWU mode write complete")
    }

    func triggerPairing(log externalLog: @escaping (String) -> Void) async throws {
        externalLog("iOS has no direct pair() API; pairing is triggered by protected GATT operations")
        externalLog("Pairing trigger 1/2: reading capability characteristic")
        _ = try await readCapabilityState(log: externalLog)
        externalLog("Pairing trigger 2/2: enabling SMP notifications")
        try await subscribeToSMP()
        if let peripheral, let smp {
            externalLog("Disabling SMP notifications after pairing trigger")
            peripheral.setNotifyValue(false, for: smp)
        }
    }

    func readCapabilityState(log externalLog: ((String) -> Void)? = nil) async throws -> (main: String, radio: String) {
        guard let capability else { throw BLEError.missingCharacteristic("capability") }
        let data = try await read(capability)
        externalLog?("Capability raw: \(data.utf8DebugString)")
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let main = ((object?["main"] as? [String: Any])?["state"] as? String) ?? ""
        let radio = ((object?["radio"] as? [String: Any])?["state"] as? String) ?? ""
        externalLog?("Capability state: main=\(main), radio=\(radio)")
        return (main, radio)
    }

    func readSlots(log externalLog: @escaping (String) -> Void) async throws -> (main: Int, radio: Int) {
        guard let capability else { throw BLEError.missingCharacteristic("capability") }
        let data = try await read(capability)
        externalLog("Capability raw: \(data.utf8DebugString)")
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BLEError.remoteError("Capability JSON is not an object")
        }
        guard let main = Self.intValue(object["mainFreeSlot"]), let radio = Self.intValue(object["radioFreeSlot"]) else {
            throw BLEError.remoteError("Capability JSON missing mainFreeSlot/radioFreeSlot")
        }
        externalLog("Capability slots: mainFreeSlot=\(main), radioFreeSlot=\(radio)")
        return (main, radio)
    }

    func waitForState(
        _ state: String,
        initialDelay: TimeInterval = 0,
        timeout: TimeInterval = 300,
        log: @escaping (String) -> Void
    ) async throws {
        if initialDelay > 0 {
            log("Waiting \(Int(initialDelay))s before first capability read")
            try await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
        }
        let deadline = Date().addingTimeInterval(timeout)
        log("Waiting for \(state), timeout=\(Int(timeout))s")
        while Date() < deadline {
            do {
                let current = try await readCapabilityState(log: log)
                if current.main == state || current.radio == state {
                    log("State \(state) reached")
                    return
                }
                if current.main == "error" || current.radio == "error" {
                    throw BLEError.remoteError("FWU state is error: main=\(current.main), radio=\(current.radio)")
                }
                log("State not reached yet; main=\(current.main), radio=\(current.radio)")
            } catch let error as BLEError {
                throw error
            } catch {
                log("Capability read while waiting failed: \(error.detailedDescription)")
            }
            try await Task.sleep(nanoseconds: 5_000_000_000)
        }
        throw BLEError.timeout("Timed out waiting for \(state)")
    }

    func uploadImage(
        url: URL,
        slot: Int,
        payloadSize: Int,
        windowSize: Int,
        retryCount: Int,
        withoutResponse: Bool,
        progress: @escaping (Int, Int) -> Void,
        log: @escaping (String) -> Void
    ) async throws {
        guard let smp else { throw BLEError.missingCharacteristic("smp") }
        let image = try Data(contentsOf: url)
        var totalSent = 0
        var sequence: UInt8 = 0
        let writeType: CBCharacteristicWriteType = withoutResponse ? .withoutResponse : .withResponse
        let maximumWriteLength = peripheral?.maximumWriteValueLength(for: writeType) ?? 0
        let maximumPayloadSize = maximumPayloadSize(forMaximumWriteLength: maximumWriteLength)
        let start = Date()
        var nextProgressStep = 100_000

        guard payloadSize >= SMP.minimumPayloadSize else {
            throw BLEError.remoteError("SMP payload size must be at least \(SMP.minimumPayloadSize)")
        }
        guard maximumWriteLength > 0, payloadSize <= maximumPayloadSize else {
            throw BLEError.remoteError(
                "SMP payload \(payloadSize) exceeds BLE \(writeType.debugDescription) limit; max payload is \(maximumPayloadSize) for write length \(maximumWriteLength)"
            )
        }

        try await subscribeToSMP()
        defer {
            log("Unsubscribing from SMP notifications")
            peripheral?.setNotifyValue(false, for: smp)
            self.smpResponseError = nil
        }

        log("Uploading \(url.lastPathComponent), \(image.count) bytes")
        log("Window \(windowSize), payload \(payloadSize), retries \(retryCount), write \(withoutResponse ? "without response" : "with response")")
        log("BLE maximum write length for \(writeType.debugDescription): \(maximumWriteLength), max SMP payload: \(maximumPayloadSize)")

        while totalSent < image.count {
            var pending: [SMP.PendingRequest] = []
            var windowOffset = totalSent
            let currentWindowSize = totalSent == 0 ? 1 : windowSize

            for _ in 0..<currentWindowSize where windowOffset < image.count {
                let chunkSize = min(payloadSize, image.count - windowOffset)
                let chunk = image.subdata(in: windowOffset..<(windowOffset + chunkSize))
                let packet = SMP.imageUploadRequest(
                    sequence: sequence,
                    slot: slot,
                    offset: windowOffset,
                    data: chunk,
                    totalSize: image.count
                )
                pending.append(.init(sequence: sequence, offset: windowOffset, chunkSize: chunkSize, packet: packet))
                log("SMP request prepared: seq=\(sequence), slot=\(slot), off=\(windowOffset), chunk=\(chunkSize), packet=\(packet.count) bytes")
                windowOffset += chunkSize
                sequence = sequence &+ 1
            }

            totalSent = try await sendWindowWithRetry(pending, characteristic: smp, writeType: writeType, retries: retryCount, log: log)
            progress(totalSent, image.count)
            log("Sent up to offset \(totalSent); \(max(image.count - totalSent, 0)) bytes remaining")
            if totalSent >= nextProgressStep || totalSent >= image.count {
                let elapsed = Date().timeIntervalSince(start)
                log("Progress \(totalSent)/\(image.count) bytes in \(elapsed.formattedSeconds)")
                while nextProgressStep <= totalSent {
                    nextProgressStep += 100_000
                }
            }
        }
        log("Upload complete for \(url.lastPathComponent): \(totalSent) bytes in \(Date().timeIntervalSince(start).formattedSeconds)")
    }

    private func discoverRequiredCharacteristics() async throws {
        guard let peripheral else { throw BLEError.notConnected }
        try await withCheckedThrowingContinuation { continuation in
            self.discoverContinuation = continuation
            self.pendingCharacteristicServices.removeAll()
            self.log("Discovering all services")
            peripheral.discoverServices(nil)
        }
    }

    private func writeJSON(_ object: [String: Any]) async throws {
        guard let fwuWrite else { throw BLEError.missingCharacteristic("fwu write") }
        let data = try JSONSerialization.data(withJSONObject: object)
        log("Writing JSON to \(fwuWrite.uuid): \(data.utf8DebugString), \(data.count) bytes")
        try await write(data, to: fwuWrite, type: .withResponse)
    }

    private func read(_ characteristic: CBCharacteristic) async throws -> Data {
        guard let peripheral else { throw BLEError.notConnected }
        log("Reading \(characteristic.uuid) properties=\(characteristic.properties.debugDescription)")
        return try await withCheckedThrowingContinuation { continuation in
            self.readContinuation = continuation
            peripheral.readValue(for: characteristic)
        }
    }

    private func write(_ data: Data, to characteristic: CBCharacteristic, type: CBCharacteristicWriteType) async throws {
        guard let peripheral else { throw BLEError.notConnected }
        log("Writing \(data.count) bytes to \(characteristic.uuid), type=\(type.debugDescription), props=\(characteristic.properties.debugDescription)")
        if type == .withoutResponse {
            while !peripheral.canSendWriteWithoutResponse {
                log("Waiting for canSendWriteWithoutResponse")
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            peripheral.writeValue(data, for: characteristic, type: type)
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            self.writeContinuations[characteristic.uuid] = continuation
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }

    private func subscribeToSMP() async throws {
        guard let peripheral, let smp else { throw BLEError.missingCharacteristic("smp") }
        log("Subscribing to SMP notifications on \(smp.uuid), props=\(smp.properties.debugDescription)")
        try await withCheckedThrowingContinuation { continuation in
            self.notifyContinuation = continuation
            peripheral.setNotifyValue(true, for: smp)
        }
        log("SMP notifications enabled")
    }

    private func nextSMPResponse(timeout: TimeInterval = 30) async throws -> Data {
        if !self.smpResponses.isEmpty {
            self.log("Using queued SMP response; queued count before pop=\(self.smpResponses.count)")
            return self.smpResponses.removeFirst()
        }
        self.log("Waiting for SMP response, timeout=\(Int(timeout))s")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let error = self.smpResponseError {
                self.smpResponseError = nil
                throw error
            }
            if !self.smpResponses.isEmpty {
                self.log("Received queued SMP response")
                return self.smpResponses.removeFirst()
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw BLEError.timeout("SMP response timeout")
    }

    private func sendWindowWithRetry(
        _ pending: [SMP.PendingRequest],
        characteristic: CBCharacteristic,
        writeType: CBCharacteristicWriteType,
        retries: Int,
        log: @escaping (String) -> Void
    ) async throws -> Int {
        let pendingSequences = Set(pending.map(\.sequence))

        for attempt in 0...retries {
            let staleCount = self.smpResponses.count
            self.smpResponses.removeAll()
            if staleCount > 0 {
                log("Discarded \(staleCount) stale SMP response(s)")
            }
            do {
                log("Sending SMP window attempt \(attempt + 1)/\(retries + 1), requests=\(pending.count)")
                for request in pending {
                    log("SMP write: seq=\(request.sequence), off=\(request.offset), chunk=\(request.chunkSize), packet=\(request.packet.count) bytes")
                    try await write(request.packet, to: characteristic, type: writeType)
                }

                var responses: [UInt8: Int] = [:]
                while responses.count < pending.count {
                    let response = try await nextSMPResponse()
                    log("SMP response raw: \(response.hexString)")
                    let parsed = try SMP.responseSequenceAndOffset(response)
                    log("SMP response parsed: seq=\(parsed.sequence), nextOff=\(parsed.offset)")
                    guard pendingSequences.contains(parsed.sequence) else {
                        log("Discarding stale SMP response: unexpected seq=\(parsed.sequence)")
                        continue
                    }
                    responses[parsed.sequence] = parsed.offset
                }

                var nextOffset = pending.last!.offset + pending.last!.chunkSize
                for request in pending {
                    let responseOffset = responses[request.sequence] ?? (request.offset + request.chunkSize)
                    let expectedOffset = request.offset + request.chunkSize
                    if responseOffset >= 0, responseOffset != expectedOffset {
                        log("SMP resync: seq=\(request.sequence) expected=\(expectedOffset) got=\(responseOffset)")
                        nextOffset = responseOffset
                        break
                    }
                }
                return nextOffset
            } catch {
                if attempt == retries { throw error }
                log("SMP window retry \(attempt + 1)/\(retries): \(error.detailedDescription)")
            }
        }
        throw BLEError.remoteError("unreachable retry state")
    }

    private func maximumPayloadSize(forMaximumWriteLength maximumWriteLength: Int) -> Int {
        guard maximumWriteLength > 0 else { return 0 }
        var payloadSize = 0
        while SMP.imageUploadRequest(
            sequence: 0,
            slot: 255,
            offset: 0,
            data: Data(count: payloadSize + 1),
            totalSize: Int(UInt32.max)
        ).count <= maximumWriteLength {
            payloadSize += 1
        }
        return payloadSize
    }

    private func log(_ line: String) {
        logHandler?(line)
    }

    private func logRequiredCharacteristics() {
        if let fwuWrite {
            log("FWU write characteristic found: \(fwuWrite.uuid), props=\(fwuWrite.properties.debugDescription)")
        }
        if let capability {
            log("Capability characteristic found: \(capability.uuid), props=\(capability.properties.debugDescription)")
        }
        if let smp {
            log("SMP characteristic found: \(smp.uuid), props=\(smp.properties.debugDescription)")
        }
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }
}

extension BLEFirmwareClient: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.isBluetoothReady = central.state == .poweredOn
            self.log("Bluetooth state updated: \(central.state.description)")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            if !self.discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                self.discoveredDevices.append(peripheral)
                self.log("Discovered \(peripheral.debugName), RSSI=\(RSSI), advertisement=\(advertisementData.debugDescription)")
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.log("CoreBluetooth didConnect \(peripheral.debugName)")
            self.connectContinuation?.resume(returning: ())
            self.connectContinuation = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.log("CoreBluetooth didFailToConnect \(peripheral.debugName): \((error ?? BLEError.notConnected).detailedDescription)")
            self.connectContinuation?.resume(throwing: error ?? BLEError.notConnected)
            self.connectContinuation = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let disconnectError = error ?? BLEError.notConnected
            if let error {
                self.log("Disconnected \(peripheral.debugName): \(error.detailedDescription)")
            } else {
                self.log("Disconnected \(peripheral.debugName)")
            }
            self.connectContinuation?.resume(throwing: disconnectError)
            self.connectContinuation = nil
            self.readContinuation?.resume(throwing: disconnectError)
            self.readContinuation = nil
            self.notifyContinuation?.resume(throwing: disconnectError)
            self.notifyContinuation = nil
            for continuation in self.writeContinuations.values {
                continuation.resume(throwing: disconnectError)
            }
            self.writeContinuations.removeAll()
            self.smpResponseError = disconnectError
        }
    }
}

extension BLEFirmwareClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Task { @MainActor in
                self.log("Service discovery failed: \(error.detailedDescription)")
                self.discoverContinuation?.resume(throwing: error)
                self.discoverContinuation = nil
            }
            return
        }
        Task { @MainActor in
            let services = peripheral.services ?? []
            self.log("Discovered \(services.count) service(s)")
            guard !services.isEmpty else {
                self.discoverContinuation?.resume(throwing: BLEError.missingCharacteristic("services"))
                self.discoverContinuation = nil
                return
            }
            self.pendingCharacteristicServices = Set(services.map(\.uuid))
            services.forEach { service in
                self.log("Discovering characteristics for service \(service.uuid)")
            }
            services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                self.log("Characteristic discovery failed for service \(service.uuid): \(error.detailedDescription)")
                self.discoverContinuation?.resume(throwing: error)
                self.discoverContinuation = nil
                return
            }

            self.log("Service \(service.uuid) characteristics: \(service.characteristics?.count ?? 0)")
            self.pendingCharacteristicServices.remove(service.uuid)
            service.characteristics?.forEach { characteristic in
                self.log(" - \(characteristic.uuid), props=\(characteristic.properties.debugDescription)")
                switch characteristic.uuid {
                case Self.fwuWriteUUID:
                    self.fwuWrite = characteristic
                case Self.capabilityUUID:
                    self.capability = characteristic
                case Self.smpUUID:
                    self.smp = characteristic
                default:
                    break
                }
            }

            if self.fwuWrite != nil, self.capability != nil, self.smp != nil {
                self.discoverContinuation?.resume(returning: ())
                self.discoverContinuation = nil
            } else if self.pendingCharacteristicServices.isEmpty {
                let missing = [
                    self.fwuWrite == nil ? "FWU write" : nil,
                    self.capability == nil ? "capability" : nil,
                    self.smp == nil ? "SMP" : nil
                ].compactMap { $0 }.joined(separator: ", ")
                self.discoverContinuation?.resume(throwing: BLEError.missingCharacteristic(missing))
                self.discoverContinuation = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                self.log("Update value failed for \(characteristic.uuid): \(error.detailedDescription)")
                if characteristic.uuid == Self.smpUUID {
                    self.smpResponseError = error
                    return
                }
                self.readContinuation?.resume(throwing: error)
                self.readContinuation = nil
                return
            }

            let data = characteristic.value ?? Data()
            self.log("Value update for \(characteristic.uuid): \(data.count) bytes")
            if characteristic.uuid == Self.smpUUID {
                self.log("Queueing SMP response")
                self.smpResponses.append(data)
            } else {
                self.log("Read value for \(characteristic.uuid): \(data.utf8DebugString)")
                self.readContinuation?.resume(returning: data)
                self.readContinuation = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard let continuation = self.writeContinuations.removeValue(forKey: characteristic.uuid) else { return }
            if let error {
                self.log("Write failed for \(characteristic.uuid): \(error.detailedDescription)")
                continuation.resume(throwing: error)
            } else {
                self.log("Write complete for \(characteristic.uuid)")
                continuation.resume(returning: ())
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard characteristic.uuid == Self.smpUUID else { return }
            if let error {
                self.log("Notification state failed for \(characteristic.uuid): \(error.detailedDescription)")
                self.notifyContinuation?.resume(throwing: error)
            } else {
                self.log("Notification state for \(characteristic.uuid): isNotifying=\(characteristic.isNotifying)")
                self.notifyContinuation?.resume(returning: ())
            }
            self.notifyContinuation = nil
        }
    }
}

enum BLEError: Error, LocalizedError {
    case notConnected
    case missingCharacteristic(String)
    case timeout(String)
    case remoteError(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected"
        case .missingCharacteristic(let name):
            return "Missing BLE characteristic: \(name)"
        case .timeout(let message):
            return message
        case .remoteError(let message):
            return message
        }
    }
}

private extension CBManagerState {
    var description: String {
        switch self {
        case .unknown:
            return "unknown"
        case .resetting:
            return "resetting"
        case .unsupported:
            return "unsupported"
        case .unauthorized:
            return "unauthorized"
        case .poweredOff:
            return "poweredOff"
        case .poweredOn:
            return "poweredOn"
        @unknown default:
            return "unknown(\(rawValue))"
        }
    }
}

private extension CBPeripheral {
    var debugName: String {
        "\(name ?? "unnamed") [\(identifier.uuidString)]"
    }
}

private extension CBCharacteristicProperties {
    var debugDescription: String {
        var values: [String] = []
        if contains(.broadcast) { values.append("broadcast") }
        if contains(.read) { values.append("read") }
        if contains(.writeWithoutResponse) { values.append("writeWithoutResponse") }
        if contains(.write) { values.append("write") }
        if contains(.notify) { values.append("notify") }
        if contains(.indicate) { values.append("indicate") }
        if contains(.authenticatedSignedWrites) { values.append("authenticatedSignedWrites") }
        if contains(.extendedProperties) { values.append("extendedProperties") }
        if contains(.notifyEncryptionRequired) { values.append("notifyEncryptionRequired") }
        if contains(.indicateEncryptionRequired) { values.append("indicateEncryptionRequired") }
        return values.isEmpty ? "none" : values.joined(separator: ",")
    }
}

private extension CBCharacteristicWriteType {
    var debugDescription: String {
        switch self {
        case .withResponse:
            return "withResponse"
        case .withoutResponse:
            return "withoutResponse"
        @unknown default:
            return "unknown"
        }
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }

    var utf8DebugString: String {
        if let string = String(data: self, encoding: .utf8) {
            return "\(string) [hex=\(hexString)]"
        }
        return "hex=\(hexString)"
    }
}

private extension Error {
    var detailedDescription: String {
        let nsError = self as NSError
        var parts = ["\(localizedDescription)"]
        parts.append("domain=\(nsError.domain)")
        parts.append("code=\(nsError.code)")
        if !nsError.userInfo.isEmpty {
            parts.append("userInfo=\(nsError.userInfo)")
        }
        return parts.joined(separator: ", ")
    }
}

private extension TimeInterval {
    var formattedSeconds: String {
        String(format: "%.2fs", self)
    }
}
