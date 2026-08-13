import AppKit
import MarkdownUI
import SwiftUI

/// Native presentation for answers grounded in TurboCode's official guide.
struct ProductGuideWidget: View {
    let block: ChatBlock

    @Environment(ChatStore.self) private var chatStore
    @Environment(\.chatFontSize) private var chatFontSize
    @Environment(\.openSettings) private var openSettings

    private var guide: ProductGuideBlock? { block.productGuide }

    var body: some View {
        if let guide {
            VStack(alignment: .leading, spacing: 16) {
                header(guide)

                Markdown(ChatMarkdownPresentation.cleaned(block.text))
                    .markdownTheme(AppTypography.chatMarkdownTheme(size: chatFontSize))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !guide.sources.isEmpty {
                    sourceRow(guide.sources)
                }

                if !guide.actions.isEmpty {
                    Divider()
                    actionRow(guide.actions)
                }
            }
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.accentColor.opacity(0.2), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 12, y: 4)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("TurboCode Guide: \(guide.title)")
        } else {
            Text(block.text)
                .font(AppTypography.chatBody(size: chatFontSize))
        }
    }

    private func header(_ guide: ProductGuideBlock) -> some View {
        HStack(spacing: 12) {
            logo
                .frame(width: 42, height: 42)

            VStack(alignment: .leading, spacing: 2) {
                Text("TURBOCODE GUIDE")
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Text(guide.title)
                    .font(.title3.weight(.semibold))
            }

            Spacer()

            Text("Docs \(guide.documentationVersion)")
                .font(AppTypography.badge)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary.opacity(0.45), in: Capsule())
        }
    }

    @ViewBuilder
    private var logo: some View {
        if let image = NSImage(named: NSImage.Name("turbocode-logo-provisional")) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 10))
        } else {
            Image(systemName: "hammer.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func sourceRow(_ sources: [ProductGuideSource]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("Official documentation", systemImage: "checkmark.seal.fill")
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)

            HStack(spacing: 6) {
                ForEach(sources) { source in
                    Text(source.title)
                        .font(AppTypography.badge)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.35), in: Capsule())
                }
            }
        }
    }

    private func actionRow(_ actions: [ProductGuideAction]) -> some View {
        HStack(spacing: 10) {
            ForEach(actions, id: \.self) { action in
                switch action {
                case .chooseWorkspace:
                    Button {
                        chatStore.chooseWorkspace()
                    } label: {
                        Label("Choose Workspace", systemImage: "folder")
                    }
                case .openSettings:
                    Button {
                        openSettings()
                    } label: {
                        Label("Open Settings", systemImage: "slider.horizontal.3")
                    }
                }
            }
            Spacer()
        }
        .controlSize(.small)
    }
}
