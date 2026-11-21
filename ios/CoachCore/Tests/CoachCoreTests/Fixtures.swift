import Foundation
import XCTest

/// JSON fixtures written by `node tools/make-fixtures.mjs` from the web app's JS.
enum Fixture {
    static let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    /// Repo root (…/ios/CoachCore/Tests/CoachCoreTests/Fixtures.swift -> 5 levels up).
    static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: dir.appendingPathComponent(name))
    }

    static func json(_ name: String) throws -> Any {
        try JSONSerialization.jsonObject(with: data(name), options: [.fragmentsAllowed])
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(T.self, from: data(name))
    }
}

/// FNV-1a 32-bit, same as tools/make-fixtures.mjs.
func fnv(_ bytes: UnsafeRawBufferPointer) -> UInt32 {
    var h: UInt32 = 0x811c_9dc5
    for b in bytes { h = (h ^ UInt32(b)) &* 0x0100_0193 }
    return h
}
func fnv(_ data: Data) -> UInt32 { data.withUnsafeBytes { fnv($0) } }
func fnv(_ samples: [Int16]) -> UInt32 { samples.withUnsafeBytes { fnv($0) } }

func num(_ x: Any?) -> Double? {
    if x is NSNull { return nil }
    return (x as? NSNumber)?.doubleValue
}

func close(_ a: Double?, _ b: Double?, rel: Double = 1e-9) -> Bool {
    switch (a, b) {
    case (nil, nil): return true
    case let (x?, y?): return abs(x - y) <= rel * max(1, abs(x), abs(y))
    default: return false
    }
}

/// Checks that everything in `expected` (parsed JS JSON) is matched in `actual` (parsed
/// Swift JSON). JS null == absent. Keys only Swift has are ignored (filled-in defaults);
/// JS keys Swift drops must be listed in `dropped`.
func compareJSON(_ expected: Any?, _ actual: Any?, path: String = "$", dropped: Set<String> = [], failures: inout [String]) {
    let act: Any? = actual is NSNull ? nil : actual
    guard let exp = expected, !(exp is NSNull) else {
        if let act { failures.append("\(path): expected null, got \(act)") }
        return
    }
    switch exp {
    case let e as [String: Any]:
        guard let a = act as? [String: Any] else { failures.append("\(path): expected object, got \(String(describing: act))"); return }
        for (k, v) in e {
            if let av = a[k] {
                compareJSON(v, av, path: "\(path).\(k)", dropped: dropped, failures: &failures)
            } else if !(v is NSNull) && !dropped.contains(k) {
                failures.append("\(path).\(k): missing in Swift output")
            }
        }
    case let e as [Any]:
        guard let a = act as? [Any], a.count == e.count else {
            failures.append("\(path): expected array of \(e.count), got \(String(describing: act))"); return
        }
        for i in e.indices { compareJSON(e[i], a[i], path: "\(path)[\(i)]", dropped: dropped, failures: &failures) }
    case let e as String:
        if (act as? String) != e { failures.append("\(path): expected \"\(e)\", got \(String(describing: act))") }
    case let e as NSNumber:
        guard let a = act as? NSNumber, close(e.doubleValue, a.doubleValue) else {
            failures.append("\(path): expected \(e), got \(String(describing: act))"); return
        }
    default:
        failures.append("\(path): unexpected value \(String(describing: exp))")
    }
}
