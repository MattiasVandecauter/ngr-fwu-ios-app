import CoreBluetooth
import Foundation
import UIKit

@MainActor
final class FirmwareUpdateViewModel: ObservableObject {
    @Published var targetPrefix = "BRC_"
    @Published var mainImageURL: URL?
    @Published var radioImageURL: URL?
    @Published var mainSlot = 1
    @Published var radioSmpImage = 3
    @Published var windowSize = 10
    @Published var payloadSize = 384
    @Published var retryCount = 3
    @Published var writeWithoutResponse = false
    @Published var devices: [CBPeripheral] = []
    @Published var selectedDevice: CBPeripheral?
    @Published var isBusy = false
    @Published var progressText = "Idle"
    @Published var progress = 0.0
    @Published var logLines: [String] = []

    let ble = BLEFirmwareClient()

    var logText: String {
        logLines.joined(separator: "\n")
    }

    init() {
        ble.logHandler = { [weak self] line in
            self?.log(line)
        }
    }

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
                self.log("Trying iOS pairing trigger")
                try await self.ble.triggerPairing(log: self.log)
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
                self.log("Reading capability to determine upload slots")
                let slots = try await self.ble.readSlots(log: self.log)
                self.mainSlot = slots.main
                self.radioSmpImage = slots.radio + 2
                self.log("Using ST slot \(self.mainSlot), nRF SMP image \(self.radioSmpImage)")

                try await self.ble.enterFirmwareUpdateMode()

                try await self.ble.waitForState("readyForInfo", initialDelay: 15, log: self.log)
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
        let timestamp = Self.logTimestampFormatter.string(from: Date())
        logLines.append("\(timestamp) \(line)")
        if logLines.count > 1000 {
            logLines.removeFirst(logLines.count - 1000)
        }
        print("\(timestamp) \(line)")
    }

    func copyLogs() {
        let text = logText
        guard !text.isEmpty else {
            log("No logs to copy")
            return
        }

        UIPasteboard.general.setValue(text, forPasteboardType: "public.plain-text")
        log("Copied \(logLines.count) log line(s) to clipboard")
    }

    func clearLogs() {
        logLines.removeAll()
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

    private static let logTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
}
