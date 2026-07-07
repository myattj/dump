import Foundation
import PDFKit

/// Extracts text per page from a PDF and writes one markdown file per page
/// under `<storage>/pdfs/<name>/page-NN.md`. Frontmatter records the source
/// path so the user can jump back to the original.
public struct PDFImporter: Sendable {
    private let storage: StoragePreference
    private let writer: MarkdownWriter

    public init(storage: StoragePreference, writer: MarkdownWriter) {
        self.storage = storage
        self.writer = writer
    }

    public struct ImportResult: Sendable, Equatable {
        public let directory: URL
        public let pageURLs: [URL]
        public let extractedPages: Int
        public let totalPages: Int
    }

    public enum PDFError: Error, Equatable {
        case unreadable
        case empty
    }

    public func importPDF(at pdfURL: URL) throws -> ImportResult {
        guard let document = PDFDocument(url: pdfURL) else { throw PDFError.unreadable }
        let pageCount = document.pageCount
        guard pageCount > 0 else { throw PDFError.empty }

        let baseName = pdfURL.deletingPathExtension().lastPathComponent
        let folder = storage.subdirectory(.pdfs).appendingPathComponent(slugify(baseName), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var pageURLs: [URL] = []
        var extracted = 0
        for i in 0..<pageCount {
            guard let page = document.page(at: i) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if text.isEmpty { continue }
            extracted += 1
            let filename = String(format: "page-%02d.md", i + 1)
            let pageURL = folder.appendingPathComponent(filename)
            let fm = Frontmatter(
                id: ULID().value,
                type: .reference,
                createdAt: Date(),
                status: .active,
                tags: ["pdf", baseName.lowercased()],
                source: .pdf,
                title: "\(baseName) — page \(i + 1)",
                pdfPath: pdfURL.path,
                pageNumber: i + 1
            )
            let contents = FrontmatterCodec.encode(fm, body: text)
            try contents.write(to: pageURL, atomically: true, encoding: .utf8)
            pageURLs.append(pageURL)
        }

        return ImportResult(directory: folder, pageURLs: pageURLs, extractedPages: extracted, totalPages: pageCount)
    }

    private func slugify(_ name: String) -> String {
        let lowered = name.lowercased()
        var out = ""
        var lastDash = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
