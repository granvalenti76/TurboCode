import SwiftUI

/// Metadata menus are isolated from the editor so catalog changes do not
/// invalidate the canvas. Only metadata supported by the desk is presented.
struct EditorialDeskMetadataBar: View {
    @Environment(SettingsStore.self) private var settings
    @Binding var selectedSectionID: UUID?
    @Binding var selectedTypeID: UUID?

    let hasDocument: Bool
    let selectedSourceCount: Int
    let totalSourceCount: Int

    private var selectedSection: EditorialDeskSection? {
        guard let selectedSectionID else { return nil }
        return settings.editorialDeskCatalog.sections.first { $0.id == selectedSectionID }
    }

    private var selectedType: EditorialDeskType? {
        guard let selectedTypeID else { return nil }
        return settings.editorialDeskCatalog.types.first { $0.id == selectedTypeID }
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                Menu {
                    if settings.editorialDeskCatalog.sections.isEmpty {
                        Text("Configure sections in Settings")
                    } else {
                        ForEach(settings.editorialDeskCatalog.sections) { option in
                            Button {
                                selectedSectionID = option.id
                            } label: {
                                Label(option.name, systemImage: option.systemImage)
                            }
                        }
                    }
                } label: {
                    metadataChip(
                        icon: selectedSection?.systemImage ?? "tag",
                        title: "Section",
                        value: selectedSection?.name ?? "",
                        isPlaceholder: selectedSection == nil
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(settings.editorialDeskCatalog.sections.isEmpty)

                Menu {
                    if settings.editorialDeskCatalog.types.isEmpty {
                        Text("Configure article types in Settings")
                    } else {
                        ForEach(settings.editorialDeskCatalog.types) { option in
                            Button {
                                selectedTypeID = option.id
                            } label: {
                                Label(option.name, systemImage: option.systemImage)
                            }
                        }
                    }
                } label: {
                    metadataChip(
                        icon: selectedType?.systemImage ?? "bolt",
                        title: selectedType == nil ? "Type" : "",
                        value: selectedType?.name ?? "",
                        tint: selectedType.map { editorialColor($0.colorHex) } ?? .secondary,
                        isPlaceholder: selectedType == nil
                    )
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(settings.editorialDeskCatalog.types.isEmpty)

                if totalSourceCount > 0 {
                    metadataChip(
                        icon: "checkmark.shield",
                        title: "",
                        value: "\(selectedSourceCount)/\(totalSourceCount) sources",
                        tint: .green
                    )
                    .help("\(selectedSourceCount) of \(totalSourceCount) sources will be used as ground truth.")
                }

                if !hasDocument, totalSourceCount == 0, selectedSection == nil, selectedType == nil {
                    Text("Start with a document or a source")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func metadataChip(
        icon: String,
        title: String,
        value: String,
        tint: Color = .secondary,
        isPlaceholder: Bool = false
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(isPlaceholder ? Color.secondary : tint)
            metadataChipText(title: title, value: value, tint: tint)
            if title != "" || value != "" {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .fixedSize(horizontal: true, vertical: false)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(.separator, lineWidth: 0.5) }
    }

    private func metadataChipText(title: String, value: String, tint: Color) -> Text {
        let valueColor = tint == Color.secondary ? Color.primary : tint
        if title.isEmpty {
            return Text(value).foregroundColor(valueColor)
        }
        if value.isEmpty {
            return Text("\(title):").foregroundColor(.secondary)
        }
        return Text("\(title): ").foregroundColor(.secondary)
            + Text(value).foregroundColor(valueColor)
    }

    private func editorialColor(_ hex: String) -> Color {
        let normalized = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard let value = UInt64(normalized, radix: 16) else { return .accentColor }
        return Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
