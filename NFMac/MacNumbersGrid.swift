import AppKit
import SwiftUI

final class MacNumbersCellEdit {
    let cell: MacNumbersCell
    let original: String
    var value: String

    init(cell: MacNumbersCell, original: String) {
        self.cell = cell
        self.original = original
        value = original
    }
}

struct MacNumbersGrid: NSViewRepresentable {
    let table: MacNumbersTable
    let revealedCell: MacNumbersCell?
    let revealSequence: Int
    let edit: MacNumbersCellEdit?
    let onBeginEdit: (Int, Int) -> MacNumbersCellEdit?
    let onFinishEdit: () -> Bool
    let onCancelEdit: () -> Void
    let onFind: () -> Void
    let onFindNext: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(grid: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        let view = TableView()
        view.dataSource = context.coordinator
        view.delegate = context.coordinator
        view.columnAutoresizingStyle = .noColumnAutoresizing
        view.allowsColumnReordering = false
        view.selectionHighlightStyle = .none
        view.intercellSpacing = .zero
        view.rowHeight = 26
        view.setAccessibilityIdentifier("numbers.grid")
        view.target = context.coordinator
        view.doubleAction = #selector(Coordinator.editClickedCell(_:))
        view.coordinator = context.coordinator
        scroll.documentView = view

        let rowNumbers = NSTableColumn(identifier: .init("row"))
        rowNumbers.title = ""
        rowNumbers.width = 36
        view.addTableColumn(rowNumbers)
        for index in 0..<table.columnCount {
            let column = NSTableColumn(identifier: .init(String(index)))
            column.title = MacCSVDocument.columnTitle(index)
            column.headerCell.alignment = .center
            column.width = 200
            column.minWidth = 60
            view.addTableColumn(column)
        }
        view.reloadData()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TableView else { return }
        let coordinator = context.coordinator
        let previous = coordinator.grid
        coordinator.grid = self
        view.find = onFind
        view.findNext = onFindNext
        if edit == nil { coordinator.removeEditor(from: view) }
        if previous.table.values != table.values {
            coordinator.updateRowHeights()
            view.reloadData()
        }
        guard let revealedCell, coordinator.lastReveal != revealSequence else { return }
        coordinator.lastReveal = revealSequence
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard coordinator?.lastReveal == revealSequence else { return }
            view?.reveal(revealedCell)
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
        var grid: MacNumbersGrid
        var lastReveal: Int?
        private var rowHeights: [Int: CGFloat] = [:]
        private var draft: MacNumbersCellEdit?
        private var editorScroll: NSScrollView?
        private(set) weak var editor: NSTextView?

        init(grid: MacNumbersGrid) {
            self.grid = grid
            super.init()
            updateRowHeights()
        }

        func updateRowHeights() {
            rowHeights = [:]
            for (index, value) in grid.table.values {
                let lines = value.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).count
                guard lines > 1 else { continue }
                let row = index / grid.table.columnCount
                let height = CGFloat(lines * 16 + 10)
                rowHeights[row] = max(rowHeights[row] ?? 26, height)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { grid.table.rowCount }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { rowHeights[row] ?? 26 }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let columnIndex = tableView.column(withIdentifier: tableColumn.identifier)
            let header = row < grid.table.headerRows
            let cell = (tableView.makeView(withIdentifier: tableColumn.identifier, owner: self) as? CellView) ?? CellView()
            cell.identifier = tableColumn.identifier
            cell.isSelected = (tableView as? TableView)?.isSelected(row: row, column: columnIndex) == true
            cell.configure(
                text: columnIndex > 0 ? grid.table.value(row: row, column: columnIndex - 1) : String(row + 1),
                rowLabel: columnIndex == 0,
                header: header
            )
            if columnIndex > 0 {
                cell.label.setAccessibilityLabel("\(tableColumn.title)\(row + 1) \(cell.label.stringValue)")
            }
            return cell
        }

        @objc func editClickedCell(_ table: TableView) {
            beginEdit(in: table, row: table.clickedRow, column: table.clickedColumn)
        }

        func beginEdit(in table: TableView, row: Int, column: Int, replacingWith event: NSEvent? = nil) {
            guard row >= 0, row < grid.table.rowCount, column > 0, column <= grid.table.columnCount,
                  finishEdit(in: table),
                  let draft = grid.onBeginEdit(row, column - 1) else { return }
            self.draft = draft
            table.selectCell(row: row, column: column)

            let scroll = NSScrollView()
            scroll.drawsBackground = true
            scroll.backgroundColor = row < grid.table.headerRows ? CellView.headerBackground : .textBackgroundColor
            scroll.hasVerticalScroller = true
            scroll.autohidesScrollers = true

            let editor = NSTextView()
            editor.isRichText = false
            editor.allowsUndo = true
            editor.drawsBackground = false
            editor.textColor = .labelColor
            editor.font = .systemFont(ofSize: 13, weight: row < grid.table.headerRows ? .semibold : .regular)
            editor.textContainerInset = NSSize(width: 1, height: 3)
            editor.isHorizontallyResizable = false
            editor.isVerticallyResizable = true
            editor.autoresizingMask = [.width]
            editor.textContainer?.widthTracksTextView = true
            editor.string = draft.value
            editor.delegate = self
            editor.setAccessibilityIdentifier("numbers.cell.editor")
            editor.setAccessibilityLabel("\(draft.cell.address) 셀 편집")
            scroll.documentView = editor
            editorScroll = scroll
            self.editor = editor
            table.addSubview(scroll)
            layoutEditor(in: table)
            editor.setFrameSize(scroll.contentSize)
            table.window?.makeFirstResponder(editor)
            if let event {
                editor.selectAll(nil)
                editor.keyDown(with: event)
            } else {
                editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            }
        }

        func layoutEditor(in table: TableView) {
            guard let draft, let editorScroll else { return }
            let frame = table.frameOfCell(atColumn: draft.cell.column + 1, row: draft.cell.row).insetBy(dx: 2, dy: 2)
            if editorScroll.frame != frame { editorScroll.frame = frame }
        }

        func finishEdit(in table: TableView, restoreFocus: Bool = false) -> Bool {
            guard let draft else { return true }
            if let editor { draft.value = editor.string }
            guard grid.onFinishEdit() else { return false }
            removeEditor(from: table, restoreFocus: restoreFocus)
            return true
        }

        func cancelEdit(in table: TableView) {
            grid.onCancelEdit()
            removeEditor(from: table, restoreFocus: true)
        }

        func removeEditor(from table: TableView, restoreFocus: Bool = false) {
            guard let editorScroll else { return }
            let heldFocus = table.window?.firstResponder === editor
            self.editorScroll = nil
            draft = nil
            editor?.delegate = nil
            editor = nil
            if heldFocus || restoreFocus { table.window?.makeFirstResponder(table) }
            editorScroll.removeFromSuperview()
        }

        func textDidChange(_ notification: Notification) {
            if let editor { draft?.value = editor.string }
        }

        func textDidEndEditing(_ notification: Notification) {
            guard let table = editorScroll?.superview as? TableView else { return }
            _ = finishEdit(in: table)
        }
    }

    private final class CellView: NSTableCellView {
        static let selectionColor = NSColor(srgbRed: 70 / 255, green: 103 / 255, blue: 236 / 255, alpha: 1)
        static var headerBackground: NSColor { .textBackgroundColor.blended(withFraction: 0.14, of: .labelColor) ?? .controlBackgroundColor }
        let label = NSTextField(labelWithString: "")
        var isSelected = false { didSet { if oldValue != isSelected { needsDisplay = true } } }
        private var header = false

        init() {
            super.init(frame: .zero)
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 0
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
                label.topAnchor.constraint(equalTo: topAnchor, constant: 5),
                label.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5)
            ])
        }

        required init?(coder: NSCoder) { nil }

        func configure(text: String, rowLabel: Bool, header: Bool) {
            self.header = header && !rowLabel
            label.stringValue = text
            label.toolTip = text
            label.font = .systemFont(ofSize: rowLabel ? 11 : 13, weight: header ? .semibold : .regular)
            label.textColor = rowLabel ? .secondaryLabelColor : .labelColor
            label.alignment = rowLabel ? .center : .natural
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if header {
                Self.headerBackground.setFill()
                bounds.fill()
            }
            NSColor.separatorColor.setStroke()
            let edges = NSBezierPath()
            let bottom = isFlipped ? bounds.maxY - 0.5 : bounds.minY + 0.5
            let top = isFlipped ? bounds.minY : bounds.maxY
            let right = bounds.maxX - 0.5
            edges.move(to: NSPoint(x: bounds.minX, y: bottom))
            edges.line(to: NSPoint(x: right, y: bottom))
            edges.line(to: NSPoint(x: right, y: top))
            edges.lineWidth = 1
            edges.stroke()
            if isSelected {
                Self.selectionColor.setStroke()
                let outline = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
                outline.lineWidth = 2
                outline.stroke()
            }
        }
    }

    final class TableView: NSTableView {
        var find: (() -> Void)?
        var findNext: ((Bool) -> Void)?
        weak var coordinator: Coordinator?
        private var monitor: Any?
        private var activeRow = -1
        private var activeColumn = 1

        func reveal(_ cell: MacNumbersCell) {
            selectCell(row: cell.row, column: cell.column + 1)
            setAccessibilityValue(cell.address)
        }

        func isSelected(row: Int, column: Int) -> Bool { row == activeRow && column == activeColumn }

        func selectCell(row: Int, column: Int) {
            guard row >= 0, row < numberOfRows, column > 0, column < numberOfColumns else { return }
            if activeRow >= 0 {
                (view(atColumn: activeColumn, row: activeRow, makeIfNecessary: false) as? CellView)?.isSelected = false
            }
            activeRow = row
            activeColumn = column
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            scrollRowToVisible(row)
            scrollColumnToVisible(column)
            (view(atColumn: column, row: row, makeIfNecessary: false) as? CellView)?.isSelected = true
        }

        override func layout() {
            super.layout()
            coordinator?.layoutEditor(in: self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor else { return event }
                let flags = event.modifierFlags
                if let editor = self.coordinator?.editor, window.firstResponder === editor {
                    guard !editor.hasMarkedText() else { return event }
                    if event.keyCode == 53 {
                        self.coordinator?.cancelEdit(in: self)
                        return nil
                    }
                    if (event.keyCode == 36 || event.keyCode == 76),
                       flags.contains(.command) || flags.contains(.control) {
                        editor.insertNewline(nil)
                        return nil
                    }
                    if flags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "s" {
                        _ = self.coordinator?.finishEdit(in: self, restoreFocus: true)
                        return nil
                    }
                } else if window.firstResponder !== self {
                    return event
                }
                guard flags.contains(.command), !flags.contains(.option), !flags.contains(.control) else { return event }
                let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
                let nonLatin = key.unicodeScalars.contains { !$0.isASCII }
                if key == "f" || nonLatin && event.keyCode == 3 { self.find?(); return nil }
                if key == "g" || nonLatin && event.keyCode == 5 { self.findNext?(flags.contains(.shift)); return nil }
                return event
            }
        }

        override func mouseDown(with event: NSEvent) {
            guard coordinator?.finishEdit(in: self) != false else { return }
            let point = convert(event.locationInWindow, from: nil)
            selectCell(row: row(at: point), column: column(at: point))
            super.mouseDown(with: event)
        }

        override func keyDown(with event: NSEvent) {
            guard activeRow >= 0 else { super.keyDown(with: event); return }
            switch event.keyCode {
            case 36, 76:
                coordinator?.beginEdit(in: self, row: activeRow, column: activeColumn)
            case 48:
                selectCell(row: activeRow, column: activeColumn + (event.modifierFlags.contains(.shift) ? -1 : 1))
            case 123:
                selectCell(row: activeRow, column: activeColumn - 1)
            case 124:
                selectCell(row: activeRow, column: activeColumn + 1)
            case 125:
                selectCell(row: activeRow + 1, column: activeColumn)
            case 126:
                selectCell(row: activeRow - 1, column: activeColumn)
            default:
                let flags = event.modifierFlags
                if !flags.contains(.command), !flags.contains(.control),
                   let characters = event.characters, !characters.isEmpty,
                   characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) }) {
                    coordinator?.beginEdit(in: self, row: activeRow, column: activeColumn, replacingWith: event)
                } else {
                    super.keyDown(with: event)
                }
            }
        }
    }
}
