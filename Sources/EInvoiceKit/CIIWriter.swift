import Foundation

/// Writes an `InvoiceDraft` as UN/CEFACT CII D16B, the syntax of ZUGFeRD 2,
/// Factur-X and XRechnung (CII). Element order follows the CII schema, which
/// validators enforce.
public enum CIIWriter {
    public static let en16931Guideline = "urn:cen.eu:en16931:2017"
    public static let xrechnungGuideline = "urn:cen.eu:en16931:2017#compliant#urn:xeinkauf.de:kosit:xrechnung_3.0"
    public static let peppolProcess = "urn:fdc:peppol.eu:2017:poacc:billing:01:1.0"

    public static func xml(_ draft: InvoiceDraft) -> Data {
        var w = XMLText()
        let currency = draft.currency.uppercased()

        w.raw("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
        w.open("rsm:CrossIndustryInvoice", attributes: [
            ("xmlns:rsm", "urn:un:unece:uncefact:data:standard:CrossIndustryInvoice:100"),
            ("xmlns:ram", "urn:un:unece:uncefact:data:standard:ReusableAggregateBusinessInformationEntity:100"),
            ("xmlns:qdt", "urn:un:unece:uncefact:data:standard:QualifiedDataType:100"),
            ("xmlns:udt", "urn:un:unece:uncefact:data:standard:UnqualifiedDataType:100"),
        ])

        w.open("rsm:ExchangedDocumentContext")
        if draft.format == .xrechnungXML {
            w.open("ram:BusinessProcessSpecifiedDocumentContextParameter")
            w.leaf("ram:ID", peppolProcess)
            w.close()
        }
        w.open("ram:GuidelineSpecifiedDocumentContextParameter")
        w.leaf("ram:ID", draft.format == .xrechnungXML ? xrechnungGuideline : en16931Guideline)
        w.close()
        w.close()

        w.open("rsm:ExchangedDocument")
        w.leaf("ram:ID", draft.number)
        w.leaf("ram:TypeCode", draft.typeCode)
        w.date("ram:IssueDateTime", draft.issueDate)
        for note in [draft.note, exemptionNote(draft)].compactMap({ $0 }) where !note.isBlank {
            w.open("ram:IncludedNote")
            w.leaf("ram:Content", note)
            w.close()
        }
        w.close()

        w.open("rsm:SupplyChainTradeTransaction")

        for (index, line) in draft.lines.enumerated() {
            w.open("ram:IncludedSupplyChainTradeLineItem")
            w.open("ram:AssociatedDocumentLineDocument")
            w.leaf("ram:LineID", String(index + 1))
            w.close()
            w.open("ram:SpecifiedTradeProduct")
            w.leaf("ram:Name", line.name)
            w.close()
            w.open("ram:SpecifiedLineTradeAgreement")
            w.open("ram:NetPriceProductTradePrice")
            w.leaf("ram:ChargeAmount", Format.price(line.unitPrice))
            w.close()
            w.close()
            w.open("ram:SpecifiedLineTradeDelivery")
            w.leaf("ram:BilledQuantity", Format.quantity(line.quantity), attributes: [("unitCode", line.unit.rawValue)])
            w.close()
            w.open("ram:SpecifiedLineTradeSettlement")
            w.open("ram:ApplicableTradeTax")
            w.leaf("ram:TypeCode", "VAT")
            w.leaf("ram:CategoryCode", line.tax.categoryCode)
            w.leaf("ram:RateApplicablePercent", Format.rate(line.tax.rate))
            w.close()
            w.open("ram:SpecifiedTradeSettlementLineMonetarySummation")
            w.leaf("ram:LineTotalAmount", Format.amount(line.netAmount))
            w.close()
            w.close()
            w.close()
        }

        w.open("ram:ApplicableHeaderTradeAgreement")
        w.optionalLeaf("ram:BuyerReference", draft.buyerReference)
        party(&w, "ram:SellerTradeParty", draft.seller, withContact: true)
        party(&w, "ram:BuyerTradeParty", draft.buyer, withContact: false)
        if !draft.orderReference.isBlank {
            w.open("ram:BuyerOrderReferencedDocument")
            w.leaf("ram:IssuerAssignedID", draft.orderReference)
            w.close()
        }
        w.close()

        w.open("ram:ApplicableHeaderTradeDelivery")
        if !draft.usesPeriod {
            w.open("ram:ActualDeliverySupplyChainEvent")
            w.date("ram:OccurrenceDateTime", draft.deliveryDate)
            w.close()
        }
        w.close()

        w.open("ram:ApplicableHeaderTradeSettlement")
        w.leaf("ram:PaymentReference", draft.number)
        w.leaf("ram:InvoiceCurrencyCode", currency)
        let iban = draft.iban.filter { !$0.isWhitespace }.uppercased()
        w.open("ram:SpecifiedTradeSettlementPaymentMeans")
        // 58 = SEPA credit transfer; 1 = not specified.
        w.leaf("ram:TypeCode", iban.isEmpty ? "1" : "58")
        if !iban.isEmpty {
            w.open("ram:PayeePartyCreditorFinancialAccount")
            w.leaf("ram:IBANID", iban)
            w.optionalLeaf("ram:AccountName", draft.accountName)
            w.close()
            if !draft.bic.isBlank {
                w.open("ram:PayeeSpecifiedCreditorFinancialInstitution")
                w.leaf("ram:BICID", draft.bic.filter { !$0.isWhitespace }.uppercased())
                w.close()
            }
        }
        w.close()

        for group in draft.taxGroups {
            w.open("ram:ApplicableTradeTax")
            w.leaf("ram:CalculatedAmount", Format.amount(group.tax))
            w.leaf("ram:TypeCode", "VAT")
            if let reason = group.treatment.exemptionReason { w.leaf("ram:ExemptionReason", reason) }
            w.leaf("ram:BasisAmount", Format.amount(group.basis))
            w.leaf("ram:CategoryCode", group.treatment.categoryCode)
            if let code = group.treatment.exemptionCode { w.leaf("ram:ExemptionReasonCode", code) }
            w.leaf("ram:RateApplicablePercent", Format.rate(group.treatment.rate))
            w.close()
        }

        if draft.usesPeriod {
            w.open("ram:BillingSpecifiedPeriod")
            w.date("ram:StartDateTime", draft.periodStart)
            w.date("ram:EndDateTime", draft.periodEnd)
            w.close()
        }

        if draft.hasDueDate || !draft.paymentTerms.isBlank {
            w.open("ram:SpecifiedTradePaymentTerms")
            w.optionalLeaf("ram:Description", draft.paymentTerms)
            if draft.hasDueDate { w.date("ram:DueDateDateTime", draft.dueDate) }
            w.close()
        }

        w.open("ram:SpecifiedTradeSettlementHeaderMonetarySummation")
        w.leaf("ram:LineTotalAmount", Format.amount(draft.lineTotal))
        w.leaf("ram:TaxBasisTotalAmount", Format.amount(draft.lineTotal))
        w.leaf("ram:TaxTotalAmount", Format.amount(draft.taxTotal), attributes: [("currencyID", currency)])
        w.leaf("ram:GrandTotalAmount", Format.amount(draft.grossTotal))
        w.leaf("ram:DuePayableAmount", Format.amount(draft.grossTotal))
        w.close()

        w.close() // ApplicableHeaderTradeSettlement
        w.close() // SupplyChainTradeTransaction
        w.close() // CrossIndustryInvoice
        return Data(w.text.utf8)
    }

    /// § 14 (4) UStG wants the reason for a missing VAT amount on the invoice
    /// itself; the VAT breakdown carries it for software, the note for people.
    private static func exemptionNote(_ draft: InvoiceDraft) -> String? {
        let reasons = draft.taxGroups.compactMap(\.treatment.exemptionReason)
        return reasons.isEmpty ? nil : reasons.joined(separator: "\n")
    }

    private static func party(_ w: inout XMLText, _ element: String, _ p: DraftParty, withContact: Bool) {
        w.open(element)
        w.leaf("ram:Name", p.name)
        if withContact && !(p.contactName.isBlank && p.phone.isBlank && p.email.isBlank) {
            w.open("ram:DefinedTradeContact")
            w.optionalLeaf("ram:PersonName", p.contactName)
            if !p.phone.isBlank {
                w.open("ram:TelephoneUniversalCommunication")
                w.leaf("ram:CompleteNumber", p.phone)
                w.close()
            }
            if !p.email.isBlank {
                w.open("ram:EmailURIUniversalCommunication")
                w.leaf("ram:URIID", p.email)
                w.close()
            }
            w.close()
        }
        w.open("ram:PostalTradeAddress")
        w.optionalLeaf("ram:PostcodeCode", p.postcode)
        w.optionalLeaf("ram:LineOne", p.street)
        w.optionalLeaf("ram:CityName", p.city)
        w.leaf("ram:CountryID", p.country.uppercased())
        w.close()
        // BT-34 / BT-49: the electronic address, here the e-mail ("EM").
        if !p.email.isBlank {
            w.open("ram:URIUniversalCommunication")
            w.leaf("ram:URIID", p.email, attributes: [("schemeID", "EM")])
            w.close()
        }
        if !p.vatID.isBlank {
            w.open("ram:SpecifiedTaxRegistration")
            w.leaf("ram:ID", p.vatID.filter { !$0.isWhitespace }.uppercased(), attributes: [("schemeID", "VA")])
            w.close()
        }
        if !p.taxNumber.isBlank {
            w.open("ram:SpecifiedTaxRegistration")
            w.leaf("ram:ID", p.taxNumber, attributes: [("schemeID", "FC")])
            w.close()
        }
        w.close()
    }
}

/// Number formats the CII schema accepts: a dot, no grouping.
enum Format {
    private static func formatter(min: Int, max: Int) -> NumberFormatter {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = min
        f.maximumFractionDigits = max
        f.roundingMode = .halfUp
        return f
    }
    private static let amountFormatter = formatter(min: 2, max: 2)
    private static let priceFormatter = formatter(min: 2, max: 4)
    private static let quantityFormatter = formatter(min: 0, max: 4)

    static func amount(_ d: Decimal) -> String { amountFormatter.string(from: d as NSDecimalNumber) ?? "0.00" }
    static func price(_ d: Decimal) -> String { priceFormatter.string(from: d as NSDecimalNumber) ?? "0.00" }
    static func quantity(_ d: Decimal) -> String { quantityFormatter.string(from: d as NSDecimalNumber) ?? "0" }
    static func rate(_ d: Decimal) -> String { quantityFormatter.string(from: d as NSDecimalNumber) ?? "0" }

    /// CII date format 102: `20261111`, in the user's calendar day.
    static func day(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        return String(format: "%04d%02d%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}

/// A minimal pretty-printing XML builder with escaping.
struct XMLText {
    private(set) var text = ""
    private var stack: [String] = []

    mutating func raw(_ s: String) { text += s }

    private var indent: String { String(repeating: "  ", count: stack.count) }

    mutating func open(_ name: String, attributes: [(String, String)] = []) {
        text += "\(indent)<\(name)\(Self.attributes(attributes))>\n"
        stack.append(name)
    }

    mutating func close() {
        let name = stack.removeLast()
        text += "\(indent)</\(name)>\n"
    }

    mutating func leaf(_ name: String, _ value: String, attributes: [(String, String)] = []) {
        text += "\(indent)<\(name)\(Self.attributes(attributes))>\(Self.escape(value.trimmingCharacters(in: .whitespacesAndNewlines)))</\(name)>\n"
    }

    mutating func optionalLeaf(_ name: String, _ value: String) {
        if !value.isBlank { leaf(name, value) }
    }

    mutating func date(_ name: String, _ date: Date) {
        open(name)
        leaf("udt:DateTimeString", Format.day(date), attributes: [("format", "102")])
        close()
    }

    private static func attributes(_ list: [(String, String)]) -> String {
        list.map { " \($0.0)=\"\(escape($0.1))\"" }.joined()
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            // Control characters other than tab and newlines are not allowed in XML 1.0.
            case _ where scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r": continue
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

extension String {
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
