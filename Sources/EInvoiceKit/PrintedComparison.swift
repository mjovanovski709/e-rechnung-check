import Foundation

/// Compares what the XML says with what a person sees on the PDF page.
///
/// In a hybrid invoice the XML is the legally binding part, yet a human only
/// ever looks at the page. If the two disagree (a different IBAN, a different
/// total) nobody notices unless something compares them.
public struct PrintedComparison: Sendable {
    public enum Field: String, Sendable {
        case number, issueDate, grossTotal, amountDue, iban

        public func label(_ lang: Lang) -> String {
            switch self {
            case .number: return lang == .de ? "Rechnungsnummer" : "Invoice number"
            case .issueDate: return lang == .de ? "Rechnungsdatum" : "Invoice date"
            case .grossTotal: return lang == .de ? "Bruttobetrag" : "Total with VAT"
            case .amountDue: return lang == .de ? "Zahlbetrag" : "Amount due"
            case .iban: return "IBAN"
            }
        }
    }

    public enum State: Sendable, Equatable {
        /// The XML value appears on the page.
        case found
        /// The XML value does not appear on the page. Not proof of a
        /// mismatch: the page may format it in a way we do not recognise.
        case notFound
        /// The page shows other values of this kind but not the XML one.
        case differs(printed: [String])
    }

    public struct Row: Sendable {
        public let field: Field
        /// The raw XML value, used for matching.
        public let xmlValue: String
        /// The same value as a person would write it.
        public let display: LocalizedText
        public let state: State

        init(field: Field, xmlValue: String, display: LocalizedText? = nil, state: State) {
            self.field = field
            self.xmlValue = xmlValue
            self.display = display ?? LocalizedText(de: xmlValue, en: xmlValue)
            self.state = state
        }
    }

    /// False for a scanned page with no text layer; then nothing is compared.
    public let hasTextLayer: Bool
    public let rows: [Row]

    public static func compare(invoice: Invoice, pageText: String) -> PrintedComparison {
        let text = normalize(pageText)
        guard text.filter({ $0.isLetter || $0.isNumber }).count >= 20 else {
            return PrintedComparison(hasTextLayer: false, rows: [])
        }
        let compact = String(text.filter { !$0.isWhitespace }).uppercased()
        var rows: [Row] = []

        if let number = invoice.number {
            let needle = String(number.filter { !$0.isWhitespace }).uppercased()
            rows.append(Row(field: .number, xmlValue: number, state: compact.contains(needle) ? .found : .notFound))
        }

        if let date = invoice.issueDate {
            let found = dateCandidates(date).contains { text.range(of: $0, options: .caseInsensitive) != nil }
            rows.append(Row(field: .issueDate, xmlValue: date.iso,
                            display: LocalizedText(de: date.formatted(.de), en: date.formatted(.en)),
                            state: found ? .found : .notFound))
        }

        if let gross = invoice.totals.grossTotal {
            rows.append(Row(field: .grossTotal, xmlValue: plain(gross), display: money(gross, invoice),
                            state: containsAmount(gross, in: text) ? .found : .notFound))
        }

        if let due = invoice.totals.due, due != invoice.totals.grossTotal {
            rows.append(Row(field: .amountDue, xmlValue: plain(due), display: money(due, invoice),
                            state: containsAmount(due, in: text) ? .found : .notFound))
        }

        if let iban = invoice.payment.iban {
            let needle = String(iban.filter { !$0.isWhitespace }).uppercased()
            if compact.contains(needle) {
                rows.append(Row(field: .iban, xmlValue: iban, state: .found))
            } else {
                // A page that shows a *different* valid IBAN is the case that
                // matters: the payer reads one account, the software pays another.
                let printed = ibans(in: text).filter { $0 != needle }
                rows.append(Row(field: .iban, xmlValue: iban, state: printed.isEmpty ? .notFound : .differs(printed: printed)))
            }
        }

        return PrintedComparison(hasTextLayer: true, rows: rows)
    }

    private static func money(_ amount: Decimal, _ invoice: Invoice) -> LocalizedText {
        LocalizedText(de: Money.format(amount, currency: invoice.currency, lang: .de),
                      en: Money.format(amount, currency: invoice.currency, lang: .en))
    }

    // MARK: - Matching helpers

    /// Replaces the exotic spaces PDF producers use with plain ones.
    static func normalize(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x00A0, 0x202F, 0x2009, 0x2007, 0x2008: out.unicodeScalars.append(" ")
            case 0x2019, 0x02BC: out.unicodeScalars.append("'")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    static func plain(_ amount: Decimal) -> String {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        return f.string(from: amount as NSDecimalNumber) ?? "\(amount)"
    }

    /// Every way a page might print this amount: 1190.00, 1190,00, 1.190,00,
    /// 1,190.00, 1 190,00, 1'190.00.
    static func amountCandidates(_ amount: Decimal) -> [String] {
        let digits = plain(abs(amount))
        let parts = digits.split(separator: ".")
        guard parts.count == 2 else { return [digits] }
        let whole = String(parts[0]), cents = String(parts[1])

        func grouped(_ separator: String) -> String {
            var result = ""
            for (offset, character) in whole.reversed().enumerated() {
                if offset > 0 && offset % 3 == 0 { result.append(separator) }
                result.append(character)
            }
            return String(result.reversed())
        }

        var candidates = ["\(whole).\(cents)", "\(whole),\(cents)"]
        if whole.count > 3 {
            candidates += [
                "\(grouped(".")),\(cents)",
                "\(grouped(",")).\(cents)",
                "\(grouped(" ")),\(cents)",
                "\(grouped(" ")).\(cents)",
                "\(grouped("'")).\(cents)",
            ]
        }
        return candidates
    }

    /// True when the amount stands on the page as a number of its own, not as
    /// the tail of a larger one ("190,00" inside "1.190,00").
    static func containsAmount(_ amount: Decimal, in text: String) -> Bool {
        let characters = Array(text)
        for candidate in amountCandidates(amount) {
            let needle = Array(candidate)
            guard needle.count <= characters.count else { continue }
            var start = 0
            while start + needle.count <= characters.count {
                if characters[start..<(start + needle.count)].elementsEqual(needle) {
                    let before = start > 0 ? characters[start - 1] : " "
                    let beforeThat = start > 1 ? characters[start - 2] : " "
                    let after = start + needle.count < characters.count ? characters[start + needle.count] : " "
                    let gluedBefore = before.isNumber || ((before == "." || before == "," || before == "'") && beforeThat.isNumber)
                    if !gluedBefore && !after.isNumber { return true }
                }
                start += 1
            }
        }
        return false
    }

    static func dateCandidates(_ day: Day) -> [String] {
        let d = day.day, m = day.month, y = day.year
        let dd = String(format: "%02d", d), mm = String(format: "%02d", m), yy = String(format: "%02d", y % 100)
        var result = [
            "\(dd).\(mm).\(y)", "\(d).\(m).\(y)", "\(dd).\(mm).\(yy)",
            "\(y)-\(mm)-\(dd)", "\(dd)/\(mm)/\(y)", "\(mm)/\(dd)/\(y)", "\(dd)-\(mm)-\(y)",
        ]
        let german = Day.monthNames(.de)[m - 1], english = Day.monthNames(.en)[m - 1]
        let french = ["janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre"][m - 1]
        result += [
            "\(d). \(german) \(y)", "\(dd). \(german) \(y)",
            "\(d) \(english) \(y)", "\(english) \(d), \(y)",
            "\(d) \(french) \(y)",
        ]
        return result
    }

    /// Valid IBANs printed on the page, without spaces.
    static func ibans(in text: String) -> [String] {
        let pattern = "[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let upper = text.uppercased()
        var found: [String] = []
        for match in regex.matches(in: upper, range: NSRange(upper.startIndex..., in: upper)) {
            guard let range = Range(match.range, in: upper) else { continue }
            var candidate = String(upper[range].filter { !$0.isWhitespace })
            // The greedy pattern may swallow a following word ("…3000 BIC");
            // shorten until the checksum fits or nothing plausible is left.
            while candidate.count >= 15 {
                if IBAN.isValid(candidate) {
                    if !found.contains(candidate) { found.append(candidate) }
                    break
                }
                candidate.removeLast()
            }
        }
        return found
    }
}

public enum IBAN {
    /// ISO 13616 mod-97 check.
    public static func isValid(_ raw: String) -> Bool {
        let iban = raw.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(iban.count),
              iban.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              iban.prefix(2).allSatisfy(\.isLetter),
              iban.dropFirst(2).prefix(2).allSatisfy(\.isNumber) else { return false }
        let rearranged = iban.dropFirst(4) + iban.prefix(4)
        var remainder = 0
        for character in rearranged {
            guard let value = character.isNumber ? character.wholeNumberValue : Int(character.asciiValue! - 55) else { return false }
            remainder = (value < 10 ? remainder * 10 + value : remainder * 100 + value) % 97
        }
        return remainder == 1
    }

    /// Two letters, two digits, then at least 11 more characters.
    public static func looksLikeIBAN(_ raw: String) -> Bool {
        let iban = raw.filter { !$0.isWhitespace }.uppercased()
        return (15...34).contains(iban.count)
            && iban.prefix(2).allSatisfy { $0.isASCII && $0.isLetter }
            && iban.dropFirst(2).prefix(2).allSatisfy(\.isNumber)
    }

    /// `DE89370400440532013000` → `DE89 3704 0044 0532 0130 00`.
    public static func grouped(_ raw: String) -> String {
        let iban = raw.filter { !$0.isWhitespace }.uppercased()
        var out = ""
        for (index, character) in iban.enumerated() {
            if index > 0 && index % 4 == 0 { out.append(" ") }
            out.append(character)
        }
        return out
    }
}
