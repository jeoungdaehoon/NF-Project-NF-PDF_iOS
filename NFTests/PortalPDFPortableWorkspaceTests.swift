import Foundation
import PDFKit
import Testing
import UIKit
@testable import NF

@Suite(.serialized)
@MainActor
struct PortalPDFPortableWorkspaceTests {
    private func androidFixture() throws -> Data {
        try #require(Data(base64Encoded: "JVBERi0xLjMKJeLjz9MKMSAwIG9iago8PAovUHJvZHVjZXIgKHB5cGRmKQo+PgplbmRvYmoKMiAwIG9iago8PAovVHlwZSAvUGFnZXMKL0NvdW50IDEKL0tpZHMgWyA0IDAgUiBdCj4+CmVuZG9iagozIDAgb2JqCjw8Ci9UeXBlIC9DYXRhbG9nCi9QYWdlcyAyIDAgUgovT3V0bGluZXMgOCAwIFIKL05hbWVzIDExIDAgUgo+PgplbmRvYmoKNCAwIG9iago8PAovQ29udGVudHMgNSAwIFIKL01lZGlhQm94IFsgMCAwIDYxMiA3OTIgXQovUmVzb3VyY2VzIDw8Ci9Gb250IDYgMCBSCi9Qcm9jU2V0IFsgL1BERiAvVGV4dCAvSW1hZ2VCIC9JbWFnZUMgL0ltYWdlSSBdCj4+Ci9Sb3RhdGUgMAovVHJhbnMgPDwKPj4KL1R5cGUgL1BhZ2UKL1BhcmVudCAyIDAgUgo+PgplbmRvYmoKNSAwIG9iago8PAovRmlsdGVyIFsgL0FTQ0lJODVEZWNvZGUgL0ZsYXRlRGVjb2RlIF0KL0xlbmd0aCAxMTkKPj4Kc3RyZWFtCkdhcFFoMEU9RiwwVVxIM1RccE5ZVF5RS2s/dGM+SVAsO1cjVTFeMjNpaFBFTV8/Q1c0S0lTaTs6YlhnXzpeRzBDZC1yXjI5W0NwVWJZXWNgOWU4b144NS4vdDw9IVBgZG82VXA7QChZT2t1NkxBISUobmQ1UX4+CmVuZHN0cmVhbQplbmRvYmoKNiAwIG9iago8PAovRjEgNyAwIFIKPj4KZW5kb2JqCjcgMCBvYmoKPDwKL0Jhc2VGb250IC9IZWx2ZXRpY2EKL0VuY29kaW5nIC9XaW5BbnNpRW5jb2RpbmcKL05hbWUgL0YxCi9TdWJ0eXBlIC9UeXBlMQovVHlwZSAvRm9udAo+PgplbmRvYmoKOCAwIG9iago8PAo+PgplbmRvYmoKOSAwIG9iago8PAovVHlwZSAvRW1iZWRkZWRGaWxlCi9MZW5ndGggMTM1OQo+PgpzdHJlYW0KJVBERi0xLjMKJZOMi54gUmVwb3J0TGFiIEdlbmVyYXRlZCBQREYgZG9jdW1lbnQgKG9wZW5zb3VyY2UpCjEgMCBvYmoKPDwKL0YxIDIgMCBSCj4+CmVuZG9iagoyIDAgb2JqCjw8Ci9CYXNlRm9udCAvSGVsdmV0aWNhIC9FbmNvZGluZyAvV2luQW5zaUVuY29kaW5nIC9OYW1lIC9GMSAvU3VidHlwZSAvVHlwZTEgL1R5cGUgL0ZvbnQKPj4KZW5kb2JqCjMgMCBvYmoKPDwKL0NvbnRlbnRzIDcgMCBSIC9NZWRpYUJveCBbIDAgMCA2MTIgNzkyIF0gL1BhcmVudCA2IDAgUiAvUmVzb3VyY2VzIDw8Ci9Gb250IDEgMCBSIC9Qcm9jU2V0IFsgL1BERiAvVGV4dCAvSW1hZ2VCIC9JbWFnZUMgL0ltYWdlSSBdCj4+IC9Sb3RhdGUgMCAvVHJhbnMgPDwKCj4+IAogIC9UeXBlIC9QYWdlCj4+CmVuZG9iago0IDAgb2JqCjw8Ci9QYWdlTW9kZSAvVXNlTm9uZSAvUGFnZXMgNiAwIFIgL1R5cGUgL0NhdGFsb2cKPj4KZW5kb2JqCjUgMCBvYmoKPDwKL0F1dGhvciAoYW5vbnltb3VzKSAvQ3JlYXRpb25EYXRlIChEOjIwMjYxMDI5MjEzNTE1KzA5JzAwJykgL0NyZWF0b3IgKGFub255bW91cykgL0tleXdvcmRzICgpIC9Nb2REYXRlIChEOjIwMjYxMDI5MjEzNTE1KzA5JzAwJykgL1Byb2R1Y2VyIChSZXBvcnRMYWIgUERGIExpYnJhcnkgLSBcKG9wZW5zb3VyY2VcKSkgCiAgL1N1YmplY3QgKHVuc3BlY2lmaWVkKSAvVGl0bGUgKHVudGl0bGVkKSAvVHJhcHBlZCAvRmFsc2UKPj4KZW5kb2JqCjYgMCBvYmoKPDwKL0NvdW50IDEgL0tpZHMgWyAzIDAgUiBdIC9UeXBlIC9QYWdlcwo+PgplbmRvYmoKNyAwIG9iago8PAovRmlsdGVyIFsgL0FTQ0lJODVEZWNvZGUgL0ZsYXRlRGVjb2RlIF0gL0xlbmd0aCAxMTkKPj4Kc3RyZWFtCkdhcFFoMEU9RiwwVVxIM1RccE5ZVF5RS2s/dGM+SVAsO1cjVTFeMjNpaFBFTV8/Q1c0S0lTaTs6YlhnXzpeRzBDZC1yXjI5W0NwVWJZXWNgOWU4b144NS4vdDw9IVBgZG82VXA7QChZT2t1NkxBISUobmQ1UX4+ZW5kc3RyZWFtCmVuZG9iagp4cmVmCjAgOAowMDAwMDAwMDAwIDY1NTM1IGYgCjAwMDAwMDAwNjEgMDAwMDAgbiAKMDAwMDAwMDA5MiAwMDAwMCBuIAowMDAwMDAwMTk5IDAwMDAwIG4gCjAwMDAwMDAzOTIgMDAwMDAgbiAKMDAwMDAwMDQ2MCAwMDAwMCBuIAowMDAwMDAwNzIxIDAwMDAwIG4gCjAwMDAwMDA3ODAgMDAwMDAgbiAKdHJhaWxlcgo8PAovSUQgCls8NjBjYWUzMGIyMGZkOWMzYmJmNmVkYWU3NGM2MjU3OWM+PDYwY2FlMzBiMjBmZDljM2JiZjZlZGFlNzRjNjI1NzljPl0KJSBSZXBvcnRMYWIgZ2VuZXJhdGVkIFBERiBkb2N1bWVudCAtLSBkaWdlc3QgKG9wZW5zb3VyY2UpCgovSW5mbyA1IDAgUgovUm9vdCA0IDAgUgovU2l6ZSA4Cj4+CnN0YXJ0eHJlZgo5ODkKJSVFT0YKCmVuZHN0cmVhbQplbmRvYmoKMTAgMCBvYmoKPDwKL1R5cGUgL0ZpbGVzcGVjCi9GIChuZlwwNTVzb3VyY2VcMDU2cGRmKQovRUYgPDwKL0YgOSAwIFIKPj4KPj4KZW5kb2JqCjExIDAgb2JqCjw8Ci9FbWJlZGRlZEZpbGVzIDEyIDAgUgo+PgplbmRvYmoKMTIgMCBvYmoKPDwKL05hbWVzIFsgKG5mXDA1NXNvdXJjZVwwNTZwZGYpIDEwIDAgUiAobmZcMDU1d29ya3NwYWNlXDA1Nmpzb24pIDE0IDAgUiBdCj4+CmVuZG9iagoxMyAwIG9iago8PAovVHlwZSAvRW1iZWRkZWRGaWxlCi9MZW5ndGggMTM1Ngo+PgpzdHJlYW0KeyJmb3JtYXQiOiAibm90ZWZyZWUtcGRmLXdvcmtzcGFjZSIsICJ2ZXJzaW9uIjogMSwgImlkIjogIjdiYjM0MzdkLTRkMDYtNDZiYy04YTBkLWJkYzA2OTk5MmE5YSIsICJ0aXRsZSI6ICJBbmRyb2lkIGZpeHR1cmUiLCAicmV2aXNpb24iOiAiYWM4OTYyNzAtYWE2Ni00M2M2LWJjNzAtZmYxNDFjNTc3NzBkIiwgInNvdXJjZVNoYTI1NiI6ICIyYTViMDc1MjY3MzE4OWUzMGU1YmMyYzJkMWZjYjgwZWNmNGQ2ZGVjOGZiYjNiNGNlYTI1N2M5NGRlNDRhNGYzIiwgImNsb3VkRG9jdW1lbnRJRCI6ICIwNGMyYWZjMy1hNWJmLTQzNmEtOTc2My03Y2E1OWU4ZGIwZjciLCAiY2xvdWRWZXJzaW9uIjogImY3NjFhMjM4LWEyZDYtNDhjNi1hZjhkLWZkNDgwZDBmZGRkOCIsICJwYWdlcyI6IFt7ImlkIjogImIwNmQwMGQ5LTc3YjUtNGUyMC1hNzVkLWM5OTQyZDQyMmY5NiIsICJzb3VyY2VQYWdlIjogMCwgIndpZHRoIjogNjEyLCAiaGVpZ2h0IjogNzkyLCAiZmF2b3JpdGUiOiB0cnVlLCAib2JqZWN0cyI6IFt7ImlkIjogIjE3ZWVjMmI5LWFlYzctNDM5YS1iYTA1LTAwZDM1ZTBlYTQyNyIsICJraW5kIjogInRleHQiLCAiYm91bmRzIjogeyJ4IjogMzAsICJ5IjogODAsICJ3aWR0aCI6IDI1MCwgImhlaWdodCI6IDUwfSwgInJvdGF0aW9uIjogMCwgImNvbG9yIjogLTE2Nzc3MjE2LCAiZmlsbENvbG9yIjogMCwgImZvbnRTaXplIjogMTYsICJmb250RmFtaWx5IjogInNhbnMtc2VyaWYiLCAidGV4dCI6ICJBbmRyb2lkIHJpY2ggdGV4dCIsICJib2xkIjogZmFsc2UsICJpdGFsaWMiOiBmYWxzZSwgInVuZGVybGluZSI6IGZhbHNlLCAic3RyaWtlVGhyb3VnaCI6IGZhbHNlLCAiYWxpZ25tZW50IjogImxlZnQiLCAibGluZVdpZHRoIjogMiwgInRleHRSdW5zIjogW3sic3RhcnQiOiAwLCAiZW5kIjogNywgImNvbG9yIjogLTY1NTM2LCAiZm9udFNpemUiOiAyMiwgImZvbnRGYW1pbHkiOiAic2Fucy1zZXJpZiIsICJib2xkIjogdHJ1ZSwgIml0YWxpYyI6IGZhbHNlLCAidW5kZXJsaW5lIjogdHJ1ZSwgInN0cmlrZVRocm91Z2giOiBmYWxzZX1dfSwgeyJpZCI6ICIzNzBjZGRmMi1lMGQ5LTQxNjItOTM4Ny1iMmQ1ZDQ1NTMyZjgiLCAia2luZCI6ICJpbmsiLCAiYm91bmRzIjogeyJ4IjogMzAsICJ5IjogMTYwLCAid2lkdGgiOiAxNzAsICJoZWlnaHQiOiAyMH0sICJwb2ludHMiOiBbWzMwLCAxNjAsIDAuM10sIFs2MCwgMTcwLCAwLjZdLCBbMTYwLCAxNzAsIDAuN10sIFsyMDAsIDE4MCwgMS4wXV0sICJzdHJva2VCcmVha3MiOiBbMl0sICJwcmVzc3VyZUVuYWJsZWQiOiB0cnVlLCAibGluZVdpZHRoIjogMywgImNvbG9yIjogLTE0MzkyMzMxLCAicm90YXRpb24iOiAwLCAiZm9udFNpemUiOiAxNn1dfV19CmVuZHN0cmVhbQplbmRvYmoKMTQgMCBvYmoKPDwKL1R5cGUgL0ZpbGVzcGVjCi9GIChuZlwwNTV3b3Jrc3BhY2VcMDU2anNvbikKL0VGIDw8Ci9GIDEzIDAgUgo+Pgo+PgplbmRvYmoKeHJlZgowIDE1CjAwMDAwMDAwMDAgNjU1MzUgZiAKMDAwMDAwMDAxNSAwMDAwMCBuIAowMDAwMDAwMDU0IDAwMDAwIG4gCjAwMDAwMDAxMTMgMDAwMDAgbiAKMDAwMDAwMDE5MiAwMDAwMCBuIAowMDAwMDAwMzgxIDAwMDAwIG4gCjAwMDAwMDA1OTEgMDAwMDAgbiAKMDAwMDAwMDYyMiAwMDAwMCBuIAowMDAwMDAwNzI5IDAwMDAwIG4gCjAwMDAwMDA3NTAgMDAwMDAgbiAKMDAwMDAwMjE4MSAwMDAwMCBuIAowMDAwMDAyMjYzIDAwMDAwIG4gCjAwMDAwMDIzMDcgMDAwMDAgbiAKMDAwMDAwMjQwMiAwMDAwMCBuIAowMDAwMDAzODMxIDAwMDAwIG4gCnRyYWlsZXIKPDwKL1NpemUgMTUKL1Jvb3QgMyAwIFIKL0luZm8gMSAwIFIKPj4Kc3RhcnR4cmVmCjM5MTgKJSVFT0YK"))
    }
    @Test func importsAndroidEmbeddedOriginalAndEditableObjects() throws {
        let document = try #require(PortalPDFPortableWorkspace.restore(data: androidFixture()))
        #expect(document.pageCount == 1)
        #expect(document.string?.contains("Original searchable PDF") == true)
        let edits = PortalPDFPageEditDocument.capture(from: document)
        let objects = try #require(edits.page(at: 0)?.objects)
        #expect(objects.map(\.kind) == [.text, .pressureInk])
        #expect(objects[0].text?.text == "Android rich text")
        #expect(objects[0].text?.attributedTextRTF != nil)
        let fragments = try #require(objects[1].ink?.pressureFragments)
        #expect(fragments.count == 2)
        #expect(abs(fragments[0].points[0].x - 30) < 0.01)
        #expect(abs(fragments[0].points[0].y - 632) < 0.01)
        #expect(fragments[0].pressures == [0.3, 0.6])
    }
    @Test func reexportKeepsOriginalTextAndSeparatedStrokesEditable() throws {
        let document = try #require(PortalPDFPortableWorkspace.restore(data: androidFixture()))
        let data = try #require(PortalPDFPortableWorkspace.export(document: document))
        let restored = try #require(PortalPDFPortableWorkspace.restore(data: data))
        #expect(restored.string?.contains("Original searchable PDF") == true)
        let objects = try #require(PortalPDFPageEditDocument.capture(from: restored).page(at: 0)?.objects)
        #expect(objects.count == 2)
        #expect(objects[1].ink?.pressureFragments.count == 2)
        let reference = try #require(PortalPDFPortableWorkspace.cloudReference(data: data))
        #expect(!reference.id.isEmpty)
        #expect(UUID(uuidString: reference.version) != nil)
    }
    @Test func duplicatePagesReceiveIndependentPortableObjectIdentities() throws {
        let document = try #require(PortalPDFPortableWorkspace.restore(data: androidFixture()))
        let duplicateData = try #require(document.portalEditableDataRepresentation())
        let duplicate = try #require(PDFDocument(data:duplicateData))
        _ = duplicate.restorePortalEditableAnnotations()
        let copy = try #require(duplicate.page(at:0))
        document.insert(copy,at:1)
        let data = try #require(PortalPDFPortableWorkspace.export(document:document))
        let flat = try #require(PDFDocument(data:data))
        let contents = try #require(flat.page(at:0)?.annotations.first { $0.contents?.hasPrefix(PortalPDFPortableWorkspace.marker) == true }?.contents)
        let root = try #require(try JSONSerialization.jsonObject(with:Data(contents.dropFirst(PortalPDFPortableWorkspace.marker.count).utf8)) as? [String:Any])
        let pages = try #require(root["pages"] as? [[String:Any]])
        #expect(pages.count == 2)
        #expect(pages[0]["id"] as? String != pages[1]["id"] as? String)
        let ids = pages.flatMap { $0["objects"] as? [[String:Any]] ?? [] }.compactMap { $0["id"] as? String }
        #expect(Set(ids).count == ids.count)
        #expect(PortalPDFPortableWorkspace.restore(data:data)?.pageCount == 2)
    }
    @Test func deletingFirstPageAndSavingRetainsTheImmutableSource() throws {
        func sourceHash(_ data:Data) throws -> String {
            let pdf=try #require(PDFDocument(data:data))
            let contents=try #require(pdf.page(at:0)?.annotations.first {$0.contents?.hasPrefix(PortalPDFPortableWorkspace.marker)==true}?.contents)
            let root=try #require(try JSONSerialization.jsonObject(with:Data(contents.dropFirst(PortalPDFPortableWorkspace.marker.count).utf8)) as? [String:Any])
            return try #require(root["sourceSha256"] as? String)
        }
        let document=try #require(PortalPDFPortableWorkspace.restore(data:androidFixture()))
        let second=try #require(PortalPDFPortableWorkspace.restore(data:androidFixture())?.page(at:0))
        // Keep exactly one source metadata marker, as in a real duplicated document.
        second.annotations.filter {$0.contents=="NF_ORIGINAL_PDF_V1"}.forEach(second.removeAnnotation)
        document.insert(second,at:1)
        let before=try #require(PortalPDFPortableWorkspace.export(document:document))
        document.removePage(at:0)
        let base=try #require(document.portalBaseDataRepresentation())
        let reloaded=try #require(PDFDocument(data:base))
        let after=try #require(PortalPDFPortableWorkspace.export(document:reloaded))
        #expect(try sourceHash(before)==sourceHash(after))
        #expect(PortalPDFPortableWorkspace.restore(data:after)?.pageCount==1)
    }
    @Test func rejectsOriginalHashMismatch() throws {
        let document = try #require(PortalPDFPortableWorkspace.restore(data: androidFixture()))
        let data = try #require(PortalPDFPortableWorkspace.export(document:document))
        let flat = try #require(PDFDocument(data:data))
        let annotation = try #require(flat.page(at:0)?.annotations.first { $0.contents?.hasPrefix(PortalPDFPortableWorkspace.marker) == true })
        annotation.setValue(Data("bad PDF".utf8).base64EncodedString(),forAnnotationKey:PDFAnnotationKey(rawValue:"NFSource"))
        #expect(PortalPDFPortableWorkspace.restore(data: try #require(flat.dataRepresentation())) == nil)
    }
}
