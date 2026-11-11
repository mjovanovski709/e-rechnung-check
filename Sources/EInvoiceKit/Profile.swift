import Foundation

/// The profile an invoice declares in BT-24. The profile decides how much
/// structured data the file carries, and with it whether German tax rules
/// accept the file as an e-invoice at all.
public enum Profile: String, Sendable {
    case minimum
    case basicWL
    case basic
    case en16931
    case extended
    case xrechnung
    case peppol
    case zugferd1
    case unknown

    public var displayName: String {
        switch self {
        case .minimum: return "MINIMUM"
        case .basicWL: return "BASIC WL"
        case .basic: return "BASIC"
        case .en16931: return "EN 16931"
        case .extended: return "EXTENDED"
        case .xrechnung: return "XRechnung"
        case .peppol: return "Peppol BIS Billing"
        case .zugferd1: return "ZUGFeRD 1.0"
        case .unknown: return "?"
        }
    }

    public static func detect(guideline: String?, syntax: Syntax) -> Profile {
        if syntax == .zugferd1 { return .zugferd1 }
        guard let g = guideline?.lowercased(), !g.isEmpty else { return .unknown }
        if g.contains("xrechnung") { return .xrechnung }
        if g.contains("peppol") { return .peppol }
        if g.contains("urn:ferd:crossindustrydocument") { return .zugferd1 }
        if g.hasSuffix(":minimum") { return .minimum }
        if g.hasSuffix(":basicwl") { return .basicWL }
        if g.hasSuffix(":extended") { return .extended }
        if g.hasSuffix(":basic") { return .basic }
        if g.hasSuffix(":comfort") { return .en16931 }
        if g.hasPrefix("urn:cen.eu:en16931:2017") { return .en16931 }
        return .unknown
    }

    /// Whether the German tax authority treats a file with this profile as an
    /// e-invoice under § 14 UStG.
    ///
    /// Source: BMF letter of 15 October 2024 (III C 2 - S 7287-a/23/10001 :007):
    /// XRechnung and ZUGFeRD from version 2.0.1 qualify, "ausgenommen die
    /// Profile MINIMUM und BASIC-WL". ZUGFeRD 1.0 predates EN 16931 and is
    /// therefore outside the definition as well.
    public var germanStatus: LegalStatus {
        switch self {
        case .basic, .en16931, .extended, .xrechnung, .peppol: return .qualifies
        case .minimum, .basicWL, .zugferd1: return .doesNotQualify
        case .unknown: return .unclear
        }
    }

    /// MINIMUM and BASIC WL carry no line items by design.
    var hasLineItems: Bool { self != .minimum && self != .basicWL }
}

public enum LegalStatus: Sendable {
    case qualifies
    case doesNotQualify
    case unclear
}
