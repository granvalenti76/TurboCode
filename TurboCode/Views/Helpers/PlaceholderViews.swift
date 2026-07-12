import SwiftUI

// MARK: - Empty State Icon Helper

struct PlaceholderIcon: View {
    let icon: String
    let label: String

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text(label)
                .font(.title3)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Write Placeholder

struct WritePlaceholderView: View {
    var body: some View {
        PlaceholderIcon(icon: "doc.text.magnifyingglass", label: "Write Workspace")
    }
}

// MARK: - Terminal Placeholder

struct TerminalPlaceholderView: View {
    var body: some View {
        VStack {
            HStack {
                Image(systemName: "terminal")
                    .foregroundStyle(.secondary)
                Text("Terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            Spacer()
            Text("Terminal output will appear here")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(.background)
    }
}
