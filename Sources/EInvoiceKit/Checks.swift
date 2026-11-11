import Foundation

public enum Severity: Int, Sendable, Comparable {
    case ok = 0, info, warning, error

    public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

/// One result line of the check: what was looked at and how it turned out.
public struct Finding: Sendable, Identifiable {
    /// Stable code, e.g. `sums.gross`. Tests and the summary output key on it.
    public let id: String
    public let severity: Severity
    public let title: LocalizedText
    public let detail: LocalizedText?

    init(_ id: String, _ severity: Severity, _ title: LocalizedText, _ detail: LocalizedText? = nil) {
        self.id = id
        self.severity = severity
        self.title = title
        self.detail = detail
    }
}

/// Checks on the invoice content itself.
///
/// These are a deliberate subset of the EN 16931 business rules: the ones a
/// recipient cares about and that can be stated without a schema validator.
/// They do not replace the official validators (KoSIT, Mustang).
enum ContentChecks {
    static func run(_ inv: Invoice, profile: Profile) -> [Finding] {
        var findings: [Finding] = []
        findings += mandatoryFields(inv, profile: profile)
        findings += sums(inv, profile: profile)
        findings += paymentChecks(inv)
        findings += plausibility(inv)
        if profile == .xrechnung { findings += xrechnungRules(inv) }
        return findings
    }

    // MARK: Mandatory fields

    private static func mandatoryFields(_ inv: Invoice, profile: Profile) -> [Finding] {
        var missing: [LocalizedText] = []
        func require(_ present: Bool, _ de: String, _ en: String) {
            if !present { missing.append(T(de, en)) }
        }

        require(inv.number != nil, "Rechnungsnummer", "invoice number")
        require(inv.issueDate != nil, "Rechnungsdatum", "invoice date")
        require(inv.typeCode != nil, "Rechnungsart", "document type")
        require(inv.currency != nil, "Währung", "currency")
        require(inv.seller.name != nil, "Name des Verkäufers", "seller name")
        require(inv.seller.country != nil, "Land des Verkäufers", "seller country")
        require(inv.seller.vatID != nil || inv.seller.taxNumber != nil,
                "Steuernummer oder USt-IdNr. des Verkäufers", "seller tax number or VAT ID")
        require(inv.buyer.name != nil, "Name des Käufers", "buyer name")
        require(inv.totals.grossTotal != nil, "Bruttobetrag", "total with VAT")

        // ZUGFeRD 1.0 predates EN 16931 and is reported as "not an e-invoice"
        // anyway; holding it to the newer field list would only add noise.
        if profile != .zugferd1 {
            require(inv.totals.due != nil, "Zahlbetrag", "amount due")
        }

        if profile.hasLineItems && profile != .zugferd1 {
            require(inv.buyer.country != nil, "Land des Käufers", "buyer country")
            require(inv.totals.netTotal != nil, "Nettobetrag", "total without VAT")
            require(!inv.lines.isEmpty, "mindestens eine Rechnungsposition", "at least one line item")
            require(!inv.vatRows.isEmpty, "Umsatzsteuer-Aufschlüsselung", "VAT breakdown")
        }

        if missing.isEmpty {
            return [Finding("fields", .ok, T("Geprüfte Pflichtangaben sind vorhanden", "Checked mandatory fields are present"))]
        }
        return [Finding(
            "fields", .error,
            T("Pflichtangaben fehlen", "Mandatory fields are missing"),
            T(missing.map(\.de).joined(separator: ", "), missing.map(\.en).joined(separator: ", "))
        )]
    }

    // MARK: Arithmetic

    private static func sums(_ inv: Invoice, profile: Profile) -> [Finding] {
        var problems: [Finding] = []
        var checked = 0
        let t = inv.totals
        let currency = inv.currency

        func compare(_ id: String, _ actual: Decimal?, _ expected: Decimal?, _ de: String, _ en: String) {
            guard let actual, let expected else { return }
            checked += 1
            let difference = abs(Money.rounded(actual - expected))
            guard difference > 0 else { return }
            // One cent is a rounding disagreement, not a wrong invoice.
            let severity: Severity = difference <= Decimal(string: "0.01")! ? .warning : .error
            let a = Money.format(actual, currency: currency, lang: .de), e = Money.format(expected, currency: currency, lang: .de)
            let a2 = Money.format(actual, currency: currency, lang: .en), e2 = Money.format(expected, currency: currency, lang: .en)
            problems.append(Finding(id, severity, T(de, en), T("Angegeben: \(a), rechnerisch: \(e)", "Stated: \(a2), calculated: \(e2)")))
        }

        // BR-CO-10: sum of the lines = line total.
        if !inv.lines.isEmpty, inv.lines.allSatisfy({ $0.netAmount != nil }) {
            let lineSum = inv.lines.reduce(Decimal(0)) { $0 + ($1.netAmount ?? 0) }
            compare("sums.lines", t.lineTotal, lineSum,
                    "Summe der Positionen passt nicht zur Zwischensumme",
                    "Line items do not add up to the line total")
        }

        // BR-CO-13: net = line total − allowances + charges.
        if let lineTotal = t.lineTotal {
            compare("sums.net", t.netTotal, lineTotal - (t.allowances ?? 0) + (t.charges ?? 0),
                    "Nettobetrag passt nicht zu Positionen, Zu- und Abschlägen",
                    "Net total does not match lines, charges and allowances")
        }

        // BR-CO-14: VAT total = sum of the VAT rows.
        if !inv.vatRows.isEmpty, inv.vatRows.allSatisfy({ $0.tax != nil }) {
            let vatSum = inv.vatRows.reduce(Decimal(0)) { $0 + ($1.tax ?? 0) }
            compare("sums.vat", t.vatTotal ?? 0, vatSum,
                    "Umsatzsteuer gesamt passt nicht zur Aufschlüsselung",
                    "VAT total does not match the VAT breakdown")
        }

        // BR-CO-17: per rate, VAT = basis × rate.
        for row in inv.vatRows {
            guard let basis = row.basis, let rate = row.rate, let tax = row.tax else { continue }
            compare("sums.vatrate", tax, Money.rounded(basis * rate / 100),
                    "Umsatzsteuer bei \(rate) % ist falsch berechnet",
                    "VAT at \(rate)% is calculated incorrectly")
        }

        // BR-CO-15: gross = net + VAT.
        if let net = t.netTotal {
            compare("sums.gross", t.grossTotal, net + (t.vatTotal ?? 0),
                    "Bruttobetrag ist nicht Netto plus Umsatzsteuer",
                    "Total with VAT is not net plus VAT")
        }

        // BR-CO-16: due = gross − prepaid + rounding. MINIMUM has no field for
        // the prepaid amount, so a lower amount due is legitimate there.
        if let gross = t.grossTotal, profile != .minimum || t.prepaid != nil {
            compare("sums.due", t.due, gross - (t.prepaid ?? 0) + (t.rounding ?? 0),
                    "Zahlbetrag passt nicht zu Brutto und Anzahlungen",
                    "Amount due does not match total and prepayments")
        }

        if !problems.isEmpty { return problems }
        guard checked > 0 else { return [] }
        return [Finding("sums", .ok, T("Summen und Umsatzsteuer rechnen sich richtig", "Totals and VAT add up"))]
    }

    // MARK: Payment

    private static func paymentChecks(_ inv: Invoice) -> [Finding] {
        var findings: [Finding] = []
        if let iban = inv.payment.iban {
            if IBAN.isValid(iban) {
                findings.append(Finding("iban", .ok, T("IBAN hat eine gültige Prüfziffer", "IBAN has a valid checksum"),
                                        T(IBAN.grouped(iban), IBAN.grouped(iban))))
            } else if IBAN.looksLikeIBAN(iban) {
                // The invoice is still an e-invoice, but a transfer to this
                // account would bounce, so the payer should know.
                findings.append(Finding("iban", .warning,
                                        T("IBAN-Prüfziffer stimmt nicht – eine Überweisung würde scheitern", "IBAN checksum fails – a transfer would bounce"),
                                        T(IBAN.grouped(iban), IBAN.grouped(iban))))
            }
            // Anything else is a national account number, which the field allows.
        } else if ["30", "58"].contains(inv.payment.meansCode ?? "") {
            // BR-61: a credit transfer needs an account to transfer to.
            findings.append(Finding("iban.missing", .error,
                                    T("Zahlart Überweisung, aber keine Kontoverbindung angegeben", "Payment by credit transfer, but no account is given")))
        }
        return findings
    }

    // MARK: Plausibility

    private static func plausibility(_ inv: Invoice) -> [Finding] {
        var findings: [Finding] = []

        if let due = inv.payment.dueDate, let issued = inv.issueDate, due < issued {
            findings.append(Finding("dates.due", .warning,
                                    T("Fälligkeitsdatum liegt vor dem Rechnungsdatum", "Due date is before the invoice date"),
                                    T("\(due.formatted(.de)) vor \(issued.formatted(.de))", "\(due.formatted(.en)) before \(issued.formatted(.en))")))
        }

        if let vatID = inv.seller.vatID?.filter({ !$0.isWhitespace }).uppercased(), vatID.hasPrefix("DE") {
            let digits = vatID.dropFirst(2)
            if digits.count != 9 || !digits.allSatisfy(\.isNumber) {
                findings.append(Finding("vatid", .warning,
                                        T("USt-IdNr. des Verkäufers hat nicht das deutsche Format", "Seller VAT ID is not in the German format"),
                                        T("\(vatID) – erwartet: DE und 9 Ziffern", "\(vatID) – expected: DE and 9 digits")))
            }
        }

        return findings
    }

    // MARK: XRechnung

    private static func xrechnungRules(_ inv: Invoice) -> [Finding] {
        var findings: [Finding] = []
        // BR-DE-15
        if inv.buyerReference == nil {
            findings.append(Finding("xr.buyerref", .error,
                                    T("Käuferreferenz (Leitweg-ID) fehlt", "Buyer reference (Leitweg-ID) is missing"),
                                    T("XRechnung verlangt diese Angabe.", "XRechnung requires this field.")))
        }
        // BR-DE-2, BR-DE-5 to BR-DE-7
        let s = inv.seller
        if s.contactName == nil || s.phone == nil || s.email == nil {
            findings.append(Finding("xr.contact", .warning,
                                    T("Ansprechpartner des Verkäufers unvollständig", "Seller contact is incomplete"),
                                    T("XRechnung verlangt Name, Telefon und E-Mail.", "XRechnung requires name, phone and e-mail.")))
        }
        return findings
    }
}
