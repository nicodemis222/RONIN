import Foundation
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
class MeetingPrepViewModel: ObservableObject {
    @Published var title: String = UserDefaults.standard.string(forKey: "ronin.prep.title") ?? "" {
        didSet { UserDefaults.standard.set(title, forKey: "ronin.prep.title") }
    }
    @Published var goal: String = UserDefaults.standard.string(forKey: "ronin.prep.goal") ?? "" {
        didSet { UserDefaults.standard.set(goal, forKey: "ronin.prep.goal") }
    }
    @Published var constraints: String = UserDefaults.standard.string(forKey: "ronin.prep.constraints") ?? "" {
        didSet { UserDefaults.standard.set(constraints, forKey: "ronin.prep.constraints") }
    }
    @Published var noteFiles: [NotePayload] = []
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?

    private let backendAPI = BackendAPIService()

    // MARK: - Supported File Types

    static let supportedNoteTypes: [UTType] = [
        .plainText,
        .pdf,
        .commaSeparatedText,
        UTType(filenameExtension: "md") ?? .plainText,
        UTType(filenameExtension: "docx") ?? .data,
        UTType(filenameExtension: "xlsx") ?? .data,
        UTType(filenameExtension: "pptx") ?? .data,
        UTType(filenameExtension: "doc") ?? .data,
        UTType(filenameExtension: "xls") ?? .data,
        UTType(filenameExtension: "ppt") ?? .data,
    ]

    static func iconForFile(named name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "docx", "doc": return "doc.text.fill"
        case "xlsx", "xls", "csv": return "tablecells"
        case "pptx", "ppt": return "rectangle.on.rectangle"
        default: return "doc.text"
        }
    }

    /// Set the auth token received from BackendProcessService.
    func setAuthToken(_ token: String) {
        backendAPI.authToken = token
    }

    var isValid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty &&
        !goal.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func canStart(backendStatus: BackendProcessService.Status) -> Bool {
        isValid && !isLoading && backendStatus.isRunning
    }

    func addNoteFiles(urls: [URL]) {
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer {
                if accessed { url.stopAccessingSecurityScopedResource() }
            }

            if let content = readFileContent(url: url) {
                if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errorMessage = "\(url.lastPathComponent) is empty."
                    continue
                }
                noteFiles.append(NotePayload(
                    name: url.lastPathComponent,
                    content: content
                ))
            } else {
                errorMessage = "Could not read \(url.lastPathComponent). Supported: PDF, Word, Excel, PowerPoint, text, CSV."
            }
        }
    }

    // MARK: - File Reading

    private func readFileContent(url: URL) -> String? {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return readPDF(url: url)
        case "docx":
            return readOOXML(url: url, xmlPath: "word/document.xml")
        case "xlsx":
            return readXLSX(url: url)
        case "pptx":
            return readPPTX(url: url)
        case "csv":
            return readPlainText(url: url)
        case "doc", "xls", "ppt":
            // Legacy binary Office formats — attempt plain text extraction
            return readPlainText(url: url)
        default:
            return readPlainText(url: url)
        }
    }

    private func readPlainText(url: URL) -> String? {
        let encodings: [String.Encoding] = [.utf8, .macOSRoman, .ascii, .isoLatin1]
        for encoding in encodings {
            if let content = try? String(contentsOf: url, encoding: encoding) {
                return content
            }
        }
        return nil
    }

    private func readPDF(url: URL) -> String? {
        guard let document = PDFDocument(url: url) else { return nil }
        var text = ""
        for i in 0..<document.pageCount {
            if let page = document.page(at: i), let pageText = page.string {
                text += pageText + "\n"
            }
        }
        return text.isEmpty ? nil : text
    }

    /// Read text from an OOXML file (ZIP containing XML).
    /// Used for .docx (word/document.xml).
    private func readOOXML(url: URL, xmlPath: String) -> String? {
        guard let archive = openZipArchive(url: url),
              let xmlData = extractFileFromZip(archive: archive, path: xmlPath) else {
            return nil
        }
        return stripXMLTags(xmlData)
    }

    /// Read text from an .xlsx file by extracting shared strings and sheet data.
    private func readXLSX(url: URL) -> String? {
        guard let archive = openZipArchive(url: url) else { return nil }

        // Read shared strings (where cell text values are stored)
        var sharedStrings: [String] = []
        if let ssData = extractFileFromZip(archive: archive, path: "xl/sharedStrings.xml") {
            let parser = SharedStringsParser(data: ssData)
            sharedStrings = parser.parse()
        }

        // Read the first sheet
        guard let sheetData = extractFileFromZip(archive: archive, path: "xl/worksheets/sheet1.xml") else {
            return sharedStrings.joined(separator: "\n")
        }

        let sheetParser = SheetParser(data: sheetData, sharedStrings: sharedStrings)
        let rows = sheetParser.parse()
        return rows.isEmpty ? nil : rows.joined(separator: "\n")
    }

    /// Read text from a .pptx file by extracting all slide XML files.
    private func readPPTX(url: URL) -> String? {
        guard let archive = openZipArchive(url: url) else { return nil }

        var allText = ""
        // Extract text from slides (slide1.xml, slide2.xml, ...)
        for i in 1...100 {
            let slidePath = "ppt/slides/slide\(i).xml"
            guard let slideData = extractFileFromZip(archive: archive, path: slidePath) else {
                break
            }
            let text = stripXMLTags(slideData)
            if !text.isEmpty {
                allText += text + "\n"
            }
        }
        return allText.isEmpty ? nil : allText
    }

    // MARK: - ZIP Helpers

    /// Open a ZIP archive and return the raw file handle.
    /// Uses Foundation's Archive support (available macOS 13+).
    private func openZipArchive(url: URL) -> URL? {
        // Verify the file exists and is readable
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
        return url
    }

    /// Extract a file from a ZIP archive at the given internal path.
    private func extractFileFromZip(archive url: URL, path: String) -> Data? {
        guard let archiveData = try? Data(contentsOf: url) else { return nil }

        // OOXML files are ZIP archives. Parse the ZIP to find the entry.
        return ZipReader.extractFile(from: archiveData, entryPath: path)
    }

    /// Strip XML tags and return text content.
    private func stripXMLTags(_ data: Data) -> String {
        guard let xmlString = String(data: data, encoding: .utf8) else { return "" }
        // Replace paragraph/line break tags with newlines
        var text = xmlString
            .replacingOccurrences(of: "</w:p>", with: "\n")
            .replacingOccurrences(of: "</a:p>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
        // Strip all remaining XML tags
        text = text.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )
        // Clean up whitespace
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.joined(separator: "\n")
    }

    func removeNote(at offsets: IndexSet) {
        noteFiles.remove(atOffsets: offsets)
    }

    /// Clear persisted prep data after a meeting starts successfully.
    func clearPrepData() {
        title = ""
        goal = ""
        constraints = ""
        noteFiles = []
    }

    func startMeeting() async -> MeetingSetupResponse? {
        isLoading = true
        errorMessage = nil

        // Pre-flight health check
        let healthy = await backendAPI.checkHealth()
        if !healthy {
            errorMessage = "Backend is not responding. It may still be starting up — wait a moment and try again."
            isLoading = false
            return nil
        }

        let config = MeetingConfig(
            title: title,
            goal: goal,
            constraints: constraints,
            notes: noteFiles
        )

        do {
            let response = try await backendAPI.setupMeeting(config: config)
            guard !response.session_id.isEmpty else {
                errorMessage = "Backend returned an invalid session."
                isLoading = false
                return nil
            }
            isLoading = false
            return response
        } catch {
            errorMessage = "Failed to start meeting: \(error.localizedDescription)"
            isLoading = false
            return nil
        }
    }
}

// MARK: - Minimal ZIP Reader for OOXML

/// Reads entries from a ZIP archive stored in memory.
/// Only supports the features needed for OOXML (deflate + stored).
enum ZipReader {
    static func extractFile(from archiveData: Data, entryPath: String) -> Data? {
        let bytes = [UInt8](archiveData)
        var offset = 0

        while offset + 30 <= bytes.count {
            // Local file header signature = 0x04034b50
            guard bytes[offset] == 0x50,
                  bytes[offset + 1] == 0x4b,
                  bytes[offset + 2] == 0x03,
                  bytes[offset + 3] == 0x04 else {
                break
            }

            let compressionMethod = UInt16(bytes[offset + 8]) | (UInt16(bytes[offset + 9]) << 8)
            let compressedSize = Int(UInt32(bytes[offset + 18])
                | (UInt32(bytes[offset + 19]) << 8)
                | (UInt32(bytes[offset + 20]) << 16)
                | (UInt32(bytes[offset + 21]) << 24))
            let uncompressedSize = Int(UInt32(bytes[offset + 22])
                | (UInt32(bytes[offset + 23]) << 8)
                | (UInt32(bytes[offset + 24]) << 16)
                | (UInt32(bytes[offset + 25]) << 24))
            let nameLength = Int(UInt16(bytes[offset + 26]) | (UInt16(bytes[offset + 27]) << 8))
            let extraLength = Int(UInt16(bytes[offset + 28]) | (UInt16(bytes[offset + 29]) << 8))

            let nameStart = offset + 30
            let nameEnd = nameStart + nameLength
            guard nameEnd <= bytes.count else { break }

            let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) ?? ""
            let dataStart = nameEnd + extraLength
            let dataEnd = dataStart + compressedSize

            guard dataEnd <= bytes.count else { break }

            if name == entryPath {
                let compressedData = Data(bytes[dataStart..<dataEnd])

                if compressionMethod == 0 {
                    // Stored (no compression)
                    return compressedData
                } else if compressionMethod == 8 {
                    // Deflate — use Foundation's decompression
                    // Raw deflate: prepend a minimal zlib header (0x78 0x01)
                    var zlibData = Data([0x78, 0x01])
                    zlibData.append(compressedData)
                    if let decompressed = try? (zlibData as NSData).decompressed(using: .zlib) as Data {
                        return decompressed
                    }
                    // Fallback: try without header
                    return try? (compressedData as NSData).decompressed(using: .zlib) as Data
                }
                return nil
            }

            offset = dataEnd
            _ = uncompressedSize // suppress unused warning
        }
        return nil
    }
}

// MARK: - XLSX Shared Strings Parser

/// Parses xl/sharedStrings.xml to extract cell text values.
private class SharedStringsParser: NSObject, XMLParserDelegate {
    private let data: Data
    private var strings: [String] = []
    private var currentString = ""
    private var insideT = false

    init(data: Data) {
        self.data = data
    }

    func parse() -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if elementName == "t" {
            insideT = true
            currentString = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideT {
            currentString += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "t" {
            insideT = false
            strings.append(currentString)
        }
    }
}

// MARK: - XLSX Sheet Parser

/// Parses xl/worksheets/sheet1.xml to extract rows of cell values.
private class SheetParser: NSObject, XMLParserDelegate {
    private let data: Data
    private let sharedStrings: [String]
    private var rows: [String] = []
    private var currentRow: [String] = []
    private var currentValue = ""
    private var currentType = ""
    private var insideV = false
    private var insideRow = false

    init(data: Data, sharedStrings: [String]) {
        self.data = data
        self.sharedStrings = sharedStrings
    }

    func parse() -> [String] {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return rows
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        if elementName == "row" {
            insideRow = true
            currentRow = []
        } else if elementName == "c" {
            currentType = attributes["t"] ?? ""
            currentValue = ""
        } else if elementName == "v" {
            insideV = true
            currentValue = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideV {
            currentValue += string
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName: String?) {
        if elementName == "v" {
            insideV = false
            if currentType == "s", let idx = Int(currentValue), idx < sharedStrings.count {
                currentRow.append(sharedStrings[idx])
            } else {
                currentRow.append(currentValue)
            }
        } else if elementName == "row" {
            insideRow = false
            if !currentRow.isEmpty {
                rows.append(currentRow.joined(separator: "\t"))
            }
        }
    }
}
