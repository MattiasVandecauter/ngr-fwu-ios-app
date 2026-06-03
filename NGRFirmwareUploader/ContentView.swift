import CoreBluetooth
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = FirmwareUpdateViewModel()
    @State private var pickingMainImage = false
    @State private var pickingRadioImage = false
    @State private var sharingLogs = false
    @State private var showingDevicePicker = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Apparaat") {
                    if viewModel.connectedName.isEmpty {
                        Text("Niet verbonden")
                            .foregroundStyle(.secondary)
                    } else {
                        Label(viewModel.connectedName, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Button {
                        showingDevicePicker = true
                        viewModel.scan()
                    } label: {
                        Label("Zoeken...", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(viewModel.isBusy)
                }

                Section("Firmware") {
                    Button("ST image kiezen") { pickingMainImage = true }
                    Text(viewModel.mainImageURL?.lastPathComponent ?? "Geen ST image gekozen")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button("nRF image kiezen") { pickingRadioImage = true }
                    Text(viewModel.radioImageURL?.lastPathComponent ?? "Geen nRF image gekozen")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("SMP") {
                    Stepper("ST slot: \(viewModel.mainSlot)", value: $viewModel.mainSlot, in: 0...1)
                    Stepper("nRF SMP image: \(viewModel.radioSmpImage)", value: $viewModel.radioSmpImage, in: 2...3)
                    Stepper("Window: \(viewModel.windowSize)", value: $viewModel.windowSize, in: 1...50)
                    Stepper("Payload: \(viewModel.payloadSize)", value: $viewModel.payloadSize, in: 32...448, step: 16)
                    Stepper("Retries: \(viewModel.retryCount)", value: $viewModel.retryCount, in: 0...10)
                    Toggle("Write without response", isOn: $viewModel.writeWithoutResponse)
                }

                Section("Upload") {
                    Button("Start firmware update") {
                        viewModel.startUpload()
                    }
                    .disabled(viewModel.isBusy || viewModel.connectedName.isEmpty || viewModel.mainImageURL == nil || viewModel.radioImageURL == nil)

                    ProgressView(value: viewModel.progress)
                    Text(viewModel.progressText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Log") {
                    HStack {
                        Button("Copy") { viewModel.copyLogs() }
                        Button("Share") { sharingLogs = true }
                            .disabled(viewModel.logLines.isEmpty)
                        Button("Clear") { viewModel.clearLogs() }
                            .disabled(viewModel.logLines.isEmpty)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { _, line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .frame(minHeight: 180)
                }
            }
            .navigationTitle("NGR FWU")
        }
        .sheet(isPresented: $pickingMainImage) {
            DocumentPicker { url in viewModel.setMainImage(url) }
        }
        .sheet(isPresented: $pickingRadioImage) {
            DocumentPicker { url in viewModel.setRadioImage(url) }
        }
        .sheet(isPresented: $sharingLogs) {
            ShareSheet(items: [viewModel.logText])
        }
        .sheet(isPresented: $showingDevicePicker) {
            DevicePickerSheet(viewModel: viewModel, isPresented: $showingDevicePicker)
        }
    }
}

struct DevicePickerSheet: View {
    @ObservedObject var viewModel: FirmwareUpdateViewModel
    @Binding var isPresented: Bool

    var body: some View {
        NavigationStack {
            List {
                if viewModel.isScanning {
                    HStack(spacing: 12) {
                        ProgressView()
                        Text("Zoeken naar BRC_* apparaten...")
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }

                if !viewModel.devices.isEmpty {
                    Section("Gevonden apparaten") {
                        ForEach(viewModel.devices, id: \.identifier) { device in
                            Button {
                                isPresented = false
                                viewModel.connectTo(device)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .foregroundStyle(.blue)
                                        .frame(width: 28)
                                    VStack(alignment: .leading) {
                                        Text(device.name ?? "Onbekend apparaat")
                                            .fontWeight(.medium)
                                        Text(device.identifier.uuidString)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                            }
                            .foregroundStyle(.primary)
                        }
                    }
                }

                if !viewModel.isScanning && viewModel.devices.isEmpty {
                    ContentUnavailableView(
                        "Geen apparaten gevonden",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Zorg dat het apparaat ingeschakeld is en BLE beschikbaar.")
                    )
                    .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("Apparaten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuleer") { isPresented = false }
                }
                ToolbarItem(placement: .primaryAction) {
                    if !viewModel.isScanning {
                        Button {
                            viewModel.scan()
                        } label: {
                            Label("Opnieuw", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
