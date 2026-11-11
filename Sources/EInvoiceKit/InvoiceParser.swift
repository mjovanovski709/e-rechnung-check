import Foundation

public enum ParseOutcome: Sendable {
    case invoice(Invoice)
    /// Well-formed XML, but not one of the invoice dialects we know.
    case notAnInvoice(rootName: String)
    /// Not well-formed XML at all.
    case malformed(String)
}

/// Turns invoice XML into an `Invoice`. Lookups go by local element name and
/// ignore namespace prefixes, because real files use `ram:`, `ns2:` or none.
public enum InvoiceParser {
    public static func parse(_ data: Data) -> ParseOutcome {
        let document: XMLDocument
        do {
            // Never fetch external entities: an invoice from a stranger must
            // not be able to make this Mac read local files or call out.
            document = try XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever])
        } catch {
            return .malformed(error.localizedDescription)
        }
        guard let root = document.rootElement(), let name = root.localName else {
            return .malformed("no root element")
        }
        switch name {
        case "CrossIndustryInvoice":
            return .invoice(parseCII(root, syntax: .cii))
        case "CrossIndustryDocument":
            return .invoice(parseCII(root, syntax: .zugferd1))
        case "Invoice" where root.first("HeaderExchangedDocument") != nil:
            // The 2014 ZUGFeRD release candidate, still found in old archives.
            return .invoice(parseCII(root, syntax: .zugferd1))
        case "Invoice", "CreditNote":
            let ns = root.uri ?? ""
            let looksUBL = ns.contains("oasis:names:specification:ubl")
                || root.first("AccountingSupplierParty") != nil
            return looksUBL ? .invoice(parseUBL(root)) : .notAnInvoice(rootName: name)
        default:
            return .notAnInvoice(rootName: name)
        }
    }

    // MARK: - CII (ZUGFeRD 2.x, Factur-X, XRechnung CII) and ZUGFeRD 1.0

    /// ZUGFeRD 1.0 uses the same structure with older element names, so each
    /// lookup lists both spellings.
    private static func parseCII(_ root: XMLElement, syntax: Syntax) -> Invoice {
        var inv = Invoice(syntax: syntax)

        let context = root.first("ExchangedDocumentContext", "SpecifiedExchangedDocumentContext")
        inv.guidelineID = context?.text("GuidelineSpecifiedDocumentContextParameter", "ID")
        inv.businessProcess = context?.text("BusinessProcessSpecifiedDocumentContextParameter", "ID")

        let doc = root.first("ExchangedDocument", "HeaderExchangedDocument")
        inv.number = doc?.text("ID")
        inv.typeCode = doc?.text("TypeCode")
        inv.issueDate = (doc?.text("IssueDateTime", "DateTimeString") ?? doc?.text("IssueDateTime"))
            .flatMap(Day.init(parsing:))
        inv.notes = (doc?.all("IncludedNote") ?? []).compactMap { $0.text("Content") }

        guard let tx = root.first("SupplyChainTradeTransaction", "SpecifiedSupplyChainTradeTransaction") else {
            return inv
        }

        if let agreement = tx.first("ApplicableHeaderTradeAgreement", "ApplicableSupplyChainTradeAgreement") {
            inv.buyerReference = agreement.text("BuyerReference")
            inv.orderReference = agreement.first("BuyerOrderReferencedDocument")?.text(anyOf: "IssuerAssignedID", "ID")
            if let seller = agreement.first("SellerTradeParty") { inv.seller = ciiParty(seller) }
            if let buyer = agreement.first("BuyerTradeParty") { inv.buyer = ciiParty(buyer) }
        }

        if let delivery = tx.first("ApplicableHeaderTradeDelivery", "ApplicableSupplyChainTradeDelivery") {
            inv.deliveryDate = delivery
                .text("ActualDeliverySupplyChainEvent", "OccurrenceDateTime", "DateTimeString")
                .flatMap(Day.init(parsing:))
        }

        if let s = tx.first("ApplicableHeaderTradeSettlement", "ApplicableSupplyChainTradeSettlement") {
            inv.currency = s.text("InvoiceCurrencyCode")
            inv.payment.reference = s.text("PaymentReference")

            let means = s.all("SpecifiedTradeSettlementPaymentMeans")
            // Several payment means may be listed; the one with an IBAN is the
            // one a payer acts on.
            let chosen = means.first { $0.text("PayeePartyCreditorFinancialAccount", "IBANID") != nil } ?? means.first
            inv.payment.meansCode = chosen?.text("TypeCode")
            inv.payment.iban = chosen?.text("PayeePartyCreditorFinancialAccount", "IBANID")
            inv.payment.accountName = chosen?.text("PayeePartyCreditorFinancialAccount", "AccountName")
            inv.payment.bic = chosen?.text("PayeeSpecifiedCreditorFinancialInstitution", "BICID")

            inv.vatRows = s.all("ApplicableTradeTax").map { tax in
                var row = VATRow()
                row.tax = Money.parse(tax.text("CalculatedAmount"))
                row.basis = Money.parse(tax.text("BasisAmount"))
                row.category = tax.text("CategoryCode")
                row.rate = Money.parse(tax.text(anyOf: "RateApplicablePercent", "ApplicablePercent"))
                row.exemptionReason = tax.text("ExemptionReason")
                return row
            }

            if let period = s.first("BillingSpecifiedPeriod") {
                inv.periodStart = period.text("StartDateTime", "DateTimeString").flatMap(Day.init(parsing:))
                inv.periodEnd = period.text("EndDateTime", "DateTimeString").flatMap(Day.init(parsing:))
            }

            if let terms = s.first("SpecifiedTradePaymentTerms") {
                inv.payment.terms = terms.text("Description")
                inv.payment.dueDate = terms.text("DueDateDateTime", "DateTimeString").flatMap(Day.init(parsing:))
            }

            if let sums = s.first("SpecifiedTradeSettlementHeaderMonetarySummation", "SpecifiedTradeSettlementMonetarySummation") {
                inv.totals.lineTotal = Money.parse(sums.text("LineTotalAmount"))
                inv.totals.charges = Money.parse(sums.text("ChargeTotalAmount"))
                inv.totals.allowances = Money.parse(sums.text("AllowanceTotalAmount"))
                inv.totals.netTotal = Money.parse(sums.text("TaxBasisTotalAmount"))
                // The VAT total can appear twice (invoice currency and
                // accounting currency); take the one in the invoice currency.
                let taxTotals = sums.all("TaxTotalAmount")
                let inCurrency = taxTotals.first { $0.attr("currencyID") == inv.currency } ?? taxTotals.first
                inv.totals.vatTotal = Money.parse(inCurrency?.trimmedText)
                inv.totals.grossTotal = Money.parse(sums.text("GrandTotalAmount"))
                inv.totals.prepaid = Money.parse(sums.text("TotalPrepaidAmount"))
                inv.totals.rounding = Money.parse(sums.text("RoundingAmount"))
                inv.totals.due = Money.parse(sums.text("DuePayableAmount"))
            }
        }

        inv.lines = tx.all("IncludedSupplyChainTradeLineItem").compactMap { item in
            var line = InvoiceLine()
            line.id = item.text("AssociatedDocumentLineDocument", "LineID")
            line.name = item.text("SpecifiedTradeProduct", "Name")
            let agreement = item.first("SpecifiedLineTradeAgreement", "SpecifiedSupplyChainTradeAgreement")
            line.unitPrice = Money.parse(agreement?.text("NetPriceProductTradePrice", "ChargeAmount"))
            let delivery = item.first("SpecifiedLineTradeDelivery", "SpecifiedSupplyChainTradeDelivery")
            let quantity = delivery?.first("BilledQuantity")
            line.quantity = Money.parse(quantity?.trimmedText)
            line.unit = quantity?.attr("unitCode")
            let settlement = item.first("SpecifiedLineTradeSettlement", "SpecifiedSupplyChainTradeSettlement")
            let tax = settlement?.first("ApplicableTradeTax")
            line.vatRate = Money.parse(tax?.text(anyOf: "RateApplicablePercent", "ApplicablePercent"))
            line.vatCategory = tax?.text("CategoryCode")
            let sum = settlement?.first("SpecifiedTradeSettlementLineMonetarySummation", "SpecifiedTradeSettlementMonetarySummation")
            line.netAmount = Money.parse(sum?.text("LineTotalAmount"))
            // ZUGFeRD 1.0 allows pure text lines with no product and no amount.
            if line.name == nil && line.netAmount == nil && line.quantity == nil { return nil }
            return line
        }

        return inv
    }

    private static func ciiParty(_ el: XMLElement) -> Party {
        var p = Party()
        p.name = el.text("Name")
        p.legalID = el.text("SpecifiedLegalOrganization", "ID")
        p.tradingName = el.text("SpecifiedLegalOrganization", "TradingBusinessName")
        if let address = el.first("PostalTradeAddress") {
            p.street = address.text("LineOne")
            p.postcode = address.text("PostcodeCode")
            p.city = address.text("CityName")
            p.country = address.text("CountryID")
        }
        for registration in el.all("SpecifiedTaxRegistration") {
            guard let id = registration.first("ID"), let value = id.trimmedText else { continue }
            switch id.attr("schemeID") {
            case "VA": p.vatID = value
            case "FC": p.taxNumber = value
            default: if p.vatID == nil { p.vatID = value }
            }
        }
        if let contact = el.first("DefinedTradeContact") {
            p.contactName = contact.text(anyOf: "PersonName", "DepartmentName")
            p.phone = contact.text("TelephoneUniversalCommunication", "CompleteNumber")
            p.email = contact.text("EmailURIUniversalCommunication", "URIID")
        }
        return p
    }

    // MARK: - UBL (XRechnung UBL, Peppol BIS)

    private static func parseUBL(_ root: XMLElement) -> Invoice {
        var inv = Invoice(syntax: .ubl)
        let isCreditNote = root.localName == "CreditNote"

        inv.guidelineID = root.text("CustomizationID")
        inv.businessProcess = root.text("ProfileID")
        inv.number = root.text("ID")
        inv.typeCode = root.text(anyOf: "InvoiceTypeCode", "CreditNoteTypeCode") ?? (isCreditNote ? "381" : nil)
        inv.issueDate = root.text("IssueDate").flatMap(Day.init(parsing:))
        inv.currency = root.text("DocumentCurrencyCode")
        inv.buyerReference = root.text("BuyerReference")
        inv.orderReference = root.text("OrderReference", "ID")
        inv.notes = root.all("Note").compactMap(\.trimmedText)
        inv.payment.dueDate = root.text("DueDate").flatMap(Day.init(parsing:))

        if let period = root.first("InvoicePeriod") {
            inv.periodStart = period.text("StartDate").flatMap(Day.init(parsing:))
            inv.periodEnd = period.text("EndDate").flatMap(Day.init(parsing:))
        }
        inv.deliveryDate = root.text("Delivery", "ActualDeliveryDate").flatMap(Day.init(parsing:))

        if let seller = root.first("AccountingSupplierParty")?.first("Party") { inv.seller = ublParty(seller) }
        if let buyer = root.first("AccountingCustomerParty")?.first("Party") { inv.buyer = ublParty(buyer) }

        let means = root.all("PaymentMeans")
        let chosen = means.first { $0.text("PayeeFinancialAccount", "ID") != nil } ?? means.first
        inv.payment.meansCode = chosen?.text("PaymentMeansCode")
        inv.payment.reference = chosen?.text("PaymentID")
        inv.payment.iban = chosen?.text("PayeeFinancialAccount", "ID")
        inv.payment.accountName = chosen?.text("PayeeFinancialAccount", "Name")
        inv.payment.bic = chosen?.text("PayeeFinancialAccount", "FinancialInstitutionBranch", "ID")
        inv.payment.terms = root.text("PaymentTerms", "Note")

        // A second TaxTotal without subtotals carries the VAT in accounting
        // currency; the breakdown lives in the one that has subtotals.
        let taxTotals = root.all("TaxTotal")
        let mainTax = taxTotals.first { !$0.all("TaxSubtotal").isEmpty } ?? taxTotals.first
        inv.totals.vatTotal = Money.parse(mainTax?.text("TaxAmount"))
        inv.vatRows = (mainTax?.all("TaxSubtotal") ?? []).map { sub in
            var row = VATRow()
            row.basis = Money.parse(sub.text("TaxableAmount"))
            row.tax = Money.parse(sub.text("TaxAmount"))
            let category = sub.first("TaxCategory")
            row.category = category?.text("ID")
            row.rate = Money.parse(category?.text("Percent"))
            row.exemptionReason = category?.text("TaxExemptionReason")
            return row
        }

        if let sums = root.first("LegalMonetaryTotal") {
            inv.totals.lineTotal = Money.parse(sums.text("LineExtensionAmount"))
            inv.totals.netTotal = Money.parse(sums.text("TaxExclusiveAmount"))
            inv.totals.grossTotal = Money.parse(sums.text("TaxInclusiveAmount"))
            inv.totals.allowances = Money.parse(sums.text("AllowanceTotalAmount"))
            inv.totals.charges = Money.parse(sums.text("ChargeTotalAmount"))
            inv.totals.prepaid = Money.parse(sums.text("PrepaidAmount"))
            inv.totals.rounding = Money.parse(sums.text("PayableRoundingAmount"))
            inv.totals.due = Money.parse(sums.text("PayableAmount"))
        }

        inv.lines = root.all(isCreditNote ? "CreditNoteLine" : "InvoiceLine").map { item in
            var line = InvoiceLine()
            line.id = item.text("ID")
            let quantity = item.first("InvoicedQuantity", "CreditedQuantity")
            line.quantity = Money.parse(quantity?.trimmedText)
            line.unit = quantity?.attr("unitCode")
            line.netAmount = Money.parse(item.text("LineExtensionAmount"))
            let product = item.first("Item")
            line.name = product?.text("Name")
            line.vatRate = Money.parse(product?.text("ClassifiedTaxCategory", "Percent"))
            line.vatCategory = product?.text("ClassifiedTaxCategory", "ID")
            line.unitPrice = Money.parse(item.text("Price", "PriceAmount"))
            return line
        }

        return inv
    }

    private static func ublParty(_ el: XMLElement) -> Party {
        var p = Party()
        // BT-27 is the registered name; PartyName is only the trading name.
        p.name = el.text("PartyLegalEntity", "RegistrationName") ?? el.text("PartyName", "Name")
        p.tradingName = el.text("PartyName", "Name")
        p.legalID = el.text("PartyLegalEntity", "CompanyID")
        if let address = el.first("PostalAddress") {
            p.street = address.text("StreetName")
            p.postcode = address.text("PostalZone")
            p.city = address.text("CityName")
            p.country = address.text("Country", "IdentificationCode")
        }
        for scheme in el.all("PartyTaxScheme") {
            guard let value = scheme.text("CompanyID") else { continue }
            switch scheme.text("TaxScheme", "ID")?.uppercased() {
            case "VAT": p.vatID = value
            case "FC": p.taxNumber = value
            default: if p.vatID == nil { p.vatID = value }
            }
        }
        if let contact = el.first("Contact") {
            p.contactName = contact.text("Name")
            p.phone = contact.text("Telephone")
            p.email = contact.text("ElectronicMail")
        }
        return p
    }
}

// MARK: - Namespace-agnostic XML lookups

extension XMLElement {
    /// Direct child elements with this local name.
    func all(_ name: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.localName == name }
    }

    /// First direct child matching any of the given names.
    func first(_ names: String...) -> XMLElement? {
        for name in names {
            if let hit = all(name).first { return hit }
        }
        return nil
    }

    /// Text at the end of a path of child names, or nil when any step is
    /// missing or the text is empty.
    func text(_ path: String...) -> String? {
        var current: XMLElement? = self
        for step in path {
            current = current?.all(step).first
        }
        return current?.trimmedText
    }

    /// Text of the first existing child among alternative names.
    func text(anyOf names: String...) -> String? {
        for name in names {
            if let value = all(name).first?.trimmedText { return value }
        }
        return nil
    }

    func attr(_ name: String) -> String? {
        attribute(forName: name)?.stringValue
    }

    var trimmedText: String? {
        guard let value = stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
