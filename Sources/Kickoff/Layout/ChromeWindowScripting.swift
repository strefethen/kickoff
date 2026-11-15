import AppKit
import Foundation

protocol ChromeWindowScripting: AnyObject {
    func makeWindow(bounds: CGRect) throws -> String
    func closeWindow(id: String) throws
}

struct ChromeScriptingFailure: Error, CustomStringConvertible, Equatable {
    enum Kind: Equatable {
        case notPermitted
        case notReady
        case timedOut
        case other(Int)
    }

    let kind: Kind
    let description: String

    static func from(errorNumber: Int, message: String) -> ChromeScriptingFailure {
        switch errorNumber {
        case -1743:
            return ChromeScriptingFailure(
                kind: .notPermitted,
                description: "Kickoff is not allowed to control Google Chrome. Allow Kickoff under System Settings > Privacy & Security > Automation > Google Chrome, then run setup again."
            )
        case -600, -609, -903:
            return ChromeScriptingFailure(kind: .notReady, description: "Google Chrome is not ready for Kickoff yet (\(errorNumber)).")
        case -1712:
            return ChromeScriptingFailure(
                kind: .timedOut,
                description: "Google Chrome did not answer Kickoff in time. If macOS asked whether Kickoff may control Chrome, allow it and run setup again."
            )
        default:
            return ChromeScriptingFailure(kind: .other(errorNumber), description: "Google Chrome refused Kickoff's request (\(errorNumber)): \(message)")
        }
    }
}

final class ChromeAppleScriptClient: ChromeWindowScripting {
    func makeWindow(bounds: CGRect) throws -> String {
        let edges = [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].map { String(Int($0.rounded())) }
        let result = try run("""
        set createdWindow to make new window with properties {bounds:{\(edges.joined(separator: ", "))}}
        return id of createdWindow as text
        """)
        guard let id = result.stringValue, !id.isEmpty else {
            throw ChromeScriptingFailure(kind: .other(0), description: "Google Chrome created a window but did not report its id.")
        }
        return id
    }

    func closeWindow(id: String) throws {
        guard id.allSatisfy(\.isNumber) else {
            throw ChromeScriptingFailure(kind: .other(0), description: "Chrome window id \(id) is not numeric.")
        }
        _ = try run("close (every window whose id is \(id))")
    }

    private func run(_ body: String) throws -> NSAppleEventDescriptor {
        let source = """
        with timeout of 10 seconds
            tell application id "com.google.Chrome"
                \(body)
            end tell
        end timeout
        """
        let execute = { () throws -> NSAppleEventDescriptor in
            guard let script = NSAppleScript(source: source) else {
                throw ChromeScriptingFailure(kind: .other(0), description: "Kickoff could not prepare its Chrome request.")
            }
            var error: NSDictionary?
            let result = script.executeAndReturnError(&error)
            if let error {
                throw ChromeScriptingFailure.from(
                    errorNumber: error[NSAppleScript.errorNumber] as? Int ?? 0,
                    message: error[NSAppleScript.errorMessage] as? String ?? "unknown error"
                )
            }
            return result
        }
        if Thread.isMainThread { return try execute() }
        return try DispatchQueue.main.sync(execute: execute)
    }
}
