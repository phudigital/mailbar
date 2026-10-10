import Foundation

enum MIMEDecoder {
    /// Tách header thô thành dictionary (khoá viết thường), đã gộp các dòng gập (folded).
    static func parseHeaders(_ data: Data) -> [String: String] {
        let raw = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? ""
        var headers: [String: String] = [:]
        var currentKey: String?

        for line in raw.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if let first = line.first, first == " " || first == "\t" {
                if let key = currentKey {
                    headers[key, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            currentKey = key
            if headers[key] == nil { headers[key] = value }
        }
        return headers
    }

    private static let encodedWord = try! NSRegularExpression(pattern: #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#)

    /// Giải mã encoded-word RFC 2047 (`=?UTF-8?B?...?=`). Các word liền kề cùng charset được ghép byte
    /// trước khi giải mã để không vỡ ký tự nhiều byte (tiếng Việt, CJK...).
    static func decodeHeader(_ value: String) -> String {
        let ns = value as NSString
        var out = ""
        var pendingBytes = Data()
        var pendingCharset: String?
        var cursor = 0

        func flush() {
            guard let charset = pendingCharset else { return }
            out += string(from: pendingBytes, charset: charset)
            pendingBytes = Data()
            pendingCharset = nil
        }

        for match in encodedWord.matches(in: value, range: NSRange(location: 0, length: ns.length)) {
            let gap = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let charset = ns.substring(with: match.range(at: 1))
            let encoding = ns.substring(with: match.range(at: 2)).uppercased()
            let text = ns.substring(with: match.range(at: 3))

            let gapIsWhitespace = gap.allSatisfy(\.isWhitespace)
            if pendingCharset == nil || !gapIsWhitespace {
                flush()
                out += gap
            } else if pendingCharset!.caseInsensitiveCompare(charset) != .orderedSame {
                flush()
            }

            pendingCharset = charset
            pendingBytes.append(encoding == "B" ? decodeBase64(text) : decodeQ(text))
            cursor = match.range.location + match.range.length
        }
        flush()
        out += ns.substring(from: cursor)
        return out.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    /// `"Nguyễn Văn A" <a@b.com>` → `Nguyễn Văn A`; `a@b.com` → `a@b.com`.
    static func displayName(fromHeader raw: String) -> String {
        let decoded = decodeHeader(raw).trimmingCharacters(in: .whitespaces)
        if let lt = decoded.firstIndex(of: "<") {
            let name = decoded[..<lt].trimmingCharacters(in: CharacterSet(charactersIn: "\" \t'"))
            if !name.isEmpty { return name }
            let addr = decoded[decoded.index(after: lt)...].trimmingCharacters(in: CharacterSet(charactersIn: "> "))
            return addr
        }
        return decoded.isEmpty ? "(Không rõ người gửi)" : decoded
    }

    /// `"A" <a@b.com>` → `a@b.com`.
    static func address(fromHeader raw: String) -> String? {
        let decoded = decodeHeader(raw)
        if let lt = decoded.firstIndex(of: "<"), let gt = decoded[lt...].firstIndex(of: ">") {
            return String(decoded[decoded.index(after: lt)..<gt])
        }
        let trimmed = decoded.trimmingCharacters(in: .whitespaces)
        return trimmed.contains("@") ? trimmed : nil
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let dateFormats = [
        "EEE, d MMM yyyy HH:mm:ss Z",
        "d MMM yyyy HH:mm:ss Z",
        "EEE, d MMM yyyy HH:mm:ss zzz",
        "d MMM yyyy HH:mm:ss zzz",
        "EEE, d MMM yyyy HH:mm Z",
        "EEE, d MMM yy HH:mm:ss Z",
    ]

    static func parseDate(_ raw: String) -> Date? {
        let cleaned = raw
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        for format in dateFormats {
            dateFormatter.dateFormat = format
            if let date = dateFormatter.date(from: cleaned) { return date }
        }
        return nil
    }

    // MARK: - Helpers

    private static func decodeBase64(_ text: String) -> Data {
        var s = text
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s, options: .ignoreUnknownCharacters) ?? Data(text.utf8)
    }

    private static func decodeQ(_ text: String) -> Data {
        let chars = Array(text.utf8)
        var bytes: [UInt8] = []
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == UInt8(ascii: "_") {
                bytes.append(0x20)
                i += 1
            } else if c == UInt8(ascii: "="), i + 2 < chars.count,
                      let v = UInt8(String(decoding: chars[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                bytes.append(v)
                i += 3
            } else {
                bytes.append(c)
                i += 1
            }
        }
        return Data(bytes)
    }

    static func string(from data: Data, charset: String) -> String {
        let name = charset.split(separator: "*").first.map(String.init) ?? charset
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
            if let s = String(data: data, encoding: encoding) { return s }
        }
        return String(decoding: data, as: UTF8.self)
    }
}
