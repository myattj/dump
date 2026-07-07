import XCTest
import PDFKit
import CoreText
@testable import Dump

final class PDFImporterTests: XCTestCase {
    var tempRoot: URL!
    var storage: StoragePreference!
    var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dump-pdf-\(UUID().uuidString)", isDirectory: true)
        defaults = UserDefaults(suiteName: "pdf.\(UUID())")!
        storage = StoragePreference(defaults: defaults, fallback: tempRoot)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempRoot)
        super.tearDown()
    }

    func testImportsEachPageAsMarkdown() throws {
        let pdfURL = try buildPDF(pages: ["Hello world", "Second page"])
        let importer = PDFImporter(storage: storage, writer: MarkdownWriter())
        let result = try importer.importPDF(at: pdfURL)
        XCTAssertEqual(result.totalPages, 2)
        XCTAssertEqual(result.extractedPages, 2)
        XCTAssertEqual(result.pageURLs.count, 2)
        let firstRaw = try String(contentsOf: result.pageURLs[0], encoding: .utf8)
        XCTAssertTrue(firstRaw.contains("Hello world"), "first page should contain its text, got: \(firstRaw)")
        XCTAssertTrue(firstRaw.contains("source: pdf"))
        XCTAssertTrue(firstRaw.contains("page_number: 1"))
    }

    func testUnreadablePDFThrows() {
        let importer = PDFImporter(storage: storage, writer: MarkdownWriter())
        let bogus = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID()).pdf")
        XCTAssertThrowsError(try importer.importPDF(at: bogus))
    }

    private func buildPDF(pages: [String]) throws -> URL {
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let url = tempRoot.appendingPathComponent("sample.pdf")

        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            throw NSError(domain: "PDFImporterTests", code: 1)
        }

        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        for text in pages {
            ctx.beginPDFPage(nil)
            let attr = NSAttributedString(string: text, attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
            ])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 20, y: 350)
            CTLineDraw(line, ctx)
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }
}
