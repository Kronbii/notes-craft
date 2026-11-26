import NotesCraftCore
import SwiftUI

struct NewNotebookSheet: View {
    @Bindable var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    private var library: LibraryStore { LibraryStore.shared }
    @State private var title = ""
    @State private var paper = AppSettings.shared.defaultPaper
    @State private var cover = Cover.random()
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .top, spacing: 22) {
                        CoverView(meta: previewMeta)
                            .frame(width: 130)
                            .shadow(color: .black.opacity(0.15), radius: 10, y: 5)
                            .animation(.spring(duration: 0.3), value: cover)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Title").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                            TextField("Untitled", text: $title)
                                .font(.title2.weight(.semibold))
                                .textFieldStyle(.plain)
                                .padding(12)
                                .background(Theme.sunk, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .focused($titleFocused)
                                .submitLabel(.done)
                                .onSubmit(create)
                            CoverPicker(cover: $cover)
                        }
                    }
                    PaperPicker(paper: $paper)
                }
                .padding(24)
            }
            .background(Theme.background)
            .navigationTitle("New notebook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create", action: create)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var previewMeta: NotebookMeta {
        var m = NotebookMeta(title: title.isEmpty ? "Untitled" : title, cover: cover)
        m.pageCount = 1
        return m
    }

    private func create() {
        do {
            let meta = try library.createNotebook(title: title, paper: paper, cover: cover, folder: model.currentFolder)
            dismiss()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.open(meta.id) }
        } catch {
            library.report("Couldn't create the notebook: \(error.localizedDescription)")
        }
    }
}

/// Cover color and pattern selection.
struct CoverPicker: View {
    @Binding var cover: Cover

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cover").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(CoverColor.allCases) { color in
                        let selected: Bool = {
                            if case let .design(c, _) = cover { return c == color }
                            return false
                        }()
                        Button {
                            if case let .design(_, p) = cover { cover = .design(color: color, pattern: p) } else { cover = .design(color: color, pattern: .linen) }
                        } label: {
                            Circle()
                                .fill(color.base.color)
                                .frame(width: 30, height: 30)
                                // A hairline keeps dark covers visible on dark sheets.
                                .overlay(Circle().strokeBorder(Theme.ink.opacity(0.22), lineWidth: 1))
                                .overlay(Circle().strokeBorder(.white, lineWidth: selected ? 3 : 0))
                                .overlay(Circle().strokeBorder(Theme.accent, lineWidth: selected ? 1.5 : 0).padding(-2))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(color.title)
                    }
                    Button {
                        cover = .firstPage
                    } label: {
                        Image(systemName: "doc.text")
                            .font(.system(size: 14))
                            .frame(width: 30, height: 30)
                            .background(Theme.raised, in: Circle())
                            .overlay(Circle().strokeBorder(cover == .firstPage ? Theme.accent : Theme.hair, lineWidth: cover == .firstPage ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show first page")
                }
                .padding(4)
            }
            if case let .design(color, pattern) = cover {
                Picker("Pattern", selection: Binding(get: { pattern }, set: { cover = .design(color: color, pattern: $0) })) {
                    ForEach(CoverPattern.allCases) { p in Text(p.title).tag(p) }
                }
                .pickerStyle(.segmented)
            }
        }
    }
}

/// Paper template, color, size and orientation.
struct PaperPicker: View {
    @Binding var paper: PaperStyle
    var showsSize = true

    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 14)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Paper").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(PaperKind.allCases) { kind in
                    Button {
                        paper.kind = kind
                    } label: {
                        VStack(spacing: 6) {
                            PaperPreview(kind: kind, color: paper.color, landscape: paper.landscape, size: paper.size)
                                .frame(height: 112)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .strokeBorder(Theme.accent, lineWidth: paper.kind == kind ? 2.5 : 0)
                                        .padding(-3)
                                )
                                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                            Text(kind.title)
                                .font(.caption.weight(paper.kind == kind ? .semibold : .regular))
                                .foregroundStyle(paper.kind == kind ? Theme.ink : Theme.ink2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                Text("Color").font(.subheadline).foregroundStyle(Theme.ink2)
                ForEach(PaperColor.allCases) { c in
                    Button {
                        paper.color = c
                    } label: {
                        Circle()
                            .fill(c.fill.color)
                            .frame(width: 28, height: 28)
                            .overlay(Circle().strokeBorder(Theme.ink.opacity(0.25), lineWidth: 0.75))
                            .overlay(Circle().strokeBorder(Theme.accent, lineWidth: paper.color == c ? 2.5 : 0).padding(-4))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(c.title)
                }
            }
            if showsSize {
                HStack(spacing: 12) {
                    Text("Size").font(.subheadline).foregroundStyle(Theme.ink2)
                    Picker("Size", selection: $paper.size) {
                        ForEach(PageSizePreset.allCases) { s in Text(s.title).tag(s) }
                    }
                    .pickerStyle(.menu)
                    Picker("Orientation", selection: $paper.landscape) {
                        Image(systemName: "rectangle.portrait").tag(false).accessibilityLabel("Portrait")
                        Image(systemName: "rectangle").tag(true).accessibilityLabel("Landscape")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 110)
                }
            }
        }
    }
}

/// Picks a destination folder for notebooks.
struct MoveSheet: View {
    let ids: [UUID]
    @Environment(\.dismiss) private var dismiss
    private var library: LibraryStore { LibraryStore.shared }
    var onDone: () -> Void

    var body: some View {
        NavigationStack {
            List {
                Button {
                    library.move(ids, to: nil)
                    onDone()
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "tray").foregroundStyle(Theme.ink2)
                        Text("No folder").foregroundStyle(Theme.ink)
                    }
                }
                ForEach(flattened, id: \.0.id) { folder, depth in
                    Button {
                        library.move(ids, to: folder.id)
                        onDone()
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "folder.fill").foregroundStyle(folder.color.base.color)
                            Text(folder.name).foregroundStyle(Theme.ink)
                        }
                        .padding(.leading, CGFloat(depth) * 18)
                    }
                }
            }
            .navigationTitle(ids.count == 1 ? "Move notebook" : "Move \(ids.count) notebooks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private var flattened: [(Folder, Int)] {
        var out: [(Folder, Int)] = []
        func walk(_ parent: UUID?, _ depth: Int) {
            for f in library.index.subfolders(of: parent) {
                out.append((f, depth))
                walk(f.id, depth + 1)
            }
        }
        walk(nil, 0)
        return out
    }
}

struct CoverSheet: View {
    let id: UUID
    @Environment(\.dismiss) private var dismiss
    private var library: LibraryStore { LibraryStore.shared }
    @State private var cover: Cover = .default

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                if let meta = library.meta(id) {
                    CoverView(meta: withCover(meta))
                        .frame(width: 170)
                        .shadow(color: .black.opacity(0.15), radius: 12, y: 6)
                }
                CoverPicker(cover: $cover)
                Spacer()
            }
            .padding(24)
            .background(Theme.background)
            .navigationTitle("Cover")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        library.setCover(id, cover)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear { cover = library.meta(id)?.cover ?? .default }
        }
    }

    private func withCover(_ meta: NotebookMeta) -> NotebookMeta {
        var m = meta
        m.cover = cover
        return m
    }
}
