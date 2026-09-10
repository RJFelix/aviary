import Foundation
import AviaryCore

func testAviaryDigestFormattingPreservesCanonicalBytes() throws {
    let vectors = [
        ("", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"),
        ("abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),
        ("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
         "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"),
    ]
    for (input, expected) in vectors {
        XCTAssertEqual(AviarySHA256.hash(data: Data(input.utf8)).description, expected)
    }
    var encountered = Set<UInt8>()
    for length in 0...512 {
        let digest = AviarySHA256.hash(data: Data((0..<length).map { UInt8($0 % 256) }))
        encountered.formUnion(digest)
        let reference = digest.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest.description, reference)
        XCTAssertEqual(digest.description.utf8.count, 64)
    }
    XCTAssertEqual(encountered.count, 256, "the formatting oracle must exercise every byte value")
}

func testAviaryDigestFormattingMeasurement() throws {
    let digest = AviarySHA256.hash(data: Data("formatting measurement".utf8))
    let iterations = 2_000
    var newBytes = 0
    let start = Date()
    for _ in 0..<iterations { newBytes += digest.description.utf8.count }
    let optimizedSeconds = Date().timeIntervalSince(start)
    var oldBytes = 0
    let referenceStart = Date()
    for _ in 0..<iterations {
        oldBytes += digest.map { String(format: "%02x", $0) }.joined().utf8.count
    }
    let referenceSeconds = Date().timeIntervalSince(referenceStart)
    XCTAssertEqual(newBytes, iterations * 64)
    XCTAssertEqual(newBytes, oldBytes)
    // Timings are a diagnostic receipt, not a flaky wall-clock correctness threshold.
    print("digest formatting: \(iterations) conversions, optimized=\(optimizedSeconds)s reference=\(referenceSeconds)s")
}

let casesAviaryDigestFormatting: [Case] = [
    ("platform digest formatting preserves every byte and known vectors", {
        try testAviaryDigestFormattingPreservesCanonicalBytes()
    }),
    ("platform digest formatting measurement", {
        try testAviaryDigestFormattingMeasurement()
    }),
]
