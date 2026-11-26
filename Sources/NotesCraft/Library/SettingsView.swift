import NotesCraftCore
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    private var settings: AppSettings { AppSettings.shared }
    private var library: LibraryStore { LibraryStore.shared }
    @Environment(\.dismiss) private var dismiss
    @State private var backupURL: URL?
    @State private var showRestore = false
    @State private var working = false
    @State private var versionTaps = 0
    @State private var copiedDiagnostics = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Section {
                    Toggle("Draw with finger", isOn: $settings.drawWithFinger)
                    Picker("Double-tap on Apple Pencil", selection: $settings.pencilDoubleTap) {
                        ForEach(PencilDoubleTapAction.allCases) { a in Text(a.title).tag(a) }
                    }
                    Toggle("Draw and hold to make shapes", isOn: $settings.holdToSnapShapes)
                    Toggle("Scribble over ink to erase it", isOn: $settings.scribbleToErase)
                    Toggle("Straight highlighter lines", isOn: $settings.straightHighlighter)
                    Toggle("Switch back after erasing", isOn: $settings.eraserAutoDeselect)
                } header: {
                    Text("Writing")
                } footer: {
                    Text("With “Draw with finger” off, your finger scrolls and zooms while Apple Pencil writes. Hold the pen still at the end of a stroke to turn it into a clean line, circle or rectangle. Scribble back and forth over writing to erase it.")
                }

                Section("Gestures") {
                    Toggle("Two-finger tap to undo, three to redo", isOn: $settings.tapGesturesUndo)
                    Toggle("Haptic feedback", isOn: $settings.haptics)
                }

                Section("New notebooks") {
                    PaperPicker(paper: $settings.defaultPaper)
                        .padding(.vertical, 8)
                }

                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearance) {
                        ForEach(AppearanceMode.allCases) { m in Text(m.title).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Show page numbers", isOn: $settings.showPageNumbers)
                }

                Section {
                    Toggle("Make handwriting searchable", isOn: $settings.indexHandwriting)
                    Toggle("Export ink as vector (sharper, smaller PDFs)", isOn: $settings.vectorInkExport)
                } header: {
                    Text("Search and export")
                } footer: {
                    Text("Handwriting is recognized on this iPad; nothing leaves your device.")
                }

                Section {
                    Toggle("Back up automatically every week", isOn: $settings.autoBackup)
                    if let last = settings.lastAutoBackup {
                        LabeledContent("Last automatic backup", value: last.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote)
                    }
                    Button {
                        backup()
                    } label: {
                        AccentLabel("Back up library now", systemImage: "externaldrive.badge.checkmark")
                    }
                    .disabled(working)
                    Button {
                        showRestore = true
                    } label: {
                        AccentLabel("Restore from a backup…", systemImage: "arrow.counterclockwise")
                    }
                    .disabled(working)
                    if let backupURL {
                        Label("Saved “\(backupURL.lastPathComponent)” to Files › On My iPad › NotesCraft › Backups.", systemImage: "checkmark.circle")
                            .font(.footnote)
                            .foregroundStyle(Theme.accent)
                        Button {
                            SharePresenter.share([backupURL])
                        } label: {
                            AccentLabel("Save a copy elsewhere (iCloud Drive, AirDrop)…", systemImage: "square.and.arrow.up")
                        }
                    }
                } header: {
                    Text("Backup")
                } footer: {
                    Text("Backups are single files you can keep in iCloud Drive or copy to another device. Restoring adds the notebooks from the backup; nothing is overwritten.")
                }

                Section {
                    Link(destination: AppInfo.newIssueURL(template: "bug_report.yml")) {
                        AccentLabel("Report a problem", systemImage: "exclamationmark.bubble")
                    }
                    Link(destination: AppInfo.newIssueURL(template: "feature_request.yml")) {
                        AccentLabel("Suggest a feature", systemImage: "lightbulb")
                    }
                    Button {
                        UIPasteboard.general.string = AppInfo.diagnostics(library: library)
                        copiedDiagnostics = true
                    } label: {
                        AccentLabel(copiedDiagnostics ? "Copied" : "Copy diagnostics", systemImage: copiedDiagnostics ? "checkmark" : "doc.on.doc")
                    }
                    Link(destination: AppInfo.releases) {
                        AccentLabel("What's new", systemImage: "sparkles")
                    }
                    Link(destination: AppInfo.repository) {
                        AccentLabel("Source code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                } header: {
                    Text("Help and feedback")
                } footer: {
                    Text("Reports go to the NotesCraft project on GitHub. Diagnostics include the app and iPadOS versions, the device model and how many notebooks you have; never their contents.")
                }

                Section("About") {
                    LabeledContent("Version", value: AppInfo.versionLabel)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            versionTaps += 1
                            if versionTaps >= 5 {
                                versionTaps = 0
                                dismiss()
                                // Diagnostics for development: results go to the device log.
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                                    NotificationCenter.default.post(name: SelfTest.runRequested, object: nil)
                                }
                            }
                        }
                    LabeledContent("Notebooks", value: "\(library.index.activeNotebooks.count)")
                    Text("NotesCraft is free and open source. Your notes are stored only on this device.")
                        .font(.footnote)
                        .foregroundStyle(Theme.ink2)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .fileImporter(isPresented: $showRestore, allowedContentTypes: [.notesCraftArchive, .data]) { result in
                guard case let .success(url) = result else { return }
                restore(url)
            }
            .overlay {
                if working {
                    ProgressView().controlSize(.large).padding(30).glassBackground()
                }
            }
        }
    }

    private func backup() {
        working = true
        Task {
            do {
                backupURL = try await library.backupLibrary()
            } catch {
                library.report("Backup failed: \(error.localizedDescription)")
            }
            working = false
        }
    }

    private func restore(_ url: URL) {
        working = true
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let restored = try await library.importArchive(from: url, folder: nil)
                library.report("Restored \(restored.count) notebook\(restored.count == 1 ? "" : "s").")
            } catch {
                library.report("Restore failed: \(error.localizedDescription)")
            }
            working = false
        }
    }
}

extension UTType {
    static let notesCraftArchive = UTType(exportedAs: "com.kronbii.notescraft.notebook", conformingTo: .data)
}
