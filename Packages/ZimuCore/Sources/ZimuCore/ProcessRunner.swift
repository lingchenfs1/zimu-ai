import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ProcessResult: Sendable, Equatable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    public var stderrText: String { String(decoding: stderr, as: UTF8.self) }
}

/// 运行外部命令（ditto、xattr、codesign、重启脚本……）
public enum ProcessRunner {
    /// 进程结束后最多再等多久读完输出（防止子孙进程继承了管道导致一直读不到结尾）
    static let outputGracePeriod: TimeInterval = 2

    /// 运行命令并等待结束：stdin 为空；超时后终止进程
    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let state = RunState(process: process)
        let outputs = DispatchGroup()
        for (pipe, isStdout) in [(stdout, true), (stderr, false)] {
            outputs.enter()
            let eof = OnceFlag()
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    if eof.set() { outputs.leave() }
                } else {
                    state.append(data, toStdout: isStdout)
                }
            }
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { _ in
                DispatchQueue.global().async {
                    // 正常情况下管道很快读到结尾；超过宽限时间就用已经读到的内容
                    _ = outputs.wait(timeout: .now() + outputGracePeriod)
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(returning: state.result())
                }
            }
            do {
                try process.run()
            } catch {
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                continuation.resume(throwing: error)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                state.terminateIfRunning()
            }
        }
    }

    /// 启动后台进程后立即返回，不等待；stdout 和 stderr 以追加方式写入日志文件。
    /// 本进程退出后它会继续运行（用于更新后重启）。返回进程号
    @discardableResult
    public static func spawnDetached(_ executable: String, _ arguments: [String], logFile: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(logFile.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard descriptor >= 0 else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: logFile.path])
        }
        let log = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = log
        process.standardError = log
        try process.run()
        return process.processIdentifier
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        /// 第一次调用返回 true
        func set() -> Bool {
            lock.withLock {
                guard !done else { return false }
                done = true
                return true
            }
        }
    }

    private final class RunState: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var stdout = Data()
        private var stderr = Data()
        private var timedOut = false

        init(process: Process) {
            self.process = process
        }

        func append(_ data: Data, toStdout: Bool) {
            lock.withLock {
                if toStdout { stdout.append(data) } else { stderr.append(data) }
            }
        }

        /// 超时：先发 SIGTERM，1 秒后还没退出就 SIGKILL（子进程可能继承了屏蔽 SIGTERM 的信号掩码）
        func terminateIfRunning() {
            let pid: Int32? = lock.withLock {
                guard process.isRunning else { return nil }
                timedOut = true
                process.terminate()
                return process.processIdentifier
            }
            guard let pid else { return }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
                if lock.withLock({ process.isRunning }) {
                    kill(pid, SIGKILL)
                }
            }
        }

        func result() -> ProcessResult {
            lock.withLock {
                ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr, timedOut: timedOut)
            }
        }
    }
}
