import PDFKit
import XCTest
@testable import NF

@MainActor
final class PortalPDFNoteWorkspaceTests: XCTestCase {
    func testPopupPlacementFollowsPagePanAndZoom() {
        let initialAnchor = CGRect(x: 40, y: 60, width: 20, height: 20)
        let frame = CGRect(x: 80, y: 90, width: 200, height: 140)
        let placement = PDFNotePlacement(frame: frame, anchor: initialAnchor, scale: 1)
        let zoomedAnchor = CGRect(x: 100, y: 150, width: 40, height: 40)
        XCTAssertEqual(placement.screenFrame(anchor: zoomedAnchor, scale: 2),
                       CGRect(x: 180, y: 210, width: 400, height: 280))
        XCTAssertEqual(placement.contentScale(at: 2), 2)

        let resized = PDFNotePlacement(frame: CGRect(x: 70, y: 90, width: 210, height: 140),
                                       anchor: initialAnchor, scale: 1)
        let rescaled = PDFNotePlacement(frame: CGRect(x: 70, y: 90, width: 210, height: 140),
                                        anchor: initialAnchor, scale: 1, contentScale: 1.25)
        XCTAssertEqual(resized.contentScale(at: 2), 2)
        XCTAssertEqual(rescaled.contentScale(at: 2), 2.5)
    }

    func testLinkSurvivesPDFSerializationAndFollowsItsObject() throws {
        let state = PDFNoteWorkspaceState(origin: URL(string: "https://example.test")!)
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let id = UUID()
        let objectID = UUID()
        let annotation = PDFAnnotation(bounds: CGRect(x: 40, y: 60, width: 140, height: 80), forType: .link, withProperties: nil)
        var parts = try XCTUnwrap(URLComponents(url: XCTUnwrap(state.noteURL("example-note")), resolvingAgainstBaseURL: false))
        parts.fragment = id.uuidString
        annotation.url = parts.url
        annotation.contents = "nf-note-object:" + objectID.uuidString
        page.addAnnotation(annotation)
        let moved = annotation.bounds.offsetBy(dx: 30, dy: 10)
        XCTAssertTrue(PDFNoteWorkspaceState.refreshObjectLinks(on: page) { $0 == objectID ? moved : nil })

        let restored = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
        let restoredPage = try XCTUnwrap(restored.page(at: 0))
        let anchor = try XCTUnwrap(state.anchors(on: restoredPage).first)
        XCTAssertEqual(anchor.bounds, moved)
        XCTAssertEqual(anchor.id, id.uuidString)
        XCTAssertEqual(anchor.note, "example-note")
        PDFNoteWorkspaceState.rekeyLinks(on: restoredPage)
        XCTAssertNotEqual(state.anchors(on: restoredPage).first?.id, anchor.id)
    }

    func testMarkerGeometryAndLineStyleStayOnThePDFAnnotation() throws {
        let state = PDFNoteWorkspaceState(origin: URL(string: "https://example.test")!)
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let id = UUID().uuidString
        let initial = CGRect(x: 80, y: 150, width: 25, height: 25)
        let annotation = PDFAnnotation(bounds: initial, forType: .link, withProperties: nil)
        var parts = try XCTUnwrap(URLComponents(url: XCTUnwrap(state.noteURL("example-note")), resolvingAgainstBaseURL: false))
        parts.fragment = id
        parts.queryItems?.append(contentsOf: [.init(name: "marker", value: "1"), .init(name: "page", value: "/custom/example-note")])
        annotation.url = parts.url
        annotation.contents = "nf-note-marker"
        page.addAnnotation(annotation)
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        view.document = document
        view.layoutIfNeeded()
        state.canvas = view
        state.changeDocument = { _, edit in edit() }
        state.editingMarkerID = id

        XCTAssertEqual(state.configuredMarkerStyle.lineWidth, 1.5)
        state.configuredMarkerStyle = PDFDocumentMarkerStyle(lineRGB: 0x265ED5, lineWidth: 4)
        let edited = CGRect(x: 115, y: 165, width: 42, height: 42)
        state.moveDocumentMarker(id, to: state.viewFrame(edited, on: page))

        let restored = try XCTUnwrap(PDFDocument(data: XCTUnwrap(document.dataRepresentation())))
        let marker = try XCTUnwrap(state.anchors(on: XCTUnwrap(restored.page(at: 0))).first)
        XCTAssertEqual(marker.id, id)
        XCTAssertEqual(marker.bounds.minX, edited.minX, accuracy: 0.01)
        XCTAssertEqual(marker.bounds.minY, edited.minY, accuracy: 0.01)
        XCTAssertEqual(marker.bounds.width, edited.width, accuracy: 0.01)
        XCTAssertTrue(marker.isDocumentMarker)
        XCTAssertEqual(marker.markerStyle.lineRGB, 0x265ED5)
        XCTAssertEqual(marker.markerStyle.lineWidth, 4)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(annotation.url), resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "page" }?.value, "/custom/example-note")
    }

    func testPreviousMarkerPreferencesDecodeWithDefaultLineStyle() throws {
        let style = try JSONDecoder().decode(PDFDocumentMarkerStyle.self, from: Data(#"{"icon":"doc.text","rgb":255}"#.utf8))
        XCTAssertEqual(style.rgb, 255)
        XCTAssertNil(style.lineRGB)
        XCTAssertEqual(style.lineWidth, 1.5)

        let frame = CGRect(x: 50, y: 70, width: 180, height: 160)
        XCTAssertGreaterThan(PDFNotePlacement.zoomedFrame(frame, by: CGSize(width: 40, height: -40)).width, frame.width)
        XCTAssertLessThan(PDFNotePlacement.zoomedFrame(frame, by: CGSize(width: -40, height: 40)).width, frame.width)
    }
}
