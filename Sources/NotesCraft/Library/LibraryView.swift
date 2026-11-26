import NotesCraftCore
import SwiftUI

struct LibraryView: View {
    @Bindable var model: LibraryModel
    private var library: LibraryStore { LibraryStore.shared }
    private var settings: AppSettings { AppSettings.shared }

    private var notebooks: [NotebookMeta] {
        library.notebooks(for: model.selection, sort: settings.librarySort)
    }

    private var folders: [Folder] {
        library.folders(for: model.selection)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                    SearchResultsView(model: model)
                } else if notebooks.isEmpty && folders.isEmpty {
                    EmptyLibraryView(model: model)
                } else {
                    if !folders.isEmpty {
                        folderGrid
                    }
                    if !notebooks.isEmpty {
                        if settings.libraryLayout == .grid { notebookGrid } else { notebookList }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 120)
        }
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.background)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search notes")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) {
            if model.isSelecting { selectionBar }
        }
        .navigationBarTitleDisplayMode(.inline)
        .animation(.spring(duration: 0.35), value: notebooks.map(\.id))
    }

    // MARK: Header

    private var isSearching: Bool {
        !model.searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isSearching {
                HouseTitle(lead: "Search", human: "results")
                let hits = library.search.search(model.searchText, in: library.index.activeNotebooks)
                let books = Set(hits.map(\.notebookID)).count
                Text("\(hits.count) match\(hits.count == 1 ? "" : "es") in \(books) notebook\(books == 1 ? "" : "s") for “\(model.searchText.trimmingCharacters(in: .whitespaces))”")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.ink3)
            } else if case let .folder(id) = model.selection {
                let path = library.index.path(to: id)
                if path.count > 1 {
                    HStack(spacing: 4) {
                        ForEach(path.dropLast()) { f in
                            Button(f.name) { model.selection = .folder(f.id) }
                                .buttonStyle(.plain)
                                .foregroundStyle(Theme.ink3)
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.ink3)
                        }
                    }
                    .font(.subheadline)
                }
                HouseTitle(lead: "", human: library.folder(id)?.name ?? "Folder")
            } else {
                let t = model.selection.title
                HouseTitle(lead: t.lead, human: t.human)
            }
            if !isSearching {
                Text(subtitle)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .padding(.top, 8)
    }

    private var subtitle: String {
        let n = notebooks.count
        var parts = ["\(n) notebook\(n == 1 ? "" : "s")"]
        if !folders.isEmpty { parts.append("\(folders.count) folder\(folders.count == 1 ? "" : "s")") }
        if model.selection == .trash, n > 0 { parts.append("deleted after 30 days") }
        return parts.joined(separator: " · ")
    }

    // MARK: Grids

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 26, alignment: .top)]

    private var folderGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
            ForEach(folders) { folder in
                FolderCard(folder: folder, model: model)
            }
        }
    }

    private var notebookGrid: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 30) {
            ForEach(notebooks) { nb in
                NotebookCard(meta: nb, model: model)
            }
        }
    }

    private var notebookList: some View {
        LazyVStack(spacing: 0) {
            ForEach(notebooks) { nb in
                NotebookRow(meta: nb, model: model)
                Divider().opacity(0.5)
            }
        }
        .cardSurface()
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if model.selection == .trash {
                if !notebooks.isEmpty {
                    Button("Empty Trash", role: .destructive) { model.confirmEmptyTrash = true }
                }
            } else {
                Menu {
                    Picker("Sort by", selection: Binding(get: { settings.librarySort }, set: { settings.librarySort = $0 })) {
                        ForEach(LibrarySort.allCases) { s in Text(s.title).tag(s) }
                    }
                    Picker("View as", selection: Binding(get: { settings.libraryLayout }, set: { settings.libraryLayout = $0 })) {
                        Label("Grid", systemImage: "square.grid.2x2").tag(LibraryLayoutMode.grid)
                        Label("List", systemImage: "list.bullet").tag(LibraryLayoutMode.list)
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort and view")
                Button(model.isSelecting ? "Done" : "Select") {
                    if model.isSelecting { model.endSelecting() } else { model.isSelecting = true }
                }
                .disabled(notebooks.isEmpty && !model.isSelecting)
                NewMenu(model: model)
            }
        }
    }

    // MARK: Selection bar

    private var selectionBar: some View {
        let ids = Array(model.selectedIDs)
        return HStack(spacing: 14) {
            Text("\(ids.count) selected")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.ink2)
            Spacer()
            if model.selection == .trash {
                Button("Restore") {
                    library.restore(ids)
                    model.endSelecting()
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(ids.isEmpty)
                Button("Delete") {
                    model.confirmDeleteForever = ids
                }
                .buttonStyle(PillButtonStyle(kind: .destructive))
                .disabled(ids.isEmpty)
            } else {
                Button {
                    let allFav = ids.allSatisfy { library.meta($0)?.isFavorite == true }
                    library.setFavorite(ids, !allFav)
                } label: {
                    Label("Favorite", systemImage: "star")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(ids.isEmpty)
                Button {
                    model.moveIDs = ids
                } label: {
                    Label("Move", systemImage: "folder")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(ids.isEmpty)
                Button {
                    library.trash(ids)
                    model.endSelecting()
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(PillButtonStyle(kind: .destructive))
                .disabled(ids.isEmpty)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassBackground(cornerRadius: 24)
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
    }
}

/// "+ New": a panel of large tiles to create a notebook, whiteboard, quick note
/// or folder, or to bring something in.
struct NewMenu: View {
    @Bindable var model: LibraryModel

    var body: some View {
        Button {
            model.newPanelShowsBoards = false
            model.showNewPanel = true
        } label: {
            Label("New", systemImage: "plus")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .foregroundStyle(Theme.accentInk)
                .background(Theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("New")
        .popover(isPresented: $model.showNewPanel, arrowEdge: .top) {
            NewItemsPanel(model: model) { action in
                model.showNewPanel = false
                // Let the panel close before a sheet or picker opens.
                Task {
                    try? await Task.sleep(for: .milliseconds(350))
                    action()
                }
            }
            .presentationCompactAdaptation(.popover)
        }
    }
}

struct NewItemsPanel: View {
    @Bindable var model: LibraryModel
    /// Closes the panel, then runs the action.
    var perform: (@escaping () -> Void) -> Void
    @State private var boardColor: PaperColor = .white

    private var pickingBoard: Bool {
        get { model.newPanelShowsBoards }
        nonmutating set { model.newPanelShowsBoards = newValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if pickingBoard {
                boardPicker
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                mainPanel
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .padding(20)
        .frame(width: 428)
        .animation(.snappy(duration: 0.24), value: pickingBoard)
    }

    private var mainPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionTitle("Create")
            HStack(alignment: .top, spacing: 12) {
                NewTile(title: "Notebook", symbol: "book.closed", tint: Theme.accent) {
                    perform { model.showNewNotebook = true }
                }
                NewTile(title: "Canvas", symbol: "scribble.variable", tint: Color(red: 0.36, green: 0.55, blue: 0.80)) {
                    pickingBoard = true
                }
                NewTile(title: "Quick note", symbol: "square.and.pencil", tint: Color(red: 0.80, green: 0.60, blue: 0.18)) {
                    perform { model.quickNote() }
                }
                NewTile(title: "Folder", symbol: "folder.badge.plus", tint: Color(red: 0.24, green: 0.45, blue: 0.62)) {
                    perform { model.beginNewFolder(parent: model.currentFolder) }
                }
            }
            Divider().padding(.vertical, 2)
            sectionTitle("Import")
            HStack(alignment: .top, spacing: 12) {
                NewTile(title: "Files", subtitle: "PDF, images", symbol: "doc.badge.arrow.up", tint: Color(red: 0.42, green: 0.47, blue: 0.52)) {
                    perform { model.showImporter = true }
                }
                NewTile(title: "Photos", symbol: "photo.on.rectangle", tint: Color(red: 0.78, green: 0.45, blue: 0.50)) {
                    perform { model.showPhotos = true }
                }
                if DocumentScanner.isSupported {
                    NewTile(title: "Scan", subtitle: "Documents", symbol: "doc.viewfinder", tint: Color(red: 0.50, green: 0.38, blue: 0.62)) {
                        perform { model.showScanner = true }
                    }
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                }
                Color.clear.frame(maxWidth: .infinity)
            }
        }
    }

    private var boardPicker: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Button {
                    pickingBoard = false
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
                .accessibilityLabel("Back")
                Text("New canvas").font(.headline)
            }
            Text("A huge free-form space you can pan and zoom in any direction.")
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
            HStack(spacing: 12) {
                ForEach([PaperKind.blank, .dotted, .grid], id: \.self) { kind in
                    Button {
                        let color = boardColor
                        perform { model.newBoard(kind, color: color) }
                    } label: {
                        VStack(spacing: 8) {
                            Image(uiImage: PaperPreviewCache.image(kind: kind, color: boardColor, pageSize: CGSize(width: 320, height: 240), board: true))
                                .resizable()
                                .aspectRatio(4 / 3, contentMode: .fit)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hair))
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                            Text(kind == .blank ? "Blank" : kind == .dotted ? "Dotted" : "Grid")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(Theme.ink)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(kind == .blank ? "Blank" : kind == .dotted ? "Dotted" : "Grid") canvas")
                }
            }
            HStack(spacing: 10) {
                Text("Canvas color").font(.subheadline).foregroundStyle(Theme.ink2)
                Spacer()
                ForEach([PaperColor.white, .ivory, .dark, .black], id: \.self) { color in
                    Button {
                        boardColor = color
                    } label: {
                        Circle()
                            .fill(color.fill.color)
                            .frame(width: 26, height: 26)
                            .overlay(Circle().strokeBorder(Theme.ink.opacity(0.22), lineWidth: 1))
                            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: boardColor == color ? 2 : 0).padding(-4))
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(boardColor == color ? .isSelected : [])
                }
            }
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.ink3)
            .textCase(.uppercase)
    }
}

/// A large icon tile in the New panel.
struct NewTile: View {
    let title: String
    var subtitle: String?
    let symbol: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(tint.opacity(0.15))
                    .frame(width: 68, height: 68)
                    .overlay(
                        Image(systemName: symbol)
                            .font(.system(size: 27, weight: .medium))
                            .foregroundStyle(tint)
                    )
                VStack(spacing: 1) {
                    Text(title)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(Theme.ink3)
                    }
                }
                .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableTileStyle())
        .accessibilityLabel(subtitle.map { "\(title), \($0)" } ?? title)
    }
}

/// Shrinks a tile slightly while pressed.
struct PressableTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.snappy(duration: 0.16), value: configuration.isPressed)
    }
}

// MARK: - Cards

struct NotebookCard: View {
    let meta: NotebookMeta
    @Bindable var model: LibraryModel
    private var library: LibraryStore { LibraryStore.shared }

    var body: some View {
        let selected = model.selectedIDs.contains(meta.id)
        Button {
            if model.isSelecting {
                model.toggleSelected(meta.id)
            } else if meta.isTrashed {
                library.report("Restore this notebook from the Trash to open it.")
            } else {
                model.open(meta.id)
            }
        } label: {
            VStack(alignment: .leading, spacing: 9) {
                CoverView(meta: meta)
                    .shadow(color: .black.opacity(0.13), radius: 10, x: 0, y: 5)
                    .overlay(alignment: .topTrailing) {
                        if model.isSelecting {
                            ZStack {
                                Circle().fill(selected ? Color.white : Color.black.opacity(0.25)).frame(width: 26, height: 26)
                                Circle().strokeBorder(.white, lineWidth: 2).frame(width: 26, height: 26)
                                if selected {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 13, weight: .heavy))
                                        .foregroundStyle(Theme.canvasAccent)
                                }
                            }
                            .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                            .padding(8)
                            .accessibilityHidden(true)
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        HStack(spacing: 4) {
                            if meta.recordingCount > 0 {
                                Image(systemName: "waveform")
                            }
                            if meta.isFavorite {
                                Image(systemName: "star.fill")
                            }
                        }
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.45), in: Capsule())
                        .padding(8)
                        .opacity(meta.recordingCount > 0 || meta.isFavorite ? 1 : 0)
                    }
                    .scaleEffect(selected ? 0.95 : 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(meta.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(detail)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(CardPressStyle())
        .contextMenu { NotebookMenu(meta: meta, model: model) }
        .draggable(meta.id.uuidString) {
            CoverView(meta: meta).frame(width: 90)
        }
        .accessibilityLabel(meta.isBoard ? "\(meta.title), canvas" : "\(meta.title), \(meta.pageCount) pages")
    }

    private var detail: String {
        let date = meta.isTrashed ? (meta.trashedAt ?? meta.modifiedAt) : meta.modifiedAt
        return "\(date.formatted(.relative(presentation: .named))) · \(meta.isBoard ? "canvas" : "\(meta.pageCount)p")"
    }
}

struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

struct NotebookRow: View {
    let meta: NotebookMeta
    @Bindable var model: LibraryModel
    private var library: LibraryStore { LibraryStore.shared }

    var body: some View {
        Button {
            if model.isSelecting { model.toggleSelected(meta.id) } else if !meta.isTrashed { model.open(meta.id) }
        } label: {
            HStack(spacing: 14) {
                if model.isSelecting {
                    Image(systemName: model.selectedIDs.contains(meta.id) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(model.selectedIDs.contains(meta.id) ? Theme.accent : Theme.ink3)
                        .font(.title3)
                }
                CoverView(meta: meta, showsTitle: false)
                    .frame(width: 36)
                    .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(meta.title).font(.body.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                    if let folder = meta.folderID.flatMap({ library.folder($0) }), model.selection == .all || model.selection == .recents {
                        Text(folder.name).font(.caption).foregroundStyle(Theme.ink3)
                    }
                }
                Spacer()
                if meta.recordingCount > 0 { Image(systemName: "waveform").foregroundStyle(Theme.ink3) }
                if meta.isFavorite { Image(systemName: "star.fill").foregroundStyle(Theme.accent) }
                Text(meta.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink3)
                Text(meta.isBoard ? "canvas" : "\(meta.pageCount)p")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink3)
                    .frame(width: 40, alignment: .trailing)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { NotebookMenu(meta: meta, model: model) }
        .draggable(meta.id.uuidString)
    }
}

struct FolderCard: View {
    let folder: Folder
    @Bindable var model: LibraryModel
    private var library: LibraryStore { LibraryStore.shared }
    @State private var isTargeted = false

    var body: some View {
        Button {
            model.selection = .folder(folder.id)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                FolderGlyph(color: folder.color)
                    .scaleEffect(isTargeted ? 1.06 : 1)
                    .shadow(color: .black.opacity(0.1), radius: 6, y: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    let n = library.index.notebookCount(inTree: folder.id)
                    Text("\(n) notebook\(n == 1 ? "" : "s")")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.ink3)
                }
            }
        }
        .buttonStyle(CardPressStyle())
        .contextMenu { FolderMenu(folder: folder, model: model) }
        .draggable("folder:" + folder.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            var moved = false
            for item in items {
                if item.hasPrefix("folder:"), let id = UUID(uuidString: String(item.dropFirst(7))) {
                    if id != folder.id { moved = library.moveFolder(id, to: folder.id) || moved }
                } else if let id = UUID(uuidString: item) {
                    library.move([id], to: folder.id)
                    moved = true
                }
            }
            if moved { Haptics.success() }
            return moved
        } isTargeted: { t in
            withAnimation(.spring(duration: 0.25)) { isTargeted = t }
        }
    }
}

struct NotebookMenu: View {
    let meta: NotebookMeta
    @Bindable var model: LibraryModel
    private var library: LibraryStore { LibraryStore.shared }

    var body: some View {
        if meta.isTrashed {
            Button {
                library.restore([meta.id])
            } label: {
                Label("Restore", systemImage: "arrow.uturn.backward")
            }
            Button(role: .destructive) {
                model.confirmDeleteForever = [meta.id]
            } label: {
                Label("Delete permanently", systemImage: "trash")
            }
        } else {
            Button {
                model.open(meta.id)
            } label: {
                Label("Open", systemImage: "book")
            }
            Button {
                model.beginRename(.notebook(meta.id))
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            Button {
                library.setFavorite([meta.id], !meta.isFavorite)
            } label: {
                Label(meta.isFavorite ? "Remove from Favorites" : "Add to Favorites", systemImage: meta.isFavorite ? "star.slash" : "star")
            }
            Button {
                model.coverTarget = meta.id
            } label: {
                Label("Change cover", systemImage: "paintpalette")
            }
            Button {
                model.moveIDs = [meta.id]
            } label: {
                Label("Move to…", systemImage: "folder")
            }
            Button {
                model.duplicate(meta.id)
            } label: {
                Label("Duplicate", systemImage: "plus.square.on.square")
            }
            Menu {
                Button {
                    model.sharePDF(meta.id)
                } label: {
                    Label("PDF", systemImage: "doc.richtext")
                }
                Button {
                    model.shareArchive(meta.id)
                } label: {
                    Label("NotesCraft notebook", systemImage: "book.closed")
                }
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                library.trash([meta.id])
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
    }
}

// MARK: - Empty state

struct EmptyLibraryView: View {
    @Bindable var model: LibraryModel

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 60)
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Theme.accent)
            Text(headline)
                .font(Theme.serif(28))
                .foregroundStyle(Theme.ink)
            Text(message)
                .font(.callout)
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if model.selection != .trash && model.selection != .favorites && model.selection != .audio && model.selection != .recents {
                HStack(spacing: 12) {
                    Button("New notebook") { model.showNewNotebook = true }
                        .buttonStyle(PillButtonStyle())
                    Button("Import PDF") { model.showImporter = true }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                .padding(.top, 6)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var symbol: String {
        switch model.selection {
        case .trash: "trash"
        case .favorites: "star"
        case .audio: "waveform"
        case .recents: "clock"
        default: "book.closed"
        }
    }

    private var headline: String {
        switch model.selection {
        case .trash: "Nothing in the trash"
        case .favorites: "No favorites yet"
        case .audio: "No recordings yet"
        case .recents: "Nothing recent"
        case .folder: "An empty folder"
        default: "A blank page"
        }
    }

    private var message: String {
        switch model.selection {
        case .trash: "Notebooks you delete stay here for 30 days."
        case .favorites: "Star a notebook from its menu to keep it here."
        case .audio: "Record a lecture inside any notebook; your notes will replay in sync with the audio."
        case .recents: "Notebooks you open show up here."
        case .folder: "Create a notebook here, or drag notebooks onto this folder in the sidebar."
        default: "Create your first notebook, or bring in a PDF to annotate."
        }
    }
}

// MARK: - Search

struct SearchResultsView: View {
    @Bindable var model: LibraryModel

    private func highlighted(_ hit: SearchHit) -> Text {
        var match = AttributedString(hit.match)
        match.font = .callout.weight(.semibold)
        match.foregroundColor = Theme.ink
        match.backgroundColor = Color(red: 1, green: 0.86, blue: 0.3).opacity(0.5)
        var before = AttributedString(hit.before)
        before.foregroundColor = Theme.ink2
        var after = AttributedString(hit.after)
        after.foregroundColor = Theme.ink2
        return Text(before + match + after)
    }
    private var library: LibraryStore { LibraryStore.shared }

    var body: some View {
        let hits = library.search.search(model.searchText, in: library.index.activeNotebooks)
        let grouped = Dictionary(grouping: hits, by: \.notebookID)
        let order = hits.map(\.notebookID).reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
        VStack(alignment: .leading, spacing: 14) {
            if hits.isEmpty {
                VStack(spacing: 10) {
                    Text("No results").font(Theme.serif(24)).foregroundStyle(Theme.ink)
                    Text("Search looks through titles, typed text, PDF text and your handwriting.")
                        .font(.callout).foregroundStyle(Theme.ink2)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                ForEach(order, id: \.self) { id in
                    if let meta = library.meta(id), let items = grouped[id] {
                        VStack(alignment: .leading, spacing: 0) {
                            Button {
                                model.open(id)
                            } label: {
                                HStack(spacing: 12) {
                                    CoverView(meta: meta, showsTitle: false).frame(width: 30)
                                    Text(meta.title).font(.headline).foregroundStyle(Theme.ink)
                                    Spacer()
                                    Text("\(items.count) match\(items.count == 1 ? "" : "es")").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                                }
                                .padding(14)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            ForEach(items.filter { $0.source != .title }.prefix(6)) { hit in
                                Divider().opacity(0.5)
                                Button {
                                    model.open(id, page: hit.pageIndex, query: hit.source == .title ? nil : model.searchText)
                                } label: {
                                    HStack(alignment: .top, spacing: 10) {
                                        Image(systemName: hit.source.symbol).foregroundStyle(Theme.accent).frame(width: 20)
                                        VStack(alignment: .leading, spacing: 2) {
                                            highlighted(hit).font(.callout).lineLimit(2)
                                            Text("\(hit.source.label) · page \((hit.pageIndex ?? 0) + 1)")
                                                .font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                                        }
                                        Spacer()
                                    }
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 10)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .cardSurface()
                    }
                }
            }
        }
    }
}
