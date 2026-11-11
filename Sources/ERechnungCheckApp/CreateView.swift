import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EInvoiceKit

/// State of the "create an e-invoice" window.
@MainActor
final class CreateModel: ObservableObject {
    static let shared = CreateModel()

    @Published var draft: InvoiceDraft
    /// The visible invoice the XML is embedded into (ZUGFeRD only).
    @Published var sourcePDF: URL?
    @Published var errorMessage: String?
    @Published var isSaving = false

    private static let templateKey = "invoiceTemplate"

    private init() {
        draft = Self.loadTemplate()
    }

    /// Seller, bank details and the chosen format are remembered for the next
    /// invoice. They stay in the app's own preferences on this Mac.
    private static func loadTemplate() -> InvoiceDraft {
        var draft = InvoiceDraft()
        if let data = UserDefaults.standard.data(forKey: templateKey),
           let saved = try? JSONDecoder().decode(InvoiceDraft.self, from: data) {
            draft.format = saved.format
            draft.seller = saved.seller
            draft.iban = saved.iban
            draft.bic = saved.bic
            draft.accountName = saved.accountName
            draft.paymentTerms = saved.paymentTerms
            draft.currency = saved.currency
        }
        return draft
    }

    private func saveTemplate() {
        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: Self.templateKey)
        }
    }

    /// Clears the invoice-specific fields and keeps the remembered ones.
    func startOver() {
        let format = draft.format
        draft = Self.loadTemplate()
        draft.format = format
        sourcePDF = nil
        errorMessage = nil
    }

    func chooseSourcePDF(lang: Lang) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = lang == .de ? "Das PDF Ihrer Rechnung auswählen" : "Choose the PDF of your invoice"
        if panel.runModal() == .OK { sourcePDF = panel.url }
    }

    /// Asks where to save, writes the file, then shows the check report of
    /// what was written in the main window.
    func save(lang: Lang, openMain: @escaping () -> Void) {
        errorMessage = nil
        let de = lang == .de
        let xml = CIIWriter.xml(draft)

        let output: Data
        let suggested: String
        let type: UTType
        switch draft.format {
        case .xrechnungXML:
            output = xml
            suggested = "\(safeFileName(draft.number)).xml"
            type = .xml
        case .zugferdPDF:
            guard let source = sourcePDF else {
                errorMessage = de ? "Bitte zuerst das PDF der Rechnung auswählen." : "Please choose the invoice PDF first."
                return
            }
            let scoped = source.startAccessingSecurityScopedResource()
            defer { if scoped { source.stopAccessingSecurityScopedResource() } }
            do {
                let pdf = try Data(contentsOf: source)
                output = try HybridPDF.embed(xml: xml, into: pdf)
            } catch let failure as HybridPDF.Failure {
                errorMessage = Self.describe(failure, lang: lang)
                return
            } catch {
                errorMessage = (de ? "Das PDF ließ sich nicht lesen: " : "Could not read the PDF: ") + error.localizedDescription
                return
            }
            suggested = source.deletingPathExtension().lastPathComponent + (de ? " (E-Rechnung).pdf" : " (e-invoice).pdf")
            type = .pdf
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = suggested
        panel.canCreateDirectories = true
        panel.message = draft.format == .zugferdPDF
            ? (de ? "Die E-Rechnung wird als neue Datei gespeichert, das Original bleibt unverändert."
                  : "The e-invoice is saved as a new file; the original stays unchanged.")
            : (de ? "XRechnung speichern" : "Save XRechnung")
        guard panel.runModal() == .OK, let target = panel.url else { return }
        if target == sourcePDF {
            errorMessage = de ? "Bitte unter einem anderen Namen speichern als das Original." : "Please save under a different name than the original."
            return
        }
        do {
            try output.write(to: target, options: .atomic)
        } catch {
            errorMessage = (de ? "Speichern fehlgeschlagen: " : "Saving failed: ") + error.localizedDescription
            return
        }
        saveTemplate()
        AppModel.shared.load(target)
        openMain()
    }

    private func safeFileName(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "XRechnung" : cleaned
    }

    /// Sample content for `--snapshot create out.png --demo`.
    static func demoDraft() -> InvoiceDraft {
        var d = InvoiceDraft()
        d.number = "R-2026-042"
        d.seller.name = "Muster GmbH"; d.seller.street = "Hauptstraße 1"; d.seller.postcode = "10115"
        d.seller.city = "Berlin"; d.seller.vatID = "DE123456789"
        d.buyer.name = "Kunde AG"; d.buyer.street = "Marktplatz 5"; d.buyer.postcode = "80331"; d.buyer.city = "München"
        d.iban = "DE89 3704 0044 0532 0130 00"
        var a = DraftLine(); a.name = "Beratung"; a.quantity = Decimal(string: "7.5")!; a.unit = .hour; a.unitPrice = Decimal(string: "95.50")!
        var b = DraftLine(); b.name = "Fachbuch"; b.quantity = 3; b.unitPrice = Decimal(string: "19.99")!; b.tax = .reduced7
        d.lines = [a, b]
        return d
    }

    static func describe(_ failure: HybridPDF.Failure, lang: Lang) -> String {
        let de = lang == .de
        switch failure {
        case .notPDF: return de ? "Die gewählte Datei ist kein PDF." : "The chosen file is not a PDF."
        case .encrypted:
            return de ? "Das PDF ist verschlüsselt oder passwortgeschützt. E-Rechnungen (PDF/A) dürfen das nicht sein – bitte ein ungeschütztes PDF exportieren."
                      : "The PDF is encrypted or password-protected. E-invoices (PDF/A) must not be – please export an unprotected PDF."
        case .unsupported(let what):
            return (de ? "Dieser PDF-Aufbau wird nicht unterstützt: " : "This PDF structure is not supported: ") + what
        case .damaged(let what):
            return (de ? "Das PDF ist beschädigt: " : "The PDF is damaged: ") + what
        }
    }
}

struct CreateView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject private var model = CreateModel.shared
    @Environment(\.openWindow) private var openWindow
    @State private var showProblems = false

    private var lang: Lang { app.lang }
    private var de: Bool { lang == .de }
    private var problems: [String] { model.draft.problems(lang) }
    private func money(_ d: Decimal) -> String { Money.format(d, currency: model.draft.currency.uppercased(), lang: lang) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                formatSection
                documentSection
                partySection(de ? "Verkäufer (Ihr Unternehmen)" : "Seller (your business)", party: $model.draft.seller, isSeller: true)
                partySection(de ? "Käufer" : "Buyer", party: $model.draft.buyer, isSeller: false)
                linesSection
                paymentSection
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 860)
        .toolbar {
            ToolbarItem {
                Button {
                    model.startOver()
                } label: {
                    Label(de ? "Neu beginnen" : "Start over", systemImage: "arrow.counterclockwise")
                }
                .help(de ? "Rechnungsfelder leeren, Firmendaten behalten" : "Clear invoice fields, keep business details")
            }
        }
    }

    // MARK: Sections

    private var formatSection: some View {
        SwiftUI.Section {
            Picker(de ? "Format" : "Format", selection: $model.draft.format) {
                Text(de ? "ZUGFeRD-PDF" : "ZUGFeRD PDF").tag(OutputFormat.zugferdPDF)
                Text(de ? "XRechnung (XML)" : "XRechnung (XML)").tag(OutputFormat.xrechnungXML)
            }
            .pickerStyle(.segmented)

            if model.draft.format == .zugferdPDF {
                LabeledContent(de ? "Rechnungs-PDF" : "Invoice PDF") {
                    HStack {
                        Text(model.sourcePDF?.lastPathComponent ?? (de ? "Keines gewählt" : "None chosen"))
                            .foregroundStyle(model.sourcePDF == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button(de ? "Auswählen …" : "Choose…") { model.chooseSourcePDF(lang: lang) }
                    }
                }
            }
        } footer: {
            Text(model.draft.format == .zugferdPDF
                 ? (de ? "Ihre normale Rechnung als PDF, z. B. aus Word oder Pages exportiert. Die Angaben unten werden als XML eingebettet (Profil EN 16931); die sichtbare Seite bleibt, wie sie ist. Sie muss dieselben Werte zeigen – die Prüfung nach dem Speichern vergleicht das. Am besten eignet sich ein PDF/A-Export."
                       : "Your normal invoice as a PDF, e.g. exported from Word or Pages. The details below are embedded as XML (profile EN 16931); the visible page stays as it is. It must show the same values – the check after saving compares them. A PDF/A export works best.")
                 : (de ? "Reine XML-Datei nach XRechnung 3.0, wie sie Behörden verlangen. Leitweg-ID, Ansprechpartner und E-Mail-Adressen sind dafür Pflicht."
                       : "A plain XML file following XRechnung 3.0, as public bodies require. Leitweg-ID, contact and e-mail addresses are mandatory for it."))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var documentSection: some View {
        SwiftUI.Section(de ? "Rechnung" : "Invoice") {
            Picker(de ? "Art" : "Type", selection: $model.draft.typeCode) {
                Text(de ? "Rechnung" : "Invoice").tag("380")
                Text(de ? "Gutschrift" : "Credit note").tag("381")
                Text(de ? "Rechnungskorrektur" : "Corrected invoice").tag("384")
                Text(de ? "Teilrechnung" : "Partial invoice").tag("326")
            }
            TextField(de ? "Rechnungsnummer" : "Invoice number", text: $model.draft.number)
            DatePicker(de ? "Rechnungsdatum" : "Invoice date", selection: $model.draft.issueDate, displayedComponents: .date)
            Toggle(de ? "Leistungszeitraum statt Leistungsdatum" : "Service period instead of a date", isOn: $model.draft.usesPeriod)
            if model.draft.usesPeriod {
                DatePicker(de ? "Zeitraum von" : "Period from", selection: $model.draft.periodStart, displayedComponents: .date)
                DatePicker(de ? "bis" : "to", selection: $model.draft.periodEnd, displayedComponents: .date)
            } else {
                DatePicker(de ? "Leistungs-/Lieferdatum" : "Delivery date", selection: $model.draft.deliveryDate, displayedComponents: .date)
            }
            Toggle(de ? "Fälligkeitsdatum angeben" : "State a due date", isOn: $model.draft.hasDueDate)
            if model.draft.hasDueDate {
                DatePicker(de ? "Fällig am" : "Due on", selection: $model.draft.dueDate, displayedComponents: .date)
            }
            TextField(de ? "Zahlungsbedingungen" : "Payment terms", text: $model.draft.paymentTerms,
                      prompt: Text(de ? "z. B. Zahlbar innerhalb von 14 Tagen" : "e.g. Payable within 14 days"))
            TextField(model.draft.format == .xrechnungXML ? "Leitweg-ID" : (de ? "Käuferreferenz" : "Buyer reference"),
                      text: $model.draft.buyerReference,
                      prompt: Text(de ? "vom Käufer vorgegeben" : "given by the buyer"))
            TextField(de ? "Bestellnummer" : "Order number", text: $model.draft.orderReference)
            TextField(de ? "Währung" : "Currency", text: $model.draft.currency)
            TextField(de ? "Bemerkung" : "Note", text: $model.draft.note, axis: .vertical)
                .lineLimit(1...4)
        }
    }

    private func partySection(_ title: String, party: Binding<DraftParty>, isSeller: Bool) -> some View {
        SwiftUI.Section {
            TextField("Name", text: party.name)
            TextField(de ? "Straße und Hausnummer" : "Street", text: party.street)
            TextField(de ? "PLZ" : "Postcode", text: party.postcode)
            TextField(de ? "Ort" : "City", text: party.city)
            TextField(de ? "Land (ISO-Code)" : "Country (ISO code)", text: party.country, prompt: Text("DE"))
            TextField(de ? "USt-IdNr." : "VAT ID", text: party.vatID,
                      prompt: Text(isSeller ? "DE123456789" : (de ? "optional, Pflicht bei Reverse Charge" : "optional, required for reverse charge")))
            if isSeller {
                TextField(de ? "Steuernummer" : "Tax number", text: party.taxNumber, prompt: Text(de ? "wenn keine USt-IdNr." : "if no VAT ID"))
                TextField(de ? "Ansprechpartner" : "Contact name", text: party.contactName)
                TextField(de ? "Telefon" : "Phone", text: party.phone)
            }
            TextField(de ? "E-Mail" : "E-mail", text: party.email)
        } header: {
            Text(title)
        } footer: {
            if isSeller {
                Text(de ? "Firmendaten und Bankverbindung werden beim Speichern für die nächste Rechnung gemerkt (nur auf diesem Mac)."
                        : "Business and bank details are remembered for the next invoice when you save (on this Mac only).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var linesSection: some View {
        SwiftUI.Section(de ? "Positionen" : "Line items") {
            ForEach($model.draft.lines) { $line in
                LineEditor(line: $line, lang: lang, currency: model.draft.currency.uppercased(),
                           canDelete: model.draft.lines.count > 1) {
                    model.draft.lines.removeAll { $0.id == line.id }
                }
            }
            Button {
                var line = DraftLine()
                line.tax = model.draft.lines.last?.tax ?? .standard19
                line.unit = model.draft.lines.last?.unit ?? .piece
                model.draft.lines.append(line)
            } label: {
                Label(de ? "Position hinzufügen" : "Add line", systemImage: "plus")
            }

            LabeledContent(de ? "Summe netto" : "Net total", value: money(model.draft.lineTotal))
            ForEach(model.draft.taxGroups, id: \.treatment) { group in
                LabeledContent((de ? "USt " : "VAT ") + group.treatment.label(lang), value: money(group.tax))
            }
            LabeledContent {
                Text(money(model.draft.grossTotal)).fontWeight(.semibold)
            } label: {
                Text(de ? "Gesamtbetrag" : "Total").fontWeight(.semibold)
            }
        }
    }

    private var paymentSection: some View {
        SwiftUI.Section(de ? "Bankverbindung" : "Bank account") {
            TextField("IBAN", text: $model.draft.iban, prompt: Text("DE89 3704 0044 0532 0130 00"))
            TextField("BIC", text: $model.draft.bic, prompt: Text(de ? "optional" : "optional"))
            TextField(de ? "Kontoinhaber" : "Account holder", text: $model.draft.accountName)
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline) {
                if problems.isEmpty {
                    Label(de ? "Alle Pflichtangaben sind ausgefüllt." : "All mandatory fields are filled in.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Button {
                        showProblems.toggle()
                    } label: {
                        Label(de ? "Noch \(problems.count) Angaben offen" : "\(problems.count) items still missing",
                              systemImage: "exclamationmark.circle")
                    }
                    .buttonStyle(.link)
                    .popover(isPresented: $showProblems, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(problems, id: \.self) { Text("• " + $0) }
                        }
                        .padding()
                        .frame(maxWidth: 420, alignment: .leading)
                    }
                }
                Spacer()
                Button(model.draft.format == .zugferdPDF
                       ? (de ? "E-Rechnung speichern …" : "Save e-invoice…")
                       : (de ? "XRechnung speichern …" : "Save XRechnung…")) {
                    model.save(lang: lang) { openWindow(id: "main") }
                }
                .keyboardShortcut("s")
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!problems.isEmpty || (model.draft.format == .zugferdPDF && model.sourcePDF == nil))
            }
        }
        .padding(16)
    }
}

private struct LineEditor: View {
    @Binding var line: DraftLine
    let lang: Lang
    let currency: String
    let canDelete: Bool
    let delete: () -> Void

    private var de: Bool { lang == .de }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField(de ? "Bezeichnung" : "Description", text: $line.name)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                if canDelete {
                    Button(role: .destructive, action: delete) {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help(de ? "Position entfernen" : "Remove line")
                }
            }
            HStack(spacing: 8) {
                TextField(de ? "Menge" : "Qty", value: $line.quantity, format: .number.locale(lang.locale))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                Picker("", selection: $line.unit) {
                    ForEach(UnitCode.allCases, id: \.self) { Text($0.label(lang)).tag($0) }
                }
                .labelsHidden()
                .frame(width: 100)
                Text("×").foregroundStyle(.secondary)
                TextField(de ? "Preis netto" : "Net price", value: $line.unitPrice, format: .number.locale(lang.locale))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
                Picker("", selection: $line.tax) {
                    ForEach(TaxTreatment.allCases, id: \.self) { Text($0.label(lang)).tag($0) }
                }
                .labelsHidden()
                .frame(minWidth: 120)
                Spacer(minLength: 4)
                Text(Money.format(line.netAmount, currency: currency, lang: lang))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
