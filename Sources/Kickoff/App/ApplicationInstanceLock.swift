import Darwin
import Foundation

/// Holds menu-bar admission for this user until the process exits.
/// Keep the lock file in place: removing it would allow two locked inodes.
final class ApplicationInstanceLock {
    private let descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    deinit { close(descriptor) }

    static func acquire() throws -> ApplicationInstanceLock? {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent(AppPreferences.suiteName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return try acquire(at: directory.appendingPathComponent("instance.lock"))
    }

    /// A busy lock is a normal duplicate launch; filesystem errors fail startup.
    static func acquire(at url: URL) throws -> ApplicationInstanceLock? {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        var retained = false
        defer { if !retained { close(descriptor) } }

        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else { throw posixError() }
        guard metadata.st_uid == getuid(),
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_nlink == 1 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            if failure == EWOULDBLOCK { return nil }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(failure))
        }
        retained = true
        return ApplicationInstanceLock(descriptor: descriptor)
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
