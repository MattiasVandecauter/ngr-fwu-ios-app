import CoreBluetooth
import SwiftUI

// MARK: - Root

struct ContentView: View {
    @StateObject private var viewModel = FirmwareUpdateViewModel()
    @State private var pickingMainImage = false
    @State private var pickingRadioImage = false
    @State private var sharingLogs = false
    @State private var showingDevicePicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    DeviceCard(viewModel: viewModel, showingPicker: $showingDevicePicker)
                    FirmwareCard(viewModel: viewModel,
                                 pickingMain: $pickingMainImage,
                                 pickingRadio: $pickingRadioImage)
                    SmpCard(viewModel: viewModel)
                    if viewModel.isBusy || !viewModel.uploadPhase.isEmpty {
                        UploadProgressCard(viewModel: viewModel)
                    }
                    StartButton(viewModel: viewModel)
                    LogCard(viewModel: viewModel, sharing: $sharingLogs)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("NGR FW Updater")
            .navigationBarTitleDisplayMode(.inline)
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

// MARK: - Device Card

struct DeviceCard: View {
    @ObservedObject var viewModel: FirmwareUpdateViewModel
    @Binding var showingPicker: Bool

    var connected: Bool { !viewModel.connectedName.isEmpty }

    var body: some View {
        AppCard {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(connected ? Color.green.opacity(0.15) : Color(.systemFill))
                        .frame(width: 48, height: 48)
                    Image(systemName: connected
                          ? "checkmark.circle.fill"
                          : "antenna.radiowaves.left.and.right.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(connected ? .green : .secondary)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(connected ? viewModel.connectedName : "Niet verbonden")
                        .font(.headline)
                        .foregroundStyle(connected ? .primary : .secondary)
                    Text(connected ? "BLE verbonden" : "Tik Zoeken om te verbinden")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showingPicker = true
                    viewModel.scan()
                } label: {
                    Label(connected ? "Wijzigen" : "Zoeken",
                          systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.bordered)
                .tint(connected ? .secondary : .blue)
                .disabled(viewModel.isBusy)
            }
        }
    }
}

// MARK: - Firmware Card

struct FirmwareCard: View {
    @ObservedObject var viewModel: FirmwareUpdateViewModel
    @Binding var pickingMain: Bool
    @Binding var pickingRadio: Bool

    var body: some View {
        AppCard {
            VStack(spacing: 0) {
                CardSectionHeader(icon: "square.and.arrow.down.fill", title: "Firmware bestanden")
                    .padding(.bottom, 14)
                FirmwareRow(
                    label: "Main",
                    icon: "cpu.fill",
                    url: viewModel.mainImageURL,
                    fileSize: viewModel.mainFileSize,
                    action: { pickingMain = true }
                )
                Divider().padding(.vertical, 12)
                FirmwareRow(
                    label: "Radio",
                    icon: "antenna.radiowaves.left.and.right",
                    url: viewModel.radioImageURL,
                    fileSize: viewModel.radioFileSize,
                    action: { pickingRadio = true }
                )
            }
        }
    }
}

struct FirmwareRow: View {
    let label: String
    let icon: String
    let url: URL?
    let fileSize: String
    let action: () -> Void

    var selected: Bool { url != nil }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(selected ? .blue : .secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.subheadline.weight(.medium))
                if let name = url?.lastPathComponent {
                    Text(name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if !fileSize.isEmpty {
                        Text(fileSize)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                } else {
                    Text("Geen bestand gekozen")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button(selected ? "Wijzig" : "Kies", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(selected ? .secondary : .blue)
        }
    }
}

// MARK: - SMP Settings Card

struct SmpCard: View {
    @ObservedObject var viewModel: FirmwareUpdateViewModel
    @State private var expanded = false

    var summary: String {
        "Window \(viewModel.windowSize) · Payload \(viewModel.payloadSize) · \(viewModel.writeWithoutResponse ? "WoR" : "WR")"
    }

    var body: some View {
        AppCard {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 0) {
                    Divider().padding(.top, 12)
                    Group {
                        SmpRow { Stepper("Window: \(viewModel.windowSize)", value: $viewModel.windowSize, in: 1...50) }
                        SmpRow { Stepper("Payload: \(viewModel.payloadSize) B", value: $viewModel.payloadSize, in: 32...448, step: 16) }
                        SmpRow { Stepper("Retries: \(viewModel.retryCount)", value: $viewModel.retryCount, in: 0...10) }
                        SmpRow { Stepper("ST slot: \(viewModel.mainSlot)", value: $viewModel.mainSlot, in: 0...1) }
                        SmpRow { Stepper("nRF image: \(viewModel.radioSmpImage)", value: $viewModel.radioSmpImage, in: 2...3) }
                        SmpRow { Toggle("Write without response", isOn: $viewModel.writeWithoutResponse) }
                    }
                }
            } label: {
                HStack {
                    CardSectionHeader(icon: "slider.horizontal.3", title: "SMP instellingen")
                    Spacer()
                    if !expanded {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .tint(.primary)
        }
    }
}

struct SmpRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(.vertical, 6)
    }
}

// MARK: - Progress Card

struct UploadProgressCard: View {
    @ObservedObject var viewModel: FirmwareUpdateViewModel

    var isComplete: Bool { viewModel.uploadPhase == "Geslaagd" }
    var phaseColor: Color { isComplete ? .green : .blue }

    var body: some View {
        AppCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: isComplete ? "checkmark.circle.fill" : "arrow.up.circle.fill")
                        .foregroundStyle(phaseColor)
                    Text(viewModel.uploadPhase.isEmpty ? "Verbinden..." : viewModel.uploadPhase)
                        .font(.headline)
                        .foregroundStyle(phaseColor)
                    Spacer()
                    if viewModel.uploadPct > 0 {
                        Text("\(viewModel.uploadPct)%")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(phaseColor)
                    }
                }

                ProgressView(value: viewModel.progress)
                    .tint(phaseColor)

                if !viewModel.uploadSpeed.isEmpty || !viewModel.uploadETA.isEmpty {
                    HStack {
                        if !viewModel.uploadSpeed.isEmpty {
                            Label(viewModel.uploadSpeed, systemImage: "speedometer")
                        }
                        Spacer()
                        if !viewModel.uploadETA.isEmpty {
                            Label("ETA \(viewModel.uploadETA)", systemImage: "clock")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Start Button

struct StartButton: View {
    @ObservedObject var viewModel: FirmwareUpdateViewModel

    var ready: Bool {
        !viewModel.isBusy
        && !viewModel.connectedName.isEmpty
        && viewModel.mainImageURL != nil
        && viewModel.radioImageURL != nil
    }

    var label: String {
        if viewModel.isBusy { return "Bezig..." }
        if viewModel.uploadPhase == "Geslaagd" { return "Opnieuw starten" }
        return "Start firmware update"
    }

    var body: some View {
        Button {
            viewModel.startUpload()
        } label: {
            HStack(spacing: 8) {
                if viewModel.isBusy {
                    ProgressView().progressViewStyle(.circular).tint(.white)
                } else {
                    Image(systemName: viewModel.uploadPhase == "Geslaagd"
                          ? "arrow.clockwise.circle.fill"
                          : "arrow.up.circle.fill")
                }
                Text(label).fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        }
        .buttonStyle(.borderedProminent)
        .disabled(!ready)
        .tint(.blue)
        .animation(.easeInOut(duration: 0.2), value: viewModel.isBusy)
    }
}

// MARK: - Log Card

struct LogCard: View {
    @ObservedObject var viewModel: FirmwareUpdateViewModel
    @Binding var sharing: Bool

    var body: some View {
        AppCard {
            VStack(spacing: 10) {
                HStack {
                    CardSectionHeader(icon: "terminal.fill", title: "Log")
                    Spacer()
                    if !viewModel.logLines.isEmpty {
                        HStack(spacing: 4) {
                            IconButton(icon: "doc.on.doc", action: viewModel.copyLogs)
                            IconButton(icon: "square.and.arrow.up") { sharing = true }
                            IconButton(icon: "trash", tint: .red, action: viewModel.clearLogs)
                        }
                    }
                }

                Divider()

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(viewModel.logLines.enumerated()), id: \.offset) { index, line in
                                LogLineView(text: line).id(index)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 220)
                    .onChange(of: viewModel.logLines.count) { count in
                        if count > 0 {
                            withAnimation(.none) {
                                proxy.scrollTo(count - 1, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
    }
}

struct LogLineView: View {
    let text: String

    var color: Color {
        if text.localizedCaseInsensitiveContains("error") { return .red }
        if text.contains("Geslaagd") || text.contains("complete") || text.contains("Connected") { return .green }
        if text.contains("[BLE]") || text.contains("SMP") { return .blue }
        return .secondary
    }

    // Split timestamp from message for different styling
    var parts: (timestamp: String, message: String) {
        let components = text.split(separator: " ", maxSplits: 1)
        if components.count == 2 {
            return (String(components[0]), String(components[1]))
        }
        return ("", text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(parts.timestamp)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .fixedSize()
            Text(parts.message)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Device Picker Sheet

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
                    Section("Gevonden") {
                        ForEach(viewModel.devices, id: \.identifier) { device in
                            Button {
                                isPresented = false
                                viewModel.connectTo(device)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .foregroundStyle(.blue)
                                        .frame(width: 24)
                                    VStack(alignment: .leading) {
                                        Text(device.name ?? "Onbekend")
                                            .fontWeight(.medium)
                                            .foregroundStyle(.primary)
                                        Text(device.identifier.uuidString)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
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
                        Button { viewModel.scan() } label: {
                            Label("Opnieuw", systemImage: "arrow.clockwise")
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shared Components

struct AppCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 16))
    }
}

struct CardSectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

struct IconButton: View {
    let icon: String
    var tint: Color = .secondary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
