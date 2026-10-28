import Darwin
import Foundation

/// A bounded process result. Callers get output for diagnosis without risking an
/// unlimited buffer or waiting forever for a damaged helper process.
public enum ProcessResult: Equatable {
    case completed(exitCode: Int32, output: String, truncated: Bool)
    case timedOut(output: String, truncated: Bool)
    case outputLimitExceeded(output: String)
    case failedToLaunch(String)
}

public enum ProcessRunner {
    public static func run(executable: String, arguments: [String], timeout: TimeInterval,
                           maxOutputBytes: Int = 64 * 1024) -> ProcessResult {
        guard timeout.isFinite, timeout >= 0, timeout <= 86_400 else {
            return .failedToLaunch("Invalid process timeout")
        }

        var descriptors = [Int32](repeating: -1, count: 2)
        guard pipe(&descriptors) == 0 else {
            return .failedToLaunch("Could not create process output pipe: \(systemError())")
        }
        let readDescriptor = descriptors[0]
        let writeDescriptor = descriptors[1]
        defer { close(readDescriptor) }

        let flags = fcntl(readDescriptor, F_GETFL)
        guard flags >= 0, fcntl(readDescriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(writeDescriptor)
            return .failedToLaunch("Could not make process output nonblocking: \(systemError())")
        }

        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            close(writeDescriptor)
            return .failedToLaunch("Could not prepare process file actions")
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        let actionResults = [
            posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, writeDescriptor, STDERR_FILENO),
            posix_spawn_file_actions_addclose(&actions, readDescriptor),
            posix_spawn_file_actions_addclose(&actions, writeDescriptor),
        ]
        guard actionResults.allSatisfy({ $0 == 0 }) else {
            close(writeDescriptor)
            return .failedToLaunch("Could not configure process output")
        }

        let allocatedArguments = ([executable] + arguments).map { strdup($0) }
        defer { allocatedArguments.forEach { free($0) } }
        guard allocatedArguments.allSatisfy({ $0 != nil }) else {
            close(writeDescriptor)
            return .failedToLaunch("Could not allocate process arguments")
        }
        var argumentVector = allocatedArguments
        argumentVector.append(nil)
        var pid: pid_t = 0
        let spawnResult = executable.withCString { path in
            argumentVector.withUnsafeMutableBufferPointer { vector in
                posix_spawn(&pid, path, &actions, nil, vector.baseAddress, environ)
            }
        }
        close(writeDescriptor)
        guard spawnResult == 0 else {
            return .failedToLaunch(String(cString: strerror(spawnResult)))
        }

        let limit = max(0, maxOutputBytes)
        let deadline = DispatchTime.now().uptimeNanoseconds
            + UInt64(timeout * 1_000_000_000)
        var output = Data()
        var status: Int32 = 0

        while true {
            if !drain(descriptor: readDescriptor, into: &output, limit: limit) {
                terminateAndReap(pid)
                return .outputLimitExceeded(output: String(decoding: output, as: UTF8.self))
            }

            let waitResult = waitpid(pid, &status, WNOHANG)
            if waitResult == pid {
                _ = drain(descriptor: readDescriptor, into: &output, limit: limit)
                return .completed(exitCode: exitCode(status),
                                  output: String(decoding: output, as: UTF8.self), truncated: false)
            }
            if waitResult == -1, errno == EINTR { continue }
            if waitResult == -1 {
                return .failedToLaunch("Could not observe process exit: \(systemError())")
            }
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                terminateAndReap(pid)
                _ = drain(descriptor: readDescriptor, into: &output, limit: limit)
                return .timedOut(output: String(decoding: output, as: UTF8.self), truncated: false)
            }

            var item = pollfd(fd: readDescriptor, events: Int16(POLLIN), revents: 0)
            _ = poll(&item, 1, 10)
            if item.revents & Int16(POLLIN) == 0 { usleep(1_000) }
        }
    }

    /// Returns false on the first byte beyond `limit`.
    private static func drain(descriptor: Int32, into output: inout Data, limit: Int) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { return true }
            let remaining = max(0, limit - output.count)
            if count > remaining {
                if remaining > 0 { output.append(contentsOf: buffer.prefix(remaining)) }
                return false
            }
            output.append(contentsOf: buffer.prefix(count))
        }
    }

    private static func terminateAndReap(_ pid: pid_t) {
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid { return }
        _ = kill(pid, SIGTERM)
        if reap(pid, status: &status, within: 0.2) { return }
        _ = kill(pid, SIGKILL)
        if reap(pid, status: &status, within: 0.5) { return }
        // An uninterruptible process is rare. Reap it later so Tripwire still
        // returns at its deadline and does not leave a zombie.
        Thread.detachNewThread {
            var eventualStatus: Int32 = 0
            _ = waitpid(pid, &eventualStatus, 0)
        }
    }

    private static func reap(_ pid: pid_t, status: inout Int32, within seconds: Double) -> Bool {
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(seconds * 1_000_000_000)
        repeat {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result == -1 && errno == ECHILD) { return true }
            usleep(5_000)
        } while DispatchTime.now().uptimeNanoseconds < deadline
        return false
    }

    private static func exitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    private static func systemError() -> String {
        String(cString: strerror(errno))
    }
}
