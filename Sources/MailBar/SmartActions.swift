import Foundation

// MARK: - Kết quả nhận diện

/// Mã xác minh (OTP) tìm thấy trong thư.
struct VerificationCode: Identifiable, Equatable {
    /// Giá trị để dán vào ô nhập: đã bỏ dấu cách / gạch ngang ngăn nhóm ("482 910" → "482910").
    let value: String
    /// Dạng hiển thị cho dễ đọc ("482 910").
    let display: String
    var id: String { value }
}

/// Link dùng một lần trong thư: xác minh email, đăng nhập bằng link, đặt lại mật khẩu.
struct VerificationLink: Identifiable, Equatable {
    enum Kind: CaseIterable {
        // Thứ tự khai báo cũng là thứ tự ưu tiên khi một link khớp nhiều loại với điểm bằng nhau.
        case reset, verify, signIn

        var title: String {
            switch self {
            case .verify: return "Link xác minh"
            case .signIn: return "Link đăng nhập"
            case .reset: return "Link đặt lại mật khẩu"
            }
        }
    }

    let kind: Kind
    let url: URL
    var id: String { url.absoluteString }
    /// Tên miền đích — hiện cạnh nút để người dùng thấy link dẫn đi đâu trước khi bấm.
    var host: String { url.host ?? url.absoluteString }
}

struct SmartContent: Equatable {
    var codes: [VerificationCode] = []
    var links: [VerificationLink] = []
    var isEmpty: Bool { codes.isEmpty && links.isEmpty }
}

// MARK: - Bộ nhận diện

/// Tìm mã xác minh (OTP) và link xác minh trong thư để trình đọc hiện nút sao chép / mở.
///
/// - Chỉ đọc nội dung thư đã tải về. **Không bao giờ tải hoặc mở link giúp người dùng**: link xác minh thường chỉ
///   dùng được một lần, tự tải sẽ làm nó hết hiệu lực.
/// - Chỉ phụ thuộc Foundation để kiểm thử được bằng harness (xem AGENTS.md mục 7).
/// - Ưu tiên độ chính xác hơn độ phủ: thà bỏ sót còn hơn gắn nhãn "mã xác minh" cho số đơn hàng, số điện thoại…
enum SmartActions {
    /// Mã xác minh luôn nằm gần đầu thư; thư quá lớn thì không cần quét hết (regex chạy tuyến tính theo độ dài).
    private static let maxScanLength = 60_000
    /// Số link tối đa được chấm điểm. Thư xác minh chỉ có vài link; bản tin hàng trăm link thì không cần.
    private static let maxLinks = 300

    static func detect(in message: ParsedMessage) -> SmartContent {
        detect(subject: message.subject, text: message.text, html: message.html)
    }

    static func detect(subject: String, text: String?, html: String?) -> SmartContent {
        let plain = text.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        var stripped: String?
        func strippedHTML() -> String? {
            if stripped == nil, let html { stripped = HTMLText.strip(html) }
            return stripped
        }

        var codes = findCodes(subject: subject, body: plain ?? strippedHTML() ?? "")
        // Phần text/plain đôi khi chỉ là dòng "hãy xem bản HTML": không thấy mã thì thử cả bản HTML đã bỏ thẻ.
        if codes.isEmpty, plain != nil, let body = strippedHTML() {
            codes = findCodes(subject: subject, body: body)
        }
        return SmartContent(codes: codes, links: findLinks(subject: subject, text: plain, html: html))
    }

    // MARK: - Chuẩn hoá văn bản

    private static func re(_ pattern: String, _ options: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// NFC (tiếng Việt dựng sẵn), bỏ ký tự vô hình, đổi các loại dấu cách lạ thành dấu cách thường, thống nhất xuống dòng.
    private static func normalize(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        let unified = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        for u in unified.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch u.value {
            case 0x200B...0x200D, 0x2060, 0xFEFF, 0x00AD: continue                  // zero-width, soft hyphen
            case 0x00A0, 0x2007, 0x2009, 0x202F: out.append(" ")                    // nbsp và các dấu cách hẹp
            default: out.append(u)
            }
        }
        return String(out)
    }

    /// Bỏ dấu tiếng Việt / Latin ("Mã xác minh" → "Ma xac minh", đ → d) để viết từ khoá một lần cho cả hai kiểu gõ.
    /// Mỗi ký tự có dấu (BMP) đổi thành đúng một ký tự ASCII nên độ dài UTF-16 không đổi: vị trí khớp trên bản
    /// đã bỏ dấu dùng được thẳng cho bản gốc. Chữ hoa/thường được giữ nguyên (mã như "K4P2V" phân biệt hoa thường).
    private static func fold(_ s: String) -> String {
        var cache: [UInt32: Unicode.Scalar] = [:]
        var out = String.UnicodeScalarView()
        for u in s.unicodeScalars {
            if u.isASCII { out.append(u); continue }
            if let hit = cache[u.value] { out.append(hit); continue }
            var folded = u
            if u.value == 0x0110 { folded = "D" }
            else if u.value == 0x0111 { folded = "d" }
            else if u.value <= 0xFFFF,
                    let base = String(u).decomposedStringWithCanonicalMapping.unicodeScalars.first, base.isASCII {
                folded = base
            }
            cache[u.value] = folded
            out.append(folded)
        }
        return String(out)
    }

    /// Dạng để so khớp từ khoá: bỏ dấu + chữ thường.
    private static func key(_ s: String) -> String { fold(normalize(s)).lowercased() }

    // MARK: - Mã xác minh

    private struct Candidate {
        let code: VerificationCode
        var score: Int
        let position: Int
    }

    private enum GapLevel {
        case tiny, normal, block

        func score(_ s: (tiny: Int, normal: Int, block: Int)) -> Int {
            switch self {
            case .tiny: return s.tiny
            case .normal: return s.normal
            case .block: return s.block
            }
        }
    }

    // Số chỉ dùng [0-9] (ASCII): `\d` của ICU khớp cả chữ số Ả Rập, fullwidth…
    // Dạng nhận: 4–8 chữ số liền; nhóm 3-3 / 4-4 ("482 910", "482-910"); từng số cách nhau ("4 8 2 9 1 0", thư HTML
    // đặt mỗi số một ô bảng nên sau khi bỏ thẻ có thể mỗi số một dòng); "G-482910", "FB-12345".
    private static let tokenBody = #"(?:[A-Z]{1,2}-[0-9]{4,8}|[0-9]{3}[ -][0-9]{3}|[0-9]{4}[ -][0-9]{4}|[0-9]{4,8}|[0-9](?:[ \n][0-9]){3,7})"#
    // Không nhận số dính với số/chữ khác hoặc nằm trong số điện thoại, ngày, giá, URL, số thứ tự…
    private static let tokenBefore = #"(?<![0-9A-Za-z_.,#$€£/@+=-])(?<![0-9][ \n-])"#
    private static let tokenAfter =
        #"(?![0-9A-Za-z]|[ \n-][0-9]|[.,:/-][0-9]|\s?[%₫$€£]|\s(?:vnd|usd|minutes?|mins?|seconds?|secs?|hours?|days?|phut|giay|gio|ngay)\b)"#
    private static let token = tokenBefore + tokenBody + tokenAfter

    private static let tokenRegex = re(token)
    // Mã chữ + số ("u3p8kz2x", "K4P2V", "5ZP-K43"): phải có cả chữ lẫn số, chỉ nhận khi đứng ngay sau từ khoá mạnh.
    private static let alnumRegex = re(
        #"(?<![A-Za-z0-9])(?=[A-Za-z0-9]{0,9}[0-9])(?=[A-Za-z0-9]{0,9}[A-Za-z])[A-Za-z0-9]{5,10}(?![A-Za-z0-9])"#
        + #"|(?-i:(?<![A-Za-z0-9-])(?=[A-Z0-9-]{0,8}[0-9])(?=[A-Z0-9-]{0,8}[A-Z])[A-Z0-9]{3,4}-[A-Z0-9]{3,4}(?![A-Za-z0-9-]))"#)

    /// Từ khoá chỉ đích danh mã xác minh (đã bỏ dấu nên viết không dấu; có thêm Trung, Nga).
    private static let strongKeyword = re(
        #"(?<![A-Za-z0-9])(?:"#
        + #"(?:verification|verify|verifying|security|authentication|authorization|authorisation|auth|login|log-in|sign-in|signin|one[- ]?time|single[- ]?use|dynamic|2fa|mfa|two[- ]?factor|two[- ]?step|2[- ]?step)[ -]+(?:code|passcode|pin)"#
        + #"|(?:one[- ]?time|single[- ]?use|dynamic)[ -]+password"#
        + #"|otp|passcode|pass[ -]code"#
        + #"|ma[ ]+(?:xac[ ]+(?:minh|thuc)|otp|dang[ ]+nhap|bao[ ]+mat|kich[ ]+hoat|truy[ ]+cap|dung[ ]+mot[ ]+lan|pin|2fa)"#
        + #"|mat[ ]+khau[ ]+(?:dung[ ]+)?mot[ ]+lan"#
        + #"|验证码|驗證碼|校验码|校驗碼|动态码|動態碼|确认码|確認碼|安全码|安全碼|验证代码|驗證代碼"#
        + #"|код[ ]+(?:подтверждения|проверки|безопасности|доступа|для[ ]+входа)|проверочный[ ]+код|одноразовый[ ]+(?:код|пароль)"#
        + #")(?![A-Za-z0-9])"#)

    /// "confirmation code", "mã xác nhận"… cũng dùng cho mã đặt chỗ / đơn hàng nên kém chắc hơn: bị bỏ qua nếu tiêu đề
    /// nói về đặt chỗ / đơn hàng, hoặc nếu giữa từ khoá và số có từ chỉ đặt chỗ ("mã xác nhận đặt phòng: 1234567").
    private static let mediumKeyword = re(
        #"(?<![A-Za-z0-9])(?:(?:confirmation|confirm|activation|registration|access|temporary)[ -]+(?:code|passcode|pin)|ma[ ]+xac[ ]+nhan)(?![A-Za-z0-9])"#)
    private static let bookingWords =
        #"booking|reservation|itinerary|flight|e-?ticket|receipt|invoice|order|dat cho|dat phong|dat hang|don hang|ve may bay|hoa don"#
    private static let bookingSubject = re(bookingWords)
    private static let bookingGap = re(bookingWords)
    /// Từ chen giữa "your … code" cho biết đó là mã khác (khuyến mãi, đơn hàng…), không phải mã xác minh.
    private static let notVerificationWord =
        "promo|coupon|discount|voucher|gift|referral|invite|invitation|order|booking|reservation|tracking|zip|postal|area|country|source|product|customer|reference"

    /// "code" đơn thuần chỉ tính khi cùng câu có động từ xác thực ("use this code to verify…").
    /// Loại "promo code", "zip code"… để không nhầm mã khuyến mãi / bưu chính.
    private static let weakKeyword = re(
        #"\b(?:verify|verification|confirm|sign[ -]?in|log[ -]?in|login|authenticate|activate|reset|continue|complete|finish)\b[^.\n]{0,60}?\bcode\b"#
        + #"(?<!promo code|zip code|postal code|area code|country code|source code|qr code|dress code|discount code|coupon code|gift code|referral code|invite code|tracking code)"#
        + #"|\bcode\b(?<!promo code|zip code|postal code|area code|country code|source code|qr code|dress code|discount code|coupon code|gift code|referral code|invite code|tracking code)"#
        + #"[^.\n]{0,60}?\b(?:verify|verification|confirm|sign[ -]?in|log[ -]?in|login|authenticate|activate|reset|continue|complete|finish)\b"#)

    /// Mã đứng TRƯỚC câu giới thiệu: "G-482910 is your Google verification code", "482910 là mã xác minh của bạn".
    private static let beforePatterns = [
        re("(" + token + #")\s+(?:is|are)\s+(?:your|the)\s+(?:(?!"# + notVerificationWord + #")[^\s.:;!?]+\s+){0,4}(?:code|otp|passcode|pin)(?![A-Za-z0-9])"#),
        re("(" + token + #")\s+(?:is|are)\s+(?:your|the)\s+(?:[^\s.:;!?]+\s+){0,3}(?:one[- ]?time|single[- ]?use)\s+password"#),
        re("(" + token + #")\s+la\s+ma\s+(?:xac\s+(?:minh|nhan|thuc)|otp|dang\s+nhap|bao\s+mat|kich\s+hoat)"#),
    ]

    /// Mã đứng ngay sau câu "your … code is": "Your Uber code is 4829", "Mã của bạn là 482910".
    private static let yourCodePatterns = [
        re(#"\b(?:your|the|this)\s+(?:(?!"# + notVerificationWord + #")[A-Za-z0-9&.'-]+\s+){0,3}(?:code|pin|passcode|otp)\s*(?:is|are|:)\s*[:\-–]?\s*("# + token + #")"#),
        re(#"\bma\s+cua\s+(?:ban|quy\s+khach)\s+la\s*[:\-–]?\s*("# + token + #")"#),
    ]

    /// Câu mệnh lệnh: "Use code 482910 to verify", "Enter 482910 to sign in", "Nhập mã 482910 để xác nhận".
    private static let imperativePatterns = [
        re(#"\b(?:use|enter|type|input|submit)\s+(?:(?:the|this|your|following|below|verification|security|login)\s+)*code\s*[:\-–]?\s*("#
           + token + #")(?=[^.\n]{0,40}\b(?:verify|verification|confirm|sign\s*in|log\s*in|login|continue|activate|complete|authenticate)\b)"#),
        re(#"\b(?:use|enter|type|input)\s+("# + token + #")\s+(?:as|to)\s+(?:your|the|verify|confirm|sign|log|complete|continue|activate)\b"#),
        re(#"\b(?:nhap|su\s+dung|dung)\s+ma\s+(?:nay\s+)?("# + token + #")\s+de\s+(?:xac|dang|kich|hoan|tiep)"#),
    ]

    private static let sentenceEnd = re(#"[.!?。！？](?:\s|$)"#)
    /// Giữa từ khoá và mã chỉ có "is" / dấu hai chấm: điều kiện để nhận mã chữ + số.
    private static let tinyGap = re(#"^[\s:：=\-–—]*(?:(?:is|are|la|是)[\s:：=]*)?$"#)
    /// Số giống năm (1900–2100) chỉ nhận khi có "is" hoặc dấu hai chấm: "Your PIN is 2026", không phải "In 2026,".
    private static let connector = re(#"(?:^|\s)(?:is|are|la)(?:\s|:|$)|[:=：是]"#)

    private static func findCodes(subject: String, body: String) -> [VerificationCode] {
        let text = normalize(subject + "\n\n" + String(body.unicodeScalars.prefix(maxScanLength)))
        let folded = fold(text)                 // cùng độ dài UTF-16 với `text`
        let original = text as NSString
        let ns = folded as NSString
        guard ns.length > 0 else { return [] }
        let full = NSRange(location: 0, length: ns.length)
        let bookingContext = matches(bookingSubject, key(subject))

        var found: [String: Candidate] = [:]
        func add(_ range: NSRange, score: Int, gap: String? = nil) {
            guard range.location != NSNotFound else { return }
            let raw = ns.substring(with: range)
            // "Phòng3" bị bỏ dấu thành "Phong3": chỉ nhận chữ khi bản gốc cũng là ASCII thuần.
            if raw.contains(where: \.isLetter), original.substring(with: range) != raw { return }
            guard let code = makeCode(raw) else { return }
            if let gap, isYearLike(code.value), !matches(connector, gap) { return }
            if let old = found[code.value], old.score >= score { return }
            found[code.value] = Candidate(code: code, score: score, position: range.location)
        }

        let tokens = tokenRegex.matches(in: folded, range: full)
        let alnums = alnumRegex.matches(in: folded, range: full)

        /// Với mỗi từ khoá, lấy mã gần nhất phía sau; điểm phụ thuộc khoảng cách và có bị ngắt câu hay không.
        func scan(_ keyword: NSRegularExpression, scores: (tiny: Int, normal: Int, block: Int), alnum: Bool, vetoGap: NSRegularExpression? = nil) {
            for kw in keyword.matches(in: folded, range: full).prefix(80) {
                let end = kw.range.location + kw.range.length
                if let i = firstIndex(in: tokens, from: end) {
                    let t = tokens[i].range
                    let gapLength = t.location - end
                    if gapLength <= 140 {
                        let gap = ns.substring(with: NSRange(location: end, length: gapLength))
                        if let vetoGap, matches(vetoGap, gap) { continue }
                        if let level = gapLevel(gap, standalone: isStandalone(ns, t)) {
                            add(t, score: level.score(scores), gap: gap)
                        }
                    }
                }
                if alnum, let i = firstIndex(in: alnums, from: end) {
                    let a = alnums[i].range
                    let gapLength = a.location - end
                    if gapLength <= 14, matches(tinyGap, ns.substring(with: NSRange(location: end, length: gapLength))) {
                        add(a, score: 4)
                    }
                }
            }
        }
        scan(strongKeyword, scores: (5, 4, 3), alnum: true)
        if !bookingContext { scan(mediumKeyword, scores: (4, 3, 2), alnum: false, vetoGap: bookingGap) }
        scan(weakKeyword, scores: (3, 2, 2), alnum: false)

        // "Your … code is 482910" cũng là kiểu câu của mã đặt chỗ, nên bỏ qua khi tiêu đề nói về đặt chỗ / đơn hàng.
        let sentencePatterns: [(patterns: [NSRegularExpression], score: Int)] = [
            (beforePatterns, 5),
            (bookingContext ? [] : yourCodePatterns, 4),
            (imperativePatterns, 4),
        ]
        for (patterns, score) in sentencePatterns {
            for regex in patterns {
                for m in regex.matches(in: folded, range: full) { add(m.range(at: 1), score: score) }
            }
        }

        // Giữ mã điểm cao nhất, và mã khác chỉ khi chênh không quá 1 điểm (thư có hai mã thật là hiếm).
        let ranked = found.values.sorted { ($0.score, -$0.position) > ($1.score, -$1.position) }
        guard let top = ranked.first else { return [] }
        return ranked.filter { $0.score >= top.score - 1 }.prefix(3).map(\.code)
    }

    private static func makeCode(_ raw: String) -> VerificationCode? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        // "G-482910", "FB-12345": bỏ tiền tố chữ, chỉ giữ phần số.
        if let dash = t.firstIndex(of: "-"), (1...2).contains(t[..<dash].count), t[..<dash].allSatisfy(\.isLetter),
           t[t.index(after: dash)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
            let digits = String(t[t.index(after: dash)...])
            return VerificationCode(value: digits, display: digits)
        }
        // Chỉ gồm số, có thể chia nhóm.
        if t.allSatisfy({ ($0.isASCII && $0.isNumber) || $0.isWhitespace || $0 == "-" }) {
            let digits = t.filter { $0.isASCII && $0.isNumber }
            guard (4...8).contains(digits.count) else { return nil }
            let groups = t.split(whereSeparator: { $0.isWhitespace || $0 == "-" })
            return VerificationCode(value: digits, display: groups.count == 2 ? groups.joined(separator: " ") : digits)
        }
        return VerificationCode(value: t, display: t)          // mã chữ + số: giữ nguyên
    }

    private static func isYearLike(_ digits: String) -> Bool {
        digits.count == 4 && (1900...2100).contains(Int(digits) ?? 0)
    }

    private static func gapLevel(_ gap: String, standalone: Bool) -> GapLevel? {
        let length = (gap as NSString).length
        let ended = matches(sentenceEnd, gap)
        if !ended && length <= 14 { return .tiny }
        if !ended && length <= 70 { return .normal }
        // Mã to đứng riêng một dòng (thư HTML): cho phép cách từ khoá vài dòng và có ngắt câu.
        if standalone && length <= 140 && gap.unicodeScalars.filter({ $0 == "\n" }).count <= 6 { return .block }
        return nil
    }

    /// Token đứng riêng một dòng (chỉ kèm vài ký tự trang trí).
    private static func isStandalone(_ ns: NSString, _ range: NSRange) -> Bool {
        func isBreak(_ c: unichar) -> Bool { c == 10 || c == 13 }
        let tokenEnd = range.location + range.length
        var start = range.location
        while start > 0, !isBreak(ns.character(at: start - 1)) { start -= 1 }
        var end = tokenEnd
        while end < ns.length, !isBreak(ns.character(at: end)) { end += 1 }
        let decoration = CharacterSet(charactersIn: " \t[](){}<>*#\"'`:-–—.,;!•·")
        let before = ns.substring(with: NSRange(location: start, length: range.location - start))
        let after = ns.substring(with: NSRange(location: tokenEnd, length: end - tokenEnd))
        return before.unicodeScalars.allSatisfy(decoration.contains) && after.unicodeScalars.allSatisfy(decoration.contains)
    }

    /// Chỉ số của phần tử đầu tiên có vị trí ≥ `location` (danh sách đã sắp xếp theo vị trí).
    private static func firstIndex(in matches: [NSTextCheckingResult], from location: Int) -> Int? {
        var lo = 0, hi = matches.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if matches[mid].range.location < location { lo = mid + 1 } else { hi = mid }
        }
        return lo < matches.count ? lo : nil
    }

    // MARK: - Link xác minh

    private struct RawLink {
        let href: String
        /// Chữ trên nút (HTML) hoặc câu đứng trước URL (text thuần).
        let label: String
        let isAnchor: Bool
    }

    private struct Rule {
        let kind: VerificationLink.Kind
        let label: NSRegularExpression
        let path: NSRegularExpression
        /// Nhãn/đường dẫn khớp mẫu này thì không tính ("xem xác nhận đơn hàng" không phải link xác minh).
        let veto: NSRegularExpression?
        let minScore: Int
    }

    // Điểm: nhãn khớp +3, đường dẫn khớp +2, có tham số token +1, tiêu đề thư cùng chủ đề +1.
    // Link chỉ nhận khi đủ `minScore`; "đăng nhập" đòi cao hơn vì nút "Đăng nhập" xuất hiện ở rất nhiều thư thường.
    private static let rules: [Rule] = [
        Rule(kind: .reset,
             label: re(#"\b(?:reset|change|set|create|choose|recover|forgot|update)\b[^.\n]{0,20}\bpassword|password[ -]?reset|dat lai mat khau|doi mat khau|tao mat khau|khoi phuc mat khau|сбросить|восстановить|重置密码|重設密碼|找回密码|修改密码"#),
             path: re(#"reset[-_/]?pass|pass(?:word)?[-_/]?reset|forgot|recover"#),
             veto: nil, minScore: 3),
        Rule(kind: .verify,
             label: re(#"verif|confirm|activat|validat|xac minh|xac nhan|xac thuc|kich hoat|подтвер|активир|验证|驗證|确认|確認|激活|啟用|啟動"#),
             path: re(#"verif|confirm|activat|validat"#),
             veto: re(#"order|booking|reservation|invoice|receipt|payment|shipment|delivery|appointment|purchase|don hang|hoa don|thanh toan|giao hang|dat hang"#),
             minScore: 3),
        Rule(kind: .signIn,
             label: re(#"\b(?:sign(?:ing)?[ -]?in|log(?:ging)?[ -]?in|login|magic[ -]?link)\b|dang nhap|войти|登录|登入|登錄"#),
             path: re(#"magic|passwordless"#),
             veto: nil, minScore: 4),
    ]

    /// Link không bao giờ là link xác minh (cuối thư, mạng xã hội, cửa hàng ứng dụng…).
    private static let negativeLabel = re(#"unsubscribe|opt[ -]?out|preferences|privacy|\bterms\b|policy|learn more|read more|view (?:this )?(?:email |message )?in (?:your |a )?browser|web ?version|huy dang ky|chinh sach"#)
    private static let negativePath = re(#"unsubscribe|opt-?out|preference|/privacy|/terms|/policy|/help|/support|/faq|view[-_]?in[-_]?browser|web-?version|/cancel|/deny|/decline|/reject|/not-?me"#)
    /// Chỉ áp cho chữ trên nút HTML (còn ngữ cảnh của text thuần hay có câu "nếu không phải bạn…" ngay trước link).
    private static let negativeAnchor = re(#"not (?:me|you)|wasn'?t (?:me|you)|didn'?t|did not|cancel|deny|decline|reject|khong phai|tu choi|huy yeu cau"#)
    private static let blockedHosts = [
        "facebook.com", "fb.com", "fb.me", "twitter.com", "x.com", "linkedin.com", "instagram.com", "youtube.com",
        "youtu.be", "tiktok.com", "pinterest.com", "apps.apple.com", "itunes.apple.com", "play.google.com",
        "t.me", "wa.me", "zalo.me",
    ]
    private static let tokenParam = re(#"token|code|key|otp|ticket|hash|sig|nonce|secret|jwt|oob"#)

    // Phần ruột thẻ <a> không chứa thẻ <a> khác: thẻ không đóng chỉ quét tới thẻ kế tiếp, không quét lan hết thư.
    private static let anchorRegex = re(#"<a\b([^>]*)>((?:(?!<a\b).){0,3000}?)</a\s*>"#, [.caseInsensitive, .dotMatchesLineSeparators])
    private static let hrefRegex = re(#"(?<![\w-])href\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'>]+))"#)
    private static let altRegex = re(#"(?<![\w-])(?:alt|title|aria-label)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    private static let tagRegex = re(#"<[^>]*>"#)
    private static let spaceRegex = re(#"\s+"#)
    private static let urlRegex = re(#"https?://[^\s<>"'`]+"#)

    private static func findLinks(subject: String, text: String?, html: String?) -> [VerificationLink] {
        var raw: [RawLink] = []
        if let html { raw += anchors(in: html) }
        if let text { raw += textLinks(in: text) }

        let subjectKey = key(subject)
        var best: [VerificationLink.Kind: (score: Int, order: Int, url: URL)] = [:]
        var seen = Set<String>()
        for (order, link) in raw.enumerated() {
            // Logo, nút và dòng "copy link" thường trỏ cùng một URL với cùng nhãn: chỉ chấm một lần.
            guard seen.insert(link.href + "\u{0}" + link.label).inserted,
                  let url = cleanURL(link.href),
                  let (kind, score) = classify(url: url, label: link.label, isAnchor: link.isAnchor, subject: subjectKey)
            else { continue }
            if let old = best[kind], old.score >= score { continue }
            best[kind] = (score, order, url)
        }
        return best
            .sorted { ($0.value.score, -$0.value.order) > ($1.value.score, -$1.value.order) }
            .map { VerificationLink(kind: $0.key, url: $0.value.url) }
    }

    /// Chấm điểm một link, trả về loại phù hợp nhất nếu đủ điểm.
    private static func classify(url: URL, label rawLabel: String, isAnchor: Bool, subject: String) -> (VerificationLink.Kind, Int)? {
        let host = (url.host ?? "").lowercased()
        if blockedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return nil }
        let path = url.path.lowercased()
        if matches(negativePath, path) { return nil }

        // Nhãn trùng với chính URL thì không có thông tin gì thêm.
        let label = rawLabel.contains("://") || rawLabel.lowercased().hasPrefix("www.") ? "" : key(rawLabel)
        if matches(negativeLabel, label) || (isAnchor && matches(negativeAnchor, label)) { return nil }

        let params = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { $0.name.lowercased() }.filter { !$0.hasPrefix("utm_") }
        let hasToken = url.pathComponents.contains(where: isTokenLike) || params.contains { matches(tokenParam, $0) }

        var best: (VerificationLink.Kind, Int)?
        for rule in rules {
            let labelHit = !label.isEmpty && matches(rule.label, label) && !(rule.veto.map { matches($0, label) } ?? false)
            // Đường dẫn "/verify…" một mình chưa đủ (bài blog cũng có): phải đi kèm token khó đoán hoặc nhãn khớp.
            let pathHit = (labelHit || hasToken) && matches(rule.path, path) && !(rule.veto.map { matches($0, path) } ?? false)
            var score = (labelHit ? 3 : 0) + (pathHit ? 2 : 0)
            guard score > 0 else { continue }
            if hasToken { score += 1 }
            if matches(rule.label, subject) { score += 1 }
            if score >= rule.minScore, score > (best?.1 ?? 0) { best = (rule.kind, score) }
        }
        return best
    }

    /// Đoạn đường dẫn giống token (UUID, hex, base64url…): đủ dài, có số và không phải slug gồm các từ ("verify-your-business").
    private static func isTokenLike(_ segment: String) -> Bool {
        guard segment.count >= 16, segment.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              segment.filter(\.isNumber).count >= 2 else { return false }
        let parts = segment.split(whereSeparator: { $0 == "-" || $0 == "_" })
        return parts.count <= 5 && !parts.contains { $0.count >= 5 && $0.allSatisfy(\.isLetter) }
    }

    private static func anchors(in html: String) -> [RawLink] {
        let ns = html as NSString
        var result: [RawLink] = []
        anchorRegex.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m else { return }
            let attrs = ns.substring(with: m.range(at: 1))
            let inner = ns.substring(with: m.range(at: 2))
            if let href = firstGroup(hrefRegex, in: attrs) {
                var label = collapse(HTMLText.decodeEntities(replace(tagRegex, in: inner, with: " ")))
                if label.isEmpty { label = collapse(HTMLText.decodeEntities(firstGroup(altRegex, in: inner) ?? firstGroup(altRegex, in: attrs) ?? "")) }
                result.append(RawLink(href: HTMLText.decodeEntities(href), label: String(label.prefix(160)), isAnchor: true))
            }
            if result.count >= maxLinks { stop.pointee = true }
        }
        return result
    }

    /// URL trần trong thư text/plain; "nhãn" là câu đứng trước nó (cùng dòng, hoặc dòng trước nếu dòng này gần như trống).
    private static func textLinks(in text: String) -> [RawLink] {
        let body = String(text.unicodeScalars.prefix(maxScanLength))
        let ns = body as NSString
        var result: [RawLink] = []
        urlRegex.enumerateMatches(in: body, range: NSRange(location: 0, length: ns.length)) { m, _, stop in
            guard let m else { return }
            let href = trimTrailingPunctuation(ns.substring(with: m.range))
            var lineStart = m.range.location
            while lineStart > 0, !isLineBreak(ns.character(at: lineStart - 1)) { lineStart -= 1 }
            var context = ns.substring(with: NSRange(location: lineStart, length: m.range.location - lineStart))
            if context.trimmingCharacters(in: .whitespacesAndNewlines).count < 15, lineStart > 0 {
                var prevEnd = lineStart - 1
                while prevEnd > 0, isLineBreak(ns.character(at: prevEnd - 1)) { prevEnd -= 1 }       // bỏ qua dòng trống
                var prevStart = prevEnd
                while prevStart > 0, !isLineBreak(ns.character(at: prevStart - 1)) { prevStart -= 1 }
                context = ns.substring(with: NSRange(location: prevStart, length: prevEnd - prevStart)) + " " + context
            }
            result.append(RawLink(href: href, label: String(collapse(context).suffix(200)), isAnchor: false))
            if result.count >= maxLinks { stop.pointee = true }
        }
        return result
    }

    private static func isLineBreak(_ c: unichar) -> Bool { c == 10 || c == 13 }

    private static func trimTrailingPunctuation(_ s: String) -> String {
        var s = s
        while let last = s.last {
            if ".,;:!?]}>*'\"".contains(last) { s.removeLast(); continue }
            // ")" thuộc URL nếu có "(" tương ứng (vd. wikipedia), còn không thì là dấu đóng ngoặc của câu.
            if last == ")", s.filter({ $0 == "(" }).count < s.filter({ $0 == ")" }).count { s.removeLast(); continue }
            break
        }
        return s
    }

    /// Chỉ nhận http/https có tên miền, độ dài hợp lý.
    private static func cleanURL(_ raw: String) -> URL? {
        let s = raw.components(separatedBy: .whitespacesAndNewlines).joined()
        guard s.count < 4096, let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, host.contains(".")
        else { return nil }
        return url
    }

    private static func firstGroup(_ regex: NSRegularExpression, in s: String) -> String? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound {
            return ns.substring(with: m.range(at: i))
        }
        return nil
    }

    private static func replace(_ regex: NSRegularExpression, in s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }

    private static func collapse(_ s: String) -> String {
        replace(spaceRegex, in: s, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
