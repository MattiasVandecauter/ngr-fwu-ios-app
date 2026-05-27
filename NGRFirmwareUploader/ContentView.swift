import CoreBluetooth
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = FirmwareUpdateViewModel()
    @State private var pickingMainImage = false
    @State private var pickingRadioImage = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Target") {
                    TextField("Name prefix", text: $viewModel.targetPrefix)
                    Button("Scan") {
                        viewModel.scan()
                    }
                    Picker("Device", selection: $viewModel.selectedDevice) {
                        Text("None").tag(nil as CBPeripheral?)
                        ForEach(viewModel.devices, id: \.identifier) { device in
                            Text(device.name ?? device.identifier.uuidString).tag(Optional(device))
                        }
                    }
                    Button("Connect") {
                        viewModel.connect()
                    }
                    .disabled(viewModel.selectedDevice == nil)
                }

                Section("Images") {
                    Button("Select ST image") {
                        pickingMainImage = true
                    }
                    Text(viewModel.mainImageURL?.lastPathComponent ?? "No ST image selected")
                        .font(.footnote)

                    Button("Select nRF image") {
                        pickingRadioImage = true
                    }
                    Text(viewModel.radioImageURL?.lastPathComponent ?? "No nRF image selected")
                        .font(.footnote)
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
                    .disabled(viewModel.isBusy || viewModel.mainImageURL == nil || viewModel.radioImageURL == nil)

                    ProgressView(value: viewModel.progress)
                    Text(viewModel.progressText)
                        .font(.footnote)
                }

                Section("Log") {
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
            DocumentPicker { url in
                viewModel.mainImageURL = url
            }
        }
        .sheet(isPresented: $pickingRadioImage) {
            DocumentPicker { url in
                viewModel.radioImageURL = url
            }
        }
    }
}
