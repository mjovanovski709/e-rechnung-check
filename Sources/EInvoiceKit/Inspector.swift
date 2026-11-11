import Foundation

public enum FileKind: String, Sendable {
    /// PDF with embedded invoice XML (ZUGFeRD / Factur-X).
    case hybridPDF
    /// PDF without invoice data.
    case plainPDF
    /// Standalone invoice XML (XRechnung, Peppol, CII, UBL).
    case xmlInvoice
    /// XML that is not an invoice we recognise.
    case otherXML
    case unreadable
}

public enum Verdict: String, Sendable {
    case eInvoice
    case eInvoiceWithWarnings
    case eInvoiceWithErrors
    /// Carries structured data, but in a profile German rules do not accept.
    case structuredButNotEInvoice
    case notEInvoice
    case unreadable
}

public struct AttachmentSummary: Sendable {
    public let name: String
    public let byteCount: Int
    public let relationship: String?
}

/// Everything the tool has to say about one file.
public struct Report: Sendable {
    public let fileName: String
    public let kind: FileKind
    public let verdict: Verdict
    public let headline: LocalizedText
    public let explanation: LocalizedText
    /// "ZUGFeRD / Factur-X", "XRechnung (UBL)" …
    public let formatName: String?
    public let profile: Profile?
    public let invoice: Invoice?
    public let findings: [Finding]
    public let comparison: PrintedComparison?
    public let attachments: [AttachmentSummary]
    public let embeddedFileName: String?
    public let xml: String?

    public var errorCount: Int { findings.filter { $0.severity == .error }.count }
    public var warningCount: Int { findings.filter { $0.severity == .warning }.count }
}

public enum Inspector {
    /// Files larger than this are refused instead of read into memory.
    public static let maximumFileSize = 100 * 1024 * 1024

    public static func inspect(url: URL) -> Report {
        let name = url.lastPathComponent
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maximumFileSize, let data = try? Data(contentsOf: url) else {
            return unreadable(name, T("Die Datei konnte nicht gelesen werden oder ist zu groß.", "The file could not be read or is too large."))
        }
        return inspect(data: data, fileName: name)
    }

    public static func inspect(data: Data, fileName: String) -> Report {
        if PDFContainer.looksLikePDF(data) {
            return inspectPDF(data, fileName: fileName)
        }
        if looksLikeXML(data) {
            return inspectXML(data, fileName: fileName)
        }
        return unreadable(fileName, T("Weder PDF noch XML. E-Rechnungen sind PDF-Dateien mit eingebettetem XML oder reine XML-Dateien.",
                                      "Neither PDF nor XML. E-invoices are PDFs with embedded XML or plain XML files."))
    }

    // MARK: - PDF

    private static let standardNames = ["factur-x.xml", "zugferd-invoice.xml", "xrechnung.xml"]

    private static func inspectPDF(_ data: Data, fileName: String) -> Report {
        guard let pdf = PDFContainer.read(data) else {
            return unreadable(fileName, T("Das PDF ist beschädigt und lässt sich nicht öffnen.", "The PDF is damaged and cannot be opened."))
        }
        if pdf.isLocked {
            return unreadable(fileName, T("Das PDF ist passwortgeschützt.", "The PDF is password-protected."))
        }

        let summaries = pdf.attachments.map { AttachmentSummary(name: $0.name, byteCount: $0.data.count, relationship: $0.relationship) }
        let xmlFiles = pdf.attachments
            .filter { $0.name.lowercased().hasSuffix(".xml") || looksLikeXML($0.data) }
            .sorted { rank($0.name) < rank($1.name) }

        var damaged: String?
        for file in xmlFiles {
            switch InvoiceParser.parse(file.data) {
            case .invoice(let invoice):
                return hybridReport(invoice: invoice, file: file, pdf: pdf, fileName: fileName, summaries: summaries)
            case .malformed(let reason):
                if damaged == nil { damaged = "\(file.name): \(reason)" }
            case .notAnInvoice:
                continue
            }
        }

        if let damaged {
            return Report(
                fileName: fileName, kind: .plainPDF, verdict: .notEInvoice,
                headline: T("Keine lesbare E-Rechnung", "No readable e-invoice"),
                explanation: T("Das PDF enthält eine XML-Datei, sie ist aber beschädigt. Software kann diese Rechnung nicht einlesen.",
                               "The PDF contains an XML file, but it is damaged. Software cannot read this invoice."),
                formatName: nil, profile: nil, invoice: nil,
                findings: [Finding("xml.damaged", .error, T("Eingebettetes XML ist nicht wohlgeformt", "Embedded XML is not well-formed"), T(damaged, damaged))],
                comparison: nil, attachments: summaries, embeddedFileName: nil, xml: nil
            )
        }

        let explanation = pdf.attachments.isEmpty
            ? T("Dieses PDF enthält keine eingebetteten Rechnungsdaten. Für Software ist es nur ein Bild der Rechnung.",
                "This PDF contains no embedded invoice data. To software it is only a picture of the invoice.")
            : T("Das PDF hat Anhänge, aber keiner davon ist eine Rechnung in einem bekannten Format.",
                "The PDF has attachments, but none of them is an invoice in a known format.")
        return Report(
            fileName: fileName, kind: .plainPDF, verdict: .notEInvoice,
            headline: T("Keine E-Rechnung", "Not an e-invoice"),
            explanation: explanation,
            formatName: nil, profile: nil, invoice: nil, findings: [],
            comparison: nil, attachments: summaries, embeddedFileName: nil, xml: nil
        )
    }

    private static func rank(_ name: String) -> Int {
        standardNames.firstIndex(of: name.lowercased()) ?? standardNames.count
    }

    private static func hybridReport(invoice: Invoice, file: PDFAttachment, pdf: PDFInfo, fileName: String, summaries: [AttachmentSummary]) -> Report {
        let profile = Profile.detect(guideline: invoice.guidelineID, syntax: invoice.syntax)
        var findings: [Finding] = []

        findings.append(Finding("xml.embedded", .ok,
                                T("Eingebettete Rechnungsdaten gefunden", "Embedded invoice data found"),
                                T(file.name, file.name)))

        if !standardNames.contains(file.name.lowercased()) {
            findings.append(Finding("xml.name", .warning,
                                    T("Ungewöhnlicher Name der eingebetteten Datei", "Unusual name of the embedded file"),
                                    T("\(file.name) – üblich ist factur-x.xml. Manche Software findet die Daten dann nicht.",
                                      "\(file.name) – the usual name is factur-x.xml. Some software will not find the data.")))
        }

        findings += containerChecks(pdf: pdf, profile: profile)
        findings += ContentChecks.run(invoice, profile: profile)

        let comparison = PrintedComparison.compare(invoice: invoice, pageText: pdf.text)
        findings += comparisonFindings(comparison)

        let format = invoice.syntax == .ubl ? "PDF + UBL" : "ZUGFeRD / Factur-X"
        return assemble(fileName: fileName, kind: .hybridPDF, format: format, profile: profile, invoice: invoice,
                        findings: findings, comparison: comparison, summaries: summaries,
                        embeddedFileName: file.name, xml: file.data)
    }

    /// What the PDF wrapper declares about itself. Receivers that validate
    /// strictly reject files without these declarations.
    private static func containerChecks(pdf: PDFInfo, profile: Profile) -> [Finding] {
        guard profile != .zugferd1 else { return [] }
        var findings: [Finding] = []
        guard let xmp = pdf.xmp else {
            return [Finding("pdf.xmp", .warning,
                            T("PDF-Metadaten fehlen", "PDF metadata is missing"),
                            T("Das PDF weist sich nicht als PDF/A-3 mit Rechnungsdaten aus. Strenge Prüfprogramme lehnen das ab.",
                              "The PDF does not declare itself as PDF/A-3 with invoice data. Strict validators reject that."))]
        }
        if xmp.pdfaPart != "3" {
            findings.append(Finding("pdf.pdfa", .warning,
                                    T("PDF ist nicht als PDF/A-3 gekennzeichnet", "PDF is not marked as PDF/A-3"),
                                    T("Der Standard verlangt PDF/A-3. Strenge Prüfprogramme lehnen das ab.",
                                      "The standard requires PDF/A-3. Strict validators reject that.")))
        }
        if let level = xmp.conformanceLevel {
            let declared = level.uppercased().filter { $0.isLetter || $0.isNumber }
            let actual = profile.displayName.uppercased().filter { $0.isLetter || $0.isNumber }
            // "EN 16931" was called COMFORT in ZUGFeRD 2.0; treat as the same.
            // XRechnung is a stricter variant of EN 16931, and older files
            // declare it as such; that is not a contradiction.
            let same = declared == actual
                || (declared == "COMFORT" && profile == .en16931)
                || (declared == "EN16931" && profile == .xrechnung)
            if !same && profile != .unknown {
                findings.append(Finding("pdf.profile", .warning,
                                        T("PDF-Metadaten nennen ein anderes Profil als das XML", "PDF metadata names a different profile than the XML"),
                                        T("Metadaten: \(level), XML: \(profile.displayName)", "Metadata: \(level), XML: \(profile.displayName)")))
            }
        }
        return findings
    }

    private static func comparisonFindings(_ comparison: PrintedComparison) -> [Finding] {
        guard comparison.hasTextLayer else {
            return [Finding("page.notext", .info,
                            T("PDF-Seite ohne Text (Scan) – kein Abgleich mit dem XML möglich",
                              "PDF page has no text (scan) – cannot be compared with the XML"))]
        }
        var findings: [Finding] = []
        var matched: [PrintedComparison.Field] = []
        for row in comparison.rows {
            switch row.state {
            case .found:
                matched.append(row.field)
            case .notFound:
                findings.append(Finding("page.\(row.field.rawValue)", .warning,
                                        T("\(row.field.label(.de)) aus dem XML steht nicht auf der PDF-Seite",
                                          "\(row.field.label(.en)) from the XML is not on the PDF page"),
                                        T("Im XML steht: \(row.display.de). Bitte mit der sichtbaren Rechnung vergleichen – maßgeblich ist das XML.",
                                          "The XML says: \(row.display.en). Please compare with the visible invoice – the XML is the binding part.")))
            case .differs(let printed):
                let shown = printed.map(IBAN.grouped).joined(separator: ", ")
                findings.append(Finding("page.\(row.field.rawValue).differs", .error,
                                        T("IBAN auf der PDF-Seite ist eine andere als im XML", "IBAN on the PDF page differs from the XML"),
                                        T("XML: \(IBAN.grouped(row.xmlValue)) · PDF-Seite: \(shown). Vor der Zahlung beim Absender nachfragen.",
                                          "XML: \(IBAN.grouped(row.xmlValue)) · PDF page: \(shown). Check with the sender before paying.")))
            }
        }
        if !matched.isEmpty {
            let de = matched.map { $0.label(.de) }.joined(separator: ", ")
            let en = matched.map { $0.label(.en) }.joined(separator: ", ")
            findings.insert(Finding("page.match", .ok,
                                    T("PDF-Seite und XML stimmen überein", "PDF page and XML agree"),
                                    T(de, en)), at: 0)
        }
        return findings
    }

    // MARK: - XML

    private static func inspectXML(_ data: Data, fileName: String) -> Report {
        switch InvoiceParser.parse(data) {
        case .invoice(let invoice):
            let profile = Profile.detect(guideline: invoice.guidelineID, syntax: invoice.syntax)
            let findings = ContentChecks.run(invoice, profile: profile)
            let syntax = invoice.syntax == .ubl ? "UBL" : "CII"
            let format: String
            switch profile {
            case .xrechnung: format = "XRechnung (\(syntax))"
            case .peppol: format = "Peppol BIS (\(syntax))"
            case .zugferd1: format = "ZUGFeRD 1.0"
            default: format = "EN 16931 (\(syntax))"
            }
            return assemble(fileName: fileName, kind: .xmlInvoice, format: format, profile: profile, invoice: invoice,
                            findings: findings, comparison: nil, summaries: [], embeddedFileName: nil, xml: data)
        case .notAnInvoice(let root):
            return Report(
                fileName: fileName, kind: .otherXML, verdict: .notEInvoice,
                headline: T("Keine E-Rechnung erkannt", "No e-invoice recognised"),
                explanation: T("Eine XML-Datei, aber kein bekanntes Rechnungsformat (Wurzelelement „\(root)“).",
                               "An XML file, but not a known invoice format (root element “\(root)”)."),
                formatName: nil, profile: nil, invoice: nil, findings: [], comparison: nil,
                attachments: [], embeddedFileName: nil, xml: String(decoding: data, as: UTF8.self)
            )
        case .malformed(let reason):
            return Report(
                fileName: fileName, kind: .unreadable, verdict: .unreadable,
                headline: T("XML-Datei ist beschädigt", "XML file is damaged"),
                explanation: T("Die Datei ist kein wohlgeformtes XML und lässt sich nicht einlesen.", "The file is not well-formed XML and cannot be read."),
                formatName: nil, profile: nil, invoice: nil,
                findings: [Finding("xml.damaged", .error, T("XML ist nicht wohlgeformt", "XML is not well-formed"), T(reason, reason))],
                comparison: nil, attachments: [], embeddedFileName: nil, xml: nil
            )
        }
    }

    // MARK: - Verdict

    private static func assemble(fileName: String, kind: FileKind, format: String, profile: Profile, invoice: Invoice,
                                 findings: [Finding], comparison: PrintedComparison?, summaries: [AttachmentSummary],
                                 embeddedFileName: String?, xml: Data) -> Report {
        var findings = findings
        let described = "\(format) · \(profile == .unknown ? "Profil unbekannt" : "Profil \(profile.displayName)")"
        let describedEN = "\(format) · \(profile == .unknown ? "unknown profile" : "profile \(profile.displayName)")"

        let verdict: Verdict
        let headline: LocalizedText
        let explanation: LocalizedText

        switch profile.germanStatus {
        case .doesNotQualify:
            verdict = .structuredButNotEInvoice
            headline = T("Keine E-Rechnung im Sinne des Gesetzes", "Not an e-invoice under German rules")
            let reason = profile == .zugferd1
                ? T("ZUGFeRD 1.0 entspricht nicht der Norm EN 16931.", "ZUGFeRD 1.0 does not follow the EN 16931 standard.")
                : T("Das Profil \(profile.displayName) enthält zu wenig Daten und ist laut BMF-Schreiben vom 15.10.2024 ausgenommen.",
                    "The \(profile.displayName) profile carries too little data and is excluded by the Finance Ministry's letter of 15 Oct 2024.")
            explanation = T("\(described). Die Datei enthält Rechnungsdaten, gilt in Deutschland aber nicht als E-Rechnung: \(reason.de)",
                            "\(describedEN). The file carries invoice data but does not count as an e-invoice in Germany: \(reason.en)")
            findings.insert(Finding("profile.excluded", .error,
                                    T("Profil wird nicht als E-Rechnung anerkannt", "Profile is not accepted as an e-invoice"), reason), at: 0)
        case .unclear, .qualifies:
            if profile.germanStatus == .unclear {
                findings.insert(Finding("profile.unknown", .warning,
                                        T("Profil nicht erkannt", "Profile not recognised"),
                                        T("Kennung: \(invoice.guidelineID ?? "fehlt")", "Identifier: \(invoice.guidelineID ?? "missing")")), at: 0)
            }
            let worst = findings.map(\.severity).max() ?? .ok
            switch worst {
            case .error:
                verdict = .eInvoiceWithErrors
                headline = T("E-Rechnung mit Fehlern", "E-invoice with errors")
                explanation = T("\(described). Die Datei ist eine E-Rechnung, enthält aber Fehler – siehe unten.",
                                "\(describedEN). The file is an e-invoice but contains errors – see below.")
            case .warning:
                verdict = .eInvoiceWithWarnings
                headline = T("E-Rechnung mit Hinweisen", "E-invoice with notes")
                explanation = T("\(described). Die Datei ist eine E-Rechnung; einzelne Punkte sollten Sie ansehen.",
                                "\(describedEN). The file is an e-invoice; a few points deserve a look.")
            default:
                verdict = .eInvoice
                headline = T("Das ist eine E-Rechnung", "This is an e-invoice")
                explanation = T("\(described). Bei den geprüften Punkten ist nichts aufgefallen.",
                                "\(describedEN). Nothing stood out in the points checked.")
            }
        }

        return Report(
            fileName: fileName, kind: kind, verdict: verdict, headline: headline, explanation: explanation,
            formatName: format, profile: profile, invoice: invoice,
            findings: findings.sorted { $0.severity > $1.severity },
            comparison: comparison, attachments: summaries, embeddedFileName: embeddedFileName,
            xml: String(decoding: data(xml), as: UTF8.self)
        )
    }

    private static func data(_ xml: Data) -> Data {
        // Strip a UTF-8 byte-order mark so the source view starts cleanly.
        xml.starts(with: [0xEF, 0xBB, 0xBF]) ? xml.dropFirst(3) : xml
    }

    private static func unreadable(_ fileName: String, _ explanation: LocalizedText) -> Report {
        Report(fileName: fileName, kind: .unreadable, verdict: .unreadable,
               headline: T("Datei nicht lesbar", "File cannot be read"), explanation: explanation,
               formatName: nil, profile: nil, invoice: nil, findings: [], comparison: nil,
               attachments: [], embeddedFileName: nil, xml: nil)
    }

    static func looksLikeXML(_ data: Data) -> Bool {
        var bytes = data.prefix(256)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let head = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return head.hasPrefix("<")
    }
}
