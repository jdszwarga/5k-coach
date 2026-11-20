import Foundation

// Small helpers that reproduce JavaScript number behaviour exactly, so the port gives
// the same numbers as the web app.

/// `Math.round`: halves round up (towards +∞), unlike Swift's `.rounded()`.
@inlinable
public func jsRound(_ x: Double) -> Double {
    let f = x.rounded(.down)
    return x - f >= 0.5 ? f + 1 : f
}

/// `Math.round` to an Int.
@inlinable
public func jsRoundInt(_ x: Double) -> Int { Int(jsRound(x)) }

func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { max(lo, min(hi, v)) }

/// `Number.prototype.toFixed(digits)`. Rounds on the exact binary value, and exact
/// ties round away from zero (printf alone would round them to even).
public func jsToFixed(_ x: Double, _ digits: Int) -> String {
    if x.isNaN { return "NaN" }
    if x.isInfinite { return x > 0 ? "Infinity" : "-Infinity" }
    let neg = x < 0
    let a = abs(x)
    var s = String(format: "%.\(digits)f", a)
    let exact = String(format: "%.80f", a)
    if let dot = exact.firstIndex(of: ".") {
        let frac = exact[exact.index(after: dot)...]
        let tail = frac.dropFirst(digits)
        if tail.first == "5" && tail.dropFirst().allSatisfy({ $0 == "0" }) {
            let cut = digits == 0 ? dot : exact.index(dot, offsetBy: digits + 1)
            s = incrementDecimal(String(exact[..<cut]))
        }
    }
    return neg ? "-" + s : s
}

/// `+x.toFixed(digits)`: the number back from the rounded text.
public func jsToFixedNumber(_ x: Double, _ digits: Int) -> Double {
    Double(jsToFixed(x, digits)) ?? x
}

/// Adds one unit in the last place of a plain decimal string ("42.01562" -> "42.01563").
private func incrementDecimal(_ s: String) -> String {
    var chars = Array(s)
    var i = chars.count - 1
    while i >= 0 {
        if chars[i] == "." { i -= 1; continue }
        if chars[i] == "9" { chars[i] = "0"; i -= 1; continue }
        chars[i] = Character(String(chars[i].wholeNumberValue! + 1))
        return String(chars)
    }
    return "1" + String(chars)
}

/// Two-digit zero padding (`String(n).padStart(2, '0')`).
func pad2(_ n: Int) -> String { n >= 0 && n < 10 ? "0\(n)" : "\(n)" }
