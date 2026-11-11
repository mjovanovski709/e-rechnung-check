import SwiftUI
import EInvoiceKit

/// The whole report for one file: verdict, checks, the invoice in readable
/// form, and the technical details for those who want them.
struct ReportContent: View {
    let report: Report
    let lang: Lang
    var detailsExpanded = false

    private var de: Bool { lang == .de }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VerdictCard(report: report, lang: lang)

            if !report.findings.isEmpty {
                Section(title: de ? "Prüfung" : "Checks") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(report.findings.enumerated()), id: \.offset) { index, finding in
                            if index > 0 { Divider().padding(.leading, 34) }
                            FindingRow(finding: finding, lang: lang)
                        }
                    }
                    .card(padding: 4)
                }
            }

            if let invoice = report.invoice {
                Section(title: de ? "Inhalt laut XML" : "Content according to the XML",
                        subtitle: report.kind == .hybridPDF
                            ? (de ? "Das sind die Daten, die Software einliest – nicht die sichtbare PDF-Seite."
                                  : "This is the data software reads – not the visible PDF page.")
                            : nil) {
                    InvoiceCard(invoice: invoice, lang: lang)
                }
            }

            if report.invoice != nil || !report.attachments.isEmpty {
                DetailsCard(report: report, lang: lang, expanded: detailsExpanded)
            }

            Text(de
                 ? "Diese Prüfung findet typische Fehler. Sie ist keine amtliche Validierung und keine Steuerberatung."
                 : "This check finds typical problems. It is not an official validation and not tax advice.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Verdict

struct VerdictCard: View {
    let report: Report
    let lang: Lang

    private var style: (symbol: String, color: Color) {
        switch report.verdict {
        case .eInvoice: return ("checkmark.seal.fill", .green)
        case .eInvoiceWithWarnings: return ("exclamationmark.triangle.fill", .orange)
        case .eInvoiceWithErrors: return ("xmark.octagon.fill", .red)
        case .structuredButNotEInvoice: return ("xmark.seal.fill", .red)
        case .notEInvoice: return ("xmark.circle.fill", .secondary)
        case .unreadable: return ("questionmark.circle.fill", .secondary)
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: style.symbol)
                .font(.system(size: 40))
                .foregroundStyle(style.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(report.headline(lang))
                    .font(.title2.weight(.semibold))
                Text(report.explanation(lang))
                    .fixedSize(horizontal: false, vertical: true)
                Text(report.fileName)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(style.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style.color.opacity(0.35)))
    }
}

struct FindingRow: View {
    let finding: Finding
    let lang: Lang

    private var style: (symbol: String, color: Color) {
        switch finding.severity {
        case .ok: return ("checkmark.circle.fill", .green)
        case .info: return ("info.circle.fill", .blue)
        case .warning: return ("exclamationmark.triangle.fill", .orange)
        case .error: return ("xmark.circle.fill", .red)
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: style.symbol)
                .foregroundStyle(style.color)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(finding.title(lang))
                    .fontWeight(finding.severity >= .warning ? .medium : .regular)
                if let detail = finding.detail {
                    Text(detail(lang))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
    }
}

// MARK: - Invoice

struct InvoiceCard: View {
    let invoice: Invoice
    let lang: Lang

    private var de: Bool { lang == .de }

    private func money(_ amount: Decimal) -> String {
        Money.format(amount, currency: invoice.currency, lang: lang)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(invoice.typeName(lang)) \(invoice.number ?? "–")")
                    .font(.title3.weight(.semibold))
                    .textSelection(.enabled)
                Spacer()
                if let date = invoice.issueDate {
                    Text(date.formatted(lang)).foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 24) {
                PartyBlock(title: de ? "Von" : "From", party: invoice.seller, lang: lang)
                PartyBlock(title: de ? "An" : "To", party: invoice.buyer, lang: lang)
            }

            let meta = metaRows
            if !meta.isEmpty {
                KeyValues(rows: meta)
            }

            if !invoice.lines.isEmpty {
                Divider()
                LinesTable(invoice: invoice, lang: lang)
            }

            Divider()
            totals

            let payment = paymentRows
            if !payment.isEmpty {
                Divider()
                Text(de ? "Zahlung" : "Payment").font(.headline)
                KeyValues(rows: payment)
            }

            if !invoice.notes.isEmpty {
                Divider()
                Text(de ? "Hinweise im Dokument" : "Notes in the document").font(.headline)
                ForEach(Array(invoice.notes.prefix(4).enumerated()), id: \.offset) { _, note in
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card(padding: 18)
    }

    private var metaRows: [(String, String)] {
        var rows: [(String, String)] = []
        if let start = invoice.periodStart, let end = invoice.periodEnd {
            rows.append((de ? "Leistungszeitraum" : "Billing period", "\(start.formatted(lang)) – \(end.formatted(lang))"))
        }
        if let delivery = invoice.deliveryDate {
            rows.append((de ? "Liefer-/Leistungsdatum" : "Delivery date", delivery.formatted(lang)))
        }
        if let order = invoice.orderReference {
            rows.append((de ? "Bestellnummer" : "Order number", order))
        }
        if let reference = invoice.buyerReference {
            rows.append((de ? "Käuferreferenz" : "Buyer reference", reference))
        }
        return rows
    }

    private var paymentRows: [(String, String)] {
        let p = invoice.payment
        var rows: [(String, String)] = []
        if let iban = p.iban {
            rows.append((IBAN.looksLikeIBAN(iban) ? "IBAN" : (de ? "Konto" : "Account"),
                         IBAN.looksLikeIBAN(iban) ? IBAN.grouped(iban) : iban))
        }
        if let bic = p.bic { rows.append(("BIC", bic)) }
        if let name = p.accountName { rows.append((de ? "Kontoinhaber" : "Account holder", name)) }
        if let reference = p.reference { rows.append((de ? "Verwendungszweck" : "Payment reference", reference)) }
        if let due = p.dueDate { rows.append((de ? "Fällig am" : "Due on", due.formatted(lang))) }
        if let terms = p.terms { rows.append((de ? "Zahlungsbedingungen" : "Payment terms", terms)) }
        return rows
    }

    @ViewBuilder
    private var totals: some View {
        let t = invoice.totals
        VStack(alignment: .trailing, spacing: 5) {
            if let net = t.netTotal {
                TotalRow(label: de ? "Netto" : "Net", value: money(net))
            }
            ForEach(Array(invoice.vatRows.enumerated()), id: \.offset) { _, row in
                if let tax = row.tax {
                    TotalRow(label: vatLabel(row), value: money(tax))
                }
            }
            if invoice.vatRows.isEmpty, let vat = t.vatTotal {
                TotalRow(label: de ? "Umsatzsteuer" : "VAT", value: money(vat))
            }
            if let gross = t.grossTotal {
                TotalRow(label: de ? "Brutto" : "Total", value: money(gross), strong: t.due == nil || t.due == gross)
            }
            if let prepaid = t.prepaid, prepaid != 0 {
                TotalRow(label: de ? "Bereits gezahlt" : "Already paid", value: money(-prepaid))
            }
            if let due = t.due, due != t.grossTotal {
                TotalRow(label: de ? "Zu zahlen" : "Amount due", value: money(due), strong: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private func vatLabel(_ row: VATRow) -> String {
        let base = de ? "Umsatzsteuer" : "VAT"
        guard let rate = row.rate else { return base }
        var label = "\(base) \(Format.number(rate, lang: lang)) %"
        if let hint = Format.vatCategory(row.category, lang: lang) { label += " (\(hint))" }
        return label
    }
}

struct PartyBlock: View {
    let title: String
    let party: Party
    let lang: Lang

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(party.name ?? "–").fontWeight(.medium)
            if let street = party.street { Text(street) }
            let city = [party.postcode, party.city].compactMap { $0 }.joined(separator: " ")
            if !city.isEmpty || party.country != nil {
                Text([city.isEmpty ? nil : city, party.country].compactMap { $0 }.joined(separator: ", "))
            }
            Group {
                if let vat = party.vatID { Text("\(lang == .de ? "USt-IdNr." : "VAT ID") \(vat)") }
                if let tax = party.taxNumber { Text("\(lang == .de ? "Steuernr." : "Tax no.") \(tax)") }
                if let contact = [party.contactName, party.phone, party.email].compactMap({ $0 }).first {
                    Text(contact)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LinesTable: View {
    let invoice: Invoice
    let lang: Lang

    private var de: Bool { lang == .de }

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 7) {
            GridRow {
                Text(de ? "Position" : "Item").gridColumnAlignment(.leading)
                Text(de ? "Menge" : "Qty")
                Text(de ? "Einzelpreis" : "Unit price")
                Text(de ? "USt" : "VAT")
                Text(de ? "Netto" : "Net")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(Array(invoice.lines.enumerated()), id: \.offset) { _, line in
                GridRow(alignment: .firstTextBaseline) {
                    Text(line.name ?? "–")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(quantity(line))
                    Text(line.unitPrice.map { Money.format($0, currency: nil, lang: lang) } ?? "")
                    Text(line.vatRate.map { "\(Format.number($0, lang: lang)) %" } ?? "")
                    Text(line.netAmount.map { Money.format($0, currency: nil, lang: lang) } ?? "")
                }
                .monospacedDigit()
            }
        }
        .textSelection(.enabled)
    }

    private func quantity(_ line: InvoiceLine) -> String {
        guard let quantity = line.quantity else { return "" }
        let unit = Format.unit(line.unit, lang: lang)
        return unit.isEmpty ? Format.number(quantity, lang: lang) : "\(Format.number(quantity, lang: lang)) \(unit)"
    }
}

struct TotalRow: View {
    let label: String
    let value: String
    var strong = false

    var body: some View {
        HStack(spacing: 16) {
            Text(label).foregroundStyle(strong ? .primary : .secondary)
            Text(value)
                .monospacedDigit()
                .frame(minWidth: 110, alignment: .trailing)
                .textSelection(.enabled)
        }
        .font(strong ? .title3.weight(.semibold) : .body)
    }
}

struct KeyValues: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    Text(row.0).foregroundStyle(.secondary).gridColumnAlignment(.leading)
                    Text(row.1)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

// MARK: - Technical details

struct DetailsCard: View {
    let report: Report
    let lang: Lang
    @State private var expanded: Bool
    @State private var showXML = false

    init(report: Report, lang: Lang, expanded: Bool) {
        self.report = report
        self.lang = lang
        _expanded = State(initialValue: expanded)
    }

    private var de: Bool { lang == .de }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 12) {
                KeyValues(rows: rows)
                if let xml = report.xml {
                    DisclosureGroup(de ? "XML anzeigen" : "Show XML", isExpanded: $showXML) {
                        ScrollView([.horizontal, .vertical]) {
                            // Very large invoices would stall the text view.
                            Text(String(xml.prefix(200_000)))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: 320)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            .padding(.top, 10)
        } label: {
            Text(de ? "Technische Details" : "Technical details").font(.headline)
        }
        .card(padding: 14)
    }

    private var rows: [(String, String)] {
        var rows: [(String, String)] = []
        if let format = report.formatName { rows.append(("Format", format)) }
        if let profile = report.profile, profile != .unknown { rows.append((de ? "Profil" : "Profile", profile.displayName)) }
        if let syntax = report.invoice?.syntax { rows.append(("Syntax", syntax.displayName)) }
        if let id = report.invoice?.guidelineID { rows.append((de ? "Kennung (BT-24)" : "Identifier (BT-24)", id)) }
        if let name = report.embeddedFileName { rows.append((de ? "Eingebettete Datei" : "Embedded file", name)) }
        if !report.attachments.isEmpty {
            let list = report.attachments.map { "\($0.name) (\(ByteCountFormatter.string(fromByteCount: Int64($0.byteCount), countStyle: .file)))" }
            rows.append((de ? "Anhänge im PDF" : "Attachments in the PDF", list.joined(separator: "\n")))
        }
        return rows
    }
}

// MARK: - Building blocks

struct Section<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            content
        }
    }
}

extension View {
    func card(padding: CGFloat) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

enum Format {
    static func number(_ value: Decimal, lang: Lang) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: lang == .de ? "de_DE" : "en_GB")
        f.maximumFractionDigits = 4
        return f.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    /// The most common UN/ECE Recommendation 20 unit codes in plain words.
    static func unit(_ code: String?, lang: Lang) -> String {
        guard let code else { return "" }
        let de = lang == .de
        switch code.uppercased() {
        case "H87", "C62", "PCE", "XPP", "NAR": return de ? "Stk." : "pcs"
        case "HUR": return de ? "Std." : "h"
        case "DAY": return de ? "Tage" : "days"
        case "MON": return de ? "Monate" : "months"
        case "ANN": return de ? "Jahre" : "years"
        case "MIN": return "min"
        case "KGM": return "kg"
        case "GRM": return "g"
        case "TNE": return "t"
        case "LTR": return "l"
        case "MTR": return "m"
        case "KMT", "KTM": return "km"
        case "MTK": return "m²"
        case "MTQ": return "m³"
        case "KWH": return "kWh"
        case "LS": return de ? "pausch." : "lump sum"
        case "SET": return "Set"
        default: return code
        }
    }

    /// Names the VAT category when it is not the ordinary taxed case.
    static func vatCategory(_ code: String?, lang: Lang) -> String? {
        let de = lang == .de
        switch code?.uppercased() {
        case "E": return de ? "steuerbefreit" : "exempt"
        case "AE": return de ? "Reverse Charge" : "reverse charge"
        case "K": return de ? "innergemeinschaftliche Lieferung" : "intra-community supply"
        case "G": return de ? "Ausfuhr" : "export"
        case "O": return de ? "nicht steuerbar" : "outside scope"
        case "Z": return de ? "Nullsatz" : "zero rated"
        default: return nil
        }
    }
}
