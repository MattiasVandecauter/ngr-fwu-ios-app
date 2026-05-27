import CoreBluetooth
import Foundation

@MainActor
final class FirmwareUpdateViewModel: ObservableObject {
    @Published var targetPrefix = "BRC_"
    @Published var mainImageURL: URL?
    @Published var radioImageURL: URL?
    @Published var mainSlot = 1
    @Published var radioSmpImage = 3
    @Published var windowSize = 10
    @Published var payloadSize = 448
    @Published var retryCount = 3
    @Published var writeWithoutResponse = true
    @Published var devices: [CBPeripheral] = []
    @Published var selectedDevice: CBPeripheral?
    @Published var isBusy = false
    @Published var progressText = "Idle"
    @Published var progress = 0.0
    @Published var logLines: [String] = []

    let ble = BLEFirmwareClient()

    func scan() {
        Task { [self] in
            await self.runBusy { [self] in
                self.log("Scanning for \(self.targetPrefix)")
                self.devices = try await self.ble.scan(prefix: self.targetPrefix)
                self.log("Found \(self.devices.count) matching device(s)")
            }
        }
    }

    func connect() {
        guard let selectedDevice else { return }
        Task { [self] in
            await self.runBusy { [self] in
                self.log("Connecting to \(selectedDevice.name ?? selectedDevice.identifier.uuidString)")
                try await self.ble.connect(selectedDevice)
                self.log("Connected")
            }
        }
    }

    func startUpload() {
        guard let mainImageURL, let radioImageURL else {
            log("Select both images first")
            return
        }

        Task { [self] in
            await self.runBusy { [self] in
                self.progress = 0
                self.progressText = "Starting FWU"
                try await self.ble.enterFirmwareUpdateMode()

                try await self.ble.waitForState("readyForInfo", initialDelay: 0, log: self.log)
                try await self.ble.uploadImage(
                    url: mainImageURL,
                    slot: self.mainSlot,
                    payloadSize: self.payloadSize,
                    windowSize: self.windowSize,
                    retryCount: self.retryCount,
                    withoutResponse: self.writeWithoutResponse,
                    progress: { sent, total in
                        self.updateProgress(sent: sent, total: total)
                    },
                    log: self.log
                )

                try await self.ble.waitForState("readyForInfo", initialDelay: 0, log: self.log)
                try await self.ble.uploadImage(
                    url: radioImageURL,
                    slot: self.radioSmpImage,
                    payloadSize: self.payloadSize,
                    windowSize: self.windowSize,
                    retryCount: self.retryCount,
                    withoutResponse: self.writeWithoutResponse,
                    progress: { sent, total in
                        self.updateProgress(sent: sent, total: total)
                    },
                    log: self.log
                )

                try await self.ble.waitForState("uploadSuccess", initialDelay: 0, log: self.log)
                self.progressText = "FWU complete"
                self.log("FWU complete")
            }
        }
    }

    func log(_ line: String) {
        logLines.append(line)
        if logLines.count > 300 {
            logLines.removeFirst(logLines.count - 300)
        }
    }

    private func updateProgress(sent: Int, total: Int) {
        progress = total == 0 ? 0 : Double(sent) / Double(total)
        progressText = "\(sent) / \(total) bytes"
    }

    private func runBusy(_ operation: @escaping () async throws -> Void) async {
        isBusy = true
        defer { isBusy = false }
        do {
            try await operation()
        } catch {
            log("Error: \(error.localizedDescription)")
            progressText = "Error"
        }
    }
}
