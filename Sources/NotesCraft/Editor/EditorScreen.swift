import NotesCraftCore
import SwiftUI
import UniformTypeIdentifiers

struct EditorScreen: View {
    @Bindable var model: EditorModel
    var onClose: () -> Void
    @Environment(\.scenePhase) private var scenePhase
    private var settings: AppSettings { AppSettings.shared }
    private var library: LibraryStore { LibraryStore.shared }
    @State private var renaming = false
    @State private var renameText = ""
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var showPDFImporter = false
    @State private var pdfInsertIndex = 0
    @Environment(\.horizontalSizeClass) private var hSize
    private var compact: Bool { hSize == .compact }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ToolRow(model: model, onInsertPhoto: { showPhotoPicker = true }, onInsertCamera: { showCamera = true })
                .padding(.bottom, 6)
            ZStack {
                HStack(spacing: 0) {
                    if model.showNavigator {
                        PageNavigator(model: model, onInsertPDF: { index in
                            pdfInsertIndex = index
                            showPDFImporter = true
                        })
                        .frame(width: compact ? 150 : 200)
                        .transition(.move(edge: .leading).combined(with: .opacity))
                        Rectangle().fill(Theme.hair).frame(width: 0.5)
                    }
                    // The canvas handles the keyboard itself (content inset), so
                    // SwiftUI must not shrink it when the keyboard appears.
                    CanvasRepresentable(controller: model.canvas)
                        .ignoresSafeArea(.container, edges: .bottom)
                        .ignoresSafeArea(.keyboard)
                    if model.showFind {
                        Rectangle().fill(Theme.hair).frame(width: 0.5)
                        FindPanel(model: model, onClose: {
                            withAnimation(.spring(duration: 0.3)) { model.showFind = false }
                            model.clearFind()
                        })
                        .frame(width: compact ? 260 : 300)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                    if model.showTranscript {
                        Rectangle().fill(Theme.hair).frame(width: 0.5)
                        TranscriptPanel(model: model, onClose: {
                            withAnimation(.spring(duration: 0.3)) { model.showTranscript = false }
                        })
                        .frame(width: compact ? 280 : 320)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                overlays
            }
        }
        .background(Theme.desk.ignoresSafeArea())
        .background(Theme.background)
        .animation(.spring(duration: 0.32), value: model.showNavigator)
        .animation(.spring(duration: 0.32), value: model.showTranscript)
        .animation(.spring(duration: 0.32), value: model.showAudioBar)
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { model.saveForBackground() }
        }
        .onChange(of: settings.drawWithFinger) { _, _ in
            model.canvas.applyTool(model.tools)
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoPicker(selectionLimit: 1) { datas in
                if let data = datas.first, let image = UIImage(data: data) {
                    model.insertImage(image)
                } else {
                    model.showToast("That photo couldn't be loaded")
                }
            }
            .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in model.insertImage(image) }.ignoresSafeArea()
        }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
            if case let .success(url) = result {
                Task { await model.importPDFPages(from: url, after: pdfInsertIndex) }
            }
        }
        .sheet(item: $model.sheet) { sheet in
            sheetContent(sheet)
        }
        .alert("Rename notebook", isPresented: $renaming) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { library.rename(model.document.id, to: renameText) }
        }
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("NotesCraft", isPresented: Binding(get: { library.errorMessage != nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: SelfTest.closeEditor)) { _ in onClose() }
        .statusBarHidden(false)
        .persistentSystemOverlays(.hidden)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 2) {
            Button {
                onClose()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Back to library")
            .keyboardShortcut("w", modifiers: .command)

            if !model.isBoard {
                Button {
                    model.showNavigator.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(IconButtonStyle(isSelected: model.showNavigator))
                .accessibilityLabel("Pages")
            }

            Menu {
                Button {
                    renameText = model.title
                    renaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                Button {
                    model.sheet = .notebookSettings
                } label: {
                    Label("Cover", systemImage: "paintpalette")
                }
                Button {
                    library.setFavorite([model.document.id], !(library.meta(model.document.id)?.isFavorite ?? false))
                } label: {
                    let fav = library.meta(model.document.id)?.isFavorite ?? false
                    Label(fav ? "Remove from Favorites" : "Add to Favorites", systemImage: fav ? "star.slash" : "star")
                }
            } label: {
                HStack(spacing: 4) {
                    Text(model.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.ink3)
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: 320, alignment: .leading)
            }

            Spacer(minLength: 8)

            Button {
                model.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!model.canUndo)
            .opacity(model.canUndo ? 1 : 0.35)
            .keyboardShortcut("z", modifiers: .command)
            .accessibilityLabel("Undo")

            Button {
                model.redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .buttonStyle(IconButtonStyle())
            .disabled(!model.canRedo)
            .opacity(model.canRedo ? 1 : 0.35)
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .accessibilityLabel("Redo")

            Rectangle().fill(Theme.hair).frame(width: 1, height: 22).padding(.horizontal, 4)

            RecordButton(model: model)

            if !model.recordings.isEmpty && !compact {
                Button {
                    if model.showAudioBar { model.closeAudioBar() } else { model.showAudioBar = true }
                } label: {
                    Image(systemName: "waveform")
                }
                .buttonStyle(IconButtonStyle(isSelected: model.showAudioBar))
                .accessibilityLabel("Recordings")
            }

            if !compact {
                Button {
                    withAnimation(.spring(duration: 0.32)) { model.showZoomWindow.toggle() }
                } label: {
                    Image(systemName: "rectangle.bottomthird.inset.filled")
                }
                .buttonStyle(IconButtonStyle(isSelected: model.showZoomWindow))
                .accessibilityLabel(model.showZoomWindow ? "Close zoom window" : "Zoom window")
                .help("Write magnified; ink lands small and neat on the page")

                Button {
                    toggleFind()
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(IconButtonStyle(isSelected: model.showFind))
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityLabel("Find in notebook")
            }

            Menu {
                if !model.isBoard {
                    Button {
                        model.addPage(after: model.currentPage)
                    } label: {
                        Label("Add page after this one", systemImage: "doc.badge.plus")
                    }
                    Button {
                        model.addPage(before: model.currentPage)
                    } label: {
                        Label("Add page before this one", systemImage: "doc.on.doc")
                    }
                    Button {
                        model.sheet = .newPage(afterIndex: model.currentPage)
                    } label: {
                        Label("Add page with template…", systemImage: "square.grid.3x3")
                    }
                    Divider()
                    Button {
                        pdfInsertIndex = model.currentPage
                        showPDFImporter = true
                    } label: {
                        Label("Insert PDF pages…", systemImage: "doc.richtext")
                    }
                }
                Button {
                    showPhotoPicker = true
                } label: {
                    Label("Insert photo", systemImage: "photo")
                }
                Button {
                    showCamera = true
                } label: {
                    Label("Take photo", systemImage: "camera")
                }
            } label: {
                Image(systemName: "plus.rectangle.on.rectangle")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Add")

            if !compact {
                Button {
                    model.sheet = .export
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Share and export")
            }

            Menu {
                if compact {
                    Button {
                        toggleFind()
                    } label: {
                        Label("Find in notebook", systemImage: "magnifyingglass")
                    }
                    Button {
                        model.sheet = .export
                    } label: {
                        Label("Share and export", systemImage: "square.and.arrow.up")
                    }
                    if !model.recordings.isEmpty {
                        Button {
                            model.showAudioBar = true
                        } label: {
                            Label("Audio player", systemImage: "waveform")
                        }
                    }
                    Divider()
                }
                Button {
                    model.sheet = .pageSetup(pageIDs: model.document.pages.indices.contains(model.currentPage) ? [model.document.pages[model.currentPage].id] : [])
                } label: {
                    Label(model.isBoard ? "Canvas background…" : "Page template…", systemImage: "doc.text")
                }
                if !model.isBoard {
                    Button {
                        if model.document.pages.indices.contains(model.currentPage) {
                            model.toggleBookmark(model.document.pages[model.currentPage].id)
                        }
                    } label: {
                        let marked = model.document.pages.indices.contains(model.currentPage) && model.document.pages[model.currentPage].bookmarked
                        Label(marked ? "Remove bookmark" : "Bookmark this page", systemImage: marked ? "bookmark.slash" : "bookmark")
                    }
                }
                Button {
                    model.canvas.zoomToFit(animated: true)
                } label: {
                    if model.isBoard {
                        Label("Show everything", systemImage: "arrow.down.right.and.arrow.up.left")
                    } else {
                        Label("Fit page width", systemImage: "arrow.left.and.right")
                    }
                }
                Toggle(isOn: Binding(get: { model.showZoomWindow }, set: { on in
                    withAnimation(.spring(duration: 0.32)) { model.showZoomWindow = on }
                })) {
                    Label("Zoom window", systemImage: "rectangle.bottomthird.inset.filled")
                }
                Toggle(isOn: $model.rulerActive) {
                    Label("Ruler", systemImage: "ruler")
                }
                Button {
                    model.paste()
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                }
                .disabled(!Clipboard.hasContent)
                Divider()
                Button {
                    model.printNotebook()
                } label: {
                    Label("Print", systemImage: "printer")
                }
                Button {
                    model.sheet = .recordings
                } label: {
                    Label("Recordings", systemImage: "waveform")
                }
                .disabled(model.recordings.isEmpty)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .medium))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("More")
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 10)
        .frame(height: 50)
    }

    private func toggleFind() {
        withAnimation(.spring(duration: 0.3)) { model.showFind.toggle() }
        if !model.showFind { model.clearFind() }
    }

    // MARK: Overlays

    private var overlays: some View {
        ZStack {
            // Page indicator
            if settings.showPageNumbers && !model.isBoard {
                VStack {
                    Spacer()
                    HStack {
                        Button {
                            model.showNavigator.toggle()
                        } label: {
                            Text("\(model.currentPage + 1) / \(model.pageCount)")
                                .font(Theme.mono(12, weight: .medium))
                                .foregroundStyle(Theme.ink2)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .glassCapsule()
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Page \(model.currentPage + 1) of \(model.pageCount)")
                        Spacer()
                    }
                    .padding(.leading, model.showNavigator ? (compact ? 166 : 216) : 16)
                    .padding(.bottom, (model.showAudioBar ? 84 : 16) + (model.showZoomWindow ? ZoomWindowPanel.height + 10 : 0))
                }
            }
            if let zoom = model.zoomBadge {
                Text("\(zoom)%")
                    .font(Theme.mono(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .glassCapsule()
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
            if let toast = model.toast {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                        .glassCapsule()
                        .padding(.bottom, (model.showAudioBar ? 90 : 60) + (model.showZoomWindow ? ZoomWindowPanel.height + 10 : 0))
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                .allowsHitTesting(false)
            }
            if model.showZoomWindow {
                VStack {
                    Spacer()
                    ZoomWindowPanel(model: model)
                        .padding(.horizontal, 12)
                        .padding(.bottom, model.showAudioBar ? 82 : 10)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if model.showAudioBar {
                VStack {
                    Spacer()
                    AudioBar(model: model)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            if let message = model.busyMessage {
                BusyOverlay(message: message)
            }
            if !settings.hasSeenEditorTips && !SelfTest.enabled {
                EditorTips { withAnimation(.spring(duration: 0.3)) { settings.hasSeenEditorTips = true } }
                    .transition(.scale(scale: 0.95).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: EditorSheet) -> some View {
        switch sheet {
        case let .pageSetup(ids):
            PageSetupSheet(model: model, pageIDs: ids)
        case let .newPage(index):
            NewPageSheet(model: model, afterIndex: index)
        case .export:
            ExportSheet(model: model)
        case .find:
            EmptyView()
        case .recordings:
            RecordingsSheet(model: model)
        case let .convertedText(text):
            ConvertedTextSheet(model: model, text: text)
        case .notebookSettings:
            CoverSheet(id: model.document.id)
        case .elements:
            ElementsSheet(model: model)
        }
    }
}

/// Record button that becomes a live recording control.
struct RecordButton: View {
    @Bindable var model: EditorModel

    var body: some View {
        let audio = model.audio
        if audio.recordState == .idle {
            Button {
                model.toggleRecording()
            } label: {
                Image(systemName: "mic")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Record audio")
        } else {
            HStack(spacing: 6) {
                Circle()
                    .fill(Theme.record)
                    .frame(width: 9, height: 9)
                    .opacity(audio.recordState == .recording ? 1 : 0.35)
                    .scaleEffect(audio.recordState == .recording ? 1 + CGFloat(audio.recordLevel) * 0.5 : 1)
                    .animation(.easeOut(duration: 0.1), value: audio.recordLevel)
                Text(audio.recordElapsed.clock)
                    .font(Theme.mono(13, weight: .semibold))
                    .foregroundStyle(Theme.record)
                    .monospacedDigit()
                Button {
                    if audio.recordState == .recording { audio.pauseRecording() } else { audio.resumeRecording() }
                } label: {
                    Image(systemName: audio.recordState == .recording ? "pause.fill" : "record.circle")
                        .font(.system(size: 13, weight: .bold))
                }
                .accessibilityLabel(audio.recordState == .recording ? "Pause recording" : "Resume recording")
                Button {
                    model.toggleRecording()
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 13, weight: .bold))
                }
                .accessibilityLabel("Stop recording")
            }
            .foregroundStyle(Theme.record)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Theme.record.opacity(0.12), in: Capsule())
        }
    }
}


/// Shown once, the first time a notebook is opened.
struct EditorTips: View {
    var onDone: () -> Void

    private let tips: [(String, String, String)] = [
        ("pencil.tip", "Write with Apple Pencil", "Your finger scrolls and pinches to zoom. No Pencil? Turn on “Draw with finger” in the pen options."),
        ("hand.tap", "Undo with two fingers", "Tap with two fingers to undo, three to redo."),
        ("skew", "Draw and hold for shapes", "Pause at the end of a stroke and it becomes a clean line, circle or rectangle."),
        ("slider.horizontal.3", "Tap a tool again for options", "Pens, colors and thickness live behind the tool you're using."),
        ("mic", "Record while you write", "Play it back later and your notes replay with the audio. Tap any ink to jump there."),
    ]

    var body: some View {
        ZStack {
            Color.black.opacity(0.25).ignoresSafeArea().onTapGesture(perform: onDone)
            VStack(alignment: .leading, spacing: 18) {
                HouseTitle(lead: "A few", human: "tips", size: 28)
                ForEach(tips, id: \.1) { symbol, title, detail in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: symbol)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).font(.headline).foregroundStyle(Theme.ink)
                            Text(detail).font(.subheadline).foregroundStyle(Theme.ink2)
                        }
                    }
                }
                Button("Start writing", action: onDone)
                    .buttonStyle(PillButtonStyle())
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(28)
            .frame(maxWidth: 460)
            .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.radiusLarge, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 30, y: 10)
            .padding(24)
        }
    }
}
