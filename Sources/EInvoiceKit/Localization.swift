import Foundation

/// The two languages the tool speaks. Strings live in code (not .lproj files)
/// so the command-line tool and the app share exactly the same wording.
public enum Lang: String, Sendable, CaseIterable {
    case de, en

    public static var system: Lang {
        (Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("de") ? .de : .en
    }

    var locale: Locale { Locale(identifier: self == .de ? "de_DE" : "en_GB") }
}

/// A sentence in both languages.
public struct LocalizedText: Sendable, Equatable {
    public let de: String
    public let en: String

    public init(de: String, en: String) {
        self.de = de
        self.en = en
    }

    public func callAsFunction(_ lang: Lang) -> String { lang == .de ? de : en }
}

func T(_ de: String, _ en: String) -> LocalizedText { LocalizedText(de: de, en: en) }

/// A calendar day without a time zone. Invoice dates are plain days; turning
/// them into `Date` would shift them around midnight in other time zones.
public struct Day: Sendable, Equatable, Comparable {
    public let year: Int
    public let month: Int
    public let day: Int

    public init?(year: Int, month: Int, day: Int) {
        guard (1...12).contains(month), (1...31).contains(day), (1900...2200).contains(year) else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Accepts `20261103` (CII format 102) and `2026-11-03` (UBL), ignoring a
    /// trailing time or zone such as `2026-11-03+01:00`.
    public init?(parsing raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = s.prefix(10).filter(\.isNumber)
        guard digits.count == 8,
              let y = Int(digits.prefix(4)),
              let m = Int(digits.dropFirst(4).prefix(2)),
              let d = Int(digits.suffix(2)) else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public static func < (a: Day, b: Day) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public func formatted(_ lang: Lang) -> String {
        lang == .de
            ? String(format: "%02d.%02d.%04d", day, month, year)
            : "\(day) \(Day.monthNames(.en)[month - 1]) \(year)"
    }

    static func monthNames(_ lang: Lang) -> [String] {
        lang == .de
            ? ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember"]
            : ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"]
    }
}

public enum Money {
    /// `1190` → `1.190,00` (de) or `1,190.00` (en), with the currency appended.
    public static func format(_ amount: Decimal, currency: String?, lang: Lang) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = lang.locale
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        let number = f.string(from: amount as NSDecimalNumber) ?? "\(amount)"
        guard let currency, !currency.isEmpty else { return number }
        return "\(number) \(currency == "EUR" ? "€" : currency)"
    }

    static func rounded(_ value: Decimal, places: Int = 2) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, places, .plain)
        return output
    }

    static func parse(_ raw: String?) -> Decimal? {
        guard let raw else { return nil }
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }) else { return nil }
        return Decimal(string: s, locale: Locale(identifier: "en_US_POSIX"))
    }
}
