import Foundation

/// Which XML dialect the invoice is written in.
public enum Syntax: String, Sendable {
    /// UN/CEFACT Cross Industry Invoice: ZUGFeRD 2.x, Factur-X, XRechnung (CII).
    case cii
    /// OASIS UBL 2.1: XRechnung (UBL), Peppol BIS.
    case ubl
    /// The pre-2017 ZUGFeRD 1.0 dialect. Readable, but not EN 16931.
    case zugferd1

    public var displayName: String {
        switch self {
        case .cii: return "UN/CEFACT CII"
        case .ubl: return "UBL 2.1"
        case .zugferd1: return "ZUGFeRD 1.0 (CII 2013)"
        }
    }
}

public struct Party: Sendable, Equatable {
    public var name: String?
    public var tradingName: String?
    public var street: String?
    public var postcode: String?
    public var city: String?
    public var country: String?
    /// BT-31 / BT-48: VAT identification number (USt-IdNr.).
    public var vatID: String?
    /// BT-32: national tax number (Steuernummer).
    public var taxNumber: String?
    public var legalID: String?
    public var contactName: String?
    public var phone: String?
    public var email: String?

    public init() {}

    public var addressLine: String? {
        let cityPart = [postcode, city].compactMap { $0 }.joined(separator: " ")
        let parts = [street, cityPart.isEmpty ? nil : cityPart, country].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

public struct InvoiceLine: Sendable, Equatable {
    public var id: String?
    public var name: String?
    public var quantity: Decimal?
    public var unit: String?
    public var unitPrice: Decimal?
    public var netAmount: Decimal?
    public var vatRate: Decimal?
    public var vatCategory: String?

    public init() {}
}

/// One row of the VAT breakdown (BG-23).
public struct VATRow: Sendable, Equatable {
    public var category: String?
    public var rate: Decimal?
    public var basis: Decimal?
    public var tax: Decimal?
    public var exemptionReason: String?

    public init() {}
}

/// Document totals (BG-22). Names follow the EN 16931 business terms.
public struct Totals: Sendable, Equatable {
    /// BT-106 Sum of line net amounts.
    public var lineTotal: Decimal?
    /// BT-107 Sum of document-level allowances.
    public var allowances: Decimal?
    /// BT-108 Sum of document-level charges.
    public var charges: Decimal?
    /// BT-109 Total without VAT.
    public var netTotal: Decimal?
    /// BT-110 Total VAT.
    public var vatTotal: Decimal?
    /// BT-112 Total with VAT.
    public var grossTotal: Decimal?
    /// BT-113 Already paid.
    public var prepaid: Decimal?
    /// BT-114 Rounding amount.
    public var rounding: Decimal?
    /// BT-115 Amount due for payment.
    public var due: Decimal?

    public init() {}
}

public struct Payment: Sendable, Equatable {
    public var meansCode: String?
    public var iban: String?
    public var bic: String?
    public var accountName: String?
    public var reference: String?
    public var terms: String?
    public var dueDate: Day?

    public init() {}
}

public struct Invoice: Sendable, Equatable {
    public var syntax: Syntax
    /// BT-24: the specification identifier that names the profile.
    public var guidelineID: String?
    public var businessProcess: String?
    public var number: String?
    public var typeCode: String?
    public var issueDate: Day?
    public var currency: String?
    /// BT-10: buyer reference; for German public bodies the Leitweg-ID.
    public var buyerReference: String?
    public var orderReference: String?
    public var deliveryDate: Day?
    public var periodStart: Day?
    public var periodEnd: Day?
    public var notes: [String] = []
    public var seller = Party()
    public var buyer = Party()
    public var lines: [InvoiceLine] = []
    public var vatRows: [VATRow] = []
    public var totals = Totals()
    public var payment = Payment()

    public init(syntax: Syntax) { self.syntax = syntax }

    /// UNTDID 1001 document type, in plain words.
    public func typeName(_ lang: Lang) -> String {
        let de: String, en: String
        switch typeCode {
        case "380": (de, en) = ("Rechnung", "Invoice")
        case "381": (de, en) = ("Gutschrift", "Credit note")
        case "384": (de, en) = ("Rechnungskorrektur", "Corrected invoice")
        case "389": (de, en) = ("Gutschrift im Abrechnungsverfahren", "Self-billed invoice")
        case "326": (de, en) = ("Teilrechnung", "Partial invoice")
        case "875": (de, en) = ("Abschlagsrechnung", "Partial construction invoice")
        case "876": (de, en) = ("Teilschlussrechnung", "Partial final construction invoice")
        case "877": (de, en) = ("Schlussrechnung", "Final construction invoice")
        case "386": (de, en) = ("Anzahlungsrechnung", "Prepayment invoice")
        default: (de, en) = ("Rechnung", "Invoice")
        }
        return lang == .de ? de : en
    }
}
