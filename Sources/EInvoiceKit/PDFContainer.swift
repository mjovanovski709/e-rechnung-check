import Foundation
import CoreGraphics
import PDFKit

/// A file embedded in a PDF.
public struct PDFAttachment: Sendable {
    public let name: String
    public let data: Data
    /// `/AFRelationship` of the file specification: Alternative, Data, Source…
    public let relationship: String?
}

/// What the PDF's XMP metadata claims about itself.
public struct XMPInfo: Sendable, Equatable {
    /// `pdfaid:part`, "3" for the PDF/A-3 a hybrid invoice must be.
    public var pdfaPart: String?
    /// `fx:ConformanceLevel` (or `zf:` in older files), e.g. "EN 16931".
    public var conformanceLevel: String?
    /// `fx:DocumentFileName`, the attachment the metadata points to.
    public var documentFileName: String?
}

public struct PDFInfo: Sendable {
    public let attachments: [PDFAttachment]
    public let xmp: XMPInfo?
    /// Text layer of all pages. Empty for a scan.
    public let text: String
    public let pageCount: Int
    public let isLocked: Bool
}

/// Reads the parts of a PDF that matter for a hybrid invoice.
///
/// Apple's Preview and PDFKit do not show embedded files, which is why a
/// ZUGFeRD PDF looks like any other PDF on a Mac. Core Graphics does expose
/// the raw document catalog, so the attachments can be read without a
/// third-party PDF library.
public enum PDFContainer {
    public static func looksLikePDF(_ data: Data) -> Bool {
        // The header may be preceded by a few junk bytes in real-world files.
        data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil
    }

    public static func read(_ data: Data) -> PDFInfo? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider) else { return nil }

        if document.isEncrypted && !document.isUnlocked {
            _ = document.unlockWithPassword("")
        }
        guard document.isUnlocked else {
            return PDFInfo(attachments: [], xmp: nil, text: "", pageCount: document.numberOfPages, isLocked: true)
        }

        var attachments: [PDFAttachment] = []
        var xmp: XMPInfo?

        if let catalog = document.catalog {
            var names: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(catalog, "Names", &names), let names {
                var embedded: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(names, "EmbeddedFiles", &embedded), let embedded {
                    walkNameTree(embedded, depth: 0, into: &attachments)
                }
            }

            // PDF/A-3 also lists invoice data under /AF (associated files).
            // Some producers fill only this array and skip the name tree.
            var associated: CGPDFArrayRef?
            if CGPDFDictionaryGetArray(catalog, "AF", &associated), let associated {
                for index in 0..<CGPDFArrayGetCount(associated) {
                    var spec: CGPDFDictionaryRef?
                    guard CGPDFArrayGetDictionary(associated, index, &spec), let spec,
                          let attachment = attachment(from: spec, fallbackName: nil) else { continue }
                    if !attachments.contains(where: { $0.name == attachment.name && $0.data == attachment.data }) {
                        attachments.append(attachment)
                    }
                }
            }

            var metadata: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(catalog, "Metadata", &metadata), let metadata {
                var format = CGPDFDataFormat.raw
                if let raw = CGPDFStreamCopyData(metadata, &format) {
                    xmp = parseXMP(String(decoding: raw as Data, as: UTF8.self))
                }
            }
        }

        let text = PDFDocument(data: data)?.string ?? ""
        return PDFInfo(attachments: attachments, xmp: xmp, text: text, pageCount: document.numberOfPages, isLocked: false)
    }

    /// A name tree node holds either `/Names [name spec name spec …]` or
    /// `/Kids` with further nodes. The depth limit guards against a
    /// malicious file whose kids point back at a parent.
    private static func walkNameTree(_ node: CGPDFDictionaryRef, depth: Int, into result: inout [PDFAttachment]) {
        guard depth < 16 else { return }

        var pairs: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Names", &pairs), let pairs {
            let count = CGPDFArrayGetCount(pairs)
            var index = 0
            while index + 1 < count {
                var nameRef: CGPDFStringRef?
                var spec: CGPDFDictionaryRef?
                let treeName = CGPDFArrayGetString(pairs, index, &nameRef) ? string(nameRef) : nil
                if CGPDFArrayGetDictionary(pairs, index + 1, &spec), let spec,
                   let attachment = attachment(from: spec, fallbackName: treeName) {
                    result.append(attachment)
                }
                index += 2
            }
        }

        var kids: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(node, "Kids", &kids), let kids {
            for index in 0..<CGPDFArrayGetCount(kids) {
                var kid: CGPDFDictionaryRef?
                if CGPDFArrayGetDictionary(kids, index, &kid), let kid {
                    walkNameTree(kid, depth: depth + 1, into: &result)
                }
            }
        }
    }

    private static func attachment(from spec: CGPDFDictionaryRef, fallbackName: String?) -> PDFAttachment? {
        var files: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(spec, "EF", &files), let files else { return nil }

        var data: Data?
        // "/F" is the classic key, "/UF" the Unicode one; producers set
        // either or both.
        for key in ["F", "UF"] {
            var stream: CGPDFStreamRef?
            if CGPDFDictionaryGetStream(files, key, &stream), let stream {
                var format = CGPDFDataFormat.raw
                if let raw = CGPDFStreamCopyData(stream, &format) {
                    data = raw as Data
                    break
                }
            }
        }
        guard let data else { return nil }

        var name = fallbackName
        for key in ["UF", "F"] {
            var ref: CGPDFStringRef?
            if CGPDFDictionaryGetString(spec, key, &ref), let value = string(ref), !value.isEmpty {
                name = value
                break
            }
        }

        var relationship: String?
        var rawName: UnsafePointer<CChar>?
        if CGPDFDictionaryGetName(spec, "AFRelationship", &rawName), let rawName {
            relationship = String(cString: rawName)
        }

        return PDFAttachment(name: name ?? "unnamed", data: data, relationship: relationship)
    }

    private static func string(_ ref: CGPDFStringRef?) -> String? {
        guard let ref, let text = CGPDFStringCopyTextString(ref) else { return nil }
        return text as String
    }

    /// XMP can state a value as an element (`<fx:ConformanceLevel>EN 16931<`)
    /// or as an attribute (`fx:ConformanceLevel="EN 16931"`), and the prefix
    /// is the producer's choice, so both forms are matched by local name.
    static func parseXMP(_ xmp: String) -> XMPInfo? {
        func value(_ localName: String) -> String? {
            let patterns = [
                "<[A-Za-z0-9_]+:\(localName)>\\s*([^<]+?)\\s*<",
                "[A-Za-z0-9_]+:\(localName)\\s*=\\s*[\"']([^\"']+)[\"']",
            ]
            for pattern in patterns {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(xmp.startIndex..., in: xmp)
                if let match = regex.firstMatch(in: xmp, range: range),
                   let captured = Range(match.range(at: 1), in: xmp) {
                    return String(xmp[captured])
                }
            }
            return nil
        }

        let info = XMPInfo(
            pdfaPart: value("part"),
            conformanceLevel: value("ConformanceLevel"),
            documentFileName: value("DocumentFileName")
        )
        return info == XMPInfo() ? nil : info
    }
}
