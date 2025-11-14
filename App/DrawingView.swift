//
//  DrawingView.swift
//  Paind
//
//  Created by Anton Hristov on 9.05.25.
//
import Cocoa
import CoreGraphics
import SwiftUI
import UniformTypeIdentifiers

final class DrawingView: NSView {

    // MARK: – Modes & interactions
    private enum Mode {
        case normal
        case brush
        case textEditing(Int)
    }
    private enum DragOp { case none, marquee, moveSelection, resize(Corner) }
    private enum Corner { case tl, tr, bl, br }

    private var mode: Mode = .brush
    private var dragOp: DragOp = .none

    // MARK: – Timeline
    private var frames: [Frame] = [Frame()]   // start with one blank frame
    private var index: Int = 0                // which frame we’re editing
    private var strokes: [Stroke] = []        // ↔ frames[index].strokes
    private var images: [ImageObject] = []    // ↔ frames[index].images
    private var textBoxes: [TextBox] = []     // ↔ frames[index].texts

    // MARK: – Pen + UI state
    private var currentPath: NSBezierPath?
    private var penSize: CGFloat = 3
    private var currentColour: NSColor = .black
    private let penSizes: [Character: CGFloat] = [
        "1": 1, "2": 3, "3": 5, "4": 7, "5": 9, "6": 12, "7": 15, "8": 19, "9": 24
    ]
    private var onionSkin = false             // show faint previous frame?

    // MARK: – Pan + Zoom
    private var canvasOffset: CGPoint = .zero
    private var canvasScale: CGFloat = 1.0
    private let minScale: CGFloat = 0.1
    private let maxScale: CGFloat = 10.0

    // Middle mouse panning
    private var isPanning = false
    private var panAnchorViewPt: NSPoint = .zero

    // MARK: – Selection state (Normal mode)
    private var selectedStrokeIndices: Set<Int> = []
    private var selectedImageIndices: Set<Int> = []
    private var selectedTextIndices: Set<Int> = []
    private var selectionRect: CGRect? = nil
    private var marqueeStart: CGPoint? = nil
    private var marqueeRect: CGRect? = nil

    // Moving
    private var dragStartCanvasPt: CGPoint = .zero
    private var lastDelta: CGPoint = .zero

    // Resizing
    private var resizeStartRect: CGRect = .zero
    private var resizeAnchor: CGPoint = .zero
    private var originalPaths: [Int: NSBezierPath] = [:]
    private var originalLineWidths: [Int: CGFloat] = [:]
    private var originalImageRects: [Int: CGRect] = [:]
    private var originalTextRects: [Int: CGRect] = [:]
    private let handleRadius: CGFloat = 5

    // Text editing
    private var textEditor: NSTextView?
    private var textEditorIndex: Int?
    private let textInset: CGFloat = 6
    private let defaultTextBoxSize = CGSize(width: 240, height: 120)
    private let defaultFontName = NSFont.systemFont(ofSize: 12).fontName
    private let textFontSizeMap: [CGFloat: CGFloat] = [
        CGFloat(1): CGFloat(12),
        CGFloat(3): CGFloat(18),
        CGFloat(5): CGFloat(21),
        CGFloat(7): CGFloat(26),
        CGFloat(9): CGFloat(32),
        CGFloat(12): CGFloat(38),
        CGFloat(15): CGFloat(46),
        CGFloat(19): CGFloat(55),
        CGFloat(24): CGFloat(64)
    ]
    private func desiredTextFontSize(forPen pen: CGFloat) -> CGFloat {
        if let mapped = textFontSizeMap[pen] {
            return mapped
        }
        return max(CGFloat(9), pen * 3 + 9)
    }

    private struct HistoryState {
        var frames: [Frame]
        var index: Int
        var canvasOffset: CGPoint
        var canvasScale: CGFloat
    }
    private var undoStack: [HistoryState] = []
    private var redoStack: [HistoryState] = []
    private let maxHistoryDepth = 200
    private var hasCapturedUndoForCurrentDrag = false
    private var hasCapturedUndoForCurrentEraser = false
    private var didCaptureTextEditSnapshot = false

    // MARK: – Mouse ---------------------------------------------------------
    override func mouseDown(with e: NSEvent) {
        guard e.type == .leftMouseDown else { return }
        hasCapturedUndoForCurrentDrag = false
        let viewPoint = convert(e.locationInWindow, from: nil)

        if case .textEditing = mode, let editor = textEditor, !editor.frame.contains(viewPoint) {
            finishEditingText(commit: true)
            mode = .normal
        }

        let p = toCanvas(e.locationInWindow)
        switch mode {
        case .brush:
            beginStroke(atCanvas: p, colour: currentColour)

        case .normal:
            if let corner = hitTestHandle(p) {
                // Begin resizing
                guard let selRect = selectionRect else { return }
                dragOp = .resize(corner)
                resizeStartRect = selRect
                resizeAnchor = oppositeCornerPoint(of: selRect, to: corner)
                originalPaths.removeAll()
                originalLineWidths.removeAll()
                originalImageRects.removeAll()
                originalTextRects.removeAll()
                for i in selectedStrokeIndices {
                    originalPaths[i] = (strokes[i].path.copy() as! NSBezierPath)
                    originalLineWidths[i] = strokes[i].path.lineWidth
                }
                for j in selectedImageIndices {
                    originalImageRects[j] = images[j].frame
                }
                for k in selectedTextIndices {
                    originalTextRects[k] = textBoxes[k].frame
                }
                return
            }

            if e.clickCount == 2, let textIndex = hitTestTopmostText(p) {
                selectTextBox(textIndex)
                startEditingText(at: textIndex)
                return
            }

            if let hitTextIndex = hitTestTopmostText(p) {
                selectTextBox(hitTextIndex)
                dragOp = .moveSelection
                dragStartCanvasPt = p
                lastDelta = .zero
                return
            }

            // Direct-click on image selects and arms move immediately
            if let hitImgIndex = hitTestTopmostImage(p) {
                selectedStrokeIndices.removeAll()
                selectedImageIndices = [hitImgIndex]
                selectedTextIndices.removeAll()
                selectionRect = unionOfSelected()
                dragOp = .moveSelection          // ← arm move right away
                dragStartCanvasPt = p
                lastDelta = .zero
                marqueeStart = nil
                marqueeRect = nil
                needsDisplay = true
                return
            }

            if selectionRect?.contains(p) == true {
                // Clicked inside current selection -> prepare to move on drag
                dragOp = .moveSelection
                dragStartCanvasPt = p
                lastDelta = .zero
            } else {
                // Start marquee from any direction
                dragOp = .marquee
                marqueeStart = p
                marqueeRect = normalizedRect(from: p, to: p)
                selectedStrokeIndices.removeAll()
                selectedImageIndices.removeAll()
                selectedTextIndices.removeAll()
                selectionRect = nil
                needsDisplay = true
            }

        case .textEditing:
            return
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard e.type == .leftMouseDragged else { return }
        let p = toCanvas(e.locationInWindow)

        switch mode {
        case .brush:
            appendPointCanvas(p)

        case .normal:
            switch dragOp {
            case .marquee:
                if let start = marqueeStart {
                    marqueeRect = normalizedRect(from: start, to: p)
                    needsDisplay = true
                }

            case .moveSelection:
                let dx = p.x - dragStartCanvasPt.x
                let dy = p.y - dragStartCanvasPt.y
                let step = CGPoint(x: dx - lastDelta.x, y: dy - lastDelta.y)
                if (abs(step.x) > 0.0001 || abs(step.y) > 0.0001) {
                    captureUndoForCurrentDragIfNeeded()
                }
                translateSelected(by: step)
                lastDelta = CGPoint(x: dx, y: dy)
                needsDisplay = true

            case .resize(let corner):
                guard resizeStartRect.width != 0, resizeStartRect.height != 0 else { return }
                captureUndoForCurrentDragIfNeeded()
                var newRect = resizeStartRect
                // drag the appropriate corner to current point `p`
                switch corner {
                case .tl: newRect.origin.x = p.x; newRect.size.width = resizeAnchor.x - p.x
                          newRect.size.height = p.y - resizeAnchor.y; newRect.origin.y = resizeAnchor.y
                case .tr: newRect.size.width = p.x - resizeAnchor.x
                          newRect.size.height = p.y - resizeAnchor.y; newRect.origin.y = resizeAnchor.y
                case .bl: newRect.origin.x = p.x; newRect.size.width = resizeAnchor.x - p.x
                          newRect.size.height = resizeStartRect.maxY - p.y; newRect.origin.y = p.y
                case .br: newRect.size.width = p.x - resizeAnchor.x
                          newRect.size.height = resizeStartRect.maxY - p.y; newRect.origin.y = p.y
                }
                let minW: CGFloat = 1, minH: CGFloat = 1
                newRect.size.width = max(minW, newRect.size.width)
                newRect.size.height = max(minH, newRect.size.height)

                let sx = newRect.width / resizeStartRect.width
                let sy = newRect.height / resizeStartRect.height

                // Reset to originals, then scale around anchor
                for i in selectedStrokeIndices {
                    guard let base = originalPaths[i]?.copy() as? NSBezierPath else { continue }
                    var t = AffineTransform()
                    t.translate(x: resizeAnchor.x, y: resizeAnchor.y)
                    t.scale(x: sx, y: sy)
                    t.translate(x: -resizeAnchor.x, y: -resizeAnchor.y)
                    base.transform(using: t)
                    strokes[i].path = base

                    if let lw = originalLineWidths[i] {
                        let k = (abs(sx) + abs(sy)) / 2
                        strokes[i].path.lineWidth = max(0.5, lw * k)
                    }
                }
                for j in selectedImageIndices {
                    if let r0 = originalImageRects[j] {
                        // Scale rect about anchor
                        let originVec = CGPoint(x: r0.origin.x - resizeAnchor.x, y: r0.origin.y - resizeAnchor.y)
                        let newOrigin = CGPoint(x: resizeAnchor.x + originVec.x * sx,
                                                y: resizeAnchor.y + originVec.y * sy)
                        let newSize = CGSize(width: r0.size.width * sx, height: r0.size.height * sy)
                        images[j].frame = CGRect(origin: newOrigin, size: newSize)
                    }
                }
                for k in selectedTextIndices {
                    if let r0 = originalTextRects[k] {
                        let originVec = CGPoint(x: r0.origin.x - resizeAnchor.x, y: r0.origin.y - resizeAnchor.y)
                        let newOrigin = CGPoint(x: resizeAnchor.x + originVec.x * sx,
                                                y: resizeAnchor.y + originVec.y * sy)
                        let newSize = CGSize(width: r0.size.width * sx, height: r0.size.height * sy)
                        textBoxes[k].frame = CGRect(origin: newOrigin, size: newSize)
                    }
                }

                selectionRect = unionOfSelected()
                needsDisplay = true
                syncTextEditorFrame()

            case .none:
                break
            }

        case .textEditing:
            break
        }
    }

    override func mouseUp(with e: NSEvent) {
        let p = toCanvas(e.locationInWindow)
        switch mode {
        case .brush:
            appendPointCanvas(p)
            currentPath = nil

        case .normal:
            switch dragOp {
            case .marquee:
                if let m = marqueeRect {
                    let box = m // already normalized
                    // Select strokes and images intersecting the marquee
                    selectedStrokeIndices = Set(strokes.enumerated().compactMap { idx, s in
                        s.path.strokedBoundingBox.intersects(box) ? idx : nil
                    })
                    selectedImageIndices = Set(images.enumerated().compactMap { idx, im in
                        im.frame.intersects(box) ? idx : nil
                    })
                    selectedTextIndices = Set(textBoxes.enumerated().compactMap { idx, txt in
                        txt.frame.intersects(box) ? idx : nil
                    })
                    selectionRect = unionOfSelected()
                    marqueeStart = nil
                    marqueeRect = nil
                    needsDisplay = true
                }
            case .moveSelection, .resize:
                originalPaths.removeAll()
                originalLineWidths.removeAll()
                originalImageRects.removeAll()
                originalTextRects.removeAll()
                commitCurrentFrame()
                needsDisplay = true
            case .none:
                break
            }
            dragOp = .none
            hasCapturedUndoForCurrentDrag = false

        case .textEditing:
            break
        }
    }

    // MMB → pan canvas (no more MMB eraser)
    override func otherMouseDown(with e: NSEvent) {
        guard e.buttonNumber == 2 else { return }
        isPanning = true
        panAnchorViewPt = convert(e.locationInWindow, from: nil)
    }
    override func otherMouseDragged(with e: NSEvent) {
        guard e.buttonNumber == 2, isPanning else { return }
        let pNow = convert(e.locationInWindow, from: nil)
        canvasOffset.x += (pNow.x - panAnchorViewPt.x)
        canvasOffset.y += (pNow.y - panAnchorViewPt.y)
        panAnchorViewPt = pNow
        needsDisplay = true
        syncTextEditorFrame()
    }
    override func otherMouseUp(with e: NSEvent) {
        guard e.buttonNumber == 2 else { return }
        isPanning = false
    }

    // Right-click → object eraser (strokes by proximity, else images under pointer)
    override func rightMouseDown(with e: NSEvent) {
        hasCapturedUndoForCurrentEraser = false
        deleteObject(atCanvas: toCanvas(e.locationInWindow))
    }
    override func rightMouseDragged(with e: NSEvent) {
        deleteObject(atCanvas: toCanvas(e.locationInWindow))
    }
    override func rightMouseUp(with e: NSEvent) {
        hasCapturedUndoForCurrentEraser = false
    }

    // MARK: – Scroll to zoom (and pinch)
    override func scrollWheel(with event: NSEvent) {
        let viewPt = convert(event.locationInWindow, from: nil)
        let canvasPtBefore = toCanvas(viewPt)

        // Smooth zoom factor
        let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.deltaY
        let zoomStep: CGFloat = 1.0 + (abs(dy) > 0 ? 0.12 : 0)
        let factor: CGFloat = dy > 0 ? zoomStep : 1.0 / zoomStep

        setZoom(scale: canvasScale * factor, anchorViewPoint: viewPt, anchorCanvasPoint: canvasPtBefore)
    }

    override func magnify(with event: NSEvent) {
        let viewPt = convert(event.locationInWindow, from: nil)
        let canvasPtBefore = toCanvas(viewPt)
        let newScale = canvasScale * (1.0 + event.magnification)
        setZoom(scale: newScale, anchorViewPoint: viewPt, anchorCanvasPoint: canvasPtBefore)
    }

    private func setZoom(scale newScaleRaw: CGFloat, anchorViewPoint V: NSPoint, anchorCanvasPoint C: NSPoint) {
        let newScale = max(minScale, min(maxScale, newScaleRaw))
        guard newScale != canvasScale else { return }
        // Keep anchor point stationary in view: V = offset' + newScale * C
        canvasOffset.x = V.x - newScale * C.x
        canvasOffset.y = V.y - newScale * C.y
        canvasScale = newScale
        needsDisplay = true
        syncTextEditorFrame()
    }

    private func panViewByKeyboard(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        canvasOffset.x += dx
        canvasOffset.y += dy
        needsDisplay = true
        syncTextEditorFrame()
    }

    // MARK: – Keyboard ------------------------------------------------------
    override func keyDown(with e: NSEvent) {
        // Handle ⌘V (paste)
        if e.modifierFlags.contains(.command), let chars = e.charactersIgnoringModifiers, chars.lowercased() == "v" {
            paste(nil)
            return
        }

        if let chars = e.charactersIgnoringModifiers?.lowercased() {
            if e.modifierFlags.contains(.command), chars == "z" {
                if e.modifierFlags.contains(.shift) {
                    redoAction()
                } else {
                    undoAction()
                }
                return
            }
            if e.modifierFlags.contains(.control), chars == "r" {
                redoAction()
                return
            }
            if e.modifierFlags.contains(.command), chars == "y" {
                redoAction()
                return
            }
        }

        // First handle non-character keys
        switch e.keyCode {
        case 53: // Esc → NORMAL mode
            endTextEditingIfNeeded()
            mode = .normal
            currentPath = nil
            needsDisplay = true
            return
        case 123:
            endTextEditingIfNeeded()
            goToPreviousFrame()
            return        // ←
        case 124:
            endTextEditingIfNeeded()
            goToNextFrame()
            return            // →
        case 36, 76:
            onionSkin.toggle()
            needsDisplay = true
            return   // Enter
        default: break
        }

        guard let ch = e.characters?.first else { return }

        if let s = penSizes[ch] {
            penSize = s
            if applyPenSizeToSelectedText() { return }
            return
        }

        switch ch {
        case "i":
            prepareForTextInsertion()
            return
        case "u":
            undoAction()
            return

        case "h" where mode == .normal:
            panViewByKeyboard(dx: bounds.width * 0.1, dy: 0)
            return
        case "l" where mode == .normal:
            panViewByKeyboard(dx: -bounds.width * 0.1, dy: 0)
            return
        case "j" where mode == .normal:
            panViewByKeyboard(dx: 0, dy: bounds.height * 0.1)
            return
        case "k" where mode == .normal:
            panViewByKeyboard(dx: 0, dy: -bounds.height * 0.1)
            return

        // Brush colors → set color, switch to INSERT, and (if LMB held) start drawing now
        case "w": setColourAndHandleInput(.white); return
        case "g": setColourAndHandleInput(.systemGreen); return
        case "c": setColourAndHandleInput(.systemCyan); return
        case "y": setColourAndHandleInput(.systemYellow); return
        case "o": setColourAndHandleInput(.systemOrange); return
        case "p": setColourAndHandleInput(.systemPink); return
        case "P": setColourAndHandleInput(.systemPurple); return
        case "B": setColourAndHandleInput(.systemBlue); return
        case "r": setColourAndHandleInput(.systemRed); return
        case "b": setColourAndHandleInput(.black); return

        case " ":
            endTextEditingIfNeeded()
            if e.modifierFlags.contains(.shift) {
                duplicateFrameAfterCurrent()
            } else {
                addBlankFrameAfterCurrent()
            }
            return
        default:
            break
        }
    }

    /// Set brush colour, switch to brush mode (unless a text box is selected),
    /// and if the left mouse button is held start a stroke immediately.
    private func setColourAndHandleInput(_ colour: NSColor) {
        currentColour = colour
        if applyColourToSelectedText(colour) { return }

        mode = .brush
        needsDisplay = true

        // Only auto-start if LMB is currently pressed and we don't already have a stroke
        if NSEvent.pressedMouseButtons & 0x1 == 0x1, currentPath == nil {
            if let w = window {
                let winPt = w.mouseLocationOutsideOfEventStream
                let vPt = convert(winPt, from: nil)
                if bounds.contains(vPt) {
                    let cPt = toCanvas(winPt)
                    beginStroke(atCanvas: cPt, colour: currentColour)
                }
            }
        }
    }

    // MARK: – Paste image (PNG/NSImage) ------------------------------------
    func paste(_ sender: Any?) {
        let pb = NSPasteboard.general

        // Try direct NSImage first
        if let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let img = imgs.first {
            insertPasted(image: img)
            return
        }

        // Try PNG/TIFF data → NSImage
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff),
           let img = NSImage(data: data) {
            insertPasted(image: img)
            return
        }
        NSSound.beep()
    }

    private func insertPasted(image: NSImage) {
        endTextEditingIfNeeded()
        pushUndoSnapshot()
        // Paste centered at mouse if inside view; else center of view
        let viewPt: NSPoint = {
            if let w = window {
                let winPt = w.mouseLocationOutsideOfEventStream
                let v = convert(winPt, from: nil)
                if bounds.contains(v) { return v }
            }
            return NSPoint(x: bounds.midX, y: bounds.midY)
        }()
        let canvasPt = toCanvas(viewPt)

        let imgSize = image.size
        let rect = CGRect(x: canvasPt.x - imgSize.width/2,
                          y: canvasPt.y - imgSize.height/2,
                          width: imgSize.width, height: imgSize.height)
        images.append(ImageObject(image: image, frame: rect))

        // Select it immediately
        selectedStrokeIndices.removeAll()
        selectedImageIndices = [images.count - 1]
        selectedTextIndices.removeAll()
        selectionRect = unionOfSelected()
        mode = .normal
        commitCurrentFrame()
        needsDisplay = true
    }

    // MARK: – Text boxes ----------------------------------------------------
    private func prepareForTextInsertion() {
        endTextEditingIfNeeded()
        clearSelection()
        let insertionPoint = currentCanvasInsertionPoint()
        insertTextBox(atCanvas: insertionPoint)
    }

    @objc func saveDocumentFromMenu() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.saveDocumentFromMenu()
            }
            return
        }

        endTextEditingIfNeeded()
        let panel = NSSavePanel()
        if #available(macOS 12.0, *) {
            if let type = UTType(filenameExtension: "paind", conformingTo: .data) {
                panel.allowedContentTypes = [type]
            } else {
                panel.allowedContentTypes = [.data]
            }
        } else {
            panel.allowedFileTypes = ["paind"]
        }
        panel.nameFieldStringValue = "Untitled.paind"
        panel.canCreateDirectories = true
        panel.allowsOtherFileTypes = true

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.writeDocument(to: url)
            } catch {
                self?.presentErrorAlert(message: "Failed to save document.", info: error.localizedDescription)
            }
        }

        if let hostWindow = window {
            panel.beginSheetModal(for: hostWindow, completionHandler: completion)
        } else {
            let response = panel.runModal()
            completion(response)
        }
    }

    @objc func openDocumentFromMenu() {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in
                self?.openDocumentFromMenu()
            }
            return
        }

        endTextEditingIfNeeded()
        let panel = NSOpenPanel()
        if #available(macOS 12.0, *) {
            if let type = UTType(filenameExtension: "paind", conformingTo: .data) {
                panel.allowedContentTypes = [type]
            } else {
                panel.allowedContentTypes = [.data]
            }
        } else {
            panel.allowedFileTypes = ["paind"]
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.readDocument(from: url)
            } catch {
                self?.presentErrorAlert(message: "Failed to open document.", info: error.localizedDescription)
            }
        }

        if let hostWindow = window {
            panel.beginSheetModal(for: hostWindow, completionHandler: completion)
        } else {
            let response = panel.runModal()
            completion(response)
        }
    }

    // MARK: – Undo / Redo ----------------------------------------------------

    private func pushUndoSnapshot() {
        commitCurrentFrame()
        let state = makeHistoryState()
        undoStack.append(state)
        if undoStack.count > maxHistoryDepth {
            undoStack.removeFirst()
        }
        redoStack.removeAll()
    }

    private func makeHistoryState() -> HistoryState {
        HistoryState(frames: deepCopyFrames(frames),
                     index: index,
                     canvasOffset: canvasOffset,
                     canvasScale: canvasScale)
    }

    private func deepCopyFrames(_ frames: [Frame]) -> [Frame] {
        frames.map { frame in
            let strokeCopies = frame.strokes.map { stroke -> Stroke in
                let pathCopy = stroke.path.copy() as! NSBezierPath
                return Stroke(path: pathCopy, colour: stroke.colour)
            }
            return Frame(strokes: strokeCopies,
                         images: frame.images,
                         texts: frame.texts)
        }
    }

    private func restoreHistoryState(_ state: HistoryState) {
        frames = deepCopyFrames(state.frames)
        if frames.isEmpty {
            frames = [Frame()]
        }
        index = min(state.index, frames.count - 1)
        strokes = frames[index].strokes
        images = frames[index].images
        textBoxes = frames[index].texts
        canvasOffset = state.canvasOffset
        canvasScale = state.canvasScale
        clearSelection()
        currentPath = nil
        mode = .normal
        dragOp = .none
        hasCapturedUndoForCurrentDrag = false
        hasCapturedUndoForCurrentEraser = false
        didCaptureTextEditSnapshot = false
        needsDisplay = true
        syncTextEditorFrame()
        window?.makeFirstResponder(self)
    }

    private func undoAction() {
        commitCurrentFrame()
        guard let state = undoStack.popLast() else {
            NSSound.beep()
            return
        }
        let currentState = makeHistoryState()
        redoStack.append(currentState)
        if case .textEditing = mode {
            finishEditingText(commit: false)
        }
        restoreHistoryState(state)
    }

    private func redoAction() {
        commitCurrentFrame()
        guard let state = redoStack.popLast() else {
            NSSound.beep()
            return
        }
        let currentState = makeHistoryState()
        undoStack.append(currentState)
        if undoStack.count > maxHistoryDepth {
            undoStack.removeFirst()
        }
        if case .textEditing = mode {
            finishEditingText(commit: false)
        }
        restoreHistoryState(state)
    }

    private func captureUndoForCurrentDragIfNeeded() {
        if !hasCapturedUndoForCurrentDrag {
            pushUndoSnapshot()
            hasCapturedUndoForCurrentDrag = true
        }
    }

    private func captureUndoForEraserIfNeeded() {
        if !hasCapturedUndoForCurrentEraser {
            pushUndoSnapshot()
            hasCapturedUndoForCurrentEraser = true
        }
    }

    private func insertTextBox(atCanvas point: CGPoint) {
        endTextEditingIfNeeded()
        pushUndoSnapshot()
        let origin = CGPoint(x: point.x - defaultTextBoxSize.width / 2,
                             y: point.y - defaultTextBoxSize.height / 2)
        let box = TextBox(text: "",
                          frame: CGRect(origin: origin, size: defaultTextBoxSize),
                          fontSize: desiredTextFontSize(forPen: penSize),
                          colour: currentColour,
                          fontName: defaultFontName)
        textBoxes.append(box)
        let idx = textBoxes.count - 1
        selectTextBox(idx)
        commitCurrentFrame()
        startEditingText(at: idx, selectAll: true)
    }

    private func selectTextBox(_ index: Int) {
        guard textBoxes.indices.contains(index) else { return }
        selectedStrokeIndices.removeAll()
        selectedImageIndices.removeAll()
        selectedTextIndices = [index]
        selectionRect = unionOfSelected()
        marqueeStart = nil
        marqueeRect = nil
        dragOp = .none
        needsDisplay = true
    }

    private func startEditingText(at index: Int, selectAll: Bool = false) {
        guard textBoxes.indices.contains(index) else { return }
        finishEditingText(commit: true)
        didCaptureTextEditSnapshot = false

        let box = textBoxes[index]
        let editorFrame = viewRect(fromCanvas: box.frame)
        let editor = NSTextView(frame: editorFrame)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.textContainerInset = NSSize(width: textInset, height: textInset)
        editor.string = box.text
        editor.textColor = box.colour
        editor.insertionPointColor = box.colour
        let fontSize = max(1, box.fontSize) * canvasScale
        editor.font = NSFont(name: box.fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        editor.isHorizontallyResizable = false
        editor.isVerticallyResizable = false
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        if let container = editor.textContainer {
            container.widthTracksTextView = false
            container.heightTracksTextView = false
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byClipping
            container.containerSize = CGSize(width: max(10, editorFrame.width - textInset * 2),
                                             height: CGFloat.greatestFiniteMagnitude)
        }
        editor.delegate = self
        editor.allowsUndo = true
        editor.isContinuousSpellCheckingEnabled = false
        editor.smartInsertDeleteEnabled = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticLinkDetectionEnabled = false
        addSubview(editor)
        textEditor = editor
        textEditorIndex = index
        mode = .textEditing(index)
        if selectAll {
            editor.selectAll(self)
        }
        window?.makeFirstResponder(editor)
    }

    private func finishEditingText(commit: Bool) {
        guard let editor = textEditor, let idx = textEditorIndex else {
            didCaptureTextEditSnapshot = false
            textEditor = nil
            textEditorIndex = nil
            mode = .normal
            return
        }

        if commit, textBoxes.indices.contains(idx) {
            textBoxes[idx].text = editor.string
            let metrics = intrinsicTextSize(for: textBoxes[idx])
            var frame = textBoxes[idx].frame
            frame.size.width = max(frame.size.width, metrics.width)
            frame.size.height = max(frame.size.height, metrics.height)
            textBoxes[idx].frame = frame
            commitCurrentFrame()
        }

        didCaptureTextEditSnapshot = false
        editor.removeFromSuperview()
        textEditor = nil
        textEditorIndex = nil
        window?.makeFirstResponder(self)
        selectionRect = unionOfSelected()
        mode = .normal
        needsDisplay = true
    }

    private func endTextEditingIfNeeded() {
        if case .textEditing = mode {
            finishEditingText(commit: true)
        }
    }

    private func syncTextEditorFrame() {
        guard let editor = textEditor, let idx = textEditorIndex, textBoxes.indices.contains(idx) else { return }
        let rect = viewRect(fromCanvas: textBoxes[idx].frame)
        editor.frame = rect
        let fontSize = max(1, textBoxes[idx].fontSize) * canvasScale
        editor.font = NSFont(name: textBoxes[idx].fontName, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
        editor.textColor = textBoxes[idx].colour
        editor.insertionPointColor = textBoxes[idx].colour
        if let container = editor.textContainer {
            container.containerSize = CGSize(width: max(10, rect.width - textInset * 2),
                                             height: CGFloat.greatestFiniteMagnitude)
        }
    }

    @discardableResult
    private func applyPenSizeToSelectedText() -> Bool {
        guard !selectedTextIndices.isEmpty else { return false }
        let newSize = desiredTextFontSize(forPen: penSize)
        var changed = false
        for idx in selectedTextIndices where textBoxes.indices.contains(idx) {
            if abs(textBoxes[idx].fontSize - newSize) < 0.001 { continue }
            if !changed {
                pushUndoSnapshot()
                changed = true
            }
            textBoxes[idx].fontSize = newSize
            let metrics = intrinsicTextSize(for: textBoxes[idx])
            textBoxes[idx].frame.size.width = max(textBoxes[idx].frame.size.width, metrics.width)
            textBoxes[idx].frame.size.height = max(textBoxes[idx].frame.size.height, metrics.height)
        }
        guard changed else { return false }
        if let current = textEditorIndex, selectedTextIndices.contains(current) {
            syncTextEditorFrame()
        }
        selectionRect = unionOfSelected()
        commitCurrentFrame()
        needsDisplay = true
        return true
    }

    @discardableResult
    private func applyColourToSelectedText(_ colour: NSColor) -> Bool {
        guard !selectedTextIndices.isEmpty else { return false }
        var changed = false
        for idx in selectedTextIndices where textBoxes.indices.contains(idx) {
            if textBoxes[idx].colour == colour { continue }
            if !changed {
                pushUndoSnapshot()
                changed = true
            }
            textBoxes[idx].colour = colour
        }
        guard changed else { return false }
        if let current = textEditorIndex, selectedTextIndices.contains(current) {
            textEditor?.textColor = colour
            textEditor?.insertionPointColor = colour
        }
        commitCurrentFrame()
        needsDisplay = true
        return true
    }

    private func intrinsicTextSize(for box: TextBox) -> CGSize {
        let font = NSFont(name: box.fontName, size: box.fontSize) ?? NSFont.systemFont(ofSize: box.fontSize)
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let lines = box.text.components(separatedBy: "\n")
        let lineHeight = font.ascender - font.descender + font.leading
        var maxWidth: CGFloat = 0
        for line in lines {
            let size = (line as NSString).size(withAttributes: attributes)
            maxWidth = max(maxWidth, size.width)
        }
        let height = lineHeight * CGFloat(max(lines.count, 1))
        return CGSize(width: max(maxWidth + textInset * 2, 20),
                      height: max(height + textInset * 2, lineHeight + textInset * 2))
    }

    private func viewRect(fromCanvas rect: CGRect) -> CGRect {
        CGRect(x: canvasOffset.x + rect.origin.x * canvasScale,
               y: canvasOffset.y + rect.origin.y * canvasScale,
               width: rect.width * canvasScale,
               height: rect.height * canvasScale)
    }

    private func drawTextBox(_ box: TextBox, in context: CGContext) {
        let font = NSFont(name: box.fontName, size: box.fontSize) ?? NSFont.systemFont(ofSize: box.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byClipping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: box.colour,
            .paragraphStyle: paragraph
        ]
        let lines = box.text.components(separatedBy: "\n")
        let lineHeight = font.ascender - font.descender + font.leading
        var baselineY = box.frame.maxY - textInset - font.ascender
        let startX = box.frame.minX + textInset

        context.saveGState()
        context.clip(to: box.frame)
        for line in lines {
            NSString(string: line).draw(at: CGPoint(x: startX, y: baselineY), withAttributes: attributes)
            baselineY -= lineHeight
        }
        context.restoreGState()
    }

    // MARK: – Drawing -------------------------------------------------------
    override func draw(_ dirty: NSRect) {
        // Background
        NSColor.white.setFill()
        dirty.fill()

        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.saveGState()
        // View <- offset + scale * canvas
        cg.translateBy(x: canvasOffset.x, y: canvasOffset.y)
        cg.scaleBy(x: canvasScale, y: canvasScale)

        // Onion skin (previous frame at 25 % opacity)
        if onionSkin, index > 0 {
            // Images (faint)
            for im in frames[index - 1].images {
                cg.saveGState()
                cg.setAlpha(0.25)
                im.image.draw(in: im.frame)
                cg.restoreGState()
            }
            // Strokes (faint)
            for s in frames[index - 1].strokes {
                s.colour.withAlphaComponent(0.25).setStroke()
                s.path.stroke()
            }
        }

        // Current frame content
        // Draw images below strokes, so you can draw on top of them
        for im in images {
            im.image.draw(in: im.frame)
        }
        for s in strokes {
            s.colour.setStroke()
            s.path.stroke()
        }
        for (idx, txt) in textBoxes.enumerated() {
            if case .textEditing(let editingIdx) = mode, editingIdx == idx {
                continue
            }
            drawTextBox(txt, in: cg)
        }

        // Overlays (selection / marquee) in canvas space
        drawSelectionOverlay()
        drawMarquee()

        cg.restoreGState()
    }

    // MARK: – Frame navigation helpers -------------------------------------
    private func commitCurrentFrame() {
        frames[index].strokes = strokes
        frames[index].images = images
        frames[index].texts = textBoxes
    }
    private func goToPreviousFrame() {
        guard index > 0 else { return }
        commitCurrentFrame()
        index -= 1
        strokes = frames[index].strokes
        images = frames[index].images
        textBoxes = frames[index].texts
        clearSelection()
        needsDisplay = true
    }
    private func goToNextFrame() {
        guard index + 1 < frames.count else { return }
        commitCurrentFrame()
        index += 1
        strokes = frames[index].strokes
        images = frames[index].images
        textBoxes = frames[index].texts
        clearSelection()
        needsDisplay = true
    }
    private func addBlankFrameAfterCurrent() {
        commitCurrentFrame()
        pushUndoSnapshot()
        frames.insert(Frame(), at: index + 1)
        index += 1
        strokes = []
        images = []
        textBoxes = []
        clearSelection()
        needsDisplay = true
    }

    private func duplicateFrameAfterCurrent() {
        commitCurrentFrame()
        pushUndoSnapshot()
        let copied = deepCopyFrames([frames[index]]).first ?? Frame()
        frames.insert(copied, at: index + 1)
        index += 1
        strokes = frames[index].strokes
        images = frames[index].images
        textBoxes = frames[index].texts
        clearSelection()
        needsDisplay = true
    }

    // MARK: – Stroke helpers ------------------------------------------------
    private func beginStroke(atCanvas p: NSPoint, colour: NSColor) {
        pushUndoSnapshot()
        let path = NSBezierPath()
        path.lineWidth = penSize
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: p)
        strokes.append(Stroke(path: path, colour: colour))
        currentPath = path
        needsDisplay = true
    }
    private func appendPointCanvas(_ p: NSPoint) {
        currentPath?.line(to: p)
        needsDisplay = true
    }

    private func deleteObject(atCanvas p: NSPoint) {
        let strokeHits = strokes.enumerated().filter { $0.element.path.hitsStroke(p, tolerance: 2) }.map(\.offset)
        if !strokeHits.isEmpty {
            captureUndoForEraserIfNeeded()
            for idx in strokeHits.sorted(by: >) {
                strokes.remove(at: idx)
            }
            compactSelectionAfterDeletion()
            commitCurrentFrame()
            needsDisplay = true
            return
        }

        if let idx = images.indices.reversed().first(where: { images[$0].frame.contains(p) }) {
            captureUndoForEraserIfNeeded()
            images.remove(at: idx)
            compactSelectionAfterDeletion()
            commitCurrentFrame()
            needsDisplay = true
            return
        }

        if let idx = textBoxes.indices.reversed().first(where: { textBoxes[$0].frame.contains(p) }) {
            captureUndoForEraserIfNeeded()
            if case .textEditing(let editingIdx) = mode, editingIdx == idx {
                finishEditingText(commit: false)
            }
            textBoxes.remove(at: idx)
            compactSelectionAfterDeletion()
            commitCurrentFrame()
            needsDisplay = true
        }
    }

    override var acceptsFirstResponder: Bool { true }

    // MARK: – Coordinates
    private func toCanvas(_ winPt: NSPoint) -> NSPoint {
        let v = convert(winPt, from: nil)
        // canvas C = (V - offset)/scale
        return NSPoint(x: (v.x - canvasOffset.x) / canvasScale,
                       y: (v.y - canvasOffset.y) / canvasScale)
    }

    private func canvasPoint(fromView viewPt: CGPoint) -> CGPoint {
        CGPoint(x: (viewPt.x - canvasOffset.x) / canvasScale,
                y: (viewPt.y - canvasOffset.y) / canvasScale)
    }

    private func currentCanvasInsertionPoint() -> CGPoint {
        if let window = window {
            let winPt = window.mouseLocationOutsideOfEventStream
            let viewPt = convert(winPt, from: nil)
            if bounds.contains(viewPt) {
                return canvasPoint(fromView: viewPt)
            }
        }
        let centerView = CGPoint(x: bounds.midX, y: bounds.midY)
        return canvasPoint(fromView: centerView)
    }

    // MARK: – Selection utilities
    private func clearSelection() {
        selectedStrokeIndices.removeAll()
        selectedImageIndices.removeAll()
        selectedTextIndices.removeAll()
        selectionRect = nil
        marqueeStart = nil
        marqueeRect = nil
        dragOp = .none
    }

    private func translateSelected(by delta: CGPoint) {
        guard !(selectedStrokeIndices.isEmpty && selectedImageIndices.isEmpty && selectedTextIndices.isEmpty) else { return }
        var t = AffineTransform()
        t.translate(x: delta.x, y: delta.y)
        for i in selectedStrokeIndices {
            strokes[i].path.transform(using: t)
        }
        for j in selectedImageIndices {
            images[j].frame.origin.x += delta.x
            images[j].frame.origin.y += delta.y
        }
        for k in selectedTextIndices {
            textBoxes[k].frame.origin.x += delta.x
            textBoxes[k].frame.origin.y += delta.y
        }
        selectionRect = unionOfSelected()
        syncTextEditorFrame()
    }

    private func unionOfSelected() -> CGRect? {
        var rect = CGRect.null
        for i in selectedStrokeIndices {
            rect = rect.union(strokes[i].path.strokedBoundingBox)
        }
        for j in selectedImageIndices {
            rect = rect.union(images[j].frame)
        }
        for k in selectedTextIndices {
            rect = rect.union(textBoxes[k].frame)
        }
        return rect.isNull ? nil : rect
    }

    private func compactSelectionAfterDeletion() {
        selectedStrokeIndices.removeAll()
        selectedImageIndices.removeAll()
        selectedTextIndices.removeAll()
        selectionRect = nil
    }

    private func normalizedRect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x),
               y: min(a.y, b.y),
               width: abs(a.x - b.x),
               height: abs(a.y - b.y))
    }

    // MARK: – Selection overlay & handles
    private func drawSelectionOverlay() {
        guard let r = selectionRect else { return }
        NSColor.systemBlue.setStroke()
        let box = NSBezierPath(rect: r)
        box.lineWidth = 1.5
        box.stroke()

        // Corner handles
        for h in handleRects(for: r) {
            NSColor.systemBlue.setFill()
            NSBezierPath(ovalIn: h).fill()
        }
    }

    private func drawMarquee() {
        guard let m = marqueeRect else { return }
        let p = NSBezierPath(rect: m)
        let dash: [CGFloat] = [4, 3]
        p.setLineDash(dash, count: dash.count, phase: 0)
        NSColor.black.withAlphaComponent(0.6).setStroke()
        p.lineWidth = 1
        p.stroke()

        NSColor.controlAccentColor.withAlphaComponent(0.08).setFill()
        NSBezierPath(rect: m).fill()
    }

    private func handleRects(for r: CGRect) -> [CGRect] {
        let d = handleRadius
        return [
            CGRect(x: r.minX - d, y: r.maxY - d, width: 2*d, height: 2*d), // tl
            CGRect(x: r.maxX - d, y: r.maxY - d, width: 2*d, height: 2*d), // tr
            CGRect(x: r.minX - d, y: r.minY - d, width: 2*d, height: 2*d), // bl
            CGRect(x: r.maxX - d, y: r.minY - d, width: 2*d, height: 2*d)  // br
        ]
    }

    private func hitTestHandle(_ p: CGPoint) -> Corner? {
        guard let r = selectionRect else { return nil }
        let hs = handleRects(for: r)
        if hs[0].contains(p) { return .tl }
        if hs[1].contains(p) { return .tr }
        if hs[2].contains(p) { return .bl }
        if hs[3].contains(p) { return .br }
        return nil
    }

    private func oppositeCornerPoint(of r: CGRect, to c: Corner) -> CGPoint {
        switch c {
        case .tl: return CGPoint(x: r.maxX, y: r.minY)
        case .tr: return CGPoint(x: r.minX, y: r.minY)
        case .bl: return CGPoint(x: r.maxX, y: r.maxY)
        case .br: return CGPoint(x: r.minX, y: r.maxY)
        }
    }

    private func hitTestTopmostText(_ p: CGPoint) -> Int? {
        for idx in textBoxes.indices.reversed() {
            if textBoxes[idx].frame.contains(p) { return idx }
        }
        return nil
    }

    private func hitTestTopmostImage(_ p: CGPoint) -> Int? {
        for idx in images.indices.reversed() {
            if images[idx].frame.contains(p) { return idx }
        }
        return nil
    }
}

extension DrawingView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard let idx = textEditorIndex,
              textBoxes.indices.contains(idx),
              let editor = textEditor else { return }
        if !didCaptureTextEditSnapshot {
            pushUndoSnapshot()
            didCaptureTextEditSnapshot = true
        }
        textBoxes[idx].text = editor.string
        let metrics = intrinsicTextSize(for: textBoxes[idx])
        var frame = textBoxes[idx].frame
        frame.size.width = max(frame.size.width, metrics.width)
        frame.size.height = max(frame.size.height, metrics.height)
        textBoxes[idx].frame = frame
        commitCurrentFrame()
        syncTextEditorFrame()
        selectionRect = unionOfSelected()
        needsDisplay = true
    }
}

// MARK: – Persistence ------------------------------------------------------
private extension DrawingView {
    struct PaindDocument: Codable {
        var version: Int
        var canvasScale: CGFloat
        var canvasOffset: CGPoint
        var currentFrameIndex: Int
        var penSize: CGFloat
        var currentColour: PaindColour
        var frames: [PaindFrame]
    }

    struct PaindFrame: Codable {
        var strokes: [PaindStroke]
        var images: [PaindImage]
        var texts: [PaindTextBox]
    }

    struct PaindStroke: Codable {
        var colour: PaindColour
        var lineWidth: CGFloat
        var lineCap: Int
        var lineJoin: Int
        var miterLimit: CGFloat
        var segments: [PaindPathSegment]
    }

    struct PaindPathSegment: Codable {
        enum Kind: String, Codable {
            case moveTo, lineTo, curveTo, close
        }
        var kind: Kind
        var points: [CGPoint]
    }

    struct PaindImage: Codable {
        var frame: CGRect
        var base64PNG: String
    }

    struct PaindTextBox: Codable {
        var text: String
        var frame: CGRect
        var fontSize: CGFloat
        var colour: PaindColour
        var fontName: String
    }

    struct PaindColour: Codable {
        var r: CGFloat
        var g: CGFloat
        var b: CGFloat
        var a: CGFloat

        init(color: NSColor) {
            if let converted = color.usingColorSpace(.deviceRGB) ?? color.usingColorSpace(.sRGB) {
                r = converted.redComponent
                g = converted.greenComponent
                b = converted.blueComponent
                a = converted.alphaComponent
            } else {
                r = color.redComponent
                g = color.greenComponent
                b = color.blueComponent
                a = color.alphaComponent
            }
        }

        func makeColor() -> NSColor {
            NSColor(deviceRed: r, green: g, blue: b, alpha: a)
        }
    }

    enum PaindPersistenceError: LocalizedError {
        case imageEncodingFailed
        case imageDecodingFailed

        var errorDescription: String? {
            switch self {
            case .imageEncodingFailed:
                return "Unable to encode image data."
            case .imageDecodingFailed:
                return "Unable to decode image data."
            }
        }
    }

    func writeDocument(to url: URL) throws {
        commitCurrentFrame()
        let document = PaindDocument(
            version: 1,
            canvasScale: canvasScale,
            canvasOffset: canvasOffset,
            currentFrameIndex: index,
            penSize: penSize,
            currentColour: PaindColour(color: currentColour),
            frames: try frames.map { frame in
                PaindFrame(
                    strokes: frame.strokes.map { persistedStroke(from: $0) },
                    images: try frame.images.map { try persistedImage(from: $0) },
                    texts: frame.texts.map { persistedText(from: $0) }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try data.write(to: url, options: .atomic)
    }

    func readDocument(from url: URL) throws {
        endTextEditingIfNeeded()
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        let document = try decoder.decode(PaindDocument.self, from: data)
        try apply(document: document)
    }

    func presentErrorAlert(message: String, info: String?) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = message
        if let info = info, !info.isEmpty {
            alert.informativeText = info
        }
        if let hostWindow = window {
            alert.beginSheetModal(for: hostWindow, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    func apply(document: PaindDocument) throws {
        let convertedFrames: [Frame] = try document.frames.map { persistedFrame in
            let strokes = try persistedFrame.strokes.map { try stroke(from: $0) }
            let images = try persistedFrame.images.map { try image(from: $0) }
            let texts = persistedFrame.texts.map { textBox(from: $0) }
            return Frame(strokes: strokes, images: images, texts: texts)
        }

        frames = convertedFrames.isEmpty ? [Frame()] : convertedFrames
        index = max(0, min(document.currentFrameIndex, frames.count - 1))
        strokes = frames[index].strokes
        images = frames[index].images
        textBoxes = frames[index].texts

        canvasScale = document.canvasScale
        canvasOffset = document.canvasOffset
        penSize = document.penSize
        currentColour = document.currentColour.makeColor()

        undoStack.removeAll()
        redoStack.removeAll()
        currentPath = nil
        mode = .brush
        dragOp = .none
        clearSelection()
        needsDisplay = true
        syncTextEditorFrame()
        window?.makeFirstResponder(self)
    }

    func persistedStroke(from stroke: Stroke) -> PaindStroke {
        PaindStroke(
            colour: PaindColour(color: stroke.colour),
            lineWidth: stroke.path.lineWidth,
            lineCap: Int(stroke.path.lineCapStyle.rawValue),
            lineJoin: Int(stroke.path.lineJoinStyle.rawValue),
            miterLimit: stroke.path.miterLimit,
            segments: segments(from: stroke.path)
        )
    }

    func persistedImage(from image: ImageObject) throws -> PaindImage {
        guard let data = pngData(for: image.image) else {
            throw PaindPersistenceError.imageEncodingFailed
        }
        return PaindImage(frame: image.frame, base64PNG: data.base64EncodedString())
    }

    func persistedText(from text: TextBox) -> PaindTextBox {
        PaindTextBox(
            text: text.text,
            frame: text.frame,
            fontSize: text.fontSize,
            colour: PaindColour(color: text.colour),
            fontName: text.fontName
        )
    }

    func stroke(from persisted: PaindStroke) throws -> Stroke {
        let path = NSBezierPath()
        path.lineWidth = persisted.lineWidth
        if let cap = NSBezierPath.LineCapStyle(rawValue: UInt(persisted.lineCap)) {
            path.lineCapStyle = cap
        }
        if let join = NSBezierPath.LineJoinStyle(rawValue: UInt(persisted.lineJoin)) {
            path.lineJoinStyle = join
        }
        path.miterLimit = persisted.miterLimit
        for segment in persisted.segments {
            switch segment.kind {
            case .moveTo:
                if let point = segment.points.first {
                    path.move(to: point)
                }
            case .lineTo:
                if let point = segment.points.first {
                    path.line(to: point)
                }
            case .curveTo:
                guard segment.points.count == 3 else { continue }
                path.curve(to: segment.points[2], controlPoint1: segment.points[0], controlPoint2: segment.points[1])
            case .close:
                path.close()
            }
        }
        return Stroke(path: path, colour: persisted.colour.makeColor())
    }

    func image(from persisted: PaindImage) throws -> ImageObject {
        guard let data = Data(base64Encoded: persisted.base64PNG),
              let image = NSImage(data: data) else {
            throw PaindPersistenceError.imageDecodingFailed
        }
        return ImageObject(image: image, frame: persisted.frame)
    }

    func textBox(from persisted: PaindTextBox) -> TextBox {
        TextBox(
            text: persisted.text,
            frame: persisted.frame,
            fontSize: persisted.fontSize,
            colour: persisted.colour.makeColor(),
            fontName: persisted.fontName
        )
    }

    func segments(from path: NSBezierPath) -> [PaindPathSegment] {
        var segments: [PaindPathSegment] = []
        for index in 0..<path.elementCount {
            var points = [NSPoint](repeating: .zero, count: 3)
            switch path.element(at: index, associatedPoints: &points) {
            case .moveTo:
                segments.append(PaindPathSegment(kind: .moveTo, points: [points[0]]))
            case .lineTo:
                segments.append(PaindPathSegment(kind: .lineTo, points: [points[0]]))
            case .curveTo:
                segments.append(PaindPathSegment(kind: .curveTo, points: [points[0], points[1], points[2]]))
            case .closePath:
                segments.append(PaindPathSegment(kind: .close, points: []))
            case .quadraticCurveTo:
                let start = path.currentPoint
                let control = points[0]
                let end = points[1]
                let c1 = CGPoint(x: start.x + 2.0 / 3.0 * (control.x - start.x),
                                 y: start.y + 2.0 / 3.0 * (control.y - start.y))
                let c2 = CGPoint(x: end.x + 2.0 / 3.0 * (control.x - end.x),
                                 y: end.y + 2.0 / 3.0 * (control.y - end.y))
                segments.append(PaindPathSegment(kind: .curveTo, points: [c1, c2, end]))
            @unknown default:
                continue
            }
        }
        return segments
    }

    func pngData(for image: NSImage) -> Data? {
        if let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            return bitmap.representation(using: .png, properties: [:])
        }
        if let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff) {
            return bitmap.representation(using: .png, properties: [:])
        }
        return nil
    }
}
