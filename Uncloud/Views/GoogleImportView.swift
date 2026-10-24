import AppKit
import SwiftUI

/// The Google Photos pane (`Pane.google`): imports a Google Takeout download into the backup folder. A grouped form
/// like Export Settings. Three steps: get the download from Google, choose its files, import them. No Google logo.
struct GoogleImportView: View {
    @Environment(ExportModel.self) private var model

    private static let takeoutURL = URL(string: "https://takeout.google.com/settings/takeout/custom/photos")!

    private var imports: GoogleImportModel {
        model.googleImport
    }

    var body: some View {
        Form {
            getSection
            chooseSection
            importSection

            Section {
                Text("Uncloud reads these files on your Mac. Nothing is sent to Google or to Uncloud. Google Photos is a trademark of Google LLC. Uncloud isn’t affiliated with Google.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Steps

    private var getSection: some View {
        Section {
            Text("Google Takeout makes a copy of your Google Photos library you can download.")
            Button("Open Google Takeout") {
                NSWorkspace.shared.open(Self.takeoutURL)
            }
            HelpText("Choose Google Photos, export once, file type .zip. Larger files (50 GB) mean fewer downloads.")
        } header: {
            SectionTitle("Get your photos from Google")
        }
    }

    private var chooseSection: some View {
        Section {
            Button("Choose Takeout Files…") {
                imports.addInputs()
            }
            .disabled(imports.isRunning)
            ForEach(imports.inputs, id: \.self) { url in
                inputRow(url)
            }
        } header: {
            SectionTitle("Choose the downloaded files")
        } footer: {
            if imports.inputs.isEmpty {
                Text("Choose the .zip files or the folders Finder made from them.")
            }
        }
    }

    private func inputRow(_ url: URL) -> some View {
        let name = url.lastPathComponent
        return LabeledContent {
            HStack(spacing: Tokens.Space.s) {
                Text(sizeText(for: url))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button {
                    imports.remove(url)
                } label: {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .disabled(imports.isRunning)
                .help("Remove \(name)")
                .accessibilityLabel("Remove \(name)")
            }
        } label: {
            Label(name, systemImage: url.hasDirectoryPath ? "folder" : "doc.zipper")
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func sizeText(for url: URL) -> String {
        guard let bytes = imports.sizes[url] else { return "Folder" }
        return bytes.formatted(.byteCount(style: .file))
    }

    private var importSection: some View {
        Section {
            switch imports.phase {
            case .idle:
                idleContent
            case .scanning, .importing, .paused:
                runningContent
            case .finished(let summary):
                finishedContent(summary)
            case .failed(let message):
                failedContent(message)
            }
        } header: {
            SectionTitle("Import")
        }
    }

    /// The button, its reason and where the photos go, before a run.
    @ViewBuilder
    private var idleContent: some View {
        if let name = imports.destinationName {
            HelpText("Photos go to \(name), arranged like the rest of your backup.")
        }
        HStack {
            Button("Import to Backup") {
                imports.start()
            }
            .buttonStyle(.borderedProminent)
            .disabled(!imports.canStart)
            Spacer()
        }
        if let reason = imports.blockReason {
            HStack {
                HelpText(reason.message)
                Spacer()
                if reason == .noFolder {
                    Button("Open Export Settings") {
                        model.pane = .backup
                    }
                    .fixedSize()
                }
            }
        }
    }

    /// The progress while the import reads or copies, with Pause and Stop.
    @ViewBuilder
    private var runningContent: some View {
        if imports.phase == .scanning {
            ProgressView()
                .progressViewStyle(.linear)
                .accessibilityLabel("Reading your Takeout files")
            Text("Reading your Takeout files…")
                .font(.callout)
        } else {
            ProgressView(value: imports.fractionComplete)
                .accessibilityLabel("Import progress")
            Text("Importing \(imports.done.formatted()) of \(imports.total.formatted())")
                .font(.callout)
                .monospacedDigit()
            if imports.alreadyInBackup > 0 {
                HelpText("\(imports.alreadyInBackup.formatted()) already in your backup")
            }
            if let notice = imports.notice {
                HelpText(notice)
            }
        }
        HStack(spacing: Tokens.Space.s) {
            if imports.phase != .scanning {
                Button(imports.isPaused ? "Resume" : "Pause") {
                    if imports.isPaused {
                        imports.resume()
                    } else {
                        imports.pause()
                    }
                }
                .disabled(imports.isStopping)
            }
            Button("Stop") {
                imports.stop()
            }
            .disabled(imports.isStopping)
            Spacer()
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func finishedContent(_ summary: GoogleImportModel.Summary) -> some View {
        Label {
            Text(summary.headline)
                .font(.headline)
        } icon: {
            Image(systemName: summary.wasStopped ? "stop.circle" : "checkmark.circle.fill")
                .foregroundStyle(summary.wasStopped ? Tokens.Status.neutral : Tokens.Status.success)
        }
        if let already = summary.alreadyInBackupText {
            HelpText(already)
        }
        if summary.wasStopped {
            HelpText("Import again to pick up where it stopped.")
        }
        if summary.failedCount > 0 {
            Label("\(summary.failedCount.formatted()) couldn’t be imported", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Tokens.Status.warning)
            DisclosureGroup("Show What Couldn’t Be Imported") {
                ForEach(Array(summary.failures.enumerated()), id: \.offset) { _, failure in
                    VStack(alignment: .leading, spacing: Tokens.Space.xs) {
                        Text(failure.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HelpText(failure.reason)
                    }
                }
            }
        }
        HStack {
            Button("Show in Browse Backup") {
                model.pane = .browse
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func failedContent(_ message: String) -> some View {
        Label {
            Text(message)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Tokens.Status.danger)
        }
        HStack {
            Button("Import to Backup") {
                imports.start()
            }
            .disabled(!imports.canStart)
            Spacer()
        }
    }
}
