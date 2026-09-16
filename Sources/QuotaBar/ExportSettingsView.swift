import SwiftUI

struct ExportSettingsView: View {
    @ObservedObject var model: ExportSettingsModel

    private static let paneWidth: CGFloat = 620
    private static let paneHeight: CGFloat = 460

    var body: some View {
        Form {
            Section("Report") {
                LabeledContent("Layout") {
                    Text("Usage trends")
                }

                Picker("Period", selection: self.$model.period) {
                    ForEach(ExportPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
                .disabled(self.model.isExporting)

                LabeledContent("Scope") {
                    Text("All stored sources")
                }

                LabeledContent("Format") {
                    Text("Bilingual HTML (offline)")
                }
            }

            Section {
                Text("Switch between Chinese and English in the report. Uses saved local usage; cache costs are not stored separately.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("Open after export", isOn: self.$model.openAfterExport)
                    .disabled(self.model.isExporting)
            }

            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        self.statusView
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Spacer(minLength: 12)
                        Button {
                            Task { await self.model.export() }
                        } label: {
                            Label(self.exportButtonTitle, systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                        .disabled(self.model.isExporting)
                    }

                    if case let .failed(message) = self.model.status {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }

                    if case .saved = self.model.status {
                        HStack(spacing: 8) {
                            Button {
                                self.model.openReport()
                            } label: {
                                Label("Open Report", systemImage: "doc.text")
                            }
                            Button {
                                self.model.showInFinder()
                            } label: {
                                Label("Show in Finder", systemImage: "folder")
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: Self.paneWidth, height: Self.paneHeight)
    }

    @ViewBuilder
    private var statusView: some View {
        switch self.model.status {
        case .idle:
            Text("Choose a period, then export an offline report.")
                .foregroundStyle(.secondary)
        case .exporting:
            HStack(spacing: 7) {
                ProgressView()
                    .controlSize(.small)
                Text("Exporting report…")
            }
        case .choosingDestination:
            Label("Choose where to save the report.", systemImage: "folder.badge.plus")
                .foregroundStyle(.secondary)
        case let .saved(url):
            Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .lineLimit(2)
                .truncationMode(.middle)
                .help(url.path)
        case .cancelled:
            Label("Export cancelled.", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .noRecordedUsage:
            Label("No saved usage in this period", systemImage: "tray")
                .foregroundStyle(.secondary)
        case .failed:
            Label("Export failed.", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }

    private var exportButtonTitle: String {
        switch self.model.status {
        case .failed:
            "Try Again…"
        default:
            "Export Report…"
        }
    }
}
