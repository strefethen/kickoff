import Foundation

protocol SetupLogging: AnyObject {
    var location: String { get }
    var writeFailure: String? { get }
    func record(_ line: String)
}

final class SetupLog: SetupLogging {
    static var standardURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Kickoff/setup.log")
    }

    let location: String
    private(set) var writeFailure: String?
    private let handle: FileHandle
    private let now: () -> Date
    private let timestamp = ISO8601DateFormatter()

    init(url: URL = SetupLog.standardURL, maximumBytes: UInt64 = 1_000_000, now: @escaping () -> Date = Date.init) throws {
        let files = FileManager.default
        do {
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let size = (try? files.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
            if size > maximumBytes {
                let previous = url.deletingPathExtension().appendingPathExtension("1.log")
                if files.fileExists(atPath: previous.path) { try files.removeItem(at: previous) }
                try files.moveItem(at: url, to: previous)
            }
            if !files.fileExists(atPath: url.path) {
                guard files.createFile(atPath: url.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
            }
            handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
        } catch {
            throw AccessibilityFailure("Kickoff could not open its setup log at \(url.path): \(error.localizedDescription)")
        }
        location = url.path
        self.now = now
    }

    deinit {
        try? handle.close()
    }

    func record(_ line: String) {
        guard writeFailure == nil else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("\(timestamp.string(from: now())) \(line)\n".utf8))
        } catch {
            writeFailure = error.localizedDescription
        }
    }
}
