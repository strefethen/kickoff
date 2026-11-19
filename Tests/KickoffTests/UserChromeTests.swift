import XCTest
@testable import Kickoff

final class UserChromeTests: XCTestCase {
    private let devtoolsArguments = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "--enable-automation",
        "--user-data-dir=/Users/me/.cache/chrome-devtools-mcp/chrome-profile",
        "--remote-debugging-pipe",
    ]
    private let userArguments = ["/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"]

    func testAutomationChromeLaunchedEarlierIsNotChosenOverTheUsersChrome() {
        let instances = [
            UserChrome.Instance(pid: 11528, launchDate: Date(timeIntervalSince1970: 100), arguments: devtoolsArguments),
            UserChrome.Instance(pid: 14968, launchDate: Date(timeIntervalSince1970: 200), arguments: userArguments),
        ]
        XCTAssertEqual(UserChrome.choose(instances), 14968)
    }

    func testOnlyAutomationChromeRunningMeansUserChromeIsNotRunning() {
        let instances = [UserChrome.Instance(pid: 1, launchDate: nil, arguments: devtoolsArguments)]
        XCTAssertNil(UserChrome.choose(instances))
    }

    func testDefaultProfileIsPreferredOverCustomProfile() {
        let instances = [
            UserChrome.Instance(pid: 1, launchDate: Date(timeIntervalSince1970: 1), arguments: userArguments + ["--user-data-dir=/tmp/other"]),
            UserChrome.Instance(pid: 2, launchDate: Date(timeIntervalSince1970: 2), arguments: userArguments),
        ]
        XCTAssertEqual(UserChrome.choose(instances), 2)
    }

    func testEarliestLaunchedWinsAmongEquivalentInstances() {
        let instances = [
            UserChrome.Instance(pid: 2, launchDate: Date(timeIntervalSince1970: 2), arguments: userArguments),
            UserChrome.Instance(pid: 1, launchDate: Date(timeIntervalSince1970: 1), arguments: userArguments),
        ]
        XCTAssertEqual(UserChrome.choose(instances), 1)
    }

    func testRemoteDebuggingPortWithValueCountsAsAutomation() {
        XCTAssertTrue(UserChrome.isAutomated(userArguments + ["--remote-debugging-port=9222"]))
        XCTAssertFalse(UserChrome.isAutomated(userArguments))
    }

    func testArgumentsOfThisProcessAreReadable() {
        let arguments = UserChrome.arguments(of: getpid())
        XCTAssertEqual(arguments?.count, CommandLine.arguments.count)
    }
}
