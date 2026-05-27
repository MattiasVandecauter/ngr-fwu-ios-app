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

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var fwuWrite: CBCharacteristic?
    private var capability: CBCharacteristic?
    private var smp: CBCharacteristic?

    private var scanContinuation: CheckedContinuation<[CBPeripheral], Error>?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var discoverContinuation: CheckedContinuation<Void, Error>?
    private var readContinuation: CheckedContinuation<Data, Error>?
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var notifyContinuation: CheckedContinuation<Void, Error>?
    private var smpResponses: [Data] = []
    private var smpWaiter: CheckedContinuation<Data, Error>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func scan(prefix: String, seconds: TimeInterval = 5) async throws -> [CBPeripheral] {
        discoveredDevices = []
        return try await withCheckedThrowingContinuation { continuation in
            scanContinuation = continuation
            central.scanForPeripherals(withServices: nil)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                central.stopScan()
                let filtered = discoveredDevices.filter { ($0.name ?? "").hasPrefix(prefix) }
                scanContinuation?.resume(returning: filtered)
                scanContinuation = nil
            }
        }
    }

    func connect(_ peripheral: CBPeripheral) async throws {
        self.peripheral = peripheral
        peripheral.delegate = self
        try await withCheckedThrowingContinuation { continuation in
            connectContinuation = continuation
            central.connect(peripheral)
        }
        connectedName = peripheral.name ?? peripheral.identifier.uuidString
        try await discoverRequiredCharacteristics()
    }

    func enterFirmwareUpdateMode() async throws {
        try await writeJSON(["fwuMode": true])
    }

    func readCapabilityState() async throws -> (main: String, radio: String) {
        guard let capability else { throw BLEError.missingCharacteristic("capability") }
        let data = try await read(capability)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let main = ((object?["main"] as? [String: Any])?["state"] as? String) ?? ""
        let radio = ((object?["radio"] as? [String: Any])?["state"] as? String) ?? ""
        return (main, radio)
    }

    func waitForState(_ state: String, initialDelay: TimeInterval = 0, log: @escaping (String) -> Void) async throws {
        if initialDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(initialDelay * 1_000_000_000))
        }
        log("Waiting for \(state)")
        while true {
            let current = try await readCapabilityState()
            if current.main == state || current.radio == state {
                log("State \(state) reached")
                return
            }
            if current.main == "error" || current.radio == "error" {
                throw BLEError.remoteError("FWU state is error")
            }
            try await Task.sleep(nanoseconds: 1_000_000_000)
        }
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

        try await subscribeToSMP()
        defer {
            peripheral?.setNotifyValue(false, for: smp)
        }

        log("Uploading \(url.lastPathComponent), \(image.count) bytes")
        log("Window \(windowSize), payload \(payloadSize), retries \(retryCount), write \(withoutResponse ? "without response" : "with response")")

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
                windowOffset += chunkSize
                sequence = sequence &+ 1
            }

            totalSent = try await sendWindowWithRetry(pending, characteristic: smp, writeType: writeType, retries: retryCount, log: log)
            progress(totalSent, image.count)
        }
    }

    private func discoverRequiredCharacteristics() async throws {
        guard let peripheral else { throw BLEError.notConnected }
        try await withCheckedThrowingContinuation { continuation in
            discoverContinuation = continuation
            peripheral.discoverServices(nil)
        }
    }

    private func writeJSON(_ object: [String: Any]) async throws {
        guard let fwuWrite else { throw BLEError.missingCharacteristic("fwu write") }
        let data = try JSONSerialization.data(withJSONObject: object)
        try await write(data, to: fwuWrite, type: .withResponse)
    }

    private func read(_ characteristic: CBCharacteristic) async throws -> Data {
        guard let peripheral else { throw BLEError.notConnected }
        return try await withCheckedThrowingContinuation { continuation in
            readContinuation = continuation
            peripheral.readValue(for: characteristic)
        }
    }

    private func write(_ data: Data, to characteristic: CBCharacteristic, type: CBCharacteristicWriteType) async throws {
        guard let peripheral else { throw BLEError.notConnected }
        if type == .withoutResponse {
            while !peripheral.canSendWriteWithoutResponse {
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            peripheral.writeValue(data, for: characteristic, type: type)
            return
        }

        try await withCheckedThrowingContinuation { continuation in
            writeContinuations[characteristic.uuid] = continuation
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }

    private func subscribeToSMP() async throws {
        guard let peripheral, let smp else { throw BLEError.missingCharacteristic("smp") }
        try await withCheckedThrowingContinuation { continuation in
            notifyContinuation = continuation
            peripheral.setNotifyValue(true, for: smp)
        }
    }

    private func nextSMPResponse(timeout: TimeInterval = 30) async throws -> Data {
        if !smpResponses.isEmpty {
            return smpResponses.removeFirst()
        }
        return try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask { @MainActor in
                try await withCheckedThrowingContinuation { continuation in
                    self.smpWaiter = continuation
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BLEError.timeout("SMP response timeout")
            }
            let response = try await group.next()!
            group.cancelAll()
            return response
        }
    }

    private func sendWindowWithRetry(
        _ pending: [SMP.PendingRequest],
        characteristic: CBCharacteristic,
        writeType: CBCharacteristicWriteType,
        retries: Int,
        log: @escaping (String) -> Void
    ) async throws -> Int {
        for attempt in 0...retries {
            smpResponses.removeAll()
            do {
                for request in pending {
                    try await write(request.packet, to: characteristic, type: writeType)
                }

                var responses: [UInt8: Int] = [:]
                while responses.count < pending.count {
                    let response = try await nextSMPResponse()
                    let parsed = try SMP.responseSequenceAndOffset(response)
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
                log("SMP window retry \(attempt + 1)/\(retries): \(error.localizedDescription)")
            }
        }
        throw BLEError.remoteError("unreachable retry state")
    }
}

extension BLEFirmwareClient: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            isBluetoothReady = central.state == .poweredOn
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            if !discoveredDevices.contains(where: { $0.identifier == peripheral.identifier }) {
                discoveredDevices.append(peripheral)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectContinuation?.resume(returning: ())
            connectContinuation = nil
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            connectContinuation?.resume(throwing: error ?? BLEError.notConnected)
            connectContinuation = nil
        }
    }
}

extension BLEFirmwareClient: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            Task { @MainActor in
                discoverContinuation?.resume(throwing: error)
                discoverContinuation = nil
            }
            return
        }
        peripheral.services?.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                discoverContinuation?.resume(throwing: error)
                discoverContinuation = nil
                return
            }

            service.characteristics?.forEach { characteristic in
                switch characteristic.uuid {
                case Self.fwuWriteUUID:
                    fwuWrite = characteristic
                case Self.capabilityUUID:
                    capability = characteristic
                case Self.smpUUID:
                    smp = characteristic
                default:
                    break
                }
            }

            if fwuWrite != nil, capability != nil, smp != nil {
                discoverContinuation?.resume(returning: ())
                discoverContinuation = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                readContinuation?.resume(throwing: error)
                readContinuation = nil
                smpWaiter?.resume(throwing: error)
                smpWaiter = nil
                return
            }

            let data = characteristic.value ?? Data()
            if characteristic.uuid == Self.smpUUID {
                if let waiter = smpWaiter {
                    waiter.resume(returning: data)
                    smpWaiter = nil
                } else {
                    smpResponses.append(data)
                }
            } else {
                readContinuation?.resume(returning: data)
                readContinuation = nil
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard let continuation = writeContinuations.removeValue(forKey: characteristic.uuid) else { return }
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: ())
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            guard characteristic.uuid == Self.smpUUID else { return }
            if let error {
                notifyContinuation?.resume(throwing: error)
            } else {
                notifyContinuation?.resume(returning: ())
            }
            notifyContinuation = nil
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
