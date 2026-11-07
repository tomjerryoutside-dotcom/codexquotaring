import Foundation

struct QuotaSnapshot {
    let remaining: Double?
    let resetAt: Date?
    let cards: Int?
    let firstExpiry: Date?
    let expiryComplete: Bool
    let creditBalance: Decimal?
    let unlimitedCredits: Bool
    let fetchedAt: Date

    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }

    static func parse(_ response: [String: Any], now: Date = Date()) -> QuotaSnapshot {
        let buckets = response["rateLimitsByLimitId"] as? [String: Any]
        let bucket = (buckets?["codex"] as? [String: Any]) ?? (response["rateLimits"] as? [String: Any]) ?? [:]
        // A weekly window can be primary or secondary. Never mislabel a 5-hour window.
        let weekly = ["primary", "secondary"].compactMap { bucket[$0] as? [String: Any] }
            .first { number($0["windowDurationMins"]) == 10080 }
        let remaining = number(weekly?["usedPercent"]).map { min(100, max(0, 100 - $0)) }
        let reset = number(weekly?["resetsAt"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
        let credits = response["rateLimitResetCredits"] as? [String: Any]
        let countValue = number(credits?["availableCount"])
        let count = countValue.flatMap { $0 >= 0 && $0 <= 1_000_000 && $0.rounded() == $0 ? Int($0) : nil }
        let allRows = credits?["credits"] as? [[String: Any]]
        let available = (allRows ?? []).filter { ($0["status"] as? String) == "available" }
        let expiries = available.compactMap { row -> Date? in
            guard let t = number(row["expiresAt"]), t > 0 else { return nil }
            return Date(timeIntervalSince1970: t)
        }
        let complete = count != nil && allRows != nil && available.count == count && expiries.count == count
        let balance = bucket["credits"] as? [String: Any]
        return QuotaSnapshot(remaining: remaining, resetAt: reset, cards: count,
                             firstExpiry: expiries.min(), expiryComplete: complete,
                             creditBalance: BalanceFormat.decimal(balance?["balance"] as? String),
                             unlimitedCredits: (balance?["unlimited"] as? Bool) == true, fetchedAt: now)
    }

    var ringText: String { remaining.map { String(Int($0.rounded(.down))) } ?? "—" }
    var cardsText: String { cards.map { "\($0) 张" } ?? "暂不可用" }
    var creditBalanceText: String {
        if unlimitedCredits { return "不限量" }
        return creditBalance.map { BalanceFormat.number($0) + " 点" } ?? "暂不可用"
    }
    var expiryLabel: String { expiryComplete || firstExpiry == nil ? "最近到期" : "最近到期（已知）" }
    var expiryText: String {
        if cards == 0 { return "无可用卡" }
        return firstExpiry.map { Self.dateText($0) } ?? "暂不可用"
    }
    static func dateText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "yyyy/MM/dd HH:mm"
        return f.string(from: date)
    }
    func countdown(now: Date = Date()) -> String {
        guard let date = resetAt else { return "暂不可用" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "等待额度刷新" }
        if seconds < 60 { return "不足 1 分钟" }
        let minutes = Int(seconds / 60)
        let days = minutes / 1440, hours = minutes % 1440 / 60, mins = minutes % 60
        return days > 0 ? "\(days)天 \(hours)小时 \(mins)分钟" : "\(hours)小时 \(mins)分钟"
    }
}

enum BalanceFormat {
    static func decimal(_ text: String?, allowNegative: Bool = false) -> Decimal? {
        let pattern = allowNegative ? #"^-?[0-9]+(?:\.[0-9]+)?$"# : #"^[0-9]+(?:\.[0-9]+)?$"#
        guard let text, text.range(of: pattern, options: .regularExpression) != nil,
              let value = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              abs(value) <= Decimal(1_000_000_000_000) else { return nil }
        return value
    }
    static func number(_ value: Decimal, currency: Bool = false) -> String {
        if !currency && value > 0 && value < Decimal(string: "0.01")! { return "<0.01" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.minimumFractionDigits = currency ? 2 : 0
        formatter.maximumFractionDigits = 2
        formatter.roundingMode = .down
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "暂不可用"
    }
}

struct APIBalanceSnapshot {
    let amount: Decimal
    let verifiedAt: Date
    var amountText: String { (amount < 0 ? "-US$" : "US$") + BalanceFormat.number(abs(amount), currency: true) }
    var verifiedText: String { QuotaSnapshot.dateText(verifiedAt) }

    static func parse(_ json: [String: Any], now: Date = Date()) -> APIBalanceSnapshot? {
        guard json["currency"] as? String == "USD", let amount = BalanceFormat.decimal(json["amount"] as? String, allowNegative: true),
              let time = QuotaSnapshot.number(json["verifiedAt"]), time > 0,
              time <= now.timeIntervalSince1970 + 60 else { return nil }
        return APIBalanceSnapshot(amount: amount, verifiedAt: Date(timeIntervalSince1970: time))
    }
    static func load(from prefs: UserDefaults) -> APIBalanceSnapshot? {
        guard let saved = prefs.dictionary(forKey: "apiBalanceSnapshot") else { return nil }
        return parse(saved)
    }
    func save(to prefs: UserDefaults) {
        prefs.set(["amount": NSDecimalNumber(decimal: amount).stringValue, "currency": "USD",
                   "verifiedAt": verifiedAt.timeIntervalSince1970], forKey: "apiBalanceSnapshot")
    }
}

import CoreFoundation
