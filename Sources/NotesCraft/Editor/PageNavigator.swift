import NotesCraftCore
import SwiftUI
import UniformTypeIdentifiers

/// Sidebar of page thumbnails: jump, reorder by dragging, and page actions.
struct PageNavigator: View {
    @Bindable var model: EditorModel
    var onInsertPDF: (Int) -> Void
    @State private var dropTarget: Int?
    @State private var outline: [OutlineItem] = []
    @State private var showOutline = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Pages").font(.headline)
                Spacer()
                Button {
                    model.addPage(after: model.currentPage)
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(IconButtonStyle(size: 32))
                .accessibilityLabel("Add page")
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
            Picker("Show", selection: Binding(get: { showOutline ? 2 : (model.navigatorBookmarksOnly ? 1 : 0) }, set: { v in
                showOutline = v == 2
                model.navigatorBookmarksOnly = v == 1
            })) {
                Text("All").tag(0)
                Image(systemName: "bookmark").tag(1).accessibilityLabel("Bookmarks")
                if !outline.isEmpty {
                    Image(systemName: "list.bullet.indent").tag(2).accessibilityLabel("Contents")
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if showOutline {
                outlineList
            } else {
                pageList
            }
        }
        .background(Theme.background)
        .task(id: pdfAssetKey) {
            let assets = pdfAssets.map { (name: $0, url: model.document.assets.url(for: $0)) }
            outline = assets.isEmpty ? [] : await PDFImporter.outline(assets: assets)
            if outline.isEmpty { showOutline = false }
        }
    }

    private var pdfAssets: [String] {
        var seen: [String] = []
        for page in model.document.pages {
            if case let .pdf(asset, _) = page.background, !seen.contains(asset) { seen.append(asset) }
        }
        return seen
    }

    private var pdfAssetKey: String { pdfAssets.joined(separator: ",") }

    private var outlineList: some View {
        List(outline) { item in
            Button {
                if let index = model.document.pages.firstIndex(where: {
                    if case let .pdf(asset, i) = $0.background { return asset == item.asset && i == item.pdfPage }
                    return false
                }) {
                    model.goToPage(index)
                } else {
                    model.showToast("That page was removed from this notebook")
                }
            } label: {
                HStack {
                    Text(item.title)
                        .font(item.depth == 0 ? .subheadline.weight(.semibold) : .subheadline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(2)
                    Spacer(minLength: 4)
                    Text("\(item.pdfPage + 1)").font(Theme.mono(10)).foregroundStyle(Theme.ink3)
                }
                .padding(.leading, CGFloat(min(item.depth, 4)) * 10)
            }
            .buttonStyle(.plain)
        }
        .listStyle(.plain)
    }

    private var pageList: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 18) {
                        ForEach(Array(model.document.pages.enumerated()), id: \.element.id) { index, page in
                            if !model.navigatorBookmarksOnly || page.bookmarked {
                                PageThumb(model: model, page: page, index: index, onInsertPDF: onInsertPDF)
                                    .id(page.id)
                                    .overlay(alignment: .top) {
                                        if dropTarget == index {
                                            Capsule().fill(Theme.accent).frame(height: 3).offset(y: -10)
                                        }
                                    }
                                    .draggable(page.id.uuidString) {
                                        PageThumbImage(model: model, page: page).frame(width: 90)
                                    }
                                    .dropDestination(for: String.self) { items, _ in
                                        dropTarget = nil
                                        guard let s = items.first, let id = UUID(uuidString: s),
                                              let from = model.document.pageIndex(of: id) else { return false }
                                        model.movePage(from: from, to: index)
                                        return true
                                    } isTargeted: { t in
                                        dropTarget = t ? index : (dropTarget == index ? nil : dropTarget)
                                    }
                            }
                        }
                        if model.navigatorBookmarksOnly && !model.document.pages.contains(where: \.bookmarked) {
                            Text("Bookmark pages from their menu to find them quickly.")
                                .font(.footnote)
                                .foregroundStyle(Theme.ink3)
                                .multilineTextAlignment(.center)
                                .padding(.top, 30)
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.vertical, 12)
                    .padding(.horizontal, 26)
                }
                .onAppear {
                    if model.document.pages.indices.contains(model.currentPage) {
                        proxy.scrollTo(model.document.pages[model.currentPage].id, anchor: .center)
                    }
                }
                .onChange(of: model.currentPage) { _, page in
                    guard model.document.pages.indices.contains(page) else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(model.document.pages[page].id, anchor: .center)
                    }
                }
            }
    }
}

struct PageThumb: View {
    @Bindable var model: EditorModel
    let page: Page
    let index: Int
    var onInsertPDF: (Int) -> Void

    var body: some View {
        let current = model.currentPage == index
        Button {
            model.goToPage(index)
        } label: {
            VStack(spacing: 6) {
                PageThumbImage(model: model, page: page)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .strokeBorder(current ? Theme.accent : Theme.hair, lineWidth: current ? 2.5 : 0.5)
                            .padding(-2)
                    )
                    .overlay(alignment: .topTrailing) {
                        if page.bookmarked {
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Theme.record)
                                .offset(x: -6, y: -2)
                        }
                    }
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                Text("\(index + 1)")
                    .font(Theme.mono(11, weight: current ? .bold : .regular))
                    .foregroundStyle(current ? Theme.accent : Theme.ink3)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { model.addPage(before: index) } label: { Label("Add page before", systemImage: "arrow.up.doc") }
            Button { model.addPage(after: index) } label: { Label("Add page after", systemImage: "arrow.down.doc") }
            Button { model.duplicatePage(page.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            Button { model.toggleBookmark(page.id) } label: {
                Label(page.bookmarked ? "Remove bookmark" : "Bookmark", systemImage: page.bookmarked ? "bookmark.slash" : "bookmark")
            }
            Button { model.sheet = .pageSetup(pageIDs: [page.id]) } label: { Label("Change template…", systemImage: "doc.text") }
            Button { onInsertPDF(index) } label: { Label("Insert PDF after…", systemImage: "doc.richtext") }
            Menu {
                Button { model.sharePDF(pageIndices: [index]) } label: { Label("As PDF", systemImage: "doc.richtext") }
                Button { model.shareImages(pageIndices: [index]) } label: { Label("As image", systemImage: "photo") }
            } label: {
                Label("Share page", systemImage: "square.and.arrow.up")
            }
            Button { model.clearInk(on: page.id) } label: { Label("Clear ink", systemImage: "eraser") }
            Divider()
            Button(role: .destructive) {
                model.deletePages([page.id])
            } label: {
                Label("Delete page", systemImage: "trash")
            }
        }
        .accessibilityLabel("Page \(index + 1)\(page.bookmarked ? ", bookmarked" : "")")
    }
}

struct PageThumbImage: View {
    @Bindable var model: EditorModel
    let page: Page

    var body: some View {
        let version = model.document.version(of: page.id)
        ZStack {
            page.background.paperColor.fill.color
            if let image = model.thumbnails.image(for: page.id) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .aspectRatio(page.size.width / max(page.size.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        .task(id: "\(page.id)-\(version)") {
            model.thumbnails.request(page.id)
        }
    }
}
