import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Owns one native `muse serve` child, not a Node or Python SDK process.
/// A Muse process has one MSP stdio connection for its lifetime. Always call `stop()`;
/// closing a GUI view alone must not be mistaken for a completed Muse session.
public actor MuseMSPProcess {
    public let connection: MuseMSPConnection
    public let handshake: MuseMSPHandshake
    private let process: Process
    private let stdin: FileHandle
    private let stdout: FileHandle
    private var stopping = false

    private init(process: Process, stdin: FileHandle, stdout: FileHandle,
                 connection: MuseMSPConnection, handshake: MuseMSPHandshake) {
        self.process = process
        self.stdin = stdin
        self.stdout = stdout
        self.connection = connection
        self.handshake = handshake
    }

    /// Launch and initialize before returning the process. The caller supplies the exact
    /// executable path and workspace; this never resolves through a transient PATH shim.
    /// `ProcessEnvironment` matches Aviary's GUI login-shell environment convention.
    public static func launch(executable: String, cwd: String,
                              environment: [String: String]? = nil,
                              experimentalAPI: Bool = false,
                              requestedCapabilities: [String] = [],
                              userInputDialogs: Bool = false,
                              // On Muse 1.3.0-R3401.1, the ephemeral profile admits
                              // `turn/start` but does not advance the turn. Keep this
                              // for bounded discovery/fixture use; use the durable
                              // default for a real turn until the host fixes it.
                              memoryOnly: Bool = false,
                              disableShell: Bool = false,
                              disableWrite: Bool = false) async throws -> MuseMSPProcess {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw MuseMSPError.transport("Muse executable unavailable")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MuseMSPError.transport("Muse workspace unavailable")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        // TUI options cannot be combined with `serve`; configure the Session through MSP.
        process.arguments = ["serve"]
            + (memoryOnly ? ["--no-session-log"] : [])
            + (disableShell ? ["--disable-shell"] : [])
            + (disableWrite ? ["--disable-write"] : [])
        process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        // A parent shell may carry provider keys or model/base-url overrides. Muse's
        // account-login lane must win, so apply the same scrubber used by discovery
        // unless the caller supplied an explicit environment for a fixture.
        process.environment = environment ?? MuseCode.scrubbedEnvironment()
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        // Do not retain or display stderr: it can contain provider/account diagnostics.
        process.standardError = FileHandle.nullDevice
        let connection = MuseMSPConnection(
            stdin: input.fileHandleForWriting, stdout: output.fileHandleForReading,
            onWriteTimeout: { [weak process] in
                if process?.isRunning == true { process?.terminate() }
            })
        process.terminationHandler = { _ in
            Task { await connection.close() }
        }
        try process.run()
        do {
            let handshake = try await connection.initialize(
                clientName: "aviary", version: "0.1", experimentalAPI: experimentalAPI,
                requestedCapabilities: requestedCapabilities,
                userInputDialogs: userInputDialogs)
            return MuseMSPProcess(
                process: process, stdin: input.fileHandleForWriting,
                stdout: output.fileHandleForReading, connection: connection,
                handshake: handshake)
        } catch {
            await connection.close()
            try? input.fileHandleForWriting.close()
            if process.isRunning { process.terminate() }
            for _ in 0..<10 where process.isRunning {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            try? output.fileHandleForReading.close()
            throw error
        }
    }

    public var isRunning: Bool { process.isRunning }

    /// Ends the connection and reaps the child within a bounded grace period. This is a
    /// process stop, not evidence that a previously acknowledged command completed.
    public func stop() async {
        guard !stopping else { return }
        stopping = true
        await connection.close()
        try? stdin.close()
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning { process.terminate() }
        for _ in 0..<10 where process.isRunning {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? stdout.close()
    }
}
