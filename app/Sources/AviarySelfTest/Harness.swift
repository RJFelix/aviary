import Foundation

/// A three-hundred-byte test runner.
///
/// This machine's Swift toolchain is Command Line Tools only, which ships no XCTest and no
/// swift-testing — `swift test` cannot work here. Rather than leave the core untested, the
/// suite is an executable: `swift run AviarySelfTest`, non-zero exit on failure, usable
/// from CI or a `just` recipe unchanged.
enum Harness {
    private static let lock = NSLock()
    nonisolated(unsafe) static var failures: [String] = []
    nonisolated(unsafe) static var currentCase = ""
    nonisolated(unsafe) static var assertions = 0

    /// Keep the synchronous lock operations outside async call sites. Swift 6.3 diagnoses
    /// direct `NSLock.lock()`/`unlock()` calls from an async function even though this tiny
    /// runner never suspends while the lock is held.
    private static func withStateLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    static func run(_ cases: [(String, () async throws -> Void)]) async {
        let filter = ProcessInfo.processInfo.environment["AVIARY_SELFTEST_FILTER"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var selected: [(String, () async throws -> Void)]
        if let filter, !filter.isEmpty {
            selected = cases.filter {
                $0.0.localizedCaseInsensitiveContains(filter)
            }
            guard !selected.isEmpty else {
                print("No self-test case matched AVIARY_SELFTEST_FILTER=\(filter)")
                exit(2)
            }
        } else {
            selected = cases
        }
        let started = Date()
        for (name, body) in selected {
            let before = withStateLock {
                currentCase = name
                return failures.count
            }
            do {
                try await body()
            } catch {
                withStateLock { failures.append("\(name): threw \(error)") }
            }
            let mark = withStateLock { failures.count == before ? "✓" : "✗" }
            print("  \(mark) \(name)")
        }
        let elapsed = String(format: "%.2fs", Date().timeIntervalSince(started))
        print("")
        let (finalFailures, finalAssertions) = withStateLock { (failures, assertions) }
        if finalFailures.isEmpty {
            print("\(selected.count) cases, \(finalAssertions) assertions, all passed in \(elapsed)")
            exit(0)
        }
        print("\(finalFailures.count) failure(s) in \(selected.count) cases (\(elapsed)):")
        for f in finalFailures { print("  • \(f)") }
        exit(1)
    }

    static func check(_ condition: Bool, _ message: String, line: Int) {
        withStateLock {
            assertions += 1
            if !condition { failures.append("\(currentCase):\(line) — \(message)") }
        }
    }

    static func countAssertion() {
        withStateLock { assertions += 1 }
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

func XCTAssertNotEqual<T: Equatable>(_ a: T, _ b: T, _ m: String = "", line: Int = #line) {
    Harness.check(a != b, m.isEmpty ? "\(a) == \(b)" : m, line: line)
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
    Harness.countAssertion()
    guard let v else { throw UnwrapFailure(description: "nil at line \(line)") }
    return v
}

func XCTAssertNil<T>(_ v: T?, _ m: String = "expected nil", line: Int = #line) {
    Harness.check(v == nil, m, line: line)
}
