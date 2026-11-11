import Foundation

/// Just enough of the PDF object model to append an incremental update:
/// read the cross-reference data (tables and streams, object streams
/// included), resolve objects and write them back unchanged.
///
/// Core Graphics resolves references on reading and cannot write a PDF
/// without re-rendering it, which would throw away PDF/A properties. An
/// incremental update keeps every original byte and only appends.
indirect enum PDFValue {
    case null
    case bool(Bool)
    /// Kept as written, so integers and reals round-trip exactly.
    case number(String)
    /// Without the slash, still in its escaped form (`text#2Fxml`).
    case name(String)
    /// The literal `( … )` or hex `< … >` string with its delimiters, raw.
    case string([UInt8])
    case array([PDFValue])
    case dict(PDFDict)
    case ref(Int, Int)

    var int: Int? { if case .number(let s) = self { return Int(s) ?? Double(s).map { Int($0) } } else { return nil } }
    var dict: PDFDict? { if case .dict(let d) = self { return d } else { return nil } }
    var array: [PDFValue]? { if case .array(let a) = self { return a } else { return nil } }
    var nameValue: String? { if case .name(let n) = self { return n } else { return nil } }
    var reference: (Int, Int)? { if case .ref(let n, let g) = self { return (n, g) } else { return nil } }

    func write(to out: inout [UInt8]) {
        switch self {
        case .null: out += Array("null".utf8)
        case .bool(let b): out += Array((b ? "true" : "false").utf8)
        case .number(let s): out += Array(s.utf8)
        case .name(let n): out += Array("/\(n)".utf8)
        case .string(let raw): out += raw
        case .ref(let n, let g): out += Array("\(n) \(g) R".utf8)
        case .array(let items):
            out.append(UInt8(ascii: "["))
            for (i, item) in items.enumerated() {
                if i > 0 { out.append(UInt8(ascii: " ")) }
                item.write(to: &out)
            }
            out.append(UInt8(ascii: "]"))
        case .dict(let d):
            out += Array("<<".utf8)
            for (key, value) in d.entries {
                out += Array("/\(key) ".utf8)
                value.write(to: &out)
                out.append(UInt8(ascii: " "))
            }
            out += Array(">>".utf8)
        }
    }

    /// A literal string, escaped; non-ASCII text goes out as UTF-16BE hex.
    static func text(_ s: String) -> PDFValue {
        if s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            var raw: [UInt8] = [UInt8(ascii: "(")]
            for byte in s.utf8 {
                if byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") || byte == UInt8(ascii: "\\") {
                    raw.append(UInt8(ascii: "\\"))
                }
                raw.append(byte)
            }
            raw.append(UInt8(ascii: ")"))
            return .string(raw)
        }
        var hex = "<FEFF"
        for unit in s.utf16 { hex += String(format: "%04X", unit) }
        return .string(Array((hex + ">").utf8))
    }

    /// The text of a string value: PDFDocEncoding (taken as Latin-1, which
    /// covers the printable range) or UTF-16 with a byte order mark.
    var textValue: String? {
        guard case .string(let raw) = self, let first = raw.first else { return nil }
        var bytes: [UInt8] = []
        if first == UInt8(ascii: "<") {
            let digits = raw.dropFirst().prefix { $0 != UInt8(ascii: ">") }.filter { !PDFLexer.isWhitespace($0) }
            var nibbles = digits.compactMap { PDFLexer.hexValue($0) }
            if nibbles.count % 2 == 1 { nibbles.append(0) }
            for i in stride(from: 0, to: nibbles.count, by: 2) { bytes.append(nibbles[i] << 4 | nibbles[i + 1]) }
        } else {
            bytes = PDFLexer.unescapeLiteral(Array(raw.dropFirst().dropLast()))
        }
        if bytes.count >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF {
            return String(data: Data(bytes.dropFirst(2)), encoding: .utf16BigEndian)
        }
        if bytes.count >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF {
            return String(decoding: bytes.dropFirst(3), as: UTF8.self)
        }
        return String(bytes: bytes, encoding: .isoLatin1)
    }
}

/// A dictionary that keeps the original key order.
struct PDFDict {
    var entries: [(String, PDFValue)] = []

    subscript(key: String) -> PDFValue? {
        get { entries.first { $0.0 == key }?.1 }
        set {
            if let index = entries.firstIndex(where: { $0.0 == key }) {
                if let newValue { entries[index].1 = newValue } else { entries.remove(at: index) }
            } else if let newValue {
                entries.append((key, newValue))
            }
        }
    }
}

enum PDFError: Error, Equatable {
    case notPDF
    case encrypted
    case damaged(String)
    case unsupported(String)
}

struct PDFLexer {
    let bytes: [UInt8]
    var pos: Int

    init(_ bytes: [UInt8], at pos: Int = 0) {
        self.bytes = bytes
        self.pos = pos
    }

    static func isWhitespace(_ b: UInt8) -> Bool { b == 0 || b == 9 || b == 10 || b == 12 || b == 13 || b == 32 }
    static func isDelimiter(_ b: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(b) }
    static func hexValue(_ b: UInt8) -> UInt8? {
        switch b {
        case 48...57: return b - 48
        case 65...70: return b - 55
        case 97...102: return b - 87
        default: return nil
        }
    }

    var atEnd: Bool { pos >= bytes.count }

    mutating func skipWhitespace() {
        while pos < bytes.count {
            if Self.isWhitespace(bytes[pos]) {
                pos += 1
            } else if bytes[pos] == UInt8(ascii: "%") {
                while pos < bytes.count && bytes[pos] != 10 && bytes[pos] != 13 { pos += 1 }
            } else {
                return
            }
        }
    }

    /// A bare word such as `obj`, `R`, `stream`, `true`.
    mutating func keyword() -> String {
        skipWhitespace()
        let start = pos
        while pos < bytes.count && !Self.isWhitespace(bytes[pos]) && !Self.isDelimiter(bytes[pos]) { pos += 1 }
        return String(decoding: bytes[start..<pos], as: UTF8.self)
    }

    mutating func peek(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return pos + u.count <= bytes.count && Array(bytes[pos..<pos + u.count]) == u
    }

    mutating func value(depth: Int = 0) throws -> PDFValue {
        guard depth < 64 else { throw PDFError.damaged("nesting too deep") }
        skipWhitespace()
        guard pos < bytes.count else { throw PDFError.damaged("unexpected end") }
        let b = bytes[pos]

        if peek("<<") {
            pos += 2
            var dict = PDFDict()
            while true {
                skipWhitespace()
                if peek(">>") { pos += 2; return .dict(dict) }
                guard pos < bytes.count, bytes[pos] == UInt8(ascii: "/") else { throw PDFError.damaged("dictionary key expected at \(pos)") }
                guard case .name(let key) = try value(depth: depth + 1) else { throw PDFError.damaged("bad key") }
                dict.entries.append((key, try value(depth: depth + 1)))
            }
        }
        switch b {
        case UInt8(ascii: "<"):
            let start = pos
            while pos < bytes.count && bytes[pos] != UInt8(ascii: ">") { pos += 1 }
            pos += 1
            return .string(Array(bytes[start..<min(pos, bytes.count)]))
        case UInt8(ascii: "("):
            let start = pos
            var level = 0
            while pos < bytes.count {
                let c = bytes[pos]
                if c == UInt8(ascii: "\\") { pos += 2; continue }
                if c == UInt8(ascii: "(") { level += 1 }
                if c == UInt8(ascii: ")") { level -= 1; if level == 0 { pos += 1; break } }
                pos += 1
            }
            return .string(Array(bytes[start..<min(pos, bytes.count)]))
        case UInt8(ascii: "["):
            pos += 1
            var items: [PDFValue] = []
            while true {
                skipWhitespace()
                guard pos < bytes.count else { throw PDFError.damaged("unterminated array") }
                if bytes[pos] == UInt8(ascii: "]") { pos += 1; return .array(items) }
                items.append(try value(depth: depth + 1))
            }
        case UInt8(ascii: "/"):
            pos += 1
            let start = pos
            while pos < bytes.count && !Self.isWhitespace(bytes[pos]) && !Self.isDelimiter(bytes[pos]) { pos += 1 }
            return .name(String(decoding: bytes[start..<pos], as: UTF8.self))
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "."):
            let number = keyword()
            // "12 0 R" is a reference; look ahead without consuming otherwise.
            if let n = Int(number) {
                let saved = pos
                let generation = keyword()
                if let g = Int(generation), keyword() == "R" { return .ref(n, g) }
                pos = saved
            }
            return .number(number)
        default:
            let word = keyword()
            switch word {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: throw PDFError.damaged("unexpected token '\(word.prefix(20))' at \(pos)")
            }
        }
    }

    /// Resolves the escapes of a literal string body.
    static func unescapeLiteral(_ body: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var i = 0
        while i < body.count {
            let c = body[i]
            guard c == UInt8(ascii: "\\"), i + 1 < body.count else { out.append(c); i += 1; continue }
            let next = body[i + 1]
            i += 2
            switch next {
            case UInt8(ascii: "n"): out.append(10)
            case UInt8(ascii: "r"): out.append(13)
            case UInt8(ascii: "t"): out.append(9)
            case UInt8(ascii: "b"): out.append(8)
            case UInt8(ascii: "f"): out.append(12)
            case 13: if i < body.count && body[i] == 10 { i += 1 }
            case 10: break
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - 48)
                var digits = 1
                while digits < 3, i < body.count, (48...55).contains(body[i]) {
                    value = value * 8 + Int(body[i] - 48)
                    i += 1
                    digits += 1
                }
                out.append(UInt8(value & 0xFF))
            default: out.append(next)
            }
        }
        return out
    }
}

/// An object as stored: its value and, for a stream, the raw (still
/// encoded) data.
struct PDFObject {
    var value: PDFValue
    var stream: [UInt8]?
}

/// Read access to an existing PDF through its cross-reference data.
struct PDFFile {
    enum Entry { case offset(Int), compressed(stream: Int, index: Int) }

    let bytes: [UInt8]
    /// The newest trailer (or cross-reference stream dictionary).
    let trailer: PDFDict
    /// Offset of the newest cross-reference section.
    let startXref: Int
    /// Whether the newest section is a cross-reference stream. An update
    /// should then be one as well.
    let usesXrefStream: Bool
    private(set) var entries: [Int: Entry] = [:]
    private var objectStreams: [Int: [Int: PDFValue]] = [:]

    init(_ data: Data) throws {
        bytes = [UInt8](data)
        guard data.prefix(1024).range(of: Data("%PDF-".utf8)) != nil else { throw PDFError.notPDF }

        // The last "startxref" in the file points at the newest section.
        let marker = Array("startxref".utf8)
        var found: Int?
        var i = bytes.count - marker.count
        let floor = max(0, bytes.count - 4096)
        while i >= floor {
            if bytes[i] == marker[0] && Array(bytes[i..<i + marker.count]) == marker { found = i; break }
            i -= 1
        }
        guard let found else { throw PDFError.damaged("no startxref") }
        var lexer = PDFLexer(bytes, at: found + marker.count)
        guard let offset = Int(lexer.keyword()), offset > 0, offset < bytes.count else { throw PDFError.damaged("bad startxref") }
        startXref = offset

        var newestTrailer: PDFDict?
        var newestIsStream = false
        var visited = Set<Int>()
        var queue = [offset]
        while let next = queue.first {
            queue.removeFirst()
            guard visited.insert(next).inserted, visited.count < 1000 else { continue }
            let (sectionEntries, sectionTrailer, isStream) = try Self.readSection(bytes, at: next)
            for (number, entry) in sectionEntries where entries[number] == nil { entries[number] = entry }
            if newestTrailer == nil {
                newestTrailer = sectionTrailer
                newestIsStream = isStream
            }
            // A hybrid file keeps extra entries in a stream named by /XRefStm.
            if let hybrid = sectionTrailer["XRefStm"]?.int { queue.insert(hybrid, at: 0) }
            if let prev = sectionTrailer["Prev"]?.int { queue.append(prev) }
        }
        guard let newestTrailer else { throw PDFError.damaged("no trailer") }
        trailer = newestTrailer
        usesXrefStream = newestIsStream
    }

    private static func readSection(_ bytes: [UInt8], at offset: Int) throws -> ([Int: Entry], PDFDict, Bool) {
        var lexer = PDFLexer(bytes, at: offset)
        lexer.skipWhitespace()
        if lexer.peek("xref") {
            _ = lexer.keyword()
            var result: [Int: Entry] = [:]
            while true {
                let saved = lexer.pos
                let word = lexer.keyword()
                if word == "trailer" { break }
                guard let start = Int(word), let count = Int(lexer.keyword()) else {
                    lexer.pos = saved
                    throw PDFError.damaged("bad xref subsection")
                }
                for k in 0..<count {
                    guard let off = Int(lexer.keyword()), Int(lexer.keyword()) != nil else { throw PDFError.damaged("bad xref entry") }
                    let kind = lexer.keyword()
                    if kind == "n", result[start + k] == nil { result[start + k] = .offset(off) }
                }
            }
            guard let trailer = try lexer.value().dict else { throw PDFError.damaged("bad trailer") }
            return (result, trailer, false)
        }

        // A cross-reference stream: "n g obj << /Type /XRef … >> stream".
        let object = try parseIndirect(bytes, at: offset, length: nil)
        guard let dict = object.value.dict, dict["Type"]?.nameValue == "XRef", let raw = object.stream else {
            throw PDFError.damaged("no xref at \(offset)")
        }
        let data = try decode(raw, dict: dict)
        guard let widths = dict["W"]?.array?.compactMap(\.int), widths.count == 3 else { throw PDFError.damaged("bad /W") }
        let size = dict["Size"]?.int ?? 0
        let index = dict["Index"]?.array?.compactMap(\.int) ?? [0, size]
        let rowLength = widths.reduce(0, +)
        guard rowLength > 0 else { throw PDFError.damaged("bad /W") }

        func field(_ row: Int, _ column: Int) -> Int? {
            let width = widths[column]
            guard width > 0 else { return nil }
            var start = row * rowLength
            for c in 0..<column { start += widths[c] }
            guard start + width <= data.count else { return nil }
            return data[start..<start + width].reduce(0) { $0 << 8 | Int($1) }
        }

        var result: [Int: Entry] = [:]
        var row = 0
        for pair in stride(from: 0, to: index.count - 1, by: 2) {
            for k in 0..<index[pair + 1] {
                defer { row += 1 }
                let type = field(row, 0) ?? 1
                guard let f2 = field(row, 1) else { continue }
                let number = index[pair] + k
                switch type {
                case 1: result[number] = .offset(f2)
                case 2: result[number] = .compressed(stream: f2, index: field(row, 2) ?? 0)
                default: break
                }
            }
        }
        return (result, dict, true)
    }

    /// Parses "n g obj value [stream … endstream]" at a byte offset.
    private static func parseIndirect(_ bytes: [UInt8], at offset: Int, length: ((PDFValue) -> Int?)?) throws -> PDFObject {
        var lexer = PDFLexer(bytes, at: offset)
        guard Int(lexer.keyword()) != nil, Int(lexer.keyword()) != nil, lexer.keyword() == "obj" else {
            throw PDFError.damaged("no object at \(offset)")
        }
        let value = try lexer.value()
        lexer.skipWhitespace()
        guard lexer.peek("stream"), let dict = value.dict else { return PDFObject(value: value, stream: nil) }
        lexer.pos += 6
        if lexer.pos < bytes.count && bytes[lexer.pos] == 13 { lexer.pos += 1 }
        if lexer.pos < bytes.count && bytes[lexer.pos] == 10 { lexer.pos += 1 }
        let start = lexer.pos

        var count: Int?
        if let lengthValue = dict["Length"] {
            count = lengthValue.int ?? length?(lengthValue)
        }
        if let n = count, n >= 0, start + n <= bytes.count {
            return PDFObject(value: value, stream: Array(bytes[start..<start + n]))
        }
        // Wrong or unresolvable /Length: fall back to the endstream keyword.
        let end = Array("endstream".utf8)
        var i = start
        while i + end.count <= bytes.count {
            if bytes[i] == end[0] && Array(bytes[i..<i + end.count]) == end { break }
            i += 1
        }
        var stop = i
        if stop > start && bytes[stop - 1] == 10 { stop -= 1 }
        if stop > start && bytes[stop - 1] == 13 { stop -= 1 }
        return PDFObject(value: value, stream: Array(bytes[start..<stop]))
    }

    mutating func object(_ number: Int) throws -> PDFObject {
        switch entries[number] {
        case .offset(let offset)?:
            guard offset < bytes.count else { throw PDFError.damaged("object \(number) out of range") }
            let file = self
            return try Self.parseIndirect(bytes, at: offset) { value in
                guard let (n, _) = value.reference, n != number, case .offset(let o)? = file.entries[n],
                      let object = try? Self.parseIndirect(file.bytes, at: o, length: nil) else { return nil }
                return object.value.int
            }
        case .compressed(let stream, let index)?:
            if objectStreams[stream] == nil { objectStreams[stream] = try loadObjectStream(stream) }
            guard let value = objectStreams[stream]?[index] else { throw PDFError.damaged("object \(number) missing in stream") }
            return PDFObject(value: value, stream: nil)
        case nil:
            throw PDFError.damaged("object \(number) not found")
        }
    }

    /// Follows a reference; direct values come back unchanged.
    mutating func resolve(_ value: PDFValue?) throws -> PDFValue? {
        guard let value else { return nil }
        if let (n, _) = value.reference { return try object(n).value }
        return value
    }

    private mutating func loadObjectStream(_ number: Int) throws -> [Int: PDFValue] {
        guard case .offset(let offset)? = entries[number] else { throw PDFError.damaged("object stream \(number) not found") }
        let object = try Self.parseIndirect(bytes, at: offset, length: nil)
        guard let dict = object.value.dict, let raw = object.stream,
              let count = dict["N"]?.int, let first = dict["First"]?.int else { throw PDFError.damaged("bad object stream") }
        let data = try Self.decode(raw, dict: dict)
        var lexer = PDFLexer(data)
        var offsets: [Int] = []
        for _ in 0..<count {
            guard Int(lexer.keyword()) != nil, let o = Int(lexer.keyword()) else { throw PDFError.damaged("bad object stream header") }
            offsets.append(o)
        }
        var result: [Int: PDFValue] = [:]
        for (index, o) in offsets.enumerated() {
            var objectLexer = PDFLexer(data, at: first + o)
            result[index] = try objectLexer.value()
        }
        return result
    }

    /// Undoes the stream filters this reader needs: FlateDecode with or
    /// without PNG predictors. Cross-reference and object streams use
    /// nothing else in practice.
    static func decode(_ raw: [UInt8], dict: PDFDict) throws -> [UInt8] {
        let filters: [String]
        switch dict["Filter"] {
        case .name(let n)?: filters = [n]
        case .array(let a)?: filters = a.compactMap(\.nameValue)
        default: filters = []
        }
        guard filters.allSatisfy({ $0 == "FlateDecode" }), filters.count <= 1 else {
            throw PDFError.unsupported("stream filter \(filters.joined(separator: ", "))")
        }
        guard !filters.isEmpty else { return raw }

        var data = try inflate(raw)
        let params: PDFDict? = {
            switch dict["DecodeParms"] {
            case .dict(let d)?: return d
            case .array(let a)?: return a.first?.dict
            default: return nil
            }
        }()
        if let params, let predictor = params["Predictor"]?.int, predictor > 1 {
            guard predictor >= 10 else { throw PDFError.unsupported("TIFF predictor") }
            let columns = params["Columns"]?.int ?? 1
            let colors = params["Colors"]?.int ?? 1
            let bits = params["BitsPerComponent"]?.int ?? 8
            data = try unpredictPNG(data, columns: columns, bytesPerPixel: max(1, colors * bits / 8),
                                    rowLength: (columns * colors * bits + 7) / 8)
        }
        return data
    }

    static func inflate(_ raw: [UInt8]) throws -> [UInt8] {
        // FlateDecode is zlib: a two-byte header, raw deflate, a checksum.
        // Apple's .zlib decompressor wants the raw deflate part only.
        guard raw.count > 2 else { throw PDFError.damaged("empty flate stream") }
        let body = (raw[0] & 0x0F) == 8 ? Data(raw.dropFirst(2)) : Data(raw)
        guard let out = try? (body as NSData).decompressed(using: .zlib) else { throw PDFError.damaged("flate data") }
        return [UInt8](out as Data)
    }

    private static func unpredictPNG(_ data: [UInt8], columns: Int, bytesPerPixel bpp: Int, rowLength: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        var previous = [UInt8](repeating: 0, count: rowLength)
        var i = 0
        while i + rowLength < data.count + 1 && i < data.count {
            let filter = data[i]
            guard i + 1 + rowLength <= data.count else { break }
            var row = Array(data[i + 1..<i + 1 + rowLength])
            for x in 0..<rowLength {
                let left = x >= bpp ? Int(row[x - bpp]) : 0
                let up = Int(previous[x])
                let upLeft = x >= bpp ? Int(previous[x - bpp]) : 0
                let add: Int
                switch filter {
                case 0: add = 0
                case 1: add = left
                case 2: add = up
                case 3: add = (left + up) / 2
                case 4:
                    let p = left + up - upLeft
                    let pa = abs(p - left), pb = abs(p - up), pc = abs(p - upLeft)
                    add = pa <= pb && pa <= pc ? left : (pb <= pc ? up : upLeft)
                default: throw PDFError.damaged("PNG filter \(filter)")
                }
                row[x] = UInt8((Int(row[x]) + add) & 0xFF)
            }
            out += row
            previous = row
            i += 1 + rowLength
        }
        return out
    }
}
