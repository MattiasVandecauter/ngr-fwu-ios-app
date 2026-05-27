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
        Task {
            await runBusy {
                log("Scanning for \(targetPrefix)")
                devices = try await ble.scan(prefix: targetPrefix)
                log("Found \(devices.count) matching device(s)")
            }
        }
    }

    func connect() {
        guard let selectedDevice else { return }
        Task {
            await runBusy {
                log("Connecting to \(selectedDevice.name ?? selectedDevice.identifier.uuidString)")
                try await ble.connect(selectedDevice)
                log("Connected")
            }
        }
    }

    func startUpload() {
        guard let mainImageURL, let radioImageURL else {
            log("Select both images first")
            return
        }

        Task {
            await runBusy {
                progress = 0
                progressText = "Starting FWU"
                try await ble.enterFirmwareUpdateMode()

                try await ble.waitForState("readyForInfo", initialDelay: 0, log: log)
                try await ble.uploadImage(
                    url: mainImageURL,
                    slot: mainSlot,
                    payloadSize: payloadSize,
                    windowSize: windowSize,
                    retryCount: retryCount,
                    withoutResponse: writeWithoutResponse,
                    progress: { sent, total in
                        self.updateProgress(sent: sent, total: total)
                    },
                    log: log
                )

                try await ble.waitForState("readyForInfo", initialDelay: 0, log: log)
                try await ble.uploadImage(
                    url: radioImageURL,
                    slot: radioSmpImage,
                    payloadSize: payloadSize,
                    windowSize: windowSize,
                    retryCount: retryCount,
                    withoutResponse: writeWithoutResponse,
                    progress: { sent, total in
                        self.updateProgress(sent: sent, total: total)
                    },
                    log: log
                )

                try await ble.waitForState("uploadSuccess", initialDelay: 0, log: log)
                progressText = "FWU complete"
                log("FWU complete")
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
