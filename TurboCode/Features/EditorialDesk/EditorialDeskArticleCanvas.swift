import SwiftUI

/// Owns the writing surface and intake overlay. It mutates only the draft
/// bindings supplied by the desk ViewModel and does not know about publishing.
struct EditorialDeskArticleCanvas: View {
    @Bindable var viewModel: EditorialDeskViewModel
    @Binding var selectedTab: EditorialDeskTab
    @Binding var hoveredAction: EditorialAction?
    @Binding var actionMenuPresented: Bool
    @Binding var editorScrollOffset: CGFloat
    @FocusState private var focusedField: DraftField?

    private enum DraftField {
        case title
        case deck
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            articleHeader
            Divider()

            GeometryReader { viewport in
                ZStack(alignment: .topLeading) {
                    HStack(alignment: .top, spacing: 0) {
                        if !viewModel.documentContent.isEmpty {
                            lineNumberGutter
                                .frame(height: viewport.size.height, alignment: .top)
                                .offset(y: -editorScrollOffset)
                                .clipped()
                        }

                        ZStack(alignment: .topLeading) {
                            EditorialCanvasTextView(
                                text: Binding(
                                    get: { viewModel.documentContent },
                                    set: { viewModel.updateBody($0) }
                                ),
                                verticalScrollOffset: $editorScrollOffset
                            )
                            .accessibilityLabel("Draft body")
                            .accessibilityHint("Editable article body")

                            if viewModel.documentContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                emptyDocumentPrompt
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .padding(.vertical, 14)
                    .frame(
                        width: viewport.size.width,
                        height: viewport.size.height,
                        alignment: .top
                    )
                    .clipped()

                    if selectedTab != .write {
                        intakePanel
                            .padding(.horizontal, 28)
                            .padding(.top, 16)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }

                    if viewModel.hasDocument {
                        Button {
                            withAnimation(.snappy(duration: 0.18)) {
                                actionMenuPresented.toggle()
                            }
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.tint)
                                .frame(width: 28, height: 28)
                                .background(.background, in: Circle())
                                .overlay { Circle().strokeBorder(.separator, lineWidth: 0.5) }
                                .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                        .help("Open editorial actions")
                        .accessibilityLabel("Open editorial actions")
                        .padding(.leading, 16)
                        .padding(.top, 124)

                        if actionMenuPresented {
                            editorialActionMenu
                                .transition(.scale(scale: 0.96, anchor: .topLeading).combined(with: .opacity))
                                .padding(.top, 124)
                                .padding(.trailing, 20)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                .frame(
                    width: viewport.size.width,
                    height: viewport.size.height,
                    alignment: .topLeading
                )
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var intakePanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(selectedTab.rawValue, systemImage: selectedTab.systemImage)
                    .font(.headline)
                Spacer()
                Button {
                    selectedTab = .write
                    viewModel.selectedTab = .write
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Close intake panel")
                .accessibilityLabel("Close intake panel")
            }

            Text("Add material to the desk as a draft or as a ground-truth source.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextField(
                "Source name (optional)",
                text: Binding(
                    get: { viewModel.intakeName },
                    set: { viewModel.intakeName = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)

            TextEditor(
                text: Binding(
                    get: { viewModel.intakeText },
                    set: { viewModel.intakeText = $0 }
                )
            )
            .font(.system(size: 13))
            .frame(minHeight: 150)
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.separator, lineWidth: 0.5)
            }
            .accessibilityLabel("Source content")

            HStack {
                Button("Use as document") {
                    viewModel.useIntakeAsDocument()
                    selectedTab = .write
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.canCommitIntake)

                Button("Add as source") {
                    viewModel.addIntakeAsSource()
                }
                .buttonStyle(.bordered)
                .disabled(!viewModel.canCommitIntake)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.13), radius: 12, y: 5)
        .frame(maxWidth: 560)
    }

    private var articleHeader: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField(
                "Title",
                text: Binding(
                    get: { viewModel.documentTitle },
                    set: { viewModel.updateTitle($0) }
                )
            )
            .font(.system(size: 25, weight: .medium, design: .serif))
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .title)
            .onSubmit { focusedField = .deck }
            .accessibilityLabel("Draft title")
            .accessibilityHint("Press Return to move to the subtitle.")

            TextField(
                "Subtitle (deck)",
                text: Binding(
                    get: { viewModel.documentDeck },
                    set: { viewModel.updateDeck($0) }
                )
            )
            .font(.system(size: 14))
            .textFieldStyle(.plain)
            .focused($focusedField, equals: .deck)
            .accessibilityLabel("Draft subtitle")
            .accessibilityHint("Optional subtitle or deck.")
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 22)
    }

    private var lineNumberGutter: some View {
        let lineCount = max(1, viewModel.documentContent.split(separator: "\n", omittingEmptySubsequences: false).count)
        return VStack(alignment: .trailing, spacing: 0) {
            ForEach(0..<lineCount, id: \.self) { index in
                Text("\(index + 1)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(height: 23, alignment: .top)
            }
        }
        .frame(width: 52, alignment: .trailing)
        .padding(.trailing, 18)
        .padding(.top, 11)
        .accessibilityHidden(true)
    }

    private var emptyDocumentPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "text.cursor")
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.tertiary)
            Text("Start writing")
                .font(.system(size: 18, weight: .medium, design: .serif))
            Text("Write directly here, or choose Paste, Notes (manual), or Transcript (manual) above.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
        .padding(.leading, 12)
    }

    private var editorialActionMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionButton("Verify facts", icon: "checkmark.seal")
            actionButton("Make neutral", icon: "circle.lefthalf.filled")
            actionButton("Tighten the lead", icon: "diamond")
            actionButton("Check citations", icon: "list.bullet.indent")
            actionButton("Desk summary", icon: "list.bullet.rectangle")
        }
        .padding(6)
        .frame(width: 164)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }

    private func actionButton(_ title: String, icon: String) -> some View {
        let action = EditorialAction(rawValue: title)
        return Button {
            guard let action else { return }
            actionMenuPresented = false
            hoveredAction = nil
            viewModel.run(action: action, snapshot: viewModel.makeDraftSnapshot())
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 12))
                .foregroundStyle(hoveredAction == action ? Color.accentColor : Color.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 7)
                .frame(height: 28)
                .background(
                    hoveredAction == action
                        ? Color.accentColor.opacity(0.12)
                        : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onHover { isHovering in
            hoveredAction = isHovering ? action : nil
        }
        .animation(.easeOut(duration: 0.12), value: hoveredAction)
    }
}
