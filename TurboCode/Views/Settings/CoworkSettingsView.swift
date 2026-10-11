import SwiftUI

// MARK: - Cowork settings

/// Enables Cowork, installs its VM, and manages resources and maintenance.
///
/// Enabling triggers a one-time download only after an explicit confirmation
/// that states the download and disk sizes. Destructive maintenance actions
/// (reset, remove) always confirm first.
struct CoworkSettingsView: View {
    @Environment(SettingsStore.self) private var settings
    @State private var confirmingDownload = false
    @State private var confirmingReset = false
    @State private var confirmingRemoval = false
    @State private var maintenanceError: String?

    private var cowork: CoworkStore { settings.cowork }

    var body: some View {
        @Bindable var cowork = cowork
        Form {
            Section {
                Toggle("Enable Cowork", isOn: enabledBinding)
                Text("Cowork runs builds, scripts, and artifacts in an isolated Linux virtual machine. Your folders are shared read-only, and files reach your Mac only after you approve an export.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Section("Virtual Machine") {
                statusRow
                if case .failed = cowork.phase, cowork.isEnabled {
                    Button("Try Again") { cowork.install() }
                } else if cowork.phase == .notInstalled, cowork.isEnabled {
                    Button("Install…") { confirmingDownload = true }
                }
                if let bytes = cowork.diskUsageBytes, bytes > 0 {
                    LabeledContent("Disk usage") {
                        Text(bytes, format: .byteCount(style: .file))
                    }
                }
            }

            Section {
                Picker("Processors", selection: $cowork.cpus) {
                    ForEach(cpuChoices, id: \.self) { Text("\($0)").tag($0) }
                }
                Picker("Memory", selection: $cowork.memoryGiB) {
                    ForEach(memoryChoices, id: \.self) { Text("\($0) GB").tag($0) }
                }
                Toggle("Network access", isOn: $cowork.networkEnabled)
            } header: {
                Text("Resources")
            } footer: {
                Text("Changes apply the next time the VM starts. Package managers such as npm and pip need network access.")
            }
            .disabled(cowork.isInstalling)

            Section("Maintenance") {
                Button("Reset VM…") { confirmingReset = true }
                    .disabled(cowork.phase != .ready)
                Button("Remove Cowork…", role: .destructive) { confirmingRemoval = true }
                    .disabled((cowork.diskUsageBytes ?? 0) == 0 && cowork.phase != .ready)
            }
        }
        .formStyle(.grouped)
        .onAppear { cowork.refreshStatus() }
        .confirmationDialog(
            "Download the Cowork virtual machine?",
            isPresented: $confirmingDownload
        ) {
            Button("Download") {
                cowork.isEnabled = true
                cowork.install()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("TurboCode will download \(CoworkStore.approximateDownload) and use \(CoworkStore.approximateDiskUse) of disk space. Installation takes a few minutes.")
        }
        .confirmationDialog("Reset the Cowork VM?", isPresented: $confirmingReset) {
            Button("Reset VM", role: .destructive) { runMaintenance { try await cowork.resetVM() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything installed or created inside the VM is discarded. Your sessions and your files on this Mac are not affected.")
        }
        .confirmationDialog("Remove Cowork?", isPresented: $confirmingRemoval) {
            Button("Remove Cowork", role: .destructive) { runMaintenance { try await cowork.removeAll() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The VM and its downloaded image are deleted. Your sessions and your files on this Mac are kept.")
        }
        .alert(
            "Cowork",
            isPresented: Binding(get: { maintenanceError != nil }, set: { if !$0 { maintenanceError = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(maintenanceError ?? "")
        }
    }

    // MARK: Status

    @ViewBuilder
    private var statusRow: some View {
        switch cowork.phase {
        case .notInstalled:
            LabeledContent("Status", value: "Not installed")
        case .ready:
            LabeledContent("Status") {
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        case .failed(let message):
            LabeledContent("Status") {
                Label("Installation failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        case .installing(let step, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(step.title)
                    Spacer()
                    Text("Step \(stepNumber(step)) of \(CoworkInstallStep.allCases.count)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Button("Cancel") { cowork.cancelInstall() }
                }
                if let fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
            }
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Bindings and helpers

    /// Turning Cowork on when it is not installed asks for the download first;
    /// the toggle only flips after the user confirms.
    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { cowork.isEnabled },
            set: { enabled in
                if enabled, cowork.phase != .ready, !cowork.isInstalling {
                    confirmingDownload = true
                } else {
                    cowork.isEnabled = enabled
                }
            }
        )
    }

    private var cpuChoices: [Int] {
        let available = ProcessInfo.processInfo.activeProcessorCount
        return [2, 4, 6, 8, 12].filter { $0 <= available }
    }

    private var memoryChoices: [Int] {
        let physicalGiB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return [2, 4, 8, 16, 32].filter { $0 <= max(2, physicalGiB / 2) }
    }

    private func stepNumber(_ step: CoworkInstallStep) -> Int {
        (CoworkInstallStep.allCases.firstIndex(of: step) ?? 0) + 1
    }

    private func runMaintenance(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await action()
            } catch {
                maintenanceError = error.localizedDescription
            }
        }
    }
}
