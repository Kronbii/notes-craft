import NotesCraftCore
import SwiftUI

// MARK: - Find

struct FindPanel: View {
    @Bindable var model: EditorModel
    var onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.ink3)
                TextField("Find in notebook", text: $model.findQuery)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit { model.nextFindResult() }
                if model.isSearching {
                    ProgressView().controlSize(.small)
                } else if !model.findQuery.isEmpty {
                    Button {
                        model.clearFind()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.ink3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.sunk, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.top, 12)

            HStack(spacing: 4) {
                Text(countLabel)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.ink2)
                Spacer()
                Button {
                    model.previousFindResult()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .buttonStyle(IconButtonStyle(size: 32))
                .disabled(model.findResults.isEmpty)
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .accessibilityLabel("Previous match")
                Button {
                    model.nextFindResult()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .buttonStyle(IconButtonStyle(size: 32))
                .disabled(model.findResults.isEmpty)
                .keyboardShortcut("g", modifiers: .command)
                .accessibilityLabel("Next match")
                Button("Done", action: onClose)
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 6)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            Divider()

            if model.findResults.isEmpty {
                VStack(spacing: 8) {
                    if model.findQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                        Image(systemName: "text.magnifyingglass").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.accent)
                        Text("Search typed text, PDF text and your handwriting.")
                    } else if !model.isSearching {
                        Text("No matches").font(Theme.serif(20)).foregroundStyle(Theme.ink)
                        Text("Handwriting becomes searchable a few seconds after you write it.")
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.center)
                .padding(24)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(groups, id: \.page) { group in
                            Section {
                                ForEach(group.items, id: \.offset) { item in
                                    row(item.element, isCurrent: item.offset == model.currentFindIndex)
                                        .id(item.offset)
                                        .listRowBackground(item.offset == model.currentFindIndex ? Theme.accent.opacity(0.14) : Color.clear)
                                }
                            } header: {
                                Text("Page \(group.page + 1)").font(.caption.weight(.semibold)).foregroundStyle(Theme.ink3)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .onChange(of: model.currentFindIndex) { _, index in
                        guard let index else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(index, anchor: .center) }
                    }
                }
            }
        }
        .background(Theme.background)
        .onAppear { focused = model.findQuery.isEmpty }
        .onChange(of: model.findQuery) { _, _ in model.runFind() }
    }

    private var countLabel: String {
        let n = model.findResults.count
        if model.findQuery.trimmingCharacters(in: .whitespaces).isEmpty { return " " }
        if n == 0 { return model.isSearching ? "Searching…" : "0 matches" }
        if let i = model.currentFindIndex { return "\(i + 1) of \(n)" }
        return "\(n) match\(n == 1 ? "" : "es")"
    }

    private var groups: [(page: Int, items: [(offset: Int, element: FindResult)])] {
        var out: [(page: Int, items: [(offset: Int, element: FindResult)])] = []
        for (i, r) in model.findResults.enumerated() {
            if out.last?.page == r.pageIndex {
                out[out.count - 1].items.append((i, r))
            } else {
                out.append((r.pageIndex, [(i, r)]))
            }
        }
        return out
    }

    private func row(_ result: FindResult, isCurrent: Bool) -> some View {
        Button {
            model.showFindResult(result)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: result.source.symbol)
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .frame(width: 16)
                    .accessibilityLabel(result.source.label)
                snippet(result)
                    .font(.callout)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func snippet(_ r: FindResult) -> Text {
        var match = AttributedString(r.match)
        match.font = .callout.weight(.semibold)
        match.foregroundColor = Theme.ink
        match.backgroundColor = Color(red: 1, green: 0.86, blue: 0.3).opacity(0.5)
        var before = AttributedString(r.before)
        before.foregroundColor = Theme.ink2
        var after = AttributedString(r.after)
        after.foregroundColor = Theme.ink2
        return Text(before + match + after)
    }
}

// MARK: - Export

struct ExportSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss

    enum Format: String, CaseIterable, Identifiable {
        case pdf, images, notebook
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pdf: "PDF"
            case .images: "Images"
            case .notebook: "NotesCraft"
            }
        }
    }

    enum Range: String, CaseIterable, Identifiable {
        case all, current, bookmarked
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: "All pages"
            case .current: "This page"
            case .bookmarked: "Bookmarked"
            }
        }
    }

    @State private var format: Format = .pdf
    @State private var range: Range = .all
    @State private var includeBackgrounds = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Format", selection: $format) {
                        ForEach(Format.allCases) { f in Text(f.title).tag(f) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text(footer)
                }
                if format != .notebook {
                    Section("Pages") {
                        ForEach(Range.allCases) { r in
                            CheckRow(title: r.title, selected: range == r) { range = r }
                        }
                        if format == .pdf {
                            Toggle("Include paper templates", isOn: $includeBackgrounds)
                        }
                    }
                }
                Section {
                    Button {
                        share()
                    } label: {
                        AccentLabel("Share…", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(indices.isEmpty && format != .notebook)
                    if format == .pdf {
                        Button {
                            dismiss()
                            model.printNotebook()
                        } label: {
                            AccentLabel("Print…", systemImage: "printer")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var footer: String {
        switch format {
        case .pdf: "A PDF anyone can open, with your ink, text and images."
        case .images: "One PNG image per page."
        case .notebook: "The full notebook with audio, editable in NotesCraft on another device."
        }
    }

    private var indices: [Int] {
        switch range {
        case .all: Array(model.document.pages.indices)
        case .current: [model.currentPage]
        case .bookmarked: model.document.pages.indices.filter { model.document.pages[$0].bookmarked }
        }
    }

    private func share() {
        let chosen = indices
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            switch format {
            case .pdf: model.sharePDF(pageIndices: chosen, includeBackgrounds: includeBackgrounds)
            case .images: model.shareImages(pageIndices: chosen)
            case .notebook: model.shareArchive()
            }
        }
    }
}

// MARK: - Page setup

struct PageSetupSheet: View {
    @Bindable var model: EditorModel
    let pageIDs: [UUID]
    @Environment(\.dismiss) private var dismiss
    @State private var paper = PaperStyle.default
    @State private var allPages = false
    @State private var changeSize = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !model.isBoard {
                        Picker("Apply to", selection: $allPages) {
                            Text(pageIDs.count > 1 ? "Selected pages" : "This page").tag(false)
                            Text("All pages").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                    if hasPDFPages {
                        Label("PDF and scanned pages keep their content; only their size can't change here.", systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(Theme.ink3)
                    }
                    PaperPicker(paper: $paper, showsSize: changeSize && !model.isBoard)
                    if !model.isBoard {
                        // A whiteboard keeps its size; only its background changes.
                        Toggle("Change page size", isOn: $changeSize)
                    }
                }
                .padding(24)
            }
            .background(Theme.background)
            .navigationTitle(model.isBoard ? "Canvas background" : "Page template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        let ids = allPages ? model.document.pages.map(\.id) : pageIDs
                        model.applyPaper(paper.kind, color: paper.color, size: changeSize && !model.isBoard ? paper.pageSize : nil, to: ids)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear(perform: load)
        }
    }

    private var hasPDFPages: Bool {
        let ids = allPages ? Set(model.document.pages.map(\.id)) : Set(pageIDs)
        return model.document.pages.contains { ids.contains($0.id) && $0.background.paperKind == nil }
    }

    private func load() {
        guard let first = model.document.pages.first(where: { pageIDs.contains($0.id) }) else { return }
        if case let .paper(kind, color) = first.background {
            paper.kind = kind
            paper.color = color
        }
        if let match = PageSizePreset.matching(first.size) {
            paper.size = match.preset
            paper.landscape = match.landscape
        }
    }
}

struct NewPageSheet: View {
    @Bindable var model: EditorModel
    let afterIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var paper = PaperStyle.default

    var body: some View {
        NavigationStack {
            ScrollView {
                PaperPicker(paper: $paper)
                    .padding(24)
            }
            .background(Theme.background)
            .navigationTitle("New page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.insertPage(Page(style: paper), at: afterIndex + 1)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .onAppear {
                if model.document.pages.indices.contains(afterIndex) {
                    let page = model.document.pages[afterIndex]
                    if case let .paper(kind, color) = page.background {
                        paper.kind = kind
                        paper.color = color
                    }
                    if let match = PageSizePreset.matching(page.size) {
                        paper.size = match.preset
                        paper.landscape = match.landscape
                    }
                } else {
                    paper = AppSettings.shared.defaultPaper
                }
            }
        }
    }
}

// MARK: - Recordings

struct RecordingsSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: Recording?
    @State private var renameText = ""

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.recordings) { rec in
                    HStack(spacing: 12) {
                        Button {
                            model.play(rec)
                            dismiss()
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(Theme.accent)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Play \(rec.title)")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rec.title).font(.body.weight(.medium))
                            Text("\(rec.duration.clock) · \(rec.createdAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(Theme.mono(11))
                                .foregroundStyle(Theme.ink3)
                        }
                        Spacer()
                    }
                    .swipeActions {
                        Button(role: .destructive) {
                            model.deleteRecording(rec.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        Button {
                            renameText = rec.title
                            renaming = rec
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        .tint(Theme.canvasAccent)
                    }
                    .contextMenu {
                        Button {
                            renameText = rec.title
                            renaming = rec
                        } label: {
                            Label("Rename", systemImage: "pencil")
                        }
                        Button(role: .destructive) {
                            model.deleteRecording(rec.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }
            .overlay {
                if model.recordings.isEmpty {
                    Text("No recordings yet").font(Theme.serif(22)).foregroundStyle(Theme.ink3)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Recordings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .alert("Rename recording", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Title", text: $renameText)
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    if let r = renaming { model.renameRecording(r.id, to: renameText) }
                    renaming = nil
                }
            }
        }
    }
}

// MARK: - Converted handwriting

struct ConvertedTextSheet: View {
    @Bindable var model: EditorModel
    @State var text: String
    @Environment(\.dismiss) private var dismiss

    init(model: EditorModel, text: String) {
        self.model = model
        _text = State(initialValue: text)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("Check the recognized text and fix anything that's off.")
                    .font(.footnote)
                    .foregroundStyle(Theme.ink3)
                TextEditor(text: $text)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .background(Theme.raised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hair))
                HStack {
                    Button {
                        UIPasteboard.general.string = text
                        model.showToast("Copied")
                        dismiss()
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    Spacer()
                    Button {
                        model.canvas.replaceSelectionWithText(text)
                        dismiss()
                    } label: {
                        Label("Replace handwriting", systemImage: "character.textbox")
                    }
                    .buttonStyle(PillButtonStyle())
                }
            }
            .padding(20)
            .background(Theme.background)
            .navigationTitle("Handwriting to text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Elements

struct ElementsSheet: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    private var library: ElementsLibrary { ElementsLibrary.shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                if library.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "star.square.on.square").font(.system(size: 40, weight: .light)).foregroundStyle(Theme.accent)
                        Text("No elements yet").font(Theme.serif(24))
                        Text("Select something with the lasso, then choose ⋯ › Save to Elements. It will be here, ready to drop into any notebook.")
                            .font(.callout).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 380)
                    }
                    .padding(.top, 60)
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 16)], spacing: 16) {
                        ForEach(library.items) { item in
                            Button {
                                if let payload = library.payload(item.id) {
                                    dismiss()
                                    model.insertElement(payload)
                                }
                            } label: {
                                ZStack {
                                    Color.white
                                    if let img = library.preview(item.id) {
                                        Image(uiImage: img).resizable().aspectRatio(contentMode: .fit).padding(10)
                                    }
                                }
                                .frame(height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.hair))
                            }
                            .buttonStyle(CardPressStyle())
                            .contextMenu {
                                Button(role: .destructive) {
                                    library.remove(item.id)
                                } label: {
                                    Label("Delete element", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .padding(20)
                }
            }
            .background(Theme.background)
            .navigationTitle("Elements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
