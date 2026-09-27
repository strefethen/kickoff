import Foundation
import XCTest
@testable import Kickoff

final class ApplicationInstanceLockTests: XCTestCase {
    private var directory: URL!
    private var lockURL: URL { directory.appendingPathComponent("instance.lock") }

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testDuplicateIsDeniedAndOwnerReleasePermitsNextInstance() throws {
        var owner = try ApplicationInstanceLock.acquire(at: lockURL)
        XCTAssertNotNil(owner)
        try withExtendedLifetime(owner) {
            XCTAssertNil(try ApplicationInstanceLock.acquire(at: lockURL))
        }
        owner = nil
        let next = try ApplicationInstanceLock.acquire(at: lockURL)
        XCTAssertNotNil(next)
    }

    func testStaleFileDoesNotPreventAcquisition() throws {
        try Data("old process".utf8).write(to: lockURL)
        let owner = try ApplicationInstanceLock.acquire(at: lockURL)
        XCTAssertNotNil(owner)
    }

    func testFilesystemErrorIsNotTreatedAsDuplicate() {
        let unavailable = directory.appendingPathComponent("missing/instance.lock")
        XCTAssertThrowsError(try ApplicationInstanceLock.acquire(at: unavailable))
    }

    func testSymlinkIsRejected() throws {
        let target = directory.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: target)
        XCTAssertThrowsError(try ApplicationInstanceLock.acquire(at: lockURL))
    }

    func testConcurrentAcquisitionsHaveOneOwner() {
        let group = DispatchGroup()
        let mutex = NSLock()
        var owners: [ApplicationInstanceLock] = []
        var failures: [Error] = []
        let url = lockURL
        for _ in 0..<8 {
            DispatchQueue.global().async(group: group) {
                do {
                    let owner = try ApplicationInstanceLock.acquire(at: url)
                    mutex.lock()
                    if let owner { owners.append(owner) }
                    mutex.unlock()
                } catch {
                    mutex.lock()
                    failures.append(error)
                    mutex.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 3), .success)
        XCTAssertTrue(failures.isEmpty)
        withExtendedLifetime(owners) { XCTAssertEqual(owners.count, 1) }
    }
}
