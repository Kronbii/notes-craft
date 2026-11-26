import NotesCraftCore
import PencilKit
import UIKit

enum TextStyleChange {
    case family(TextFontFamily)
    case size(Double)
    case bold
    case italic
    case underline
    case strikethrough
    case color(RGBA)
    case highlight(RGBA?)
    case alignment(TextAlign)
    case fill(RGBA?)
}

/// In-place editor for a text box, laid over the page at the current zoom.
final class TextEditorView: UITextView {
    var docFrame: CGRect
    private(set) var editZoom: CGFloat
    var fill: RGBA?
    var onHeightChange: (() -> Void)?
    private let dashed = CAShapeLayer()
    /// Typing keeps its own history while the box is open (the canvas's undo
    /// manager is a sink for PencilKit's registrations).
    private let typingUndo: UndoManager = {
        let u = UndoManager()
        u.levelsOfUndo = 200
        return u
    }()

    override var undoManager: UndoManager? { typingUndo }

    /// The text when editing began, to tell whether closing the box changes the page.
    private let initialText: String

    var hasChanges: Bool { text != initialText }

    init(content: TextContent, docFrame: CGRect, zoom: CGFloat, typing: TextRun) {
        self.initialText = content.plainText
        self.docFrame = docFrame
        self.editZoom = zoom
        self.fill = content.fill
        super.init(frame: .zero, textContainer: nil)
        backgroundColor = content.fill.map { UIColor($0) } ?? .clear
        isScrollEnabled = false
        allowsEditingTextAttributes = true
        textContainer.lineFragmentPadding = 0
        autocorrectionType = .default
        smartQuotesType = .default
        keyboardDismissMode = .none
        layer.cornerRadius = 4
        dashed.fillColor = nil
        dashed.strokeColor = Theme.accentUI.cgColor
        dashed.lineWidth = 1.2
        dashed.lineDashPattern = [5, 4]
        layer.addSublayer(dashed)
        apply(content: content, typing: typing)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func apply(content: TextContent, typing: TextRun) {
        let inset = TextStyling.textInset * editZoom
        textContainerInset = UIEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
        attributedText = TextStyling.attributedString(content, scale: editZoom)
        var t = typing
        if let last = content.runs.last { t = last; t.text = "" }
        typingAttributes = TextStyling.attributes(for: t, alignment: content.alignment, scale: editZoom)
    }

    /// Content at page scale.
    func currentContent() -> TextContent {
        TextStyling.content(from: attributedText ?? NSAttributedString(), scale: editZoom, fill: fill)
    }

    func updateFrame(zoom: CGFloat) {
        let height = TextStyling.measuredHeight(currentContent(), width: docFrame.width)
        docFrame.size.height = max(height, 24)
        // Anchor at the top-left; while zooming the editor is scaled, and it
        // re-renders sharply (rescale) when the zoom gesture ends.
        layer.anchorPoint = .zero
        bounds = CGRect(x: 0, y: 0, width: docFrame.width * editZoom, height: docFrame.height * editZoom)
        layer.position = CGPoint(x: docFrame.minX * zoom, y: docFrame.minY * zoom)
        let scale = zoom / max(editZoom, 0.0001)
        transform = abs(scale - 1) > 0.001 ? CGAffineTransform(scaleX: scale, y: scale) : .identity
        dashed.frame = bounds
        dashed.path = CGPath(roundedRect: bounds.insetBy(dx: -2, dy: -2), cornerWidth: 4, cornerHeight: 4, transform: nil)
    }

    /// Re-renders the text at a new zoom, keeping the selection.
    func rescale(zoom: CGFloat) {
        guard abs(zoom - editZoom) > 0.001 else { return }
        let content = currentContent()
        let selected = selectedRange
        var typing = TextRun(text: "")
        if let font = typingAttributes[.font] as? UIFont {
            let parsed = TextStyling.content(from: NSAttributedString(string: "x", attributes: typingAttributes), scale: editZoom, fill: nil)
            if let run = parsed.runs.first { typing = run; typing.text = "" }
            _ = font
        }
        editZoom = zoom
        apply(content: content, typing: typing)
        selectedRange = selected
        updateFrame(zoom: zoom)
    }

    func applyStyle(_ change: TextStyleChange) {
        let range = selectedRange
        let storage = textStorage
        let whole = NSRange(location: 0, length: storage.length)
        let target = range.length > 0 ? range : whole
        func update(_ attrs: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
            var run = TextStyling.content(from: NSAttributedString(string: "x", attributes: attrs), scale: editZoom, fill: nil).runs.first ?? TextRun(text: "x")
            var alignment: TextAlign = .left
            if let p = attrs[.paragraphStyle] as? NSParagraphStyle {
                alignment = p.alignment == .center ? .center : (p.alignment == .right ? .right : .left)
            }
            switch change {
            case let .family(f): run.family = f
            case let .size(s): run.size = s
            case .bold: run.bold.toggle()
            case .italic: run.italic.toggle()
            case .underline: run.underline.toggle()
            case .strikethrough: run.strikethrough.toggle()
            case let .color(c): run.color = c
            case let .highlight(h): run.highlight = h
            case let .alignment(a): alignment = a
            case .fill: break
            }
            return TextStyling.attributes(for: run, alignment: alignment, scale: editZoom)
        }
        if case let .fill(color) = change {
            fill = color
            backgroundColor = color.map { UIColor($0) } ?? .clear
            return
        }
        if case .alignment = change {
            // Alignment applies to the whole box.
            storage.beginEditing()
            storage.enumerateAttributes(in: whole) { attrs, r, _ in storage.setAttributes(update(attrs), range: r) }
            storage.endEditing()
            typingAttributes = update(typingAttributes)
            return
        }
        if target.length > 0 {
            storage.beginEditing()
            storage.enumerateAttributes(in: target) { attrs, r, _ in storage.setAttributes(update(attrs), range: r) }
            storage.endEditing()
        }
        typingAttributes = update(typingAttributes)
        selectedRange = range
        onHeightChange?()
    }
}

extension CanvasController: UITextViewDelegate {
    var isEditingText: Bool { textEditor != nil }

    func createTextBox(at p: CGPoint, pageIndex: Int) {
        clearSelection()
        let frame = layout.pageFrames[pageIndex]
        let page = document.pages[pageIndex]
        let tools = editor?.tools ?? ToolState()
        var color = tools.textColor
        if page.background.paperColor.isDark && color.isDark { color = .white } else if !page.background.paperColor.isDark && color.luminance > 0.9 { color = .black }
        let typing = TextRun(text: "", family: tools.textFamily, size: tools.textSize, color: color)
        let local = CGPoint(x: p.x - frame.minX, y: p.y - frame.minY)
        let width = min(360, max(120, page.size.width - local.x - 18))
        let lineHeight = TextStyling.measuredHeight(TextContent(runs: [TextRun(text: "A", family: typing.family, size: typing.size)]), width: width)
        var rect = CGRect(x: local.x - TextStyling.textInset, y: local.y - lineHeight / 2, width: width, height: lineHeight)
        rect.origin.x = min(max(rect.minX, 0), max(0, page.size.width - rect.width))
        rect.origin.y = min(max(rect.minY, 0), max(0, page.size.height - rect.height))
        let element = PageElement(frame: rect, content: .text(TextContent(runs: [])))
        editingText = (page.id, element.id, true, currentState)
        showTextEditor(content: TextContent(runs: []), docFrame: rect.offsetBy(dx: frame.minX, dy: frame.minY), typing: typing)
    }

    func beginEditingText(pageID: UUID, elementID: UUID) {
        if textEditor != nil { endTextEditing() }
        clearSelection()
        guard let pi = document.pageIndex(of: pageID),
              let element = document.pages[pi].elements.first(where: { $0.id == elementID }),
              let content = element.textContent else { return }
        editingText = (pageID, elementID, false, currentState)
        hiddenElements.insert(elementID)
        refreshPageViews()
        let origin = layout.pageFrames[pi].origin
        let tools = editor?.tools ?? ToolState()
        let typing = content.runs.last ?? TextRun(text: "", family: tools.textFamily, size: tools.textSize, color: tools.textColor)
        showTextEditor(content: content, docFrame: element.frame.offsetBy(dx: origin.x, dy: origin.y), typing: typing)
        if currentTool != .text { editor?.selectTool(.text, remember: true) }
    }

    private func showTextEditor(content: TextContent, docFrame: CGRect, typing: TextRun) {
        let editorView = TextEditorView(content: content, docFrame: docFrame, zoom: zoom, typing: typing)
        editorView.delegate = self
        editorView.onHeightChange = { [weak self, weak editorView] in
            guard let self, let editorView else { return }
            editorView.updateFrame(zoom: self.zoom)
        }
        canvas.overlay.addSubview(editorView)
        textEditor = editorView
        editorView.updateFrame(zoom: zoom)
        editorView.becomeFirstResponder()
        editor?.textEditingChanged(true)
        ensureVisible(docRect: docFrame, animated: true)
    }

    /// Scrolls so a document rectangle sits inside the part of the canvas not
    /// covered by the keyboard.
    func ensureVisible(docRect: CGRect, animated: Bool) {
        let r = docToContent(docRect)
        let visibleHeight = max(canvas.bounds.height - max(keyboardInset, zoomPanelInset), 120)
        let margin: CGFloat = 48
        var y = canvas.contentOffset.y
        if r.maxY > y + visibleHeight - margin {
            y = r.maxY - visibleHeight + margin
        }
        if r.minY < y + margin {
            y = r.minY - margin
        }
        y = clampOffsetY(y)
        guard abs(y - canvas.contentOffset.y) > 1 else { return }
        canvas.setContentOffset(CGPoint(x: canvas.contentOffset.x, y: y), animated: animated)
    }

    func textViewDidChange(_ textView: UITextView) {
        guard let editorView = textEditor else { return }
        editorView.updateFrame(zoom: zoom)
        // Keep the line being typed in view as the box grows.
        ensureVisible(docRect: editorView.docFrame, animated: false)
        editor?.undoStateChanged()
    }

    /// Commits the text box being edited (an empty box is removed).
    func endTextEditing() {
        guard let editorView = textEditor, let info = editingText else { return }
        textEditor = nil
        editingText = nil
        let content = editorView.currentContent()
        let docFrame = editorView.docFrame
        editorView.delegate = nil
        hiddenElements.remove(info.elementID)

        if let pi = document.pageIndex(of: info.pageID) {
            let origin = layout.pageFrames[pi].origin
            var frame = docFrame.offsetBy(dx: -origin.x, dy: -origin.y)
            frame.size.height = TextStyling.measuredHeight(content, width: frame.width)
            let old = info.before
            var new = currentState
            if let npi = new.pages.firstIndex(where: { $0.id == info.pageID }) {
                if content.isEmpty {
                    new.pages[npi].elements.removeAll { $0.id == info.elementID }
                } else if let ei = new.pages[npi].elements.firstIndex(where: { $0.id == info.elementID }) {
                    new.pages[npi].elements[ei].content = .text(content)
                    new.pages[npi].elements[ei].frame = frame
                } else {
                    new.pages[npi].elements.append(PageElement(id: info.elementID, frame: frame, content: .text(content)))
                }
            }
            let changed = new.pages != old.pages
            apply(new)
            if changed {
                registerUndo(from: old, to: new, name: info.isNew ? "Add text" : "Edit text")
                editor?.scheduleSave()
                // Remember the style for the next box.
                if let run = content.runs.last { editor?.rememberTextStyle(run) }
            }
        } else {
            refreshPageViews()
        }
        editorView.resignFirstResponder()
        // Keep the editor visible a moment so the page tile can redraw beneath it.
        UIView.animate(withDuration: 0.12, delay: 0.1, options: []) {
            editorView.alpha = 0
        } completion: { _ in
            editorView.removeFromSuperview()
        }
        editor?.textEditingChanged(false)
    }

    /// Drops the editor without saving (used when undoing).
    func cancelTextEditing() {
        guard let editorView = textEditor, let info = editingText else { return }
        textEditor = nil
        editingText = nil
        editorView.delegate = nil
        hiddenElements.remove(info.elementID)
        editorView.resignFirstResponder()
        editorView.removeFromSuperview()
        refreshPageViews()
        editor?.textEditingChanged(false)
    }

    /// Applies a style from the text toolbar to the editor or the selected text box.
    func applyTextStyle(_ change: TextStyleChange) {
        if let editorView = textEditor {
            editorView.applyStyle(change)
            editorView.updateFrame(zoom: zoom)
            return
        }
        guard let selection, selection.strokeIndices.isEmpty, !selection.elements.isEmpty else { return }
        let refs = selection.elements
        perform("Text style") { state in
            for ref in refs {
                guard let pi = state.pages.firstIndex(where: { $0.id == ref.pageID }),
                      let ei = state.pages[pi].elements.firstIndex(where: { $0.id == ref.elementID }),
                      var text = state.pages[pi].elements[ei].textContent else { continue }
                for r in text.runs.indices {
                    switch change {
                    case let .family(f): text.runs[r].family = f
                    case let .size(s): text.runs[r].size = s
                    case .bold: text.runs[r].bold.toggle()
                    case .italic: text.runs[r].italic.toggle()
                    case .underline: text.runs[r].underline.toggle()
                    case .strikethrough: text.runs[r].strikethrough.toggle()
                    case let .color(c): text.runs[r].color = c
                    case let .highlight(h): text.runs[r].highlight = h
                    default: break
                    }
                }
                if case let .alignment(a) = change { text.alignment = a }
                if case let .fill(f) = change { text.fill = f }
                state.pages[pi].elements[ei].content = .text(text)
                state.pages[pi].elements[ei].frame.size.height = TextStyling.measuredHeight(text, width: state.pages[pi].elements[ei].frame.width)
            }
        }
        if var sel = self.selection {
            sel.bounds = selectionBounds(sel)
            self.selection = sel
            layoutSelectionView()
        }
    }

    // MARK: - Images

    /// Inserts an image centered on the visible part of the current page.
    func insertImage(_ image: UIImage) {
        let pageIndex = currentPageIndex
        guard pageIndex < document.pages.count else { return }
        let page = document.pages[pageIndex]
        let frame = layout.pageFrames[pageIndex]
        let visible = visibleDocRect.intersection(frame)
        let center = visible.isNull ? CGPoint(x: frame.midX, y: frame.midY) : CGPoint(x: visible.midX, y: visible.midY)
        Task {
            let maxSize = CGSize(width: page.size.width * 0.7, height: page.size.height * 0.6)
            guard var element = await ImageInsertion.element(for: image, document: document, maxSize: maxSize) else {
                editor?.showToast("That image couldn't be added.")
                return
            }
            element.frame.origin = CGPoint(x: center.x - frame.minX - element.frame.width / 2, y: center.y - frame.minY - element.frame.height / 2)
            element.frame.origin.x = min(max(element.frame.minX, 0), max(0, page.size.width - element.frame.width))
            element.frame.origin.y = min(max(element.frame.minY, 0), max(0, page.size.height - element.frame.height))
            let id = element.id
            performElementEdit("Add image", pageID: page.id) { $0.elements.append(element) }
            if currentTool != .lasso { editor?.selectTool(.lasso, remember: true) }
            setSelection(strokes: [], elements: [ElementRef(pageID: page.id, elementID: id)])
        }
    }
}
