import Charts
import SwiftUI

/// Native receipt for an explicit Git status tool call. The chart deliberately
/// summarizes only a bounded set so it remains readable inside the chat canvas.
struct GitStatusWidget: View {
    let status: GitStatusBlock

    private var displayedFiles: [GitStatusFileChange] {
        status.mostModifiedFiles()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            if let errorMessage = status.errorMessage {
                Text("File statistics unavailable: \(errorMessage)")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else if status.isClean {
                Label("Working tree clean", systemImage: "checkmark.circle")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
            } else if displayedFiles.isEmpty {
                Text("Line statistics are unavailable for the changed files.")
                    .font(AppTypography.metadata)
                    .foregroundStyle(.secondary)
            } else {
                Divider()

                HStack(spacing: 12) {
                    Text("Most modified files")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    legendItem("Added", color: .green)
                    legendItem("Deleted", color: .red)
                }

                Chart {
                    ForEach(displayedFiles) { file in
                        if file.additions > 0 {
                            BarMark(
                                x: .value("Lines", file.additions),
                                y: .value("File", file.path)
                            )
                            .foregroundStyle(by: .value("Change", "Added"))
                        }

                        if file.deletions > 0 {
                            BarMark(
                                x: .value("Lines", file.deletions),
                                y: .value("File", file.path)
                            )
                            .foregroundStyle(by: .value("Change", "Deleted"))
                        }
                    }
                }
                .chartForegroundStyleScale(
                    domain: ["Added", "Deleted"],
                    range: [Color.green, Color.red]
                )
                .chartLegend(.hidden)
                // Reversing the categorical domain places the largest file at
                // the top of the Cartesian y-axis instead of at the bottom.
                .chartYScale(domain: displayedFiles.map(\.path).reversed())
                .chartYAxis {
                    AxisMarks(position: .leading) { value in
                        AxisValueLabel {
                            if let path = value.as(String.self) {
                                Text(compactPath(path))
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                    .help(path)
                            }
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom) { value in
                        AxisGridLine()
                            .foregroundStyle(.separator.opacity(0.45))
                        AxisValueLabel {
                            if let count = value.as(Int.self) {
                                Text(count.formatted(.number.notation(.compactName)))
                            }
                        }
                    }
                }
                .frame(height: CGFloat(displayedFiles.count * 27 + 22))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Most modified files")
                .accessibilityValue(accessibilitySummary)
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator.opacity(0.55), lineWidth: 0.5)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("Git status")
                    .font(.system(size: 13, weight: .semibold))

                HStack(spacing: 8) {
                    Text(status.branch)
                        .fontDesign(.monospaced)
                    Text(changedFilesDescription)
                    if !status.files.isEmpty {
                        Text("+\(status.additions)")
                            .foregroundStyle(.green)
                        Text("-\(status.deletions)")
                            .foregroundStyle(.red)
                    }
                }
                .font(AppTypography.metadata)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
    }

    private var changedFilesDescription: String {
        let count = status.changedFilesCount
        return "\(count) \(count == 1 ? "file" : "files")"
    }

    private var accessibilitySummary: String {
        displayedFiles.map {
            "\($0.path), \($0.additions) added and \($0.deletions) deleted"
        }.joined(separator: "; ")
    }

    /// Retains the filename and nearest parent while avoiding a wide y-axis for
    /// deeply nested workspace paths. The full path remains available on hover.
    private func compactPath(_ path: String) -> String {
        let components = path.split(separator: "/")
        guard components.count > 2 else { return path }
        return components.suffix(2).joined(separator: "/")
    }

    private func legendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(title)
        }
        .font(.system(size: 9, weight: .medium))
        .foregroundStyle(.secondary)
    }
}
