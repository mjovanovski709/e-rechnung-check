import Foundation
import EInvoiceKit

// Command-line front end:
//   erechnung-check [--lang de|en] [--summary] file…
// --summary prints one tab-separated line per file, for sweeping a folder
// of sample invoices.

var lang = Lang.system
var summary = false
var paths: [String] = []

var arguments = Array(CommandLine.arguments.dropFirst())
while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    switch argument {
    case "--lang":
        if let value = arguments.first, let parsed = Lang(rawValue: value) {
            lang = parsed
            arguments.removeFirst()
        }
    case "--summary":
        summary = true
    case "--help", "-h":
        print("usage: erechnung-check [--lang de|en] [--summary] file…")
        exit(0)
    default:
        paths.append(argument)
    }
}

guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: erechnung-check [--lang de|en] [--summary] file…\n".utf8))
    exit(64)
}

func symbol(_ severity: Severity) -> String {
    switch severity {
    case .ok: return "✓"
    case .info: return "i"
    case .warning: return "!"
    case .error: return "✗"
    }
}

var worst = 0
for path in paths {
    let report = Inspector.inspect(url: URL(fileURLWithPath: path))

    switch report.verdict {
    case .eInvoice: break
    case .eInvoiceWithWarnings, .eInvoiceWithErrors: worst = max(worst, 1)
    case .structuredButNotEInvoice, .notEInvoice, .unreadable: worst = max(worst, 2)
    }

    if summary {
        let ids = report.findings.filter { $0.severity >= .warning }.map(\.id).joined(separator: ",")
        print([
            report.verdict.rawValue,
            report.profile?.displayName ?? "-",
            report.invoice?.syntax.rawValue ?? "-",
            "E\(report.errorCount) W\(report.warningCount)",
            ids.isEmpty ? "-" : ids,
            path,
        ].joined(separator: "\t"))
        continue
    }

    print("\n\(report.fileName)")
    print(String(repeating: "─", count: max(8, report.fileName.count)))
    print(report.headline(lang).uppercased())
    print(report.explanation(lang))

    if !report.findings.isEmpty {
        print("")
        for finding in report.findings {
            print("  \(symbol(finding.severity)) \(finding.title(lang))")
            if let detail = finding.detail { print("      \(detail(lang))") }
        }
    }

    if let inv = report.invoice {
        let de = lang == .de
        print("")
        print("  \(inv.typeName(lang)) \(inv.number ?? "?")  ·  \(inv.issueDate?.formatted(lang) ?? "?")")
        print("  \(de ? "Von" : "From"): \(inv.seller.name ?? "?")\(inv.seller.addressLine.map { ", \($0)" } ?? "")")
        print("  \(de ? "An" : "To"):  \(inv.buyer.name ?? "?")\(inv.buyer.addressLine.map { ", \($0)" } ?? "")")
        for line in inv.lines {
            let amount = line.netAmount.map { Money.format($0, currency: inv.currency, lang: lang) } ?? ""
            let quantity = line.quantity.map { "\($0) × " } ?? ""
            print("    · \(quantity)\(line.name ?? "?")  \(amount)")
        }
        if let net = inv.totals.netTotal { print("  \(de ? "Netto" : "Net"):   \(Money.format(net, currency: inv.currency, lang: lang))") }
        if let vat = inv.totals.vatTotal { print("  \(de ? "USt" : "VAT"):   \(Money.format(vat, currency: inv.currency, lang: lang))") }
        if let gross = inv.totals.grossTotal { print("  \(de ? "Brutto" : "Total"): \(Money.format(gross, currency: inv.currency, lang: lang))") }
        if let due = inv.totals.due { print("  \(de ? "Zu zahlen" : "Due"): \(Money.format(due, currency: inv.currency, lang: lang))") }
        if let iban = inv.payment.iban { print("  IBAN:  \(IBAN.grouped(iban))") }
    }
}

if !summary {
    print("")
    print(lang == .de
        ? "Hinweis: Das ist eine Prüfung auf typische Fehler, keine amtliche Validierung."
        : "Note: this is a check for typical problems, not an official validation.")
}
exit(Int32(worst))
