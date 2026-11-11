import XCTest
import CoreText
@testable import EInvoiceKit

final class FixtureTests: XCTestCase {
    private func fixture(_ name: String) -> URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures/\(name)")
    }

    func testHybridPDFIsRecognisedAndRead() {
        let report = Inspector.inspect(url: fixture("EN16931_Einfach.pdf"))
        XCTAssertEqual(report.kind, .hybridPDF)
        XCTAssertEqual(report.verdict, .eInvoice)
        XCTAssertEqual(report.profile, .en16931)
        XCTAssertEqual(report.embeddedFileName, "factur-x.xml")

        let invoice = try! XCTUnwrap(report.invoice)
        XCTAssertEqual(invoice.number, "471102")
        XCTAssertEqual(invoice.issueDate, Day(year: 2018, month: 3, day: 5))
        XCTAssertEqual(invoice.seller.name, "Lieferant GmbH")
        XCTAssertEqual(invoice.buyer.name, "Kunden AG Mitte")
        XCTAssertEqual(invoice.lines.count, 2)
        XCTAssertEqual(invoice.totals.netTotal, Decimal(string: "473.00"))
        XCTAssertEqual(invoice.totals.grossTotal, Decimal(string: "529.87"))
        XCTAssertEqual(invoice.currency, "EUR")

        // The visible page must agree with the XML for this official sample.
        let comparison = try! XCTUnwrap(report.comparison)
        XCTAssertTrue(comparison.hasTextLayer)
        XCTAssertTrue(comparison.rows.allSatisfy { $0.state == .found })
    }

    func testXRechnungProfileInsidePDF() {
        let report = Inspector.inspect(url: fixture("XRECHNUNG_Einfach.pdf"))
        XCTAssertEqual(report.kind, .hybridPDF)
        XCTAssertEqual(report.profile, .xrechnung)
        XCTAssertEqual(report.verdict, .eInvoice)
    }

    func testStandaloneCIIAndUBLDescribeTheSameInvoice() {
        let cii = Inspector.inspect(url: fixture("EN16931_Einfach.cii.xml"))
        let ubl = Inspector.inspect(url: fixture("EN16931_Einfach.ubl.xml"))
        XCTAssertEqual(cii.kind, .xmlInvoice)
        XCTAssertEqual(ubl.kind, .xmlInvoice)
        XCTAssertEqual(cii.invoice?.syntax, .cii)
        XCTAssertEqual(ubl.invoice?.syntax, .ubl)
        XCTAssertEqual(cii.verdict, .eInvoice)
        XCTAssertEqual(ubl.verdict, .eInvoice)

        XCTAssertEqual(cii.invoice?.number, ubl.invoice?.number)
        XCTAssertEqual(cii.invoice?.issueDate, ubl.invoice?.issueDate)
        XCTAssertEqual(cii.invoice?.seller.name, ubl.invoice?.seller.name)
        XCTAssertEqual(cii.invoice?.seller.vatID, ubl.invoice?.seller.vatID)
        XCTAssertEqual(cii.invoice?.totals.grossTotal, ubl.invoice?.totals.grossTotal)
        XCTAssertEqual(cii.invoice?.totals.vatTotal, ubl.invoice?.totals.vatTotal)
        XCTAssertEqual(cii.invoice?.lines.count, ubl.invoice?.lines.count)
        XCTAssertEqual(cii.invoice?.vatRows.count, ubl.invoice?.vatRows.count)
    }

    func testMinimumProfileIsNotAnEInvoiceInGermany() {
        let report = Inspector.inspect(url: fixture("Facture_FR_MINIMUM.pdf"))
        XCTAssertEqual(report.profile, .minimum)
        XCTAssertEqual(report.verdict, .structuredButNotEInvoice)
        XCTAssertTrue(report.findings.contains { $0.id == "profile.excluded" })
        // MINIMUM cannot state a prepayment, so a lower amount due is fine.
        XCTAssertFalse(report.findings.contains { $0.id == "sums.due" })
    }

    func testZUGFeRD1IsReadButNotAccepted() {
        let report = Inspector.inspect(url: fixture("ZUGFeRD_1p0_COMFORT_Einfach.pdf"))
        XCTAssertEqual(report.profile, .zugferd1)
        XCTAssertEqual(report.verdict, .structuredButNotEInvoice)
        XCTAssertEqual(report.invoice?.number, "471102")
        XCTAssertFalse(report.findings.contains { $0.id == "fields" && $0.severity == .error })
    }

    func testOrdinaryPDFIsNotAnEInvoice() {
        let report = Inspector.inspect(data: makePDF(text: "Rechnung Nr. 4711 – Betrag 119,00 EUR"), fileName: "rechnung.pdf")
        XCTAssertEqual(report.kind, .plainPDF)
        XCTAssertEqual(report.verdict, .notEInvoice)
        XCTAssertNil(report.invoice)
    }

    func testNeitherPDFNorXML() {
        let report = Inspector.inspect(data: Data("hello".utf8), fileName: "notes.txt")
        XCTAssertEqual(report.verdict, .unreadable)
    }

    func testUnrelatedXML() {
        let report = Inspector.inspect(data: Data("<?xml version=\"1.0\"?><note><to>x</to></note>".utf8), fileName: "note.xml")
        XCTAssertEqual(report.kind, .otherXML)
        XCTAssertEqual(report.verdict, .notEInvoice)
    }

    func testBrokenXML() {
        let report = Inspector.inspect(data: Data("<?xml version=\"1.0\"?><a><b></a>".utf8), fileName: "broken.xml")
        XCTAssertEqual(report.verdict, .unreadable)
    }

    /// A one-page PDF with a text layer and no attachments.
    private func makePDF(text: String) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 60, y: 760)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }
}

final class ContentCheckTests: XCTestCase {
    private func report(_ xml: Data) -> Report {
        Inspector.inspect(data: xml, fileName: "test.xml")
    }

    func testCleanInvoicePasses() {
        let r = report(SampleXML.cii())
        XCTAssertEqual(r.verdict, .eInvoice, "\(r.findings.map(\.id))")
        XCTAssertEqual(r.profile, .en16931)
    }

    func testWrongGrossTotalIsAnError() {
        let r = report(SampleXML.cii(gross: "129.00", due: "129.00"))
        XCTAssertEqual(r.verdict, .eInvoiceWithErrors)
        XCTAssertTrue(r.findings.contains { $0.id == "sums.gross" && $0.severity == .error })
    }

    func testOneCentOffIsOnlyAWarning() {
        let r = report(SampleXML.cii(gross: "119.01", due: "119.01"))
        XCTAssertEqual(r.verdict, .eInvoiceWithWarnings)
        XCTAssertTrue(r.findings.contains { $0.id == "sums.gross" && $0.severity == .warning })
    }

    func testMissingSellerTaxIDIsAnError() {
        let r = report(SampleXML.cii(sellerVAT: nil))
        XCTAssertTrue(r.findings.contains { $0.id == "fields" && $0.severity == .error })
    }

    func testBadIBANChecksumIsAWarning() {
        let r = report(SampleXML.cii(iban: "DE89370400440532013001"))
        XCTAssertEqual(r.verdict, .eInvoiceWithWarnings)
        XCTAssertTrue(r.findings.contains { $0.id == "iban" && $0.severity == .warning })
    }

    func testNationalAccountNumberIsNotTreatedAsBrokenIBAN() {
        let r = report(SampleXML.cii(iban: "52491234"))
        XCTAssertFalse(r.findings.contains { $0.id == "iban" })
    }

    func testCreditTransferWithoutAccount() {
        let r = report(SampleXML.cii(iban: nil))
        XCTAssertTrue(r.findings.contains { $0.id == "iban.missing" && $0.severity == .error })
    }

    func testXRechnungNeedsBuyerReference() {
        let guideline = "urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0"
        let without = report(SampleXML.cii(guideline: guideline))
        XCTAssertEqual(without.profile, .xrechnung)
        XCTAssertTrue(without.findings.contains { $0.id == "xr.buyerref" })
        let with = report(SampleXML.cii(guideline: guideline, buyerReference: "04011000-12345-06"))
        XCTAssertFalse(with.findings.contains { $0.id == "xr.buyerref" })
    }

    func testExternalEntitiesAreNotResolved() {
        let xml = """
        <?xml version="1.0"?>
        <!DOCTYPE x [<!ENTITY leak SYSTEM "file:///etc/hosts">]>
        <rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100" xmlns:ram="urn:r">
        <rsm:ExchangedDocument><ram:ID>&leak;</ram:ID></rsm:ExchangedDocument>
        </rsm:CrossIndustryInvoice>
        """
        if case .invoice(let invoice) = InvoiceParser.parse(Data(xml.utf8)) {
            XCTAssertFalse((invoice.number ?? "").contains("localhost"), "external entity was expanded")
        }
    }
}

final class ComparisonTests: XCTestCase {
    private var invoice: Invoice {
        guard case .invoice(let invoice) = InvoiceParser.parse(SampleXML.cii(gross: "1190.00", due: "1190.00", net: "1000.00", vat: "190.00")) else {
            fatalError("sample does not parse")
        }
        return invoice
    }

    func testAgreeingPage() {
        let page = "Rechnung R-2026-001 vom 03.11.2026\nGesamtbetrag 1.190,00 EUR\nIBAN DE89 3704 0044 0532 0130 00"
        let c = PrintedComparison.compare(invoice: invoice, pageText: page)
        XCTAssertTrue(c.hasTextLayer)
        XCTAssertEqual(c.rows.count, 4)
        XCTAssertTrue(c.rows.allSatisfy { $0.state == .found }, "\(c.rows.map { ($0.field, $0.state) })")
    }

    func testDifferentIBANOnThePageIsReported() {
        let page = "Rechnung R-2026-001 vom 03.11.2026\nGesamtbetrag 1.190,00 EUR\nIBAN DE02 1203 0000 0000 2020 51 BIC BYLADEM1001"
        let c = PrintedComparison.compare(invoice: invoice, pageText: page)
        let row = c.rows.first { $0.field == .iban }
        XCTAssertEqual(row?.state, .differs(printed: ["DE02120300000000202051"]))
    }

    func testDifferentTotalOnThePage() {
        let page = "Rechnung R-2026-001 vom 03.11.2026\nGesamtbetrag 1.180,00 EUR\nIBAN DE89370400440532013000"
        let c = PrintedComparison.compare(invoice: invoice, pageText: page)
        XCTAssertEqual(c.rows.first { $0.field == .grossTotal }?.state, .notFound)
    }

    func testScanHasNothingToCompare() {
        XCTAssertFalse(PrintedComparison.compare(invoice: invoice, pageText: " \n ").hasTextLayer)
    }

    func testAmountMustStandAlone() {
        let amount = Decimal(string: "190.00")!
        XCTAssertFalse(PrintedComparison.containsAmount(amount, in: "Summe 1.190,00 EUR"))
        XCTAssertTrue(PrintedComparison.containsAmount(amount, in: "USt 190,00 EUR"))
        XCTAssertTrue(PrintedComparison.containsAmount(Decimal(string: "1190")!, in: "Total 1,190.00"))
        XCTAssertTrue(PrintedComparison.containsAmount(Decimal(string: "1190")!, in: "Total 1\u{00A0}190,00 €".replacingOccurrences(of: "\u{00A0}", with: " ")))
        XCTAssertTrue(PrintedComparison.containsAmount(Decimal(string: "1190")!, in: "CHF 1'190.00"))
    }

    func testDateSpellings() {
        let day = Day(year: 2026, month: 11, day: 3)!
        let candidates = PrintedComparison.dateCandidates(day)
        for spelling in ["03.11.2026", "3.11.2026", "2026-11-03", "3. November 2026", "November 3, 2026"] {
            XCTAssertTrue(candidates.contains(spelling), spelling)
        }
    }
}

final class SmallPartsTests: XCTestCase {
    func testIBAN() {
        XCTAssertTrue(IBAN.isValid("DE89 3704 0044 0532 0130 00"))
        XCTAssertTrue(IBAN.isValid("GB82WEST12345698765432"))
        XCTAssertTrue(IBAN.isValid("NL13RABO0377815500"))
        XCTAssertFalse(IBAN.isValid("DE89370400440532013001"))
        XCTAssertFalse(IBAN.isValid("52491234"))
        XCTAssertEqual(IBAN.grouped("DE89370400440532013000"), "DE89 3704 0044 0532 0130 00")
    }

    func testProfileDetection() {
        XCTAssertEqual(Profile.detect(guideline: "urn:factur-x.eu:1p0:minimum", syntax: .cii), .minimum)
        XCTAssertEqual(Profile.detect(guideline: "urn:factur-x.eu:1p0:basicwl", syntax: .cii), .basicWL)
        XCTAssertEqual(Profile.detect(guideline: "urn:cen.eu:en16931:2017#compliant#urn:factur-x.eu:1p0:basic", syntax: .cii), .basic)
        XCTAssertEqual(Profile.detect(guideline: "urn:cen.eu:en16931:2017", syntax: .cii), .en16931)
        XCTAssertEqual(Profile.detect(guideline: "urn:cen.eu:en16931:2017#conformant#urn:factur-x.eu:1p0:extended", syntax: .cii), .extended)
        XCTAssertEqual(Profile.detect(guideline: "urn:cen.eu:en16931:2017#compliant#urn:xoev-de:kosit:standard:xrechnung_2.3", syntax: .ubl), .xrechnung)
        XCTAssertEqual(Profile.detect(guideline: "urn:cen.eu:en16931:2017#compliant#urn:fdc:peppol.eu:2017:poacc:billing:3.0", syntax: .ubl), .peppol)
        XCTAssertEqual(Profile.detect(guideline: "urn:ferd:CrossIndustryDocument:invoice:1p0:comfort", syntax: .zugferd1), .zugferd1)
        XCTAssertEqual(Profile.detect(guideline: nil, syntax: .cii), .unknown)

        XCTAssertEqual(Profile.minimum.germanStatus, .doesNotQualify)
        XCTAssertEqual(Profile.basicWL.germanStatus, .doesNotQualify)
        XCTAssertEqual(Profile.basic.germanStatus, .qualifies)
        XCTAssertEqual(Profile.extended.germanStatus, .qualifies)
    }

    func testDayParsing() {
        XCTAssertEqual(Day(parsing: "20261103"), Day(year: 2026, month: 11, day: 3))
        XCTAssertEqual(Day(parsing: "2026-11-03"), Day(year: 2026, month: 11, day: 3))
        XCTAssertEqual(Day(parsing: "2026-11-03+01:00"), Day(year: 2026, month: 11, day: 3))
        XCTAssertNil(Day(parsing: "soon"))
        XCTAssertNil(Day(parsing: "20261350"))
    }

    func testXMPInBothSpellings() {
        let element = "<pdfaid:part>3</pdfaid:part><fx:ConformanceLevel>EN 16931</fx:ConformanceLevel><fx:DocumentFileName>factur-x.xml</fx:DocumentFileName>"
        XCTAssertEqual(PDFContainer.parseXMP(element), XMPInfo(pdfaPart: "3", conformanceLevel: "EN 16931", documentFileName: "factur-x.xml"))
        let attribute = "<rdf:Description pdfaid:part=\"3\" fx:ConformanceLevel=\"BASIC\"/>"
        XCTAssertEqual(PDFContainer.parseXMP(attribute)?.conformanceLevel, "BASIC")
        XCTAssertNil(PDFContainer.parseXMP("<x/>"))
    }

    func testMoneyFormatting() {
        XCTAssertEqual(Money.format(Decimal(string: "1190")!, currency: "EUR", lang: .de), "1.190,00 €")
        XCTAssertEqual(Money.format(Decimal(string: "1190")!, currency: "CHF", lang: .en), "1,190.00 CHF")
    }
}

/// A small, valid EN 16931 invoice whose parts can be bent for a test.
enum SampleXML {
    static func cii(
        guideline: String = "urn:cen.eu:en16931:2017",
        gross: String = "119.00",
        due: String = "119.00",
        net: String = "100.00",
        vat: String = "19.00",
        iban: String? = "DE89370400440532013000",
        sellerVAT: String? = "DE123456789",
        buyerReference: String? = nil
    ) -> Data {
        let buyerRef = buyerReference.map { "<ram:BuyerReference>\($0)</ram:BuyerReference>" } ?? ""
        let tax = sellerVAT.map { "<ram:SpecifiedTaxRegistration><ram:ID schemeID=\"VA\">\($0)</ram:ID></ram:SpecifiedTaxRegistration>" } ?? ""
        let account = iban.map { "<ram:PayeePartyCreditorFinancialAccount><ram:IBANID>\($0)</ram:IBANID></ram:PayeePartyCreditorFinancialAccount>" } ?? ""
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <rsm:CrossIndustryInvoice xmlns:rsm="urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100" xmlns:ram="urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100" xmlns:udt="urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100">
          <rsm:ExchangedDocumentContext><ram:GuidelineSpecifiedDocumentContextParameter><ram:ID>\(guideline)</ram:ID></ram:GuidelineSpecifiedDocumentContextParameter></rsm:ExchangedDocumentContext>
          <rsm:ExchangedDocument><ram:ID>R-2026-001</ram:ID><ram:TypeCode>380</ram:TypeCode><ram:IssueDateTime><udt:DateTimeString format="102">20261103</udt:DateTimeString></ram:IssueDateTime></rsm:ExchangedDocument>
          <rsm:SupplyChainTradeTransaction>
            <ram:IncludedSupplyChainTradeLineItem>
              <ram:AssociatedDocumentLineDocument><ram:LineID>1</ram:LineID></ram:AssociatedDocumentLineDocument>
              <ram:SpecifiedTradeProduct><ram:Name>Beratung</ram:Name></ram:SpecifiedTradeProduct>
              <ram:SpecifiedLineTradeAgreement><ram:NetPriceProductTradePrice><ram:ChargeAmount>\(net)</ram:ChargeAmount></ram:NetPriceProductTradePrice></ram:SpecifiedLineTradeAgreement>
              <ram:SpecifiedLineTradeDelivery><ram:BilledQuantity unitCode="HUR">1</ram:BilledQuantity></ram:SpecifiedLineTradeDelivery>
              <ram:SpecifiedLineTradeSettlement>
                <ram:ApplicableTradeTax><ram:TypeCode>VAT</ram:TypeCode><ram:CategoryCode>S</ram:CategoryCode><ram:RateApplicablePercent>19</ram:RateApplicablePercent></ram:ApplicableTradeTax>
                <ram:SpecifiedTradeSettlementLineMonetarySummation><ram:LineTotalAmount>\(net)</ram:LineTotalAmount></ram:SpecifiedTradeSettlementLineMonetarySummation>
              </ram:SpecifiedLineTradeSettlement>
            </ram:IncludedSupplyChainTradeLineItem>
            <ram:ApplicableHeaderTradeAgreement>
              \(buyerRef)
              <ram:SellerTradeParty><ram:Name>Muster GmbH</ram:Name>
                <ram:DefinedTradeContact><ram:PersonName>Erika Muster</ram:PersonName><ram:TelephoneUniversalCommunication><ram:CompleteNumber>+49 30 1234</ram:CompleteNumber></ram:TelephoneUniversalCommunication><ram:EmailURIUniversalCommunication><ram:URIID>erika@example.com</ram:URIID></ram:EmailURIUniversalCommunication></ram:DefinedTradeContact>
                <ram:PostalTradeAddress><ram:PostcodeCode>10115</ram:PostcodeCode><ram:LineOne>Weg 1</ram:LineOne><ram:CityName>Berlin</ram:CityName><ram:CountryID>DE</ram:CountryID></ram:PostalTradeAddress>
                \(tax)
              </ram:SellerTradeParty>
              <ram:BuyerTradeParty><ram:Name>Kunde AG</ram:Name><ram:PostalTradeAddress><ram:CountryID>DE</ram:CountryID></ram:PostalTradeAddress></ram:BuyerTradeParty>
            </ram:ApplicableHeaderTradeAgreement>
            <ram:ApplicableHeaderTradeDelivery/>
            <ram:ApplicableHeaderTradeSettlement>
              <ram:InvoiceCurrencyCode>EUR</ram:InvoiceCurrencyCode>
              <ram:SpecifiedTradeSettlementPaymentMeans><ram:TypeCode>58</ram:TypeCode>\(account)</ram:SpecifiedTradeSettlementPaymentMeans>
              <ram:ApplicableTradeTax><ram:CalculatedAmount>\(vat)</ram:CalculatedAmount><ram:TypeCode>VAT</ram:TypeCode><ram:BasisAmount>\(net)</ram:BasisAmount><ram:CategoryCode>S</ram:CategoryCode><ram:RateApplicablePercent>19</ram:RateApplicablePercent></ram:ApplicableTradeTax>
              <ram:SpecifiedTradeSettlementHeaderMonetarySummation>
                <ram:LineTotalAmount>\(net)</ram:LineTotalAmount><ram:TaxBasisTotalAmount>\(net)</ram:TaxBasisTotalAmount>
                <ram:TaxTotalAmount currencyID="EUR">\(vat)</ram:TaxTotalAmount>
                <ram:GrandTotalAmount>\(gross)</ram:GrandTotalAmount><ram:DuePayableAmount>\(due)</ram:DuePayableAmount>
              </ram:SpecifiedTradeSettlementHeaderMonetarySummation>
            </ram:ApplicableHeaderTradeSettlement>
          </rsm:SupplyChainTradeTransaction>
        </rsm:CrossIndustryInvoice>
        """
        return Data(xml.utf8)
    }
}
