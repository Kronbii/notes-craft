import Foundation
import Testing
@testable import NotesCraftCore

// MARK: - Shapes

private func circlePoints(center: CGPoint, r: Double, jitter: Double = 0, n: Int = 80, sweep: Double = 1.0) -> [CGPoint] {
    (0 ... n).map { i in
        let t = Double(i) / Double(n) * 2 * Double.pi * sweep
        let j = jitter * sin(Double(i) * 1.7)
        return CGPoint(x: Double(center.x) + (r + j) * cos(t), y: Double(center.y) + (r + j) * sin(t))
    }
}

private func polyPoints(_ corners: [CGPoint], perEdge: Int = 20, jitter: Double = 0, close: Bool = true) -> [CGPoint] {
    var pts: [CGPoint] = []
    let chain = close ? corners + [corners[0]] : corners
    for i in 0 ..< chain.count - 1 {
        let a = chain[i], b = chain[i + 1]
        for k in 0 ..< perEdge {
            let t = Double(k) / Double(perEdge)
            let j = jitter * sin(Double(pts.count) * 2.3)
            pts.append(CGPoint(x: Double(a.x) + t * Double(b.x - a.x) + j, y: Double(a.y) + t * Double(b.y - a.y) - j))
        }
    }
    pts.append(chain.last!)
    return pts
}

@Test func recognizesStraightLine() throws {
    let pts = (0 ... 40).map { CGPoint(x: Double($0) * 5, y: 100 + sin(Double($0)) * 1.2) }
    let shape = try #require(ShapeRecognizer.recognize(pts))
    guard case let .line(a, b) = shape else { Issue.record("expected line, got \(shape)"); return }
    // Nearly horizontal lines snap to exactly horizontal.
    #expect(abs(a.y - b.y) < 0.001)
    #expect(abs(Double(b.x - a.x) - 200) < 5)
}

@Test func recognizesCircle() throws {
    let shape = try #require(ShapeRecognizer.recognize(circlePoints(center: CGPoint(x: 200, y: 200), r: 80, jitter: 2)))
    guard case let .ellipse(c, rx, ry, _) = shape else { Issue.record("expected ellipse, got \(shape)"); return }
    #expect(abs(rx - ry) < 0.001)
    #expect(abs(rx - 80) < 8)
    #expect(abs(Double(c.x) - 200) < 4)
    #expect(shape.name == "Circle")
}

@Test func recognizesEllipse() throws {
    let pts = (0 ... 90).map { i -> CGPoint in
        let t = Double(i) / 90 * 2 * Double.pi
        return CGPoint(x: 300 + 150 * cos(t), y: 200 + 60 * sin(t))
    }
    let shape = try #require(ShapeRecognizer.recognize(pts))
    guard case let .ellipse(_, rx, ry, rot) = shape else { Issue.record("expected ellipse, got \(shape)"); return }
    let major = max(rx, ry), minor = min(rx, ry)
    #expect(abs(major - 150) < 12)
    #expect(abs(minor - 60) < 8)
    // Axis-aligned after snapping.
    let deg = abs(rot * 180 / Double.pi).truncatingRemainder(dividingBy: 90)
    #expect(deg < 0.001 || abs(deg - 90) < 0.001)
}

@Test func recognizesRectangle() throws {
    let corners = [CGPoint(x: 100, y: 100), CGPoint(x: 400, y: 104), CGPoint(x: 398, y: 300), CGPoint(x: 102, y: 297)]
    let shape = try #require(ShapeRecognizer.recognize(polyPoints(corners, jitter: 1.5)))
    guard case let .polygon(v) = shape else { Issue.record("expected polygon, got \(shape)"); return }
    #expect(v.count == 4)
    #expect(ShapeRecognizer.isRectangle(v))
    #expect(shape.name == "Rectangle")
    // Snapped to the axes: two distinct x values and two distinct y values.
    let xs = Set(v.map { Int(($0.x).rounded()) }), ys = Set(v.map { Int(($0.y).rounded()) })
    #expect(xs.count == 2)
    #expect(ys.count == 2)
}

@Test func recognizesTriangle() throws {
    let corners = [CGPoint(x: 200, y: 50), CGPoint(x: 350, y: 300), CGPoint(x: 50, y: 300)]
    let shape = try #require(ShapeRecognizer.recognize(polyPoints(corners, jitter: 1)))
    guard case let .polygon(v) = shape else { Issue.record("expected polygon, got \(shape)"); return }
    #expect(v.count == 3)
    #expect(shape.name == "Triangle")
}

@Test func recognizesOpenAngle() throws {
    let pts = polyPoints([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 200), CGPoint(x: 200, y: 0)], close: false)
    let shape = try #require(ShapeRecognizer.recognize(pts))
    guard case let .polyline(v) = shape else { Issue.record("expected polyline, got \(shape)"); return }
    #expect(v.count == 3)
}

@Test func leavesScribblesAlone() {
    // A wavy "s"-curve is not a shape.
    let pts = (0 ... 60).map { CGPoint(x: Double($0) * 4, y: 100 + 40 * sin(Double($0) / 6)) }
    #expect(ShapeRecognizer.recognize(pts) == nil)
    // A "C" arc (half circle) is not a closed ellipse and not straight.
    #expect(ShapeRecognizer.recognize(circlePoints(center: .zero, r: 100, sweep: 0.5)).map { if case .ellipse = $0 { true } else { false } } != true)
    // A dot.
    #expect(ShapeRecognizer.recognize([CGPoint(x: 1, y: 1), CGPoint(x: 2, y: 2), CGPoint(x: 1.5, y: 1.2)]) == nil)
}

@Test func outlineIsDenseAndClosed() {
    let shape = RecognizedShape.polygon([CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0), CGPoint(x: 100, y: 100), CGPoint(x: 0, y: 100)])
    let pts = shape.outline(spacing: 4)
    #expect(pts.count > 100)
    let circle = RecognizedShape.ellipse(center: .zero, radiusX: 50, radiusY: 50, rotation: 0).outline(spacing: 4)
    #expect(circle.count > 60)
    #expect(ShapeRecognizer.distance(circle.first!, CGPoint(x: 50, y: 0)) < 0.001)
}

@Test func straightensHighlighter() throws {
    let pts = (0 ... 30).map { CGPoint(x: Double($0) * 10, y: 50 + Double($0 % 3)) }
    let (a, b) = try #require(ShapeRecognizer.straightened(pts))
    #expect(abs(a.y - b.y) < 0.001)
    let wavy = (0 ... 60).map { CGPoint(x: Double($0) * 4, y: 100 + 40 * sin(Double($0) / 6)) }
    #expect(ShapeRecognizer.straightened(wavy) == nil)
}

// MARK: - Layout

@Test func layoutStacksPagesAndFindsThem() throws {
    let layout = DocumentLayout(pageSizes: [CGSize(width: 600, height: 800), CGSize(width: 400, height: 300), CGSize(width: 600, height: 800)])
    #expect(layout.pageFrames.count == 3)
    #expect(abs(Double(layout.contentSize.width) - (600 + 2 * DocumentLayout.sidePadding)) < 0.001)
    let f1 = try #require(layout.frame(of: 1))
    #expect(f1.minX == (layout.contentSize.width - 400) / 2)
    #expect(abs(Double(f1.minY) - (Double(layout.pageFrames[0].maxY) + DocumentLayout.pageGap)) < 0.001)
    #expect(layout.pageIndex(forY: -50) == 0)
    #expect(layout.pageIndex(forY: Double(layout.pageFrames[0].maxY) + 1) == 0)
    #expect(layout.pageIndex(forY: Double(f1.midY)) == 1)
    #expect(layout.pageIndex(forY: 1e9) == 2)
    #expect(layout.pageIndex(containing: CGPoint(x: 5, y: f1.midY)) == nil)
    #expect(layout.pages(intersecting: CGRect(x: 0, y: f1.midY, width: 700, height: 2000)) == 1 ..< 3)
    #expect(layout.pages(intersecting: CGRect(x: 0, y: f1.midY, width: 10, height: 2000)).isEmpty)
    #expect(layout.pages(intersecting: CGRect(x: 0, y: 10_000_000, width: 10, height: 10)).isEmpty)
    #expect(layout.dominantPage(in: CGRect(x: 0, y: f1.minY - 20, width: 700, height: 900)) == 2 || layout.dominantPage(in: CGRect(x: 0, y: f1.minY - 20, width: 700, height: 900)) == 1)
}

@Test func emptyLayout() {
    let layout = DocumentLayout(pageSizes: [])
    #expect(layout.pageIndex(forY: 10) == nil)
    #expect(layout.pages(intersecting: CGRect(x: 0, y: 0, width: 100, height: 100)).isEmpty)
}

// MARK: - Models

@Test func colorHexRoundTrip() throws {
    let c = try #require(RGBA(hex: "#4D6B40"))
    #expect(c.hex == "#4D6B40")
    #expect(RGBA(hex: "#fff")?.hex == "#FFFFFF")
    #expect(RGBA(hex: "#00000080")?.a ?? 0 > 0.49)
    #expect(RGBA(hex: "zz") == nil)
    #expect(RGBA.black.isDark)
    #expect(!RGBA.white.isDark)
}

@Test func notebookContentRoundTripAndTolerance() throws {
    let meta = NotebookMeta(title: "Physics")
    let text = TextContent(runs: [TextRun(text: "Hello "), TextRun(text: "world"), TextRun(text: "!", bold: true)])
    #expect(text.runs.count == 2) // first two merge
    let page = Page(size: CGSize(width: 595, height: 842), background: .paper(kind: .grid, color: .ivory),
                    elements: [PageElement(frame: CGRect(x: 10, y: 10, width: 100, height: 40), content: .text(text))])
    let rec = Recording(asset: "a.m4a", title: "Lecture", createdAt: Date(timeIntervalSince1970: 1000), duration: 60,
                        segments: [.init(wallStart: Date(timeIntervalSince1970: 1000), mediaStart: 0, duration: 30),
                                   .init(wallStart: Date(timeIntervalSince1970: 2000), mediaStart: 30, duration: 30)])
    var content = NotebookContent(meta: meta, pages: [page, Page(style: .default)], recordings: [rec])
    content.lastPageIndex = 1
    let data = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(NotebookContent.self, from: data)
    #expect(decoded.pages == content.pages)
    #expect(decoded.meta == content.meta)
    #expect(decoded.recordings == content.recordings)
    #expect(decoded.lastPageIndex == 1)
    #expect(decoded.referencedAssets == ["a.m4a"])

    // One damaged page does not lose the notebook.
    var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    var pages = try #require(json["pages"] as? [Any])
    pages.insert(["garbage": true], at: 1)
    json["pages"] = pages
    json["unknownFutureKey"] = 42
    let damaged = try JSONSerialization.data(withJSONObject: json)
    let recovered = try JSONDecoder().decode(NotebookContent.self, from: damaged)
    #expect(recovered.pages.count == 2)
}

@Test func recordingTimeMapping() {
    let rec = Recording(asset: "a", title: "", createdAt: Date(timeIntervalSince1970: 0), duration: 50,
                        segments: [.init(wallStart: Date(timeIntervalSince1970: 100), mediaStart: 0, duration: 20),
                                   .init(wallStart: Date(timeIntervalSince1970: 500), mediaStart: 20, duration: 30)])
    #expect(rec.mediaTime(for: Date(timeIntervalSince1970: 110)) == 10)
    #expect(rec.mediaTime(for: Date(timeIntervalSince1970: 510)) == 30)
    #expect(rec.mediaTime(for: Date(timeIntervalSince1970: 99.5)) == 0)
    #expect(rec.mediaTime(for: Date(timeIntervalSince1970: 300)) == nil)
}

// MARK: - Library

@Test func libraryTreeAndRepair() {
    let a = Folder(name: "School")
    let b = Folder(name: "Math", parentID: a.id)
    let c = Folder(name: "Calculus", parentID: b.id)
    var n1 = NotebookMeta(title: "Limits"); n1.folderID = c.id
    var n2 = NotebookMeta(title: "Orphan"); n2.folderID = UUID()
    var index = LibraryIndex(folders: [a, b, c], notebooks: [n1, n2])
    #expect(index.descendantFolderIDs(of: a.id) == [a.id, b.id, c.id])
    #expect(index.path(to: c.id).map(\.name) == ["School", "Math", "Calculus"])
    #expect(!index.canMove(folder: a.id, to: c.id))
    #expect(index.canMove(folder: c.id, to: nil))
    #expect(index.notebookCount(inTree: a.id) == 1)
    // Create a cycle and a dangling reference, then repair.
    index.folders[0].parentID = c.id
    index.repair()
    #expect(index.notebook(n2.id)?.folderID == nil)
    #expect(index.path(to: c.id).count <= 3)
    var seen = Set<UUID>()
    var cur: UUID? = c.id
    while let id = cur, !seen.contains(id) { seen.insert(id); cur = index.folder(id)?.parentID }
    #expect(cur == nil)
}

@Test func searchHelpers() {
    #expect(LibraryLogic.matches("Thermodynamics Lecture 3", query: "lecture thermo"))
    #expect(LibraryLogic.matches("Café notes", query: "cafe"))
    #expect(!LibraryLogic.matches("Biology", query: "bio chem"))
    #expect(!LibraryLogic.matches("anything", query: "   "))
    let snip = LibraryLogic.snippet(of: String(repeating: "a ", count: 100) + "entropy rises" + String(repeating: " b", count: 100), query: "entropy")
    #expect(snip?.contains("entropy") == true)
    #expect(snip?.hasPrefix("…") == true)
    #expect(LibraryLogic.uniqueTitle("Untitled", existing: ["Untitled", "untitled 2"]) == "Untitled 3")
    #expect(LibraryLogic.fileSafeName("a/b:c?") == "a-b-c-")
    #expect(LibraryLogic.fileSafeName("  ...  ") == "Notebook")
}

@Test func sortingIsStable() {
    var a = NotebookMeta(title: "b"); a.modifiedAt = Date(timeIntervalSince1970: 10)
    var b = NotebookMeta(title: "A"); b.modifiedAt = Date(timeIntervalSince1970: 20)
    #expect(LibraryLogic.sorted([a, b], by: .modified).map(\.title) == ["A", "b"])
    #expect(LibraryLogic.sorted([a, b], by: .title).map(\.title) == ["A", "b"])
}

// MARK: - Archive

@Test func archiveRoundTrip() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("nc-test-\(UUID().uuidString)")
    let src = root.appendingPathComponent("src")
    try fm.createDirectory(at: src.appendingPathComponent("drawings"), withIntermediateDirectories: true)
    try Data("{\"a\":1}".utf8).write(to: src.appendingPathComponent("document.json"))
    let blob = Data((0 ..< 5000).map { UInt8($0 % 251) })
    try blob.write(to: src.appendingPathComponent("drawings/page.drawing"))
    try Data().write(to: src.appendingPathComponent("empty.bin"))
    let archive = root.appendingPathComponent("x.notescraft")
    try PackageArchive.write(directory: src, to: archive)
    #expect(try PackageArchive.kind(of: archive) == "notebook")
    let out = root.appendingPathComponent("out")
    try PackageArchive.extract(archive, to: out)
    #expect(try Data(contentsOf: out.appendingPathComponent("drawings/page.drawing")) == blob)
    #expect(try Data(contentsOf: out.appendingPathComponent("document.json")) == Data("{\"a\":1}".utf8))
    #expect(fm.fileExists(atPath: out.appendingPathComponent("empty.bin").path))

    // Truncated archives fail loudly.
    let full = try Data(contentsOf: archive)
    let truncated = root.appendingPathComponent("t.notescraft")
    try full.prefix(full.count - 10).write(to: truncated)
    #expect(throws: PackageArchive.ArchiveError.self) { try PackageArchive.extract(truncated, to: root.appendingPathComponent("t")) }
    // Non-archives are rejected.
    let junk = root.appendingPathComponent("junk.notescraft")
    try Data("hello world, not an archive".utf8).write(to: junk)
    #expect(throws: PackageArchive.ArchiveError.notAnArchive) { try PackageArchive.extract(junk, to: root.appendingPathComponent("j")) }
    try? fm.removeItem(at: root)
}

@Test func archiveRejectsPathTraversal() throws {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("nc-evil-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let manifest = #"{"format":1,"kind":"notebook","entries":[{"path":"../evil.txt","size":3}]}"#
    var data = Data(PackageArchive.magic)
    var len = UInt32(manifest.utf8.count).littleEndian
    withUnsafeBytes(of: &len) { data.append(contentsOf: $0) }
    data.append(Data(manifest.utf8))
    data.append(Data("bad".utf8))
    let url = root.appendingPathComponent("evil.notescraft")
    try data.write(to: url)
    #expect(throws: PackageArchive.ArchiveError.unsafePath("../evil.txt")) {
        try PackageArchive.extract(url, to: root.appendingPathComponent("out"))
    }
    #expect(!fm.fileExists(atPath: root.appendingPathComponent("evil.txt").path))
    try? fm.removeItem(at: root)
}

// MARK: - Scribble to erase

@Test func detectsScribble() {
    // Horizontal back-and-forth sweeps drifting downward, like scribbling out a word.
    var pts: [CGPoint] = []
    for sweep in 0 ..< 7 {
        let y = 100 + Double(sweep) * 3
        let xs = stride(from: 0.0, through: 120.0, by: 4.0).map { $0 }
        for x in (sweep % 2 == 0 ? xs : xs.reversed()) {
            pts.append(CGPoint(x: 200 + x, y: y + sin(x / 10) * 2))
        }
    }
    #expect(ScribbleDetector.isScribble(pts))
}

@Test func handwritingIsNotScribble() {
    // A cursive "mmmm": up-down loops progressing to the right.
    let word = (0 ... 160).map { i -> CGPoint in
        let t = Double(i)
        return CGPoint(x: 100 + t * 1.2, y: 100 - abs(sin(t / 8)) * 18)
    }
    #expect(!ScribbleDetector.isScribble(word))
    // A circle and a straight line are not scribbles either.
    let circle = (0 ... 80).map { i -> CGPoint in
        let a = Double(i) / 80 * 2 * Double.pi
        return CGPoint(x: 100 + 40 * cos(a), y: 100 + 40 * sin(a))
    }
    #expect(!ScribbleDetector.isScribble(circle))
    let line = (0 ... 50).map { CGPoint(x: Double($0) * 4, y: 10) }
    #expect(!ScribbleDetector.isScribble(line))
    // A zig-zag "W" has only two turns.
    let w = [CGPoint(x: 0, y: 0), CGPoint(x: 20, y: 60), CGPoint(x: 40, y: 0), CGPoint(x: 60, y: 60), CGPoint(x: 80, y: 0)]
    let wPts = (0 ..< 4).flatMap { i in (0 ..< 15).map { k -> CGPoint in
        let t = Double(k) / 15
        return CGPoint(x: Double(w[i].x) + t * Double(w[i + 1].x - w[i].x), y: Double(w[i].y) + t * Double(w[i + 1].y - w[i].y))
    } }
    #expect(!ScribbleDetector.isScribble(wPts))
    // A printed "m" (down, up, down, up, down) written at handwriting speed.
    let m: [CGPoint] = [(0, 0), (0, 40), (0, 4), (14, 0), (18, 40), (18, 4), (30, 0), (36, 40)].map { CGPoint(x: $0.0, y: $0.1) }
    let mPts = (0 ..< m.count - 1).flatMap { i in (0 ..< 8).map { k -> CGPoint in
        let t = Double(k) / 8
        return CGPoint(x: Double(m[i].x) + t * Double(m[i + 1].x - m[i].x), y: Double(m[i].y) + t * Double(m[i + 1].y - m[i].y))
    } }
    #expect(!ScribbleDetector.isScribble(mPts, duration: 0.9))
    // Cursive "mmmm" written at a brisk handwriting pace is still writing.
    #expect(!ScribbleDetector.isScribble(word, duration: 1.2))
}

@Test func detectsQuickZigZag() {
    // A fast vertical zig-zag travelling along a word.
    var pts: [CGPoint] = []
    for i in 0 ..< 14 {
        let x0 = Double(i) * 9, y0 = i % 2 == 0 ? 0.0 : 34.0, y1 = i % 2 == 0 ? 34.0 : 0.0
        for k in 0 ..< 6 {
            let t = Double(k) / 6
            pts.append(CGPoint(x: x0 + t * 9, y: y0 + t * (y1 - y0)))
        }
    }
    #expect(ScribbleDetector.isScribble(pts, duration: 0.5))
    // The same shape drawn slowly is not a scribble.
    #expect(!ScribbleDetector.isScribble(pts, duration: 4))
}

@Test func hullContainsInterior() {
    let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10), CGPoint(x: 0, y: 10), CGPoint(x: 5, y: 5)]
    let hull = ScribbleDetector.convexHull(pts)
    #expect(hull.count == 4)
    #expect(ScribbleDetector.contains(hull, CGPoint(x: 5, y: 5)))
    #expect(!ScribbleDetector.contains(hull, CGPoint(x: 15, y: 5)))
    #expect(ScribbleDetector.contains(ScribbleDetector.expanded(hull, by: 6), CGPoint(x: 13, y: 5)))
}

// MARK: - Whiteboards

@Test func notebookKindDecodesWithDefault() throws {
    let board = NotebookMeta(title: "Board", kind: .board)
    let data = try JSONEncoder().encode(board)
    let back = try JSONDecoder().decode(NotebookMeta.self, from: data)
    #expect(back.isBoard)
    // Notebooks saved before whiteboards existed have no kind.
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    json.removeValue(forKey: "kind")
    let old = try JSONDecoder().decode(NotebookMeta.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.kind == .notebook)
    // A grown board keeps its size and flag through saving and loading.
    let grown = Page(size: CGSize(width: 60000, height: 30000), background: .paper(kind: .dotted, color: .white), isBoard: true)
    let reloaded = try JSONDecoder().decode(Page.self, from: JSONEncoder().encode(grown))
    #expect(reloaded.isBoard && reloaded.size == grown.size)
    // Normal pages are still limited.
    #expect(Page(size: CGSize(width: 60000, height: 900), background: .paper(kind: .blank, color: .white)).size.width == 14400)
    // Boards saved before the flag existed are recognized by their size.
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Page(size: NotebookKind.legacyBoardSize, background: .paper(kind: .grid, color: .white), isBoard: true))) as! [String: Any]
    legacy.removeValue(forKey: "board")
    #expect(try JSONDecoder().decode(Page.self, from: JSONSerialization.data(withJSONObject: legacy)).isBoard)
}

// MARK: - Canvas dots (measured from GoodNotes screenshots)

@Test func canvasDotSpacingMatchesGoodNotes() {
    // Zoom -> document spacing seen in GoodNotes at 221%, 59%, 7% and 4%.
    let cases: [(Double, Double)] = [(2.21, 25), (0.59, 25), (0.07, 200), (0.04, 200), (1.0, 25)]
    for (zoom, expected) in cases {
        #expect(PaperKind.boardPitch(base: 25, zoom: zoom, minGap: 7.5) == expected, "zoom \(zoom)")
    }
    // Never closer than 7.5 points on screen, never needlessly sparse.
    for z in stride(from: 0.02, through: 6.0, by: 0.01) {
        let pitch = PaperKind.boardPitch(base: 25, zoom: z, minGap: 7.5)
        #expect(pitch * z >= 7.5)
        if pitch > 25 { #expect(pitch / 2 * z < 7.5) }
    }
}
