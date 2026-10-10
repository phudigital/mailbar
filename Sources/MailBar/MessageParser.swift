import Foundation

struct ParsedMessage {
    var subject = ""
    var from = ""
    var fromAddress: String?
    var to = ""
    var cc = ""
    var date: Date?
    var messageID: String?
    var html: String?
    var text: String?
    var attachments: [String] = []

    /// HTML để hiển thị: ưu tiên phần HTML, nếu không có thì bọc phần chữ thuần.
    var displayHTML: String {
        if let html { return html }
        let escaped = (text ?? "(Không có nội dung)")
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return """
        <html><head><meta charset="utf-8"><meta name="color-scheme" content="light dark">
        <style>body{font:13px -apple-system,sans-serif;white-space:pre-wrap;word-wrap:break-word;margin:14px}</style>
        </head><body>\(escaped)</body></html>
        """
    }

    /// Bản văn bản để hiển thị nhẹ (không cần WebKit): phần text/plain, hoặc HTML đã bỏ thẻ.
    var plainText: String? {
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return text }
        return html.map(HTMLText.strip)
    }

    var hasRemoteContent: Bool {
        html?.range(of: #"(src|background)\s*=\s*["']?https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
            || html?.range(of: #"url\(\s*["']?https?:"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

/// Phân tích thư RFC 822 / MIME ở mức cơ bản.
/// Thư được giữ dưới dạng chuỗi ISO-8859-1 (ánh xạ 1:1 với byte) để tách cấu trúc mà không làm hỏng dữ liệu.
enum MessageParser {
    static func parse(_ data: Data) -> ParsedMessage {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: data.map { Unicode.Scalar($0) })
        let raw = String(scalars)
        var result = ParsedMessage()
        let (headerBlock, body) = splitHeader(raw)
        let headers = MIMEDecoder.parseHeaders(bytes(headerBlock))

        let subject = MIMEDecoder.decodeHeader(headers["subject"] ?? "").trimmingCharacters(in: .whitespaces)
        result.subject = subject.isEmpty ? "(Không có tiêu đề)" : subject
        result.from = MIMEDecoder.displayName(fromHeader: headers["from"] ?? "")
        result.fromAddress = MIMEDecoder.address(fromHeader: headers["from"] ?? "")
        result.to = MIMEDecoder.decodeHeader(headers["to"] ?? "")
        result.cc = MIMEDecoder.decodeHeader(headers["cc"] ?? "")
        result.date = MIMEDecoder.parseDate(headers["date"] ?? "")
        result.messageID = headers["message-id"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")) }

        walk(headers: headers, body: body, into: &result, depth: 0)
        return result
    }

    private static func walk(headers: [String: String], body: String, into result: inout ParsedMessage, depth: Int) {
        guard depth < 10 else { return }
        let contentType = HeaderValue(headers["content-type"] ?? "text/plain")
        let disposition = HeaderValue(headers["content-disposition"] ?? "")

        if contentType.value.hasPrefix("multipart/"), let boundary = contentType.params["boundary"] {
            for part in splitMultipart(body, boundary: boundary) {
                let (h, b) = splitHeader(part)
                walk(headers: MIMEDecoder.parseHeaders(bytes(h)), body: b, into: &result, depth: depth + 1)
            }
            return
        }

        let filename = disposition.params["filename"] ?? contentType.params["name"]
        let isText = contentType.value == "text/plain" || contentType.value == "text/html"
        if disposition.value == "attachment" || contentType.value == "message/rfc822" || (!isText && filename != nil) {
            if disposition.value != "inline" || !contentType.value.hasPrefix("image/") {
                result.attachments.append(MIMEDecoder.decodeHeader(filename ?? "Tệp đính kèm"))
            }
            return
        }
        guard isText else { return }

        let data = decodeTransfer(body, encoding: headers["content-transfer-encoding"] ?? "")
        let charset = contentType.params["charset"] ?? "utf-8"
        let string = MIMEDecoder.string(from: data, charset: charset)
        if contentType.value == "text/html" {
            if result.html == nil { result.html = string }
        } else if result.text == nil {
            result.text = string
        }
    }

    // MARK: - Cấu trúc

    private static func splitHeader(_ s: String) -> (String, String) {
        if s.hasPrefix("\r\n") { return ("", String(s.dropFirst(2))) }
        if s.hasPrefix("\n") { return ("", String(s.dropFirst())) }
        if let r = s.range(of: "\r\n\r\n") { return (String(s[..<r.lowerBound]), String(s[r.upperBound...])) }
        if let r = s.range(of: "\n\n") { return (String(s[..<r.lowerBound]), String(s[r.upperBound...])) }
        return (s, "")
    }

    private static func splitMultipart(_ body: String, boundary: String) -> [String] {
        let delimiter = "--" + boundary
        var parts: [String] = []
        var current: [Substring]?

        // Dùng unicodeScalars: "\r\n" là một Character nên không tách được bằng "\n".
        let lines = body.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { Substring($0) }
        for line in lines {
            let trimmed = line.hasSuffix("\r") ? line.dropLast() : line
            if trimmed.hasPrefix(delimiter) {
                let tail = trimmed.dropFirst(delimiter.count)
                if tail.hasPrefix("--") {
                    if let current { parts.append(current.joined(separator: "\n")) }
                    current = nil
                    break
                }
                if tail.allSatisfy(\.isWhitespace) {
                    if let current { parts.append(current.joined(separator: "\n")) }
                    current = []
                    continue
                }
            }
            current?.append(line)
        }
        // Thư bị cắt bớt (tải một phần) — giữ phần cuối chưa có boundary đóng.
        if let current, !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }

    // MARK: - Giải mã

    private static func bytes(_ latin1: String) -> Data {
        Data(latin1.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }

    private static func decodeTransfer(_ body: String, encoding: String) -> Data {
        switch encoding.trimmingCharacters(in: .whitespaces).lowercased() {
        case "base64":
            var clean = String(body.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) })
            clean = String(clean.prefix(clean.count - clean.count % 4))
            return Data(base64Encoded: clean, options: .ignoreUnknownCharacters) ?? Data()
        case "quoted-printable":
            return decodeQuotedPrintable(bytes(body))
        default:
            return bytes(body)
        }
    }

    private static func decodeQuotedPrintable(_ data: Data) -> Data {
        let input = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        var i = 0
        while i < input.count {
            let c = input[i]
            guard c == UInt8(ascii: "=") else { out.append(c); i += 1; continue }
            if i + 1 < input.count, input[i + 1] == 10 { i += 2; continue }                       // =\n
            if i + 2 < input.count, input[i + 1] == 13, input[i + 2] == 10 { i += 3; continue }   // =\r\n
            if i + 2 < input.count, let v = UInt8(String(decoding: input[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) {
                out.append(v)
                i += 3
            } else {
                out.append(c)
                i += 1
            }
        }
        return Data(out)
    }
}

/// Chuyển HTML thành văn bản thuần ở mức cơ bản (đủ để đọc, không cần WebKit).
enum HTMLText {
    private static func re(_ p: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }
    private static let dropBlocks = re(#"<(script|style|head|title)\b[^>]*>.*?</\1\s*>|<!--.*?-->"#)
    private static let lineBreaks = re(#"<br\s*/?>|</(p|div|tr|li|h[1-6]|blockquote|table|section|article|header|footer|pre)\s*>"#)
    private static let bullets = re(#"<li\b[^>]*>"#)
    private static let anyTag = re(#"<[^>]+>"#)
    private static let entity = re(#"&(#x[0-9a-f]+|#[0-9]+|[a-z]+);"#)
    private static let named: [String: String] = [
        "nbsp": "\u{A0}", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "#39": "'",
        "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "ndash": "–", "mdash": "—",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "bull": "•", "middot": "·",
    ]

    static func strip(_ html: String) -> String {
        var s = html
        func sub(_ r: NSRegularExpression, _ t: String) { s = r.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: t) }
        sub(dropBlocks, "")
        sub(lineBreaks, "\n")
        sub(bullets, "\n• ")
        sub(anyTag, "")
        let out = decodeEntities(s)

        // Gọn khoảng trắng: mỗi dòng trim, không quá một dòng trống liên tiếp.
        let lines = out.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: #"[ \t\u{A0}]+"#, with: " ", options: .regularExpression)
                     .trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && result.last?.isEmpty == true) { result.append(line) }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Giải mã entity HTML (`&amp;`, `&#39;`, `&#x1F600;`…).
    static func decodeEntities(_ s: String) -> String {
        let ns = s as NSString
        var out = ""
        var cursor = 0
        for m in entity.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            let code = ns.substring(with: m.range(at: 1)).lowercased()
            if code.hasPrefix("#x"), let v = UInt32(code.dropFirst(2), radix: 16), let u = Unicode.Scalar(v) {
                out.unicodeScalars.append(u)
            } else if code.hasPrefix("#"), let v = UInt32(code.dropFirst()), let u = Unicode.Scalar(v) {
                out.unicodeScalars.append(u)
            } else if let r = named[code] {
                out += r
            } else {
                out += ns.substring(with: m.range)
            }
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }
}

/// `text/html; charset="utf-8"` → value = "text/html", params = ["charset": "utf-8"].
struct HeaderValue {
    let value: String
    let params: [String: String]

    init(_ raw: String) {
        var pieces: [String] = []
        var current = ""
        var inQuotes = false
        for ch in raw {
            if ch == "\"" { inQuotes.toggle() }
            if ch == ";" && !inQuotes {
                pieces.append(current)
                current = ""
            } else {
                current.append(ch)
            }
        }
        pieces.append(current)

        value = pieces.first?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        var params: [String: String] = [:]
        for piece in pieces.dropFirst() {
            guard let eq = piece.firstIndex(of: "=") else { continue }
            var key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\"") && val.hasSuffix("\"") && val.count >= 2 { val = String(val.dropFirst().dropLast()) }
            // RFC 2231: filename*=utf-8''%E1%BA%A1.pdf
            if key.hasSuffix("*") {
                key.removeLast()
                let segments = val.components(separatedBy: "'")
                if segments.count >= 3 {
                    let charset = segments[0].isEmpty ? "utf-8" : segments[0]
                    let encoded = segments[2...].joined(separator: "'")
                    var bytes: [UInt8] = []
                    var idx = encoded.startIndex
                    while idx < encoded.endIndex {
                        if encoded[idx] == "%", let end = encoded.index(idx, offsetBy: 3, limitedBy: encoded.endIndex),
                           let b = UInt8(encoded[encoded.index(after: idx)..<end], radix: 16) {
                            bytes.append(b)
                            idx = end
                        } else {
                            bytes.append(contentsOf: Array(String(encoded[idx]).utf8))
                            idx = encoded.index(after: idx)
                        }
                    }
                    val = MIMEDecoder.string(from: Data(bytes), charset: charset)
                }
            }
            if params[key] == nil { params[key] = val }
        }
        self.params = params
    }
}
