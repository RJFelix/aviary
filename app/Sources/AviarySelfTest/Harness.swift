import Foundation

/// A three-hundred-byte test runner.
///
/// This machine's Swift toolchain is Command Line Tools only, which ships no XCTest and no
/// swift-testing — `swift test` cannot work here. Rather than leave the core untested, the
/// suite is an executable: `swift run AviarySelfTest`, non-zero exit on failure, usable
/// from CI or a `just` recipe unchanged.
enum Harness {
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var currentCase = ""
    nonisolated(unsafe) static var assertions = 0

    static func run(_ cases: [(String, () async throws -> Void)]) async {
        let started = Date()
        for (name, body) in cases {
            currentCase = name
            let before = failures.count
            do {
                try await body()
            } catch {
                failures.append("\(name): threw \(error)")
            }
            let mark = failures.count == before ? "✓" : "✗"
            print("  \(mark) \(name)")
        }
        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("")
        if failures.isEmpty {
            print("\(cases.count) cases, \(assertions) assertions, all passed in \(elapsed)")
            exit(0)
        }
        print("\(failures.count) failure(s) in \(cases.count) cases (\(elapsed)):")
        for f in failures { print("  • \(f)") }
        exit(1)
    }

    static func check(_ condition: Bool, _ message: String, line: Int) {
        assertions += 1
        if !condition { failures.append("\(currentCase):\(line) — \(message)") }
    }
}

func XCTAssertTrue(_ c: Bool, _ m: String = "expected true", line: Int = #line) {
    Harness.check(c, m, line: line)
}

func XCTAssertFalse(_ c: Bool, _ m: String = "expected false", line: Int = #line) {
    Harness.check(!c, m, line: line)
}

func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, _ m: String = "", line: Int = #line) {
    Harness.check(a == b, m.isEmpty ? "\(a) != \(b)" : m, line: line)
}

func XCTAssertNotNil<T>(_ v: T?, _ m: String = "expected non-nil", line: Int = #line) {
    Harness.check(v != nil, m, line: line)
}

func XCTFail(_ m: String, line: Int = #line) {
    Harness.check(false, m, line: line)
}

struct UnwrapFailure: Error, CustomStringConvertible {
    let description: String
}

func XCTUnwrap<T>(_ v: T?, line: Int = #line) throws -> T {
    Harness.assertions += 1
    guard let v else { throw UnwrapFailure(description: "nil at line \(line)") }
    return v
}
