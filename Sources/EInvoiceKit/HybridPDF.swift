import Foundation
import CoreGraphics

/// Turns an ordinary PDF into a ZUGFeRD / Factur-X hybrid invoice by
/// appending an incremental update that adds
///
/// - the invoice XML as an embedded file (`factur-x.xml`), linked from the
///   catalog's `/AF` array with `/AFRelationship /Alternative`;
/// - XMP metadata declaring PDF/A-3B and the Factur-X extension schema;
/// - an sRGB output intent if the file has none;
/// - a document info dictionary that matches the XMP.
///
/// The original bytes stay untouched. Whether the result is valid PDF/A-3
/// also depends on the original (embedded fonts, no transparency groups
/// without blending space …), which this code does not change; a PDF/A
/// original gives the best result.
public enum HybridPDF {
    public struct Options: Sendable {
        /// `fx:ConformanceLevel`: "EN 16931", "BASIC", "EXTENDED", "XRECHNUNG" …
        public var conformanceLevel = "EN 16931"
        public var fileName = "factur-x.xml"
        public var producer = "E-Rechnung Check"

        public init() {}
    }

    public enum Failure: Error, Equatable, Sendable {
        case notPDF
        case encrypted
        case unsupported(String)
        case damaged(String)
    }

    public static func embed(xml: Data, into pdf: Data, options: Options = Options(), date: Date = Date()) throws -> Data {
        do {
            return try write(xml: xml, pdf: pdf, options: options, date: date)
        } catch let error as PDFError {
            switch error {
            case .notPDF: throw Failure.notPDF
            case .encrypted: throw Failure.encrypted
            case .damaged(let s): throw Failure.damaged(s)
            case .unsupported(let s): throw Failure.unsupported(s)
            }
        }
    }

    private static func write(xml: Data, pdf: Data, options: Options, date: Date) throws -> Data {
        var file = try PDFFile(pdf)
        let trailer = file.trailer
        // PDF/A forbids encryption, and an update would need the key anyway.
        guard trailer["Encrypt"] == nil else { throw PDFError.encrypted }
        guard let (rootNumber, rootGeneration) = trailer["Root"]?.reference,
              var catalog = try file.object(rootNumber).value.dict else { throw PDFError.damaged("no catalog") }
        guard let size = trailer["Size"]?.int else { throw PDFError.damaged("no /Size") }

        var update = Update(base: file.bytes, next: size)

        // 1. The invoice XML.
        let pdfDate = Self.pdfDate(date)
        var fileDict = PDFDict()
        fileDict["Type"] = .name("EmbeddedFile")
        fileDict["Subtype"] = .name("text#2Fxml")
        var params = PDFDict()
        params["Size"] = .number(String(xml.count))
        params["ModDate"] = .text(pdfDate)
        fileDict["Params"] = .dict(params)
        let fileRef = update.add(.dict(fileDict), stream: [UInt8](xml))

        var spec = PDFDict()
        spec["Type"] = .name("Filespec")
        spec["F"] = .text(options.fileName)
        spec["UF"] = .text(options.fileName)
        spec["Desc"] = .text("Factur-X/ZUGFeRD Invoice")
        // EN 16931 and above replace the visual invoice ("Alternative");
        // MINIMUM and BASIC WL only supplement it ("Data").
        let level = options.conformanceLevel.uppercased()
        spec["AFRelationship"] = .name(level == "MINIMUM" || level == "BASIC WL" ? "Data" : "Alternative")
        var ef = PDFDict()
        ef["F"] = fileRef
        ef["UF"] = fileRef
        spec["EF"] = .dict(ef)
        let specRef = update.add(.dict(spec))

        // 2. Document info, rebuilt from the readable old values so that it
        //    and the XMP say the same thing (a PDF/A requirement).
        let oldInfo = try file.resolve(trailer["Info"])?.dict ?? PDFDict()
        var info = DocumentInfo()
        info.title = oldInfo["Title"]?.textValue
        info.author = oldInfo["Author"]?.textValue
        info.subject = oldInfo["Subject"]?.textValue
        info.keywords = oldInfo["Keywords"]?.textValue
        info.creator = oldInfo["Creator"]?.textValue
        info.producer = oldInfo["Producer"]?.textValue.flatMap { $0.isBlank ? nil : $0 } ?? options.producer
        info.created = oldInfo["CreationDate"]?.textValue.flatMap(Self.parsePDFDate) ?? date
        info.modified = date

        var newInfo = PDFDict()
        for (key, value) in [("Title", info.title), ("Author", info.author), ("Subject", info.subject),
                             ("Keywords", info.keywords), ("Creator", info.creator), ("Producer", info.producer)] {
            if let value, !value.isBlank { newInfo[key] = .text(value) }
        }
        newInfo["CreationDate"] = .text(Self.pdfDate(info.created))
        newInfo["ModDate"] = .text(pdfDate)
        let infoRef: PDFValue
        if let (n, g) = trailer["Info"]?.reference {
            update.replace(n, generation: g, .dict(newInfo))
            infoRef = .ref(n, g)
        } else {
            infoRef = update.add(.dict(newInfo))
        }

        // 3. XMP metadata.
        var metaDict = PDFDict()
        metaDict["Type"] = .name("Metadata")
        metaDict["Subtype"] = .name("XML")
        let xmp = Self.xmp(info: info, options: options)
        catalog["Metadata"] = update.add(.dict(metaDict), stream: [UInt8](xmp.utf8))

        // 4. Attachment lists. Other entries of an existing /Names stay.
        var names = try file.resolve(catalog["Names"])?.dict ?? PDFDict()
        var embedded = PDFDict()
        embedded["Names"] = .array([.text(options.fileName), specRef])
        names["EmbeddedFiles"] = .dict(embedded)
        catalog["Names"] = .dict(names)
        catalog["AF"] = .array([specRef])

        // 5. Output intent, required by PDF/A when the file uses device colours.
        if catalog["OutputIntents"] == nil, let icc = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? {
            var profile = PDFDict()
            profile["N"] = .number("3")
            let profileRef = update.add(.dict(profile), stream: [UInt8](icc))
            var intent = PDFDict()
            intent["Type"] = .name("OutputIntent")
            intent["S"] = .name("GTS_PDFA1")
            intent["OutputConditionIdentifier"] = .text("sRGB IEC61966-2.1")
            intent["Info"] = .text("sRGB IEC61966-2.1")
            intent["DestOutputProfile"] = profileRef
            catalog["OutputIntents"] = .array([.dict(intent)])
        }

        update.replace(rootNumber, generation: rootGeneration, .dict(catalog))

        // 6. Cross-reference section and trailer.
        var id: [UInt8] = []
        for _ in 0..<16 { id.append(UInt8.random(in: 0...255)) }
        let newID = PDFValue.string(Array(("<" + id.map { String(format: "%02X", $0) }.joined() + ">").utf8))
        let firstID = trailer["ID"]?.array?.first ?? newID

        var newTrailer = PDFDict()
        newTrailer["Root"] = .ref(rootNumber, rootGeneration)
        newTrailer["Info"] = infoRef
        newTrailer["ID"] = .array([firstID, newID])
        newTrailer["Prev"] = .number(String(file.startXref))
        return Data(update.finish(trailer: newTrailer, asStream: file.usesXrefStream))
    }

    // MARK: - Writing the update

    private struct Update {
        var out: [UInt8]
        var next: Int
        var objects: [(number: Int, generation: Int, value: PDFValue, stream: [UInt8]?)] = []

        init(base: [UInt8], next: Int) {
            out = base
            if let last = out.last, last != 10 && last != 13 { out.append(10) }
            self.next = next
        }

        mutating func add(_ value: PDFValue, stream: [UInt8]? = nil) -> PDFValue {
            let number = next
            next += 1
            objects.append((number, 0, value, stream))
            return .ref(number, 0)
        }

        mutating func replace(_ number: Int, generation: Int, _ value: PDFValue) {
            objects.append((number, generation, value, nil))
        }

        mutating func finish(trailer: PDFDict, asStream: Bool) -> [UInt8] {
            var offsets: [Int: (offset: Int, generation: Int)] = [:]
            for object in objects {
                offsets[object.number] = (out.count, object.generation)
                out += Array("\(object.number) \(object.generation) obj\n".utf8)
                if let stream = object.stream, var dict = object.value.dict {
                    dict["Length"] = .number(String(stream.count))
                    PDFValue.dict(dict).write(to: &out)
                    out += Array("\nstream\n".utf8)
                    out += stream
                    out += Array("\nendstream".utf8)
                } else {
                    object.value.write(to: &out)
                }
                out += Array("\nendobj\n".utf8)
            }

            var trailer = trailer
            let start = out.count
            if asStream {
                // The cross-reference stream is itself an object of the update.
                let xrefNumber = next
                offsets[xrefNumber] = (start, 0)
                let numbers = offsets.keys.sorted()
                var rows: [UInt8] = []
                for n in numbers {
                    let (offset, generation) = offsets[n]!
                    rows.append(1)
                    rows += [UInt8(offset >> 24 & 0xFF), UInt8(offset >> 16 & 0xFF), UInt8(offset >> 8 & 0xFF), UInt8(offset & 0xFF)]
                    rows += [UInt8(generation >> 8 & 0xFF), UInt8(generation & 0xFF)]
                }
                trailer["Type"] = .name("XRef")
                trailer["Size"] = .number(String(xrefNumber + 1))
                trailer["W"] = .array([.number("1"), .number("4"), .number("2")])
                trailer["Index"] = .array(Self.runs(numbers).flatMap { [PDFValue.number(String($0.0)), .number(String($0.1))] })
                trailer["Length"] = .number(String(rows.count))
                out += Array("\(xrefNumber) 0 obj\n".utf8)
                PDFValue.dict(trailer).write(to: &out)
                out += Array("\nstream\n".utf8)
                out += rows
                out += Array("\nendstream\nendobj\n".utf8)
            } else {
                out += Array("xref\n".utf8)
                let numbers = offsets.keys.sorted()
                var index = 0
                for (first, count) in Self.runs(numbers) {
                    out += Array("\(first) \(count)\n".utf8)
                    for n in first..<first + count {
                        let (offset, generation) = offsets[n]!
                        out += Array(String(format: "%010d %05d n\r\n", offset, generation).utf8)
                    }
                    index += count
                }
                trailer["Size"] = .number(String(next))
                out += Array("trailer\n".utf8)
                PDFValue.dict(trailer).write(to: &out)
                out += Array("\n".utf8)
            }
            out += Array("startxref\n\(start)\n%%EOF\n".utf8)
            return out
        }

        /// Groups sorted numbers into (first, count) runs.
        static func runs(_ numbers: [Int]) -> [(Int, Int)] {
            var result: [(Int, Int)] = []
            for n in numbers {
                if let last = result.last, last.0 + last.1 == n {
                    result[result.count - 1].1 += 1
                } else {
                    result.append((n, 1))
                }
            }
            return result
        }
    }

    // MARK: - Metadata

    struct DocumentInfo {
        var title: String?
        var author: String?
        var subject: String?
        var keywords: String?
        var creator: String?
        var producer: String?
        var created = Date()
        var modified = Date()
    }

    static func xmp(info: DocumentInfo, options: Options) -> String {
        func e(_ s: String) -> String { XMLText.escape(s) }
        var dc = ""
        if let t = info.title, !t.isBlank {
            dc += "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(e(t))</rdf:li></rdf:Alt></dc:title>\n"
        }
        if let a = info.author, !a.isBlank {
            dc += "<dc:creator><rdf:Seq><rdf:li>\(e(a))</rdf:li></rdf:Seq></dc:creator>\n"
        }
        if let s = info.subject, !s.isBlank {
            dc += "<dc:description><rdf:Alt><rdf:li xml:lang=\"x-default\">\(e(s))</rdf:li></rdf:Alt></dc:description>\n"
        }
        var pdf = ""
        if let p = info.producer, !p.isBlank { pdf += "<pdf:Producer>\(e(p))</pdf:Producer>\n" }
        if let k = info.keywords, !k.isBlank { pdf += "<pdf:Keywords>\(e(k))</pdf:Keywords>\n" }
        var tool = ""
        if let c = info.creator, !c.isBlank { tool = "<xmp:CreatorTool>\(e(c))</xmp:CreatorTool>\n" }

        func property(_ name: String, _ description: String) -> String {
            """
            <rdf:li rdf:parseType="Resource">
            <pdfaProperty:name>\(name)</pdfaProperty:name>
            <pdfaProperty:valueType>Text</pdfaProperty:valueType>
            <pdfaProperty:category>external</pdfaProperty:category>
            <pdfaProperty:description>\(description)</pdfaProperty:description>
            </rdf:li>
            """
        }

        let packet = """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
        <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
        <rdf:Description rdf:about="" xmlns:pdfaid="http://www.aiim.org/pdfa/ns/id/">
        <pdfaid:part>3</pdfaid:part>
        <pdfaid:conformance>B</pdfaid:conformance>
        </rdf:Description>
        <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:format>application/pdf</dc:format>
        \(dc)</rdf:Description>
        <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/">
        \(tool)<xmp:CreateDate>\(xmpDate(info.created))</xmp:CreateDate>
        <xmp:ModifyDate>\(xmpDate(info.modified))</xmp:ModifyDate>
        <xmp:MetadataDate>\(xmpDate(info.modified))</xmp:MetadataDate>
        </rdf:Description>
        <rdf:Description rdf:about="" xmlns:pdf="http://ns.adobe.com/pdf/1.3/">
        \(pdf)</rdf:Description>
        <rdf:Description rdf:about="" xmlns:fx="urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#">
        <fx:DocumentType>INVOICE</fx:DocumentType>
        <fx:DocumentFileName>\(e(options.fileName))</fx:DocumentFileName>
        <fx:Version>1.0</fx:Version>
        <fx:ConformanceLevel>\(e(options.conformanceLevel))</fx:ConformanceLevel>
        </rdf:Description>
        <rdf:Description rdf:about="" xmlns:pdfaExtension="http://www.aiim.org/pdfa/ns/extension/" xmlns:pdfaSchema="http://www.aiim.org/pdfa/ns/schema#" xmlns:pdfaProperty="http://www.aiim.org/pdfa/ns/property#">
        <pdfaExtension:schemas>
        <rdf:Bag>
        <rdf:li rdf:parseType="Resource">
        <pdfaSchema:schema>Factur-X PDFA Extension Schema</pdfaSchema:schema>
        <pdfaSchema:namespaceURI>urn:factur-x:pdfa:CrossIndustryDocument:invoice:1p0#</pdfaSchema:namespaceURI>
        <pdfaSchema:prefix>fx</pdfaSchema:prefix>
        <pdfaSchema:property>
        <rdf:Seq>
        \(property("DocumentFileName", "The name of the embedded XML document"))
        \(property("DocumentType", "The type of the hybrid document in capital letters, e.g. INVOICE or ORDER"))
        \(property("Version", "The actual version of the standard applying to the embedded XML document"))
        \(property("ConformanceLevel", "The conformance level of the embedded XML document"))
        </rdf:Seq>
        </pdfaSchema:property>
        </rdf:li>
        </rdf:Bag>
        </pdfaExtension:schemas>
        </rdf:Description>
        </rdf:RDF>
        </x:xmpmeta>
        """
        // Padding lets other tools edit the packet in place.
        let padding = String(repeating: String(repeating: " ", count: 99) + "\n", count: 20)
        return packet + "\n" + padding + "<?xpacket end=\"w\"?>"
    }

    // MARK: - Dates

    private static func offsetParts(_ date: Date) -> (sign: String, hours: Int, minutes: Int) {
        let seconds = TimeZone.current.secondsFromGMT(for: date)
        return (seconds < 0 ? "-" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    }

    private static func components(_ date: Date) -> DateComponents {
        Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
    }

    /// `D:20261111143000+01'00'`
    static func pdfDate(_ date: Date) -> String {
        let c = components(date)
        let o = offsetParts(date)
        return String(format: "D:%04d%02d%02d%02d%02d%02d%@%02d'%02d'",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, o.sign, o.hours, o.minutes)
    }

    /// `2026-11-11T14:30:00+01:00`, the same instant as `pdfDate`.
    static func xmpDate(_ date: Date) -> String {
        let c = components(date)
        let o = offsetParts(date)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d%@%02d:%02d",
                      c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, o.sign, o.hours, o.minutes)
    }

    /// Reads `D:YYYYMMDDHHmmSSOHH'mm'`; every part after the year is optional.
    static func parsePDFDate(_ raw: String) -> Date? {
        var s = Substring(raw.trimmingCharacters(in: .whitespaces))
        if s.hasPrefix("D:") { s = s.dropFirst(2) }
        let digits = s.prefix { $0.isNumber }
        guard digits.count >= 4 else { return nil }
        func part(_ from: Int, _ length: Int, _ fallback: Int) -> Int {
            guard digits.count >= from + length else { return fallback }
            let start = digits.index(digits.startIndex, offsetBy: from)
            return Int(digits[start..<digits.index(start, offsetBy: length)]) ?? fallback
        }
        var c = DateComponents()
        c.year = part(0, 4, 1970); c.month = part(4, 2, 1); c.day = part(6, 2, 1)
        c.hour = part(8, 2, 0); c.minute = part(10, 2, 0); c.second = part(12, 2, 0)
        let rest = s.dropFirst(digits.count)
        if let sign = rest.first, sign == "+" || sign == "-" {
            let numbers = rest.dropFirst().split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
            let seconds = ((numbers.first ?? 0) * 3600 + (numbers.dropFirst().first ?? 0) * 60) * (sign == "-" ? -1 : 1)
            c.timeZone = TimeZone(secondsFromGMT: seconds)
        } else if rest.first == "Z" {
            c.timeZone = TimeZone(secondsFromGMT: 0)
        } else {
            c.timeZone = .current
        }
        return Calendar(identifier: .gregorian).date(from: c)
    }
}
