# Paind is a lightweight Cocoa drawing pad with frame-based sketching, text boxes, and quick key-driven tools.

| How to use it | What it does |
| --- | --- |
| Launch `PaindApp` | Opens the Paind drawing window ready in brush mode |
| Press `i` | Drops a text box at the cursor and enters inline text editing |
| Double-click a text box | Re-enters edit mode for that text without creating a new box |
| Single-click a text box | Selects it so you can move, resize, recolor, or resize the font |
| Drag with left mouse | Paints when in brush mode or moves/resizes the active selection depending on handles |
| Hold and drag left mouse on empty canvas | Draws a marquee to select strokes, images, and text boxes |
| Press numbers `1`–`9` | Changes brush width; when text is selected, maps to larger font sizes |
| Press `w g c y o p P B r b` | Switches brush color; when text is selected, recolors the text |
| Press `u`, `⌘Z`, or `⌘Y` | Undo (`u`/`⌘Z`) or redo (`⌘Y`) the last committed action |
| Press `⌘⇧Z` or `ctrl-r` | Redo the most recently undone action |
| Press `Esc` | Returns to normal selection mode and closes active text editors |
| Press `←` / `→` | Moves to the previous or next animation frame |
| Press `Space` | Inserts a blank frame after the current one |
| Press `⇧Space` | Duplicates the current frame (strokes/images/text) into a new frame to the right |
| Press `Enter` | Toggles onion-skinning of the previous frame |
| Press `⌘V` | Pastes an image from the clipboard at the cursor |
| Middle-click drag | Pans the canvas |
| Scroll wheel or trackpad pinch | Zooms the canvas around the pointer |
| Right-click (drag) | Erases the stroke, image, or text box under the cursor |
| Delete key when a selection exists | Removes the selected strokes, images, or text boxes |

## Install on a New Mac
1. Copy/clone this folder onto the new machine.
2. In Terminal (within this folder) run `swiftc -o PaindApp Paind.swift App/DrawingView.swift App/CanvasModel.swift -framework Cocoa -framework SwiftUI`.
3. Drag the resulting `PaindApp` binary wherever you like (e.g., `/Applications`), launch it once so macOS registers it as an app, then pin it to the Dock or find it in Spotlight whenever needed.
