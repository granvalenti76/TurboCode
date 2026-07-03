import SwiftUI

// MARK: - FloatingComposerView — input area with model picker, attachments, and actions

/// Replicates Kun's FloatingComposer with:
/// - Multi-line NSTextView input
/// - Model picker popover
/// - Attachment support (placeholder)
/// - Send / interrupt button
/// - Context capacity gauge (placeholder)
/// - Execution settings (approval/sandbox)
struct FloatingComposerView: View {
    @Environment(ChatStore.self) private var chatStore
    @State private var messageText: String = ""
    @State private var showingModelPicker = false
    @State private var showingExecutionSettings = false
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 8) {
            // Active file references and attachments (when present)
            if !chatStore.composerInput.isEmpty {
                // Placeholder for attachment chips
            }

            // Main input area
            HStack(alignment: .bottom, spacing: 8) {
                // Attachment button
                attachmentButton

                // Text input
                textEditor

                // Action buttons
                actionButtons
            }

            // Bottom bar: model picker + context gauge
            bottomBar
        }
    }

    // MARK: - Attachment Button

    private var attachmentButton: some View {
        Button {
            // TODO: open file picker
        } label: {
            Image(systemName: "paperclip")
                .font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Attach files")
    }

    // MARK: - Text Editor

    private var textEditor: some View {
        TextField("Ask anything...", text: $messageText, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 14))
            .lineLimit(1...12)
            .focused($isInputFocused)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(.separator.opacity(0.5), lineWidth: 1)
            )
            .onSubmit {
                sendMessage()
            }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 2) {
            if chatStore.busy {
                // Interrupt button (red)
                Button(action: { chatStore.interrupt() }) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .help("Stop generation")
            } else {
                // Send button
                Button(action: sendMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(messageText.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray : Color.accentColor)
                }
                .buttonStyle(.borderless)
                .disabled(messageText.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Send message")
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 6) {
            // Model picker button
            Button {
                showingModelPicker.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                        .font(.system(size: 10))
                    Text(chatStore.composerModel)
                        .font(.system(size: 11, design: .monospaced))
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showingModelPicker) {
                ModelPickerPopover()
            }

            // Mode picker (agent / plan)
            modePicker

            Spacer()

            // Context capacity gauge
            ContextCapacityGauge()

            // Execution settings
            Button {
                showingExecutionSettings.toggle()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showingExecutionSettings) {
                ExecutionSettingsPopover()
            }

            // Usage stats
            HStack(spacing: 2) {
                Image(systemName: "chart.bar")
                    .font(.system(size: 9))
                Text("0")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Mode Picker

    private var modePicker: some View {
        Picker("Mode", selection: Binding(
            get: { chatStore.composerMode },
            set: { chatStore.composerMode = $0 }
        )) {
            Text("Agent").tag(ThreadMode.agent)
            Text("Plan").tag(ThreadMode.plan)
        }
        .pickerStyle(.segmented)
        .frame(width: 100)
        .controlSize(.small)
    }

    // MARK: - Send Action

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        Task {
            await chatStore.sendMessage(text)
        }
    }
}

// MARK: - Model Picker Popover

struct ModelPickerPopover: View {
    @Environment(ChatStore.self) private var chatStore

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            Divider()

            ForEach(["auto", "deepseek-chat", "deepseek-reasoner", "gpt-4o", "claude-sonnet-4-20250514"], id: \.self) { model in
                Button {
                    chatStore.composerModel = model
                } label: {
                    HStack {
                        Text(model)
                            .font(.system(size: 12, design: .monospaced))
                        Spacer()
                        if model == chatStore.composerModel {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 200)
        .padding(.vertical, 4)
    }
}

// MARK: - Execution Settings Popover

struct ExecutionSettingsPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Execution Settings")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 8)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Approval policy")
                    .font(.system(size: 11))
                Picker("", selection: .constant("always-ask")) {
                    Text("Always ask").tag("always-ask")
                    Text("Read only").tag("read-only")
                    Text("Sensitive ask").tag("sensitive-ask")
                    Text("Bypass").tag("bypass")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 12)

            VStack(alignment: .leading, spacing: 4) {
                Text("Sandbox mode")
                    .font(.system(size: 11))
                Picker("", selection: .constant("none")) {
                    Text("None").tag("none")
                    Text("Sandbox").tag("sandbox")
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .frame(width: 220)
        .padding(.vertical, 4)
    }
}

// MARK: - Context Capacity Gauge

struct ContextCapacityGauge: View {
    var body: some View {
        HStack(spacing: 4) {
            // Simple bar showing approximate usage
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(.quaternary)
                        .frame(height: 4)

                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.accentColor)
                        .frame(width: geometry.size.width * 0.3, height: 4)
                }
            }
            .frame(width: 40)

            Text("30%")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .help("Context window usage")
    }
}
