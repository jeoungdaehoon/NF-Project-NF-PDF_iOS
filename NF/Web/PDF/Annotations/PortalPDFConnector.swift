import PDFKit
import UIKit

struct PortalPDFConnectorStyle: Codable, Equatable {
    enum Route: String, Codable, CaseIterable, Identifiable {
        case straight = "직선", elbow = "꺾인선", curve = "곡선"
        var id: Self { self }
    }

    enum Anchor: String, Codable, CaseIterable, Identifiable {
        case automatic = "자동", left = "왼쪽", right = "오른쪽", top = "위", bottom = "아래"
        var id: Self { self }
    }

    var route: Route = .elbow
    var from: Anchor = .automatic
    var to: Anchor = .automatic
    var width: Double = 1.5
    var arrow = true
    var dashed = false
    var color: [Double] = [0.14, 0.39, 0.92, 1]

    func path(from source: CGRect, to target: CGRect, bend: CGPoint? = nil) -> UIBezierPath {
        let sourceCenter = CGPoint(x: source.midX, y: source.midY)
        let targetCenter = CGPoint(x: target.midX, y: target.midY)
        let start = anchor(from, on: source, facing: targetCenter)
        let end = anchor(to, on: target, facing: sourceCenter)
        let center = bend ?? CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let horizontal = abs(end.x - start.x) >= abs(end.y - start.y)
        let first = horizontal ? CGPoint(x: center.x, y: start.y) : CGPoint(x: start.x, y: center.y)
        let second = horizontal ? CGPoint(x: center.x, y: end.y) : CGPoint(x: end.x, y: center.y)
        let line = UIBezierPath()
        line.move(to: start)
        switch route {
        case .straight:
            if let bend { line.addLine(to: bend) }
            line.addLine(to: end)
        case .elbow:
            line.addLine(to: first)
            line.addLine(to: second)
            line.addLine(to: end)
        case .curve:
            line.addCurve(to: end, controlPoint1: first, controlPoint2: second)
        }
        let stroke = dashed ? UIBezierPath(cgPath: line.cgPath.copy(dashingWithPhase: 0, lengths: [CGFloat(width * 4), CGFloat(width * 3)])) : line
        if arrow {
            let reference = (route == .straight ? bend ?? start : second)
            let before = reference == end ? first : reference
            let angle = atan2(end.y - before.y, end.x - before.x)
            let size = CGFloat(min(max(width * 5, 6), 24))
            func wing(_ offset: CGFloat) -> CGPoint {
                CGPoint(x: end.x - size * cos(angle + offset), y: end.y - size * sin(angle + offset))
            }
            stroke.move(to: wing(-0.5))
            stroke.addLine(to: end)
            stroke.addLine(to: wing(0.5))
        }
        return stroke
    }

    private func anchor(_ requested: Anchor, on rect: CGRect, facing other: CGPoint) -> CGPoint {
        let dx = other.x - rect.midX
        let dy = other.y - rect.midY
        let selected: Anchor
        if requested != .automatic {
            selected = requested
        } else if abs(dx / max(rect.width, 1)) >= abs(dy / max(rect.height, 1)) {
            selected = dx >= 0 ? .right : .left
        } else {
            selected = dy >= 0 ? .top : .bottom
        }
        switch selected {
        case .left: return CGPoint(x: rect.minX, y: rect.midY)
        case .right: return CGPoint(x: rect.maxX, y: rect.midY)
        case .top: return CGPoint(x: rect.midX, y: rect.maxY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.minY)
        case .automatic: return CGPoint(x: rect.midX, y: rect.midY)
        }
    }
}

struct PortalPDFConnectorRecord: Codable, Equatable {
    static let key = PDFAnnotationKey(rawValue: "NFConnector")
    let source: UUID
    let destination: UUID
    var style: PortalPDFConnectorStyle
    var bend: CGPoint?

    init(source: UUID, destination: UUID, style: PortalPDFConnectorStyle, bend: CGPoint? = nil) {
        self.source = source
        self.destination = destination
        self.style = style
        self.bend = bend
    }

    init?(annotation: PDFAnnotation) {
        guard let data = annotation.value(forAnnotationKey: Self.key) as? String,
              let bytes = Data(base64Encoded: data),
              let decoded = try? JSONDecoder().decode(Self.self, from: bytes) else { return nil }
        self = decoded
    }

    func save(on annotation: PDFAnnotation) {
        guard let bytes = try? JSONEncoder().encode(self) else { return }
        annotation.setValue(bytes.base64EncodedString(), forAnnotationKey: Self.key)
    }

    func annotation(on page: PDFPage, id: UUID, name: String? = nil) -> PDFAnnotation? {
        let endpoints = page.annotations.filter { PortalPDFConnectorRecord(annotation: $0) == nil }
        func named(_ id: UUID) -> PDFAnnotation? {
            endpoints.first { ($0.value(forAnnotationKey: .name) as? String).flatMap(UUID.init(uuidString:)) == id }
        }
        guard let first = named(source), let last = named(destination) else { return nil }
        let path = style.path(from: first.bounds, to: last.bounds, bend: bend)
        let bounds = path.bounds.insetBy(dx: -4, dy: -4)
        let item = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        item.color = UIColor.portalColor(rgba: style.color) ?? .systemBlue
        let border = PDFBorder()
        border.lineWidth = CGFloat(style.width)
        item.border = border
        path.apply(CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        item.add(path)
        item.setValue(id.uuidString, forAnnotationKey: .name)
        item.userName = name ?? "NF Connector"
        save(on: item)
        return item
    }

    static func refresh(on page: PDFPage) {
        for item in page.annotations {
            guard let record = Self(annotation: item) else { continue }
            let updated = record.annotation(on: page, id: item.portalStableEditID)
            if let updated, updated.bounds == item.bounds,
               (updated.paths ?? []).elementsEqual(item.paths ?? [], by: { CFEqual($0.cgPath, $1.cgPath) }) { continue }
            page.removeAnnotation(item)
            if let updated { page.addAnnotation(updated) }
        }
    }
}

struct PortalPDFConnectorEditCommand {
    enum Action { case style(PortalPDFConnectorStyle), resetBend, remove }
    let id = UUID()
    let action: Action
}

extension PortalPDFKitView.Coordinator {
    func configureConnector(
        enabled: Bool,
        style: PortalPDFConnectorStyle,
        command: PortalPDFConnectorEditCommand?,
        onSelected: ((PortalPDFConnectorStyle?) -> Void)?
    ) {
        connectorSelectionChanged = onSelected
        connectorEnabled = enabled
        connectorStyle = style
        guard enabled else {
            connectorSource = nil
            selectedConnector = nil
            return
        }
        guard let command, command.id != connectorEditID else { return }
        connectorEditID = command.id
        guard let connector = selectedConnector, let page = connector.page else { return }
        DispatchQueue.main.async { [weak self, weak connector, weak page] in
            guard let self, let connector, let page, connector.page === page else { return }
            switch command.action {
            case .style(let style): replaceConnector(connector, on: page) { $0.style = style }
            case .resetBend: replaceConnector(connector, on: page) { $0.bend = nil }
            case .remove:
                page.removeAnnotation(connector)
                selectConnector(nil)
                onDocumentChanged(changedPages: [page])
            }
        }
    }

    func handleConnectorTap(on page: PDFPage, at point: CGPoint) {
        let width = 12 / currentPDFScaleFactor
        if let connector = page.annotations.reversed().first(where: { item in
            guard PortalPDFConnectorRecord(annotation: item) != nil, let paths = item.paths else { return false }
            let local = CGPoint(x: point.x - item.bounds.minX, y: point.y - item.bounds.minY)
            return paths.contains { $0.cgPath.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round,
                                                   miterLimit: 1).contains(local) }
        }) {
            connectorSource = nil
            selectConnector(connector)
            return
        }
        guard let target = PortalPDFEditableAnnotationHitTesting.topmostSelectableObject(
            in: page.annotations, at: point, scaleFactor: currentPDFScaleFactor
        ) else {
            connectorSource = nil
            selectConnector(nil)
            return
        }
        if let source = connectorSource, source.page === page, source !== target {
            let record = PortalPDFConnectorRecord(source: source.portalStableEditID,
                destination: target.portalStableEditID, style: connectorStyle)
            if let item = record.annotation(on: page, id: UUID()) {
                page.addAnnotation(item)
                connectorSource = nil
                selectConnector(item)
                onDocumentChanged(changedPages: [page])
            }
        } else {
            connectorSource = target
            selectConnector(nil)
        }
    }

    private func selectConnector(_ annotation: PDFAnnotation?) {
        selectedConnector = annotation
        connectorSelectionChanged?(annotation.flatMap { PortalPDFConnectorRecord(annotation: $0) }?.style)
    }

    func replaceConnector(_ item: PDFAnnotation, on page: PDFPage, mutate: (inout PortalPDFConnectorRecord) -> Void) {
        guard var record = PortalPDFConnectorRecord(annotation: item) else { return }
        mutate(&record)
        guard let replacement = record.annotation(on: page, id: item.portalStableEditID) else { return }
        page.removeAnnotation(item)
        page.addAnnotation(replacement)
        selectConnector(replacement)
        onDocumentChanged(changedPages: [page])
    }
}
