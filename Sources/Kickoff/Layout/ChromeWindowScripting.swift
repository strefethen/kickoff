import AppKit
import Foundation

protocol ChromeWindowScripting: AnyObject {
    func makeWindow(bounds: CGRect) throws -> String
    func closeWindow(id: String) throws
}

struct ChromeWindowLeftOpen: Error, CustomStringConvertible, Equatable {
    let description: String
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
    private let pid: pid_t

    init(pid: pid_t) {
        self.pid = pid
    }

    func makeWindow(bounds: CGRect) throws -> String {
        let edges = NSAppleEventDescriptor.list()
        for (index, edge) in [bounds.minX, bounds.minY, bounds.maxX, bounds.maxY].enumerated() {
            edges.insert(NSAppleEventDescriptor(int32: Int32(edge.rounded())), at: index + 1)
        }
        let properties = NSAppleEventDescriptor.record()
        properties.setDescriptor(edges, forKeyword: FourCharCode("pbnd"))

        let make = event("core", "crel")
        make.setParam(NSAppleEventDescriptor(typeCode: FourCharCode("cwin")), forKeyword: FourCharCode("kocl"))
        make.setParam(properties, forKeyword: FourCharCode("prdt"))
        guard let window = try send(make).paramDescriptor(forKeyword: keyDirectObject) else {
            throw ChromeScriptingFailure(kind: .other(0), description: "Google Chrome did not return the window it created.")
        }

        let get = event("core", "getd")
        get.setParam(
            Self.specifier(want: "prop", form: "prop", key: NSAppleEventDescriptor(typeCode: FourCharCode("ID  ")), container: window),
            forKeyword: keyDirectObject
        )
        do {
            guard let id = try send(get).paramDescriptor(forKeyword: keyDirectObject)?.stringValue, !id.isEmpty else {
                throw ChromeScriptingFailure(kind: .other(0), description: "Google Chrome created a window but did not report its id.")
            }
            return id
        } catch {
            let close = event("core", "clos")
            close.setParam(window, forKeyword: keyDirectObject)
            do {
                _ = try send(close)
            } catch let closeError {
                throw ChromeWindowLeftOpen(description: "\(error) Kickoff also could not close that window: \(closeError)")
            }
            throw error
        }
    }

    func closeWindow(id: String) throws {
        guard !id.isEmpty, id.allSatisfy(\.isNumber) else {
            throw ChromeScriptingFailure(kind: .other(0), description: "Chrome window id \(id) is not numeric.")
        }
        let close = event("core", "clos")
        close.setParam(
            Self.specifier(want: "cwin", form: "ID  ", key: NSAppleEventDescriptor(string: id), container: .null()),
            forKeyword: keyDirectObject
        )
        _ = try send(close)
    }

    private func event(_ eventClass: String, _ eventID: String) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: FourCharCode(eventClass),
            eventID: FourCharCode(eventID),
            targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }

    private func send(_ event: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        let reply: NSAppleEventDescriptor
        do {
            reply = try event.sendEvent(options: [.waitForReply], timeout: 10)
        } catch let error as NSError {
            throw ChromeScriptingFailure.from(errorNumber: error.code, message: error.localizedDescription)
        }
        if let number = reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value, number != 0 {
            let message = reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue ?? "unknown error"
            throw ChromeScriptingFailure.from(errorNumber: Int(number), message: message)
        }
        return reply
    }

    private static func specifier(
        want: String,
        form: String,
        key: NSAppleEventDescriptor,
        container: NSAppleEventDescriptor
    ) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: FourCharCode(want)), forKeyword: FourCharCode("want"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: FourCharCode(form)), forKeyword: FourCharCode("form"))
        record.setDescriptor(key, forKeyword: FourCharCode("seld"))
        record.setDescriptor(container, forKeyword: FourCharCode("from"))
        return record.coerce(toDescriptorType: FourCharCode("obj ")) ?? record
    }
}

private extension FourCharCode {
    init(_ code: String) {
        self = code.utf8.reduce(0) { $0 << 8 | FourCharCode($1) }
    }
}
