import Foundation
import Network
import AviaryCore

/// A minimal client for the kernel bridge, for the suite's use.
///
/// Deliberately not `MCPBridge` itself: that class speaks MCP on stdio, and pointing the test
/// at it would test the courier's plumbing rather than the bridge's contract. This speaks only
/// the socket protocol, which is the thing under test.
final class BridgeTestClient {
    /// Its own line framer rather than the core's internal one: a test reaching into a
    /// module's internals to test that module's public contract is testing the wrong thing.
    final class Framer {
        private var carry = Data()
        func feed(_ chunk: Data) -> [Data] {
            carry.append(chunk)
            var lines: [Data] = []
            while let nl = carry.firstIndex(of: UInt8(ascii: "\n")) {
                let line = carry.subdata(in: carry.startIndex..<nl)
                carry.removeSubrange(carry.startIndex...nl)
                if !line.isEmpty { lines.append(line) }
            }
            return lines
        }
    }

    private let connection: NWConnection
    private let framer = Framer()
    private let lock = NSLock()
    private var pending: [Int: (JSONValue) -> Void] = [:]
    private var nextID = 1

    init(port: UInt16) throws {
        connection = NWConnection(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = DispatchSemaphore(value: 0)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        connection.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
        receive()
    }

    deinit { connection.cancel() }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                for line in self.framer.feed(data) {
                    guard let value = JSONValue.parse(line) else { continue }
                    let id = value["id"]?.intValue ?? -1
                    self.lock.lock()
                    let handler = self.pending.removeValue(forKey: id)
                    self.lock.unlock()
                    handler?(value)
                }
            }
            if isComplete || error != nil { return }
            self.receive()
        }
    }

    /// One round trip. Nil on timeout, which is how a refused connection presents.
    func request(_ body: [String: JSONValue], timeout: TimeInterval = 5) -> JSONValue? {
        lock.lock()
        let id = nextID
        nextID += 1
        lock.unlock()

        var payload = body
        payload["id"] = .number(Double(id))
        guard var data = try? JSONEncoder().encode(JSONValue.object(payload)) else { return nil }
        data.append(UInt8(ascii: "\n"))

        let done = DispatchSemaphore(value: 0)
        var answer: JSONValue?
        lock.lock()
        pending[id] = { value in answer = value; done.signal() }
        lock.unlock()

        connection.send(content: data, completion: .contentProcessed { _ in })
        if done.wait(timeout: .now() + timeout) == .timedOut {
            lock.lock(); pending.removeValue(forKey: id); lock.unlock()
            return nil
        }
        return answer
    }
}
