import SwiftUI
import AppKit
import UniformTypeIdentifiers
import EInvoiceKit

@main
struct ERechnungCheckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    init() {
        // `--snapshot in out.png` renders a report to an image and quits.
        // Used to check the layout without clicking through the app.
        Snapshot.runIfRequested()
    }

    var body: some Scene {
        Window("E-Rechnung Check", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 560, idealWidth: 740, minHeight: 520, idealHeight: 840)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                NewInvoiceButton(lang: model.lang)
                    .keyboardShortcut("n")
                Button(model.lang == .de ? "Öffnen …" : "Open…") { model.chooseFile() }
                    .keyboardShortcut("o")
            }
        }

        Window(model.lang == .de ? "Neue E-Rechnung" : "New e-invoice", id: "create") {
            CreateView()
                .environmentObject(model)
        }
        .defaultSize(width: 720, height: 860)
    }
}

/// Opens the window for creating an e-invoice.
struct NewInvoiceButton: View {
    let lang: Lang
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(lang == .de ? "Neue E-Rechnung …" : "New e-invoice…") { openWindow(id: "create") }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    /// "Open With" in Finder and files dropped on the Dock icon arrive here.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        Task { @MainActor in AppModel.shared.load(url) }
    }

    /// The Finder Quick Action "E-Rechnung prüfen" (NSServices in Info.plist).
    /// The system grants the sandbox read access to the files it passes here.
    @objc func checkInvoice(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let url = urls.first else {
            error.pointee = "No file received." as NSString
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        Task { @MainActor in AppModel.shared.load(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var report: Report?
    @Published var isLoading = false
    @Published var lang: Lang = .system

    func load(_ url: URL) {
        isLoading = true
        Task.detached(priority: .userInitiated) {
            // Inside the sandbox a picked or dropped file is readable only
            // between these two calls.
            let scoped = url.startAccessingSecurityScopedResource()
            let report = Inspector.inspect(url: url)
            if scoped { url.stopAccessingSecurityScopedResource() }
            // Opt-in trace for testing the app from a script. Prints the
            // verdict only, never file names or invoice content.
            if ProcessInfo.processInfo.environment["ERECHNUNG_CHECK_TRACE"] != nil {
                FileHandle.standardError.write(Data("loaded: \(report.verdict.rawValue)\n".utf8))
            }
            await MainActor.run {
                self.report = report
                self.isLoading = false
            }
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .xml]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = lang == .de ? "PDF- oder XML-Rechnung auswählen" : "Choose a PDF or XML invoice"
        if panel.runModal() == .OK, let url = panel.url {
            load(url)
        }
    }

    func reset() { report = nil }
}

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var isTargeted = false

    var body: some View {
        Group {
            if let report = model.report {
                ScrollView {
                    ReportContent(report: report, lang: model.lang)
                        .padding(24)
                        .frame(maxWidth: 780)
                        .frame(maxWidth: .infinity)
                }
            } else {
                DropPrompt(lang: model.lang, isTargeted: isTargeted, isLoading: model.isLoading,
                           choose: { model.chooseFile() },
                           create: { openWindow(id: "create") })
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isTargeted && model.report != nil {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.load(url) }
            }
            return true
        }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    openWindow(id: "create")
                } label: {
                    Label(model.lang == .de ? "Neue E-Rechnung" : "New e-invoice", systemImage: "square.and.pencil")
                }
                .help(model.lang == .de ? "E-Rechnung erstellen" : "Create an e-invoice")
                if model.report != nil {
                    Button {
                        model.chooseFile()
                    } label: {
                        Label(model.lang == .de ? "Andere Datei" : "Another file", systemImage: "doc.badge.plus")
                    }
                    .help(model.lang == .de ? "Andere Datei prüfen" : "Check another file")
                }
                Picker("", selection: $model.lang) {
                    Text("Deutsch").tag(Lang.de)
                    Text("English").tag(Lang.en)
                }
                .pickerStyle(.menu)
                .help(model.lang == .de ? "Sprache" : "Language")
            }
        }
    }
}

struct DropPrompt: View {
    let lang: Lang
    let isTargeted: Bool
    let isLoading: Bool
    let choose: () -> Void
    var create: (() -> Void)?

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary)
            VStack(spacing: 6) {
                Text(lang == .de ? "Rechnung hierher ziehen" : "Drop an invoice here")
                    .font(.title2.weight(.semibold))
                Text(lang == .de
                     ? "PDF oder XML. Sie sehen sofort, ob es eine E-Rechnung ist und was wirklich darin steht."
                     : "PDF or XML. You see at once whether it is an e-invoice and what it really says.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if isLoading {
                ProgressView().controlSize(.small)
            } else {
                Button(lang == .de ? "Datei auswählen …" : "Choose a file…", action: choose)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
            if let create {
                Button(lang == .de ? "Oder eine E-Rechnung erstellen …" : "Or create an e-invoice…", action: create)
                    .buttonStyle(.link)
            }
            Label(lang == .de ? "Die Datei verlässt Ihren Mac nicht." : "The file never leaves your Mac.", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: 460)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(isTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                              style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                .padding(20)
        }
    }
}

/// Renders a report (or the empty window) to a PNG and exits.
enum Snapshot {
    @MainActor
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--snapshot"), arguments.count > index + 2 else { return }
        let input = arguments[index + 1]
        let output = URL(fileURLWithPath: arguments[index + 2])
        let lang: Lang = arguments.contains("--en") ? .en : .de

        if input == "create" {
            // The form uses AppKit-backed controls, which ImageRenderer
            // draws blank, so this one goes through a real hosting view.
            AppModel.shared.lang = lang
            if arguments.contains("--demo") { CreateModel.shared.draft = CreateModel.demoDraft() }
            let view = NSHostingView(rootView: CreateView().environmentObject(AppModel.shared))
            view.frame = CGRect(x: 0, y: 0, width: 720, height: 2350)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { exit(1) }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let png = bitmap.representation(using: .png, properties: [:])
            exit((try? png?.write(to: output)) != nil ? 0 : 1)
        }

        let content: AnyView
        if input == "-" {
            content = AnyView(DropPrompt(lang: lang, isTargeted: false, isLoading: false, choose: {})
                .frame(width: 740, height: 560))
        } else {
            let report = Inspector.inspect(url: URL(fileURLWithPath: input))
            content = AnyView(ReportContent(report: report, lang: lang, detailsExpanded: arguments.contains("--details"))
                .padding(24)
                .frame(width: 740))
        }

        let renderer = ImageRenderer(content: content.background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            FileHandle.standardError.write(Data("snapshot failed\n".utf8))
            exit(1)
        }
        do {
            try png.write(to: output)
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("cannot write \(output.path)\n".utf8))
            exit(1)
        }
    }
}
