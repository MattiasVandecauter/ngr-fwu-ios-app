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
    @Published var windowSize = 50
    @Published var payloadSize = 448
    @Published var retryCount = 3
    @Published var writeWithoutResponse = true
    @Published var devices: [CBPeripheral] = []
    @Published var selectedDevice: CBPeripheral?
    @Published var connectedName = ""
    @Published var isScanning = false
    @Published var isBusy = false
    @Published var progressText = ""
    @Published var progress = 0.0
    @Published var uploadPhase = ""
    @Published var uploadSpeed = ""
    @Published var uploadETA = ""
    @Published var uploadPct = 0
    @Published var logLines: [String] = []

    struct PhaseStats {
        let label: String
        let bytes: Int
        let duration: TimeInterval
        var avgSpeed: Double { duration > 0 ? Double(bytes) / 1024 / duration : 0 }
    }

    @Published var uploadStats: [PhaseStats] = []
    @Published var uploadTotalDuration: TimeInterval = 0

    private var lastProgressLabel = ""
    private var phaseStartDate = Date()
    private var phaseStartBytes = 0
    private var phaseTotal = 0
    private var uploadStartDate = Date()

    var mainFileSize: String { fileSizeString(mainImageURL) }
    var radioFileSize: String { fileSizeString(radioImageURL) }

    private func fileSizeString(_ url: URL?) -> String {
        guard let url,
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return "" }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }

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
            self.isScanning = true
            self.devices = []
            defer { self.isScanning = false }
            do {
                self.log("Scanning for NGR's")
                self.devices = try await self.ble.scan(prefix: self.targetPrefix)
                self.log("Found \(self.devices.count) matching device(s)")
            } catch {
                self.log("Scan error: \(error.localizedDescription)")
            }
        }
    }

    func connectTo(_ device: CBPeripheral) {
        selectedDevice = device
        Task { [self] in
            await self.runBusy { [self] in
                self.log("Connecting to \(device.name ?? device.identifier.uuidString)")
                try await self.ble.connect(device)
                self.connectedName = device.name ?? device.identifier.uuidString
                self.log("Trying iOS pairing trigger")
                try await self.ble.triggerPairing(log: self.log)
                self.log("Connected")
            }
        }
    }

    func startUpload() {
        guard let mainImageURL, let radioImageURL else {
            log("Selecteer eerst beide firmware bestanden")
            return
        }

        Task { [self] in
            await self.runBusy { [self] in
                self.progress = 0
                self.uploadPhase = ""
                self.uploadSpeed = ""
                self.uploadETA = ""
                self.uploadPct = 0
                self.lastProgressLabel = ""
                self.uploadStats = []
                self.uploadTotalDuration = 0
                self.uploadStartDate = Date()

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
                    progress: { sent, total in self.updateProgress(label: "main", sent: sent, total: total) },
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
                    progress: { sent, total in self.updateProgress(label: "radio", sent: sent, total: total) },
                    log: self.log
                )

                try await self.ble.waitForState("uploadSuccess", initialDelay: 0, log: self.log)
                self.flushPhaseStats()
                self.uploadTotalDuration = Date().timeIntervalSince(self.uploadStartDate)
                self.uploadPhase = "Geslaagd"
                self.progress = 1
                self.uploadPct = 100
                self.log("FWU voltooid in \(self.formatETA(Int(self.uploadTotalDuration)))")
            }
        }
    }

    func setMainImage(_ url: URL) {
        do {
            mainImageURL = try importFirmwareImage(from: url)
            log("Selected ST image: \(mainImageURL?.lastPathComponent ?? url.lastPathComponent)")
        } catch {
            log("Error selecting ST image: \(error.localizedDescription)")
        }
    }

    func setRadioImage(_ url: URL) {
        do {
            radioImageURL = try importFirmwareImage(from: url)
            log("Selected nRF image: \(radioImageURL?.lastPathComponent ?? url.lastPathComponent)")
        } catch {
            log("Error selecting nRF image: \(error.localizedDescription)")
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

    private func updateProgress(label: String, sent: Int, total: Int) {
        if label != lastProgressLabel {
            flushPhaseStats()
            lastProgressLabel = label
            phaseStartDate = Date()
            phaseStartBytes = sent
            phaseTotal = total
            uploadPhase = label == "main" ? "Main firmware" : "Radio firmware"
            uploadSpeed = ""
            uploadETA = ""
        }
        phaseTotal = total
        progress = total == 0 ? 0 : Double(sent) / Double(total)
        uploadPct = total == 0 ? 0 : Int(Double(sent) / Double(total) * 100)
        progressText = "\(sent) / \(total) bytes"

        let elapsed = Date().timeIntervalSince(phaseStartDate)
        let bytesSent = sent - phaseStartBytes
        if elapsed > 1, bytesSent > 0 {
            let kbps = Double(bytesSent) / 1024 / elapsed
            uploadSpeed = String(format: "%.0f KB/s", kbps)
            let remaining = total - sent
            if kbps > 0 {
                let eta = Int(Double(remaining) / (kbps * 1024))
                uploadETA = formatETA(eta)
            }
        }
    }

    private func flushPhaseStats() {
        guard !lastProgressLabel.isEmpty else { return }
        let duration = Date().timeIntervalSince(phaseStartDate)
        let label = lastProgressLabel == "main" ? "Main firmware" : "Radio firmware"
        uploadStats.append(PhaseStats(label: label, bytes: phaseTotal, duration: duration))
    }

    private func formatETA(_ sec: Int) -> String {
        if sec <= 0 { return "0s" }
        let m = sec / 60, s = sec % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    private func importFirmwareImage(from sourceURL: URL) throws -> URL {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let directory = try firmwareImageDirectory()
        let destinationURL = uniqueDestinationURL(
            in: directory,
            preferredName: sourceURL.lastPathComponent
        )

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        log("Imported \(sourceURL.lastPathComponent) to \(destinationURL.lastPathComponent)")
        return destinationURL
    }

    private func firmwareImageDirectory() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent("FirmwareImages", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func uniqueDestinationURL(in directory: URL, preferredName: String) -> URL {
        let fileManager = FileManager.default
        let fallbackName = UUID().uuidString + ".bin"
        let baseName = preferredName.isEmpty ? fallbackName : preferredName
        let baseURL = directory.appendingPathComponent(baseName)

        if !fileManager.fileExists(atPath: baseURL.path) {
            return baseURL
        }

        let ext = baseURL.pathExtension
        let stem = baseURL.deletingPathExtension().lastPathComponent
        var counter = 1
        while true {
            let candidateName = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
            let candidateURL = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidateURL.path) {
                return candidateURL
            }
            counter += 1
        }
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
