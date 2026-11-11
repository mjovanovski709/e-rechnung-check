import XCTest
import CoreText
import PDFKit
@testable import EInvoiceKit

final class CreationTests: XCTestCase {
    static func sampleDraft(format: OutputFormat = .zugferdPDF) -> InvoiceDraft {
        var d = InvoiceDraft()
        d.format = format
        d.number = "R-2026-042"
        d.issueDate = date(2026, 11, 11)
        d.deliveryDate = date(2026, 11, 10)
        d.dueDate = date(2026, 11, 25)
        d.paymentTerms = "Zahlbar innerhalb von 14 Tagen"
        d.seller.name = "Muster & Söhne GmbH"
        d.seller.street = "Hauptstraße 1"
        d.seller.postcode = "10115"
        d.seller.city = "Berlin"
        d.seller.vatID = "DE123456789"
        d.seller.contactName = "Erika Muster"
        d.seller.phone = "+49 30 123456"
        d.seller.email = "rechnung@example.com"
        d.buyer.name = "Kunde AG"
        d.buyer.street = "Marktplatz 5"
        d.buyer.postcode = "80331"
        d.buyer.city = "München"
        d.buyer.email = "eingang@example.org"
        d.iban = "DE89 3704 0044 0532 0130 00"
        d.accountName = "Muster & Söhne GmbH"
        if format == .xrechnungXML { d.buyerReference = "991-12345-67" }

        var a = DraftLine()
        a.name = "Beratung <vor Ort>"
        a.quantity = Decimal(string: "7.5")!
        a.unit = .hour
        a.unitPrice = Decimal(string: "95.50")!
        var b = DraftLine()
        b.name = "Fachbuch"
        b.quantity = 3
        b.unitPrice = Decimal(string: "19.99")!
        b.tax = .reduced7
        d.lines = [a, b]
        return d
    }

    static func date(_ y: Int, _ m: Int, _ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(timeZone: .current, year: y, month: m, day: day, hour: 12))!
    }

    // MARK: Draft

    func testTotalsAreComputedFromLines() {
        let d = Self.sampleDraft()
        // 7.5 × 95.50 = 716.25; 3 × 19.99 = 59.97
        XCTAssertEqual(d.lineTotal, Decimal(string: "776.22"))
        XCTAssertEqual(d.taxGroups.map(\.tax), [Decimal(string: "136.09")!, Decimal(string: "4.20")!])
        XCTAssertEqual(d.grossTotal, Decimal(string: "916.51"))
        XCTAssertEqual(d.problems(.en), [])
    }

    func testMissingFieldsAreListed() {
        var d = InvoiceDraft()
        d.format = .xrechnungXML
        let problems = d.problems(.en)
        XCTAssertTrue(problems.contains("Invoice number"))
        XCTAssertTrue(problems.contains("Seller: tax number or VAT ID"))
        XCTAssertTrue(problems.contains { $0.hasPrefix("Leitweg-ID") })

        d = Self.sampleDraft()
        d.lines[0].tax = .reverseCharge
        XCTAssertTrue(d.problems(.en).contains { $0.hasPrefix("Buyer: VAT ID") })
        d.iban = "DE00 0000"
        XCTAssertTrue(d.problems(.en).contains("IBAN: checksum fails"))
    }

    // MARK: XML

    func testWrittenXMLPassesTheChecker() throws {
        let draft = Self.sampleDraft()
        let report = Inspector.inspect(data: CIIWriter.xml(draft), fileName: "invoice.xml")
        XCTAssertEqual(report.kind, .xmlInvoice)
        XCTAssertEqual(report.profile, .en16931)
        XCTAssertEqual(report.verdict, .eInvoice, "\(report.findings.filter { $0.severity > .info }.map(\.id))")

        let inv = try XCTUnwrap(report.invoice)
        XCTAssertEqual(inv.number, "R-2026-042")
        XCTAssertEqual(inv.issueDate, Day(year: 2026, month: 11, day: 11))
        XCTAssertEqual(inv.deliveryDate, Day(year: 2026, month: 11, day: 10))
        XCTAssertEqual(inv.payment.dueDate, Day(year: 2026, month: 11, day: 25))
        XCTAssertEqual(inv.seller.name, "Muster & Söhne GmbH")
        XCTAssertEqual(inv.seller.vatID, "DE123456789")
        XCTAssertEqual(inv.buyer.city, "München")
        XCTAssertEqual(inv.lines.map(\.name), ["Beratung <vor Ort>", "Fachbuch"])
        XCTAssertEqual(inv.lines.first?.unit, "HUR")
        XCTAssertEqual(inv.totals.grossTotal, Decimal(string: "916.51"))
        XCTAssertEqual(inv.totals.due, Decimal(string: "916.51"))
        XCTAssertEqual(inv.vatRows.count, 2)
        XCTAssertEqual(inv.payment.iban, "DE89370400440532013000")
    }

    func testXRechnungOutput() throws {
        let report = Inspector.inspect(data: CIIWriter.xml(Self.sampleDraft(format: .xrechnungXML)), fileName: "x.xml")
        XCTAssertEqual(report.profile, .xrechnung)
        XCTAssertEqual(report.verdict, .eInvoice, "\(report.findings.filter { $0.severity > .info }.map(\.id))")
        XCTAssertEqual(report.invoice?.buyerReference, "991-12345-67")
        XCTAssertEqual(report.invoice?.businessProcess, CIIWriter.peppolProcess)
    }

    func testSmallBusinessCarriesExemptionReason() throws {
        var d = Self.sampleDraft()
        for i in d.lines.indices { d.lines[i].tax = .smallBusiness }
        XCTAssertEqual(d.taxTotal, 0)
        let report = Inspector.inspect(data: CIIWriter.xml(d), fileName: "k.xml")
        XCTAssertEqual(report.verdict, .eInvoice, "\(report.findings.filter { $0.severity > .info }.map(\.id))")
        let row = try XCTUnwrap(report.invoice?.vatRows.first)
        XCTAssertEqual(row.category, "E")
        XCTAssertTrue(row.exemptionReason?.contains("§ 19 UStG") == true)
    }

    // MARK: PDF

    func testEmbeddingIntoAPlainPDF() throws {
        let draft = Self.sampleDraft()
        let plain = Self.makePDF(lines: ["Rechnung R-2026-042", "Gesamtbetrag 916,51 EUR", "IBAN DE89 3704 0044 0532 0130 00"])
        XCTAssertEqual(Inspector.inspect(data: plain, fileName: "plain.pdf").kind, .plainPDF)

        let hybrid = try HybridPDF.embed(xml: CIIWriter.xml(draft), into: plain)
        XCTAssertTrue(hybrid.starts(with: plain), "the update must only append")

        let report = Inspector.inspect(data: hybrid, fileName: "hybrid.pdf")
        XCTAssertEqual(report.kind, .hybridPDF)
        XCTAssertEqual(report.profile, .en16931)
        XCTAssertEqual(report.embeddedFileName, "factur-x.xml")
        XCTAssertEqual(report.attachments.first?.relationship, "Alternative")
        XCTAssertEqual(report.invoice?.number, "R-2026-042")

        let info = try XCTUnwrap(PDFContainer.read(hybrid))
        XCTAssertEqual(info.xmp?.pdfaPart, "3")
        XCTAssertEqual(info.xmp?.conformanceLevel, "EN 16931")
        XCTAssertEqual(info.xmp?.documentFileName, "factur-x.xml")
        XCTAssertEqual(info.pageCount, 1)
        XCTAssertTrue(info.text.contains("916,51"))

        // PDFKit must still open it, and our own reader must parse the update.
        XCTAssertEqual(PDFDocument(data: hybrid)?.pageCount, 1)
        var file = try PDFFile(hybrid)
        let catalog = try XCTUnwrap(file.object(file.trailer["Root"]!.reference!.0).value.dict)
        XCTAssertNotNil(catalog["OutputIntents"])
        XCTAssertNotNil(catalog["AF"])

        // A second run replaces the invoice rather than adding another one.
        var changed = draft
        changed.number = "R-2026-043"
        let twice = try HybridPDF.embed(xml: CIIWriter.xml(changed), into: hybrid)
        let second = Inspector.inspect(data: twice, fileName: "twice.pdf")
        XCTAssertEqual(second.invoice?.number, "R-2026-043")
        XCTAssertEqual(second.attachments.count, 1)
    }

    func testReplacingTheInvoiceOfAnOfficialSample() throws {
        let url = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/EN16931_Einfach.pdf")
        let original = try Data(contentsOf: url)
        let hybrid = try HybridPDF.embed(xml: CIIWriter.xml(Self.sampleDraft()), into: original)
        let report = Inspector.inspect(data: hybrid, fileName: "x.pdf")
        XCTAssertEqual(report.invoice?.number, "R-2026-042")
        XCTAssertEqual(report.attachments.count, 1)
        XCTAssertEqual(PDFDocument(data: hybrid)?.pageCount, PDFDocument(data: original)?.pageCount)
    }

    func testCrossReferenceStreamsAndObjectStreams() throws {
        let original = try Self.makeCompressedPDF()
        // Core Graphics must accept the hand-made file, or the test proves nothing.
        XCTAssertEqual(PDFContainer.read(original)?.pageCount, 1)

        let hybrid = try HybridPDF.embed(xml: CIIWriter.xml(Self.sampleDraft()), into: original)
        let tail = String(decoding: hybrid.suffix(from: original.count), as: UTF8.self)
        XCTAssertTrue(tail.contains("/Type /XRef"), "an xref-stream file gets an xref-stream update")
        XCTAssertFalse(tail.contains("\nxref\n"))

        let report = Inspector.inspect(data: hybrid, fileName: "x.pdf")
        XCTAssertEqual(report.kind, .hybridPDF)
        XCTAssertEqual(report.invoice?.number, "R-2026-042")
        XCTAssertEqual(PDFDocument(data: hybrid)?.pageCount, 1)
    }

    func testEncryptedOrForeignInputIsRefused() {
        XCTAssertThrowsError(try HybridPDF.embed(xml: Data(), into: Data("hello".utf8))) {
            XCTAssertEqual($0 as? HybridPDF.Failure, .notPDF)
        }
    }

    func testPDFDates() {
        let d = HybridPDF.parsePDFDate("D:20240305143000+01'00'")!
        XCTAssertEqual(d.timeIntervalSince1970, 1709645400)
        XCTAssertEqual(HybridPDF.parsePDFDate(HybridPDF.pdfDate(d)), d)
        XCTAssertNotNil(HybridPDF.parsePDFDate("D:2024"))
        XCTAssertNil(HybridPDF.parsePDFDate("yesterday"))
    }

    func testStringValues() {
        XCTAssertEqual(PDFValue.text("a(b)\\c").textValue, "a(b)\\c")
        XCTAssertEqual(PDFValue.text("Größe").textValue, "Größe")
        XCTAssertEqual(PDFValue.string(Array("(Line\\nTwo \\101)".utf8)).textValue, "Line\nTwo A")
        XCTAssertEqual(PDFValue.string(Array("<48 65 6C6C6F>".utf8)).textValue, "Hello")
    }

    // MARK: Helpers

    static func makePDF(lines: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextTitle: "Rechnung"] as CFDictionary)!
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for (i, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            context.textPosition = CGPoint(x: 60, y: 760 - CGFloat(i) * 24)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A PDF 1.5 file whose catalog lives in a compressed object stream and
    /// whose cross-reference data is a Flate stream with a PNG predictor,
    /// the way current PDF libraries write them.
    static func makeCompressedPDF() throws -> Data {
        var out = Array("%PDF-1.5\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int: Int] = [:]
        func object(_ n: Int, _ body: [UInt8]) {
            offsets[n] = out.count
            out += Array("\(n) 0 obj\n".utf8) + body + Array("\nendobj\n".utf8)
        }
        func stream(_ dict: String, _ data: [UInt8]) -> [UInt8] {
            Array("<< \(dict) /Length \(data.count) >>\nstream\n".utf8) + data + Array("\nendstream".utf8)
        }

        let content = Array("BT /F1 12 Tf 72 720 Td (Rechnung) Tj ET".utf8)
        object(3, Array("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Contents 4 0 R /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> >>".utf8))
        object(4, stream("", content))

        // Object stream with the catalog (1) and the page tree (2).
        let catalog = "<< /Type /Catalog /Pages 2 0 R >>"
        let pages = "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"
        let header = "1 0 2 \(catalog.utf8.count + 1) "
        let body = Array((header + catalog + " " + pages).utf8)
        object(5, stream("/Type /ObjStm /N 2 /First \(header.utf8.count) /Filter /FlateDecode", try zlib(body)))

        // Cross-reference stream, rows of W [1 2 1], PNG "Up" predictor.
        let xrefNumber = 6
        offsets[xrefNumber] = out.count
        let rows: [[UInt8]] = [
            [0, 0, 0, 255],                                            // 0 free
            [2, 0, 5, 0], [2, 0, 5, 1],                                // 1, 2 in stream 5
            [1, UInt8(offsets[3]! >> 8), UInt8(offsets[3]! & 0xFF), 0],
            [1, UInt8(offsets[4]! >> 8), UInt8(offsets[4]! & 0xFF), 0],
            [1, UInt8(offsets[5]! >> 8), UInt8(offsets[5]! & 0xFF), 0],
            [1, UInt8(offsets[6]! >> 8), UInt8(offsets[6]! & 0xFF), 0],
        ]
        var predicted: [UInt8] = []
        var previous: [UInt8] = [0, 0, 0, 0]
        for row in rows {
            predicted.append(2)
            for i in 0..<4 { predicted.append(row[i] &- previous[i]) }
            previous = row
        }
        let dict = "/Type /XRef /Size 7 /W [1 2 1] /Root 1 0 R /ID [<00112233445566778899AABBCCDDEEFF> <00112233445566778899AABBCCDDEEFF>] /Filter /FlateDecode /DecodeParms << /Columns 4 /Predictor 12 >>"
        out += Array("\(xrefNumber) 0 obj\n".utf8) + stream(dict, try zlib(predicted)) + Array("\nendobj\n".utf8)
        out += Array("startxref\n\(offsets[xrefNumber]!)\n%%EOF\n".utf8)
        return Data(out)
    }

    /// zlib format: header, raw deflate, Adler-32.
    static func zlib(_ bytes: [UInt8]) throws -> [UInt8] {
        let deflated = try (Data(bytes) as NSData).compressed(using: .zlib) as Data
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes { a = (a + UInt32(byte)) % 65521; b = (b + a) % 65521 }
        let adler = b << 16 | a
        return [0x78, 0x9C] + [UInt8](deflated) + [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
    }
}
