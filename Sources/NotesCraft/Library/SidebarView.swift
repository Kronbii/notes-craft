import NotesCraftCore
import SwiftUI

struct SidebarView: View {
    @Bindable var model: LibraryModel
    private var library: LibraryStore { LibraryStore.shared }

    var body: some View {
        List(selection: Binding(get: { model.selection }, set: { if let s = $0 { model.selection = s; model.endSelecting() } })) {
            Section {
                row(.all, "All notes", "square.grid.2x2", count: library.index.activeNotebooks.count)
                row(.recents, "Recent", "clock", count: nil)
                row(.favorites, "Favorites", "star", count: library.index.activeNotebooks.filter(\.isFavorite).count)
                row(.audio, "Audio notes", "waveform", count: library.index.activeNotebooks.filter { $0.recordingCount > 0 }.count)
            }
            Section {
                ForEach(library.index.subfolders(of: nil)) { folder in
                    FolderTreeRow(folder: folder, model: model, depth: 0)
                }
                Button {
                    model.beginNewFolder(parent: nil)
                } label: {
                    Label("New folder", systemImage: "folder.badge.plus")
                        .foregroundStyle(Theme.ink2)
                }
                .buttonStyle(.plain)
            } header: {
                Text("Folders")
            }
            Section {
                row(.trash, "Trash", "trash", count: library.index.trashedNotebooks.count)
            }
        }
        .listStyle(.sidebar)
        .tint(Theme.sidebarSelection)
        .safeAreaInset(edge: .top) {
            HStack(spacing: 10) {
                AppMark(size: 30)
                (Text("Notes").font(Theme.display(22, weight: .bold)) + Text("Craft").font(Theme.serif(23)))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    model.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Settings")
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 4)
        }
        .navigationTitle("")
        .toolbar(removing: .sidebarToggle)
    }

    private func row(_ sel: LibrarySelection, _ title: String, _ symbol: String, count: Int?) -> some View {
        NavigationLink(value: sel) {
            HStack {
                Label(title, systemImage: symbol)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(Theme.mono(12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard sel == .trash || sel == .favorites || sel == .all else { return false }
            let ids = items.compactMap(UUID.init(uuidString:))
            switch sel {
            case .trash: library.trash(ids)
            case .favorites: library.setFavorite(ids, true)
            case .all: library.move(ids, to: nil)
            default: return false
            }
            return !ids.isEmpty
        }
    }
}

struct FolderTreeRow: View {
    let folder: Folder
    @Bindable var model: LibraryModel
    let depth: Int
    private var library: LibraryStore { LibraryStore.shared }
    @State private var expanded = false
    @State private var isTargeted = false

    var body: some View {
        let children = library.index.subfolders(of: folder.id)
        Group {
            if children.isEmpty {
                label
            } else {
                DisclosureGroup(isExpanded: $expanded) {
                    ForEach(children) { child in
                        FolderTreeRow(folder: child, model: model, depth: depth + 1)
                    }
                } label: {
                    label
                }
            }
        }
    }

    private var label: some View {
        NavigationLink(value: LibrarySelection.folder(folder.id)) {
            HStack(spacing: 10) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(folder.color.base.color)
                Text(folder.name)
                    .lineLimit(1)
                Spacer()
                let count = library.index.notebookCount(inTree: folder.id)
                if count > 0 {
                    Text("\(count)")
                        .font(Theme.mono(12))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listRowBackground(isTargeted ? Theme.accent.opacity(0.18) : nil)
        .dropDestination(for: String.self) { items, _ in
            var moved = false
            for item in items {
                if item.hasPrefix("folder:"), let id = UUID(uuidString: String(item.dropFirst(7))) {
                    moved = library.moveFolder(id, to: folder.id) || moved
                } else if let id = UUID(uuidString: item) {
                    library.move([id], to: folder.id)
                    moved = true
                }
            }
            if moved { Haptics.success() }
            return moved
        } isTargeted: { isTargeted = $0 }
        .contextMenu {
            FolderMenu(folder: folder, model: model)
        }
    }
}

struct FolderMenu: View {
    let folder: Folder
    @Bindable var model: LibraryModel
    private var library: LibraryStore { LibraryStore.shared }

    var body: some View {
        Button {
            model.beginRename(.folder(folder.id))
        } label: {
            Label("Rename", systemImage: "pencil")
        }
        Button {
            model.beginNewFolder(parent: folder.id)
        } label: {
            Label("New subfolder", systemImage: "folder.badge.plus")
        }
        Menu {
            ForEach(CoverColor.allCases) { color in
                Button {
                    library.setFolderColor(folder.id, color)
                } label: {
                    Label(color.title, systemImage: folder.color == color ? "checkmark.circle.fill" : "circle.fill")
                }
                .tint(color.base.color)
            }
        } label: {
            Label("Color", systemImage: "paintpalette")
        }
        if folder.parentID != nil {
            Button {
                _ = library.moveFolder(folder.id, to: nil)
            } label: {
                Label("Move to top level", systemImage: "arrow.up.to.line")
            }
        }
        Divider()
        Button(role: .destructive) {
            model.confirmDeleteFolder = folder.id
        } label: {
            Label("Delete folder", systemImage: "trash")
        }
    }
}
