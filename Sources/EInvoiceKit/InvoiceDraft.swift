import Foundation

/// What the user wants to produce.
public enum OutputFormat: String, Codable, CaseIterable, Sendable {
    /// A PDF with the invoice XML embedded, profile EN 16931 (ZUGFeRD 2 /
    /// Factur-X "COMFORT"). The usual choice between businesses.
    case zugferdPDF
    /// A plain XRechnung 3.0 XML file in CII syntax, required by German
    /// public bodies.
    case xrechnungXML
}

/// The VAT treatment of a line, as offered in the form. Each case maps to an
/// EN 16931 VAT category code, a rate and, where the rules demand one, an
/// exemption reason (BT-120).
public enum TaxTreatment: String, Codable, CaseIterable, Sendable {
    case standard19
    case reduced7
    /// § 19 UStG: small businesses that do not charge VAT.
    case smallBusiness
    /// § 13b UStG: the buyer owes the VAT.
    case reverseCharge
    /// Tax-free supply of goods to a business in another EU country.
    case intraEU
    /// Tax-free export outside the EU.
    case export
    /// Zero rate, e.g. photovoltaic systems under § 12 (3) UStG.
    case zeroRated

    public var categoryCode: String {
        switch self {
        case .standard19, .reduced7: return "S"
        case .smallBusiness: return "E"
        case .reverseCharge: return "AE"
        case .intraEU: return "K"
        case .export: return "G"
        case .zeroRated: return "Z"
        }
    }

    public var rate: Decimal {
        switch self {
        case .standard19: return 19
        case .reduced7: return 7
        default: return 0
        }
    }

    /// BT-120. Mandatory for E, AE, K and G; forbidden for S and Z.
    public var exemptionReason: String? {
        switch self {
        case .smallBusiness: return "Kein Ausweis von Umsatzsteuer, da Kleinunternehmer gemäß § 19 UStG"
        case .reverseCharge: return "Steuerschuldnerschaft des Leistungsempfängers (§ 13b UStG)"
        case .intraEU: return "Steuerfreie innergemeinschaftliche Lieferung (§ 4 Nr. 1b UStG)"
        case .export: return "Steuerfreie Ausfuhrlieferung (§ 4 Nr. 1a UStG)"
        case .standard19, .reduced7, .zeroRated: return nil
        }
    }

    /// BT-121, the code form of the exemption reason.
    public var exemptionCode: String? {
        switch self {
        case .reverseCharge: return "VATEX-EU-AE"
        case .intraEU: return "VATEX-EU-IC"
        case .export: return "VATEX-EU-G"
        default: return nil
        }
    }

    public func label(_ lang: Lang) -> String {
        switch self {
        case .standard19: return lang == .de ? "19 %" : "19%"
        case .reduced7: return lang == .de ? "7 %" : "7%"
        case .smallBusiness: return lang == .de ? "Kleinunternehmer (§ 19)" : "Small business (§ 19)"
        case .reverseCharge: return lang == .de ? "Reverse Charge (§ 13b)" : "Reverse charge (§ 13b)"
        case .intraEU: return lang == .de ? "Innergemeinschaftlich" : "Intra-EU supply"
        case .export: return lang == .de ? "Ausfuhr (Drittland)" : "Export (outside EU)"
        case .zeroRated: return lang == .de ? "0 % (Nullsatz)" : "0% (zero rate)"
        }
    }
}

/// UN/ECE Recommendation 20 unit codes that cover most small-business
/// invoices.
public enum UnitCode: String, Codable, CaseIterable, Sendable {
    case piece = "C62", hour = "HUR", day = "DAY", month = "MON", lumpSum = "LS"
    case kilogram = "KGM", metre = "MTR", squareMetre = "MTK", litre = "LTR", kilometre = "KMT"

    public func label(_ lang: Lang) -> String {
        switch self {
        case .piece: return lang == .de ? "Stück" : "piece"
        case .hour: return lang == .de ? "Stunde" : "hour"
        case .day: return lang == .de ? "Tag" : "day"
        case .month: return lang == .de ? "Monat" : "month"
        case .lumpSum: return lang == .de ? "pauschal" : "lump sum"
        case .kilogram: return "kg"
        case .metre: return "m"
        case .squareMetre: return "m²"
        case .litre: return lang == .de ? "Liter" : "litre"
        case .kilometre: return "km"
        }
    }
}

public struct DraftParty: Codable, Equatable, Sendable {
    public var name = ""
    public var street = ""
    public var postcode = ""
    public var city = ""
    /// ISO 3166-1 alpha-2.
    public var country = "DE"
    public var vatID = ""
    public var taxNumber = ""
    public var contactName = ""
    public var phone = ""
    public var email = ""

    public init() {}
}

public struct DraftLine: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var name = ""
    public var quantity: Decimal = 1
    public var unit: UnitCode = .piece
    /// Net price per unit.
    public var unitPrice: Decimal = 0
    public var tax: TaxTreatment = .standard19

    public init() {}

    /// BT-131, rounded to cents as BR-DEC-23 requires.
    public var netAmount: Decimal { Money.rounded(quantity * unitPrice) }
}

/// One row of the VAT breakdown, computed from the lines.
public struct DraftTaxGroup: Equatable, Sendable {
    public let treatment: TaxTreatment
    public let basis: Decimal
    public let tax: Decimal
}

/// Everything the form collects. Amounts are derived from the lines, never
/// typed in, so the totals in the XML always add up.
public struct InvoiceDraft: Codable, Equatable, Sendable {
    public var format: OutputFormat = .zugferdPDF
    /// 380 invoice, 381 credit note, 384 corrected invoice, 326 partial invoice.
    public var typeCode = "380"
    public var number = ""
    public var issueDate = Date()
    /// Delivery or service date. Ignored when a service period is set.
    public var deliveryDate = Date()
    public var usesPeriod = false
    public var periodStart = Date()
    public var periodEnd = Date()
    public var hasDueDate = true
    public var dueDate = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    public var currency = "EUR"
    /// BT-10. For XRechnung the buyer's Leitweg-ID.
    public var buyerReference = ""
    public var orderReference = ""
    public var note = ""
    public var paymentTerms = ""
    public var seller = DraftParty()
    public var buyer = DraftParty()
    public var lines: [DraftLine] = [DraftLine()]
    public var iban = ""
    public var bic = ""
    public var accountName = ""

    public init() {}

    // MARK: Totals

    /// BT-106.
    public var lineTotal: Decimal { lines.reduce(0) { $0 + $1.netAmount } }

    /// BG-23, one row per treatment in order of first use.
    public var taxGroups: [DraftTaxGroup] {
        var order: [TaxTreatment] = []
        var basis: [TaxTreatment: Decimal] = [:]
        for line in lines {
            if basis[line.tax] == nil { order.append(line.tax) }
            basis[line.tax, default: 0] += line.netAmount
        }
        return order.map { treatment in
            let b = basis[treatment] ?? 0
            return DraftTaxGroup(treatment: treatment, basis: b, tax: Money.rounded(b * treatment.rate / 100))
        }
    }

    /// BT-110.
    public var taxTotal: Decimal { taxGroups.reduce(0) { $0 + $1.tax } }
    /// BT-112 and, with nothing prepaid, BT-115.
    public var grossTotal: Decimal { lineTotal + taxTotal }

    // MARK: Validation

    /// What is still missing or wrong, in the user's language. Empty means
    /// the draft can be written. These follow the EN 16931 and XRechnung
    /// rules that a form can break; the arithmetic cannot go wrong here.
    public func problems(_ lang: Lang) -> [String] {
        var result: [String] = []
        func need(_ ok: Bool, _ de: String, _ en: String) {
            if !ok { result.append(lang == .de ? de : en) }
        }
        func filled(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        need(filled(number), "Rechnungsnummer", "Invoice number")
        need(currency.count == 3, "Währung (drei Buchstaben, z. B. EUR)", "Currency (three letters, e.g. EUR)")

        for (party, de, en) in [(seller, "Verkäufer", "Seller"), (buyer, "Käufer", "Buyer")] {
            need(filled(party.name), "\(de): Name", "\(en): name")
            need(filled(party.street), "\(de): Straße", "\(en): street")
            need(filled(party.postcode), "\(de): PLZ", "\(en): postcode")
            need(filled(party.city), "\(de): Ort", "\(en): city")
            need(party.country.count == 2, "\(de): Land (zwei Buchstaben, z. B. DE)", "\(en): country (two letters, e.g. DE)")
        }
        // BR-CO-26 and the per-category rules BR-S-02, BR-E-02 …
        need(filled(seller.vatID) || filled(seller.taxNumber),
             "Verkäufer: Steuernummer oder USt-IdNr.", "Seller: tax number or VAT ID")

        let treatments = Set(lines.map(\.tax))
        // BR-AE-02, BR-IC-02, BR-G-02: these need the seller's VAT ID itself.
        if !treatments.isDisjoint(with: [.reverseCharge, .intraEU, .export]) {
            need(filled(seller.vatID), "Verkäufer: USt-IdNr. (für Reverse Charge, EU-Lieferung oder Ausfuhr)",
                 "Seller: VAT ID (for reverse charge, intra-EU supply or export)")
        }
        // BR-AE-02, BR-IC-02: and the buyer's.
        if !treatments.isDisjoint(with: [.reverseCharge, .intraEU]) {
            need(filled(buyer.vatID), "Käufer: USt-IdNr. (für Reverse Charge oder EU-Lieferung)",
                 "Buyer: VAT ID (for reverse charge or intra-EU supply)")
        }
        if treatments.contains(.smallBusiness) && treatments.count > 1 {
            result.append(lang == .de
                ? "Kleinunternehmer-Positionen lassen sich nicht mit anderen Steuersätzen mischen"
                : "Small-business lines cannot be mixed with other VAT treatments")
        }

        if lines.isEmpty {
            result.append(lang == .de ? "Mindestens eine Position" : "At least one line item")
        }
        for (index, line) in lines.enumerated() {
            need(filled(line.name), "Position \(index + 1): Bezeichnung", "Line \(index + 1): description")
            need(line.quantity != 0, "Position \(index + 1): Menge", "Line \(index + 1): quantity")
        }
        if usesPeriod {
            need(periodStart <= periodEnd, "Leistungszeitraum: Beginn liegt nach dem Ende", "Service period: start is after end")
        }

        let ibanText = iban.filter { !$0.isWhitespace }
        if !ibanText.isEmpty {
            need(IBAN.isValid(ibanText), "IBAN: Prüfziffer stimmt nicht", "IBAN: checksum fails")
        }

        if format == .xrechnungXML {
            // BR-DE-15
            need(filled(buyerReference), "Leitweg-ID / Käuferreferenz (für XRechnung Pflicht)",
                 "Leitweg-ID / buyer reference (required for XRechnung)")
            // BR-DE-2, BR-DE-5 to BR-DE-7
            need(filled(seller.contactName), "Verkäufer: Ansprechpartner (für XRechnung Pflicht)", "Seller: contact name (required for XRechnung)")
            need(filled(seller.phone), "Verkäufer: Telefon (für XRechnung Pflicht)", "Seller: phone (required for XRechnung)")
            need(filled(seller.email), "Verkäufer: E-Mail (für XRechnung Pflicht)", "Seller: e-mail (required for XRechnung)")
            // XRechnung 3.0 makes both electronic addresses (BT-34, BT-49)
            // mandatory; the e-mail addresses serve as those.
            need(filled(buyer.email), "Käufer: E-Mail (für XRechnung Pflicht)", "Buyer: e-mail (required for XRechnung)")
            // BR-DE-1: payment instructions.
            need(!ibanText.isEmpty, "IBAN (für XRechnung Pflicht)", "IBAN (required for XRechnung)")
        }
        return result
    }
}
