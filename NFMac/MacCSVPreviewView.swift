import AppKit
import SwiftUI

struct MacCSVPreviewView: NSViewRepresentable {
    let document: MacCSVDocument

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true; scroll.autohidesScrollers = true
        let table = MacCSVTableView()
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.usesAlternatingRowBackgroundColors = true; table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .noColumnAutoresizing; table.allowsColumnReordering = false
        table.rowHeight = 27; table.intercellSpacing = NSSize(width: 12, height: 4)
        table.gridStyleMask = [.solidHorizontalGridLineMask, .solidVerticalGridLineMask]
        table.setAccessibilityIdentifier("attachment.viewer.csv.table")
        let menu = NSMenu()
        let copy = menu.addItem(withTitle: "선택 행 복사", action: #selector(MacCSVTableView.copyRows(_:)), keyEquivalent: "")
        copy.target = table; table.menu = menu
        scroll.documentView = table
        context.coordinator.update(table, document: document)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.document.id != document.id, let table = scroll.documentView as? MacCSVTableView else { return }
        context.coordinator.update(table, document: document)
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var document: MacCSVDocument
        init(document: MacCSVDocument) { self.document = document }
        func update(_ table: MacCSVTableView, document: MacCSVDocument) {
            self.document = document; table.csvDocument = document
            for column in table.tableColumns { table.removeTableColumn(column) }
            let rowNumbers = NSTableColumn(identifier: .init("row")); rowNumbers.title = "행"; rowNumbers.width = 60
            rowNumbers.isEditable = false
            table.addTableColumn(rowNumbers)
            for index in 0..<document.columnCount {
                let column = NSTableColumn(identifier: .init(String(index)))
                column.title = MacCSVDocument.columnTitle(index); column.isEditable = false
                let length = document.rows.prefix(64).map { index < $0.count ? $0[index].prefix(80).count : 0 }.max() ?? 0
                column.width = CGFloat(min(420, max(160, length * 9 + 24))); column.minWidth = 70
                table.addTableColumn(column)
            }
            table.reloadData()
        }
        func numberOfRows(in tableView: NSTableView) -> Int { document.rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard document.rows.indices.contains(row), let column = tableColumn else { return nil }
            let value: String
            if column.identifier.rawValue == "row" { value = String(row + 1) }
            else {
                guard let index = Int(column.identifier.rawValue) else { return nil }
                value = index < document.rows[row].count ? document.rows[row][index] : ""
            }
            let label = (tableView.makeView(withIdentifier: column.identifier, owner: self) as? NSTextField)
                ?? NSTextField(labelWithString: "")
            label.identifier = column.identifier; label.stringValue = value
            label.isEditable = false; label.isSelectable = false
            label.lineBreakMode = .byTruncatingTail; label.maximumNumberOfLines = 1
            label.font = .systemFont(ofSize: 13); label.toolTip = value
            return label
        }
    }
}

final class MacCSVTableView: NSTableView {
    var csvDocument: MacCSVDocument?
    @objc func copy(_ sender: Any?) { copyRows(sender) }
    @objc func copyRows(_ sender: Any?) {
        guard let csvDocument, !selectedRowIndexes.isEmpty else { return }
        let value = csvDocument.copiedRows(selectedRowIndexes)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
    }
    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" { copyRows(nil); return }
        super.keyDown(with: event)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command), event.charactersIgnoringModifiers?.lowercased() == "c" {
            copyRows(nil); return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
