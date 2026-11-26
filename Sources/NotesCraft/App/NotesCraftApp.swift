import NotesCraftCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct NotesCraftApp: App {
    @State private var library = LibraryStore.shared
    @State private var settings = AppSettings.shared

    init() {
        StoragePaths.clearExports()
        // UIKit parts of SwiftUI (list checkmarks, form icons) take the window's
        // tint; without this they turn system blue after switching to dark mode.
        UIWindow.appearance().tintColor = Theme.accentUI
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(library)
                .environment(settings)
                .tint(Theme.accent)
                .preferredColorScheme(settings.appearance.colorScheme)
        }
    }
}

struct RootView: View {
    @State private var model = LibraryModel()
    @State private var columns = NavigationSplitViewVisibility.all
    private var library: LibraryStore { LibraryStore.shared }
    private var settings: AppSettings { AppSettings.shared }

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            SidebarView(model: model)
                .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
        } detail: {
            NavigationStack {
                LibraryView(model: model)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .fullScreenCover(item: $model.openRequest) { request in
            EditorContainer(request: request)
                .environment(library)
                .environment(settings)
        }
        .sheet(isPresented: $model.showNewNotebook) {
            NewNotebookSheet(model: model)
        }
        .sheet(isPresented: $model.showSettings) {
            SettingsView()
        }
        .sheet(item: Binding(get: { model.moveIDs.map(IDList.init) }, set: { model.moveIDs = $0?.ids })) { list in
            MoveSheet(ids: list.ids) { model.endSelecting() }
        }
        .sheet(item: Binding(get: { model.coverTarget.map { IDList(ids: [$0]) } }, set: { model.coverTarget = $0?.ids.first })) { list in
            CoverSheet(id: list.ids[0])
        }
        .fileImporter(isPresented: $model.showImporter, allowedContentTypes: [.pdf, .image, .notesCraftArchive], allowsMultipleSelection: true) { result in
            model.handleImport(result)
        }
        .sheet(isPresented: $model.showPhotos) {
            PhotoPicker(selectionLimit: 50) { datas in model.importPhotos(datas) }
                .ignoresSafeArea()
        }
        .fullScreenCover(isPresented: $model.showScanner) {
            DocumentScanner { images in model.importScan(images) }
                .ignoresSafeArea()
        }
        .alert("Rename", isPresented: Binding(get: { model.renameTarget != nil }, set: { if !$0 { model.renameTarget = nil } })) {
            TextField("Name", text: $model.renameText)
            Button("Cancel", role: .cancel) { model.renameTarget = nil }
            Button("Rename") { model.commitRename() }
        }
        .alert("New folder", isPresented: Binding(get: { model.newFolderParent != nil }, set: { if !$0 { model.newFolderParent = nil } })) {
            TextField("Folder name", text: $model.newFolderName)
            Button("Cancel", role: .cancel) { model.newFolderParent = nil }
            Button("Create") { model.commitNewFolder() }
        }
        .alert(model.pendingPassword?.wrongPassword == true ? "Wrong password" : "Password required",
               isPresented: Binding(get: { model.pendingPassword != nil }, set: { if !$0 { model.pendingPassword = nil } })) {
            SecureField("Password", text: $model.passwordText)
            Button("Cancel", role: .cancel) { model.pendingPassword = nil }
            Button("Unlock") { model.submitPassword() }
        } message: {
            Text("“\(model.pendingPassword?.url.lastPathComponent ?? "This PDF")” is protected. Enter its password to import an unlocked copy.")
        }
        .confirmationDialog("Empty the Trash?", isPresented: $model.confirmEmptyTrash, titleVisibility: .visible) {
            Button("Delete \(library.index.trashedNotebooks.count) notebooks permanently", role: .destructive) { library.emptyTrash() }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Delete permanently?", isPresented: Binding(get: { model.confirmDeleteForever != nil }, set: { if !$0 { model.confirmDeleteForever = nil } }), titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) {
                if let ids = model.confirmDeleteForever { library.deletePermanently(ids) }
                model.confirmDeleteForever = nil
                model.endSelecting()
            }
        } message: {
            Text("This can't be undone.")
        }
        .confirmationDialog("Delete this folder?", isPresented: Binding(get: { model.confirmDeleteFolder != nil }, set: { if !$0 { model.confirmDeleteFolder = nil } }), titleVisibility: .visible) {
            Button("Delete folder", role: .destructive) {
                if let id = model.confirmDeleteFolder {
                    if case let .folder(current) = model.selection, library.index.descendantFolderIDs(of: id).contains(current) {
                        model.selection = .all
                    }
                    library.deleteFolder(id)
                }
                model.confirmDeleteFolder = nil
            }
        } message: {
            Text("Its notebooks move to the Trash, where you can restore them for 30 days.")
        }
        .alert("NotesCraft", isPresented: Binding(get: { library.errorMessage != nil && model.openRequest == nil }, set: { if !$0 { library.errorMessage = nil } })) {
            Button("OK", role: .cancel) { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .overlay {
            if let message = library.busyMessage {
                BusyOverlay(message: message)
            }
        }
        .onOpenURL { url in
            Task { await model.importFiles([url]) }
        }
        .onReceive(NotificationCenter.default.publisher(for: SelfTest.runRequested)) { _ in
            SelfTest.forced = true
            library.busyMessage = "Running diagnostics…"
            Task {
                await SelfTest.run()
                library.busyMessage = nil
                SelfTest.forced = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SelfTest.openNotebook)) { note in
            if let id = note.object as? UUID { model.open(id) }
        }
        .task {
            if SelfTest.enabled {
                await SelfTest.run()
            } else {
                try? await Task.sleep(for: .seconds(8))
                library.autoBackupIfNeeded()
            }
        }
        .onAppear {
            #if NOTESCRAFT_DEV
            Automation.libraryModel = model
            Automation.start()
            #endif
            if !settings.hasSeenWelcome, library.index.notebooks.isEmpty {
                createWelcomeNotebook()
            }
            settings.hasSeenWelcome = true
        }
    }

    private func createWelcomeNotebook() {
        _ = try? library.createNotebook(title: "My first notebook", paper: settings.defaultPaper, cover: .design(color: .sage, pattern: .linen), folder: nil)
    }
}

struct IDList: Identifiable {
    var ids: [UUID]
    var id: String { ids.map(\.uuidString).joined() }
}

struct BusyOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView().controlSize(.large)
                Text(message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
            .frame(minWidth: 200)
            .glassBackground(cornerRadius: 22)
        }
        .transition(.opacity)
    }
}

/// Loads a notebook, then shows the editor.
struct EditorContainer: View {
    let request: OpenRequest
    @Environment(\.dismiss) private var dismiss
    private var library: LibraryStore { LibraryStore.shared }
    @State private var editor: EditorModel?
    @State private var failure: String?

    var body: some View {
        ZStack {
            Theme.desk.ignoresSafeArea()
            if let editor {
                EditorScreen(model: editor) {
                    editor.close()
                    dismiss()
                }
            } else if let failure {
                VStack(spacing: 16) {
                    Text("Couldn't open this notebook").font(Theme.serif(26))
                    Text(failure).font(.callout).foregroundStyle(Theme.ink2).multilineTextAlignment(.center)
                    Button("Back to library") { dismiss() }.buttonStyle(PillButtonStyle())
                }
                .padding(40)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task {
            guard editor == nil else { return }
            guard library.beginEditing(request.id) else {
                failure = LibraryError.alreadyOpen.localizedDescription
                return
            }
            do {
                let document = try await NotebookDocument.open(id: request.id)
                let model = EditorModel(document: document)
                editor = model
                if let page = request.page {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.goToPage(page, animated: false) }
                }
                if let query = request.query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        model.showFind = true
                        model.findQuery = query
                    }
                }
            } catch {
                library.endEditing(request.id)
                failure = error.localizedDescription
            }
        }
    }
}
