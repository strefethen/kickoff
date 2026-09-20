import Foundation

/// Coordinates mutually exclusive monitoring and Chrome layout setup.
final class HuluOperationController {
    private let monitor: AdMonitor
    private let operationQueue: DispatchQueue
    private let prepareSetup: (ChromeSetupMode) throws -> (() throws -> Void)

    private(set) var isSettingUp = false
    private(set) var isQuitting = false
    private(set) var status = "Ready"
    private var shouldStartDefaultMonitoring = true
    var onChange: (() -> Void)?
    var onSetupFailure: ((String) -> Void)?

    var isMonitoring: Bool { monitor.isRunning }
    var monitorStatus: AdMonitorStatus { monitor.status }

    init(
        monitor: AdMonitor,
        operationQueue: DispatchQueue,
        prepareSetup: @escaping (ChromeSetupMode) throws -> (() throws -> Void)
    ) {
        self.monitor = monitor
        self.operationQueue = operationQueue
        self.prepareSetup = prepareSetup
        monitor.onStatusChange = { [weak self] next in
            guard let self, !self.isSettingUp else { return }
            self.status = next.message
            self.onChange?()
        }
    }

    func startMonitoring() {
        dispatchPrecondition(condition: .onQueue(.main))
        shouldStartDefaultMonitoring = false
        guard !isSettingUp else { return }
        monitor.start()
    }

    func stopMonitoring(completion: (() -> Void)? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        shouldStartDefaultMonitoring = false
        monitor.stopAndDrain(completion: completion)
    }

    func startDefaultMonitoringIfNeeded(accessibilityTrusted: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard shouldStartDefaultMonitoring,
              accessibilityTrusted,
              !isSettingUp,
              !isQuitting else { return }
        shouldStartDefaultMonitoring = false
        monitor.start()
    }

    func toggleMonitoring(accessibilityTrusted: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        shouldStartDefaultMonitoring = false
        if monitor.isRunning {
            monitor.stopAndDrain()
            return
        }
        guard accessibilityTrusted, !isSettingUp else { return }
        monitor.start()
    }

    func startSetup(mode: ChromeSetupMode = .split) {
        dispatchPrecondition(condition: .onQueue(.main))
        shouldStartDefaultMonitoring = false
        guard !isSettingUp else { return }
        let setup: () throws -> Void
        do {
            setup = try prepareSetup(mode)
        } catch {
            let failure = String(describing: error)
            status = "Setup failed: \(failure)"
            onChange?()
            onSetupFailure?(failure)
            return
        }
        isSettingUp = true
        status = "Stopping ad muting before Chrome setup…"
        monitor.stopAndDrain { [weak self] in
            guard let self, self.isSettingUp, !self.isQuitting else { return }
            self.status = "Setting up Chrome…"
            self.onChange?()
            self.operationQueue.async { [weak self] in
                guard let self else { return }
                let failure: String?
                do {
                    try setup()
                    failure = nil
                } catch {
                    failure = String(describing: error)
                }
                DispatchQueue.main.async { [weak self] in
                    self?.finishSetup(failure: failure)
                }
            }
        }
        // stopAndDrain clears isRunning synchronously. Publish afterward so
        // the checked menu item turns off in the same setup action.
        onChange?()
    }

    func stopForQuit(completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        shouldStartDefaultMonitoring = false
        isQuitting = true
        isSettingUp = false
        monitor.stopAndDrain(completion: completion)
    }

    private func finishSetup(failure: String?) {
        guard !isQuitting else { return }
        isSettingUp = false
        status = failure == nil ? "Chrome setup complete" : "Setup failed: \(failure!)"
        onChange?()
        if let failure { onSetupFailure?(failure) }
    }
}
