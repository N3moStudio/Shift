import Combine
import Foundation
import UIKit

@MainActor
final class ReliabilityRecorder: ObservableObject {
    @Published private(set) var run: ReliabilityRun?
    @Published private(set) var history = ReliabilityHistory()
    private let key = "locus.reliabilityRun.v1"
    private let historyKey = "locus.reliabilityHistory.v1"
    private var lastSave = Date.distantPast
    private var appActive = UIApplication.shared.applicationState == .active
    private var configuration: ReliabilityConfiguration?
    private var batteryObservers: [NSObjectProtocol] = []
    var running: Bool { run?.running == true }
    private var battery: Int? { ReliabilityRun.batteryPercent(level: UIDevice.current.batteryLevel) }
    private var charging: Bool { UIDevice.current.batteryState == .charging || UIDevice.current.batteryState == .full }
    private var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    init() {
        if let data = UserDefaults.standard.data(forKey: historyKey), data.count < 131_072,
           let restored = try? JSONDecoder().decode(ReliabilityHistory.self, from: data) {
            for result in restored.runs { history.record(result) }
        }
        if let data = UserDefaults.standard.data(forKey: key), data.count < 16_384,
           var restored = try? JSONDecoder().decode(ReliabilityRun.self, from: data) {
            restored.endAfterRelaunch()
            run = restored
            persist(force: true)
            archiveCurrent()
        }
    }
    func start(confirmedAt: Date?, configuration: ReliabilityConfiguration) {
        guard !running else { return }
        archiveCurrent()
        self.configuration = configuration
        appActive = UIApplication.shared.applicationState == .active
        run = ReliabilityRun(now: Date(), confirmedAt: confirmedAt, battery: battery, charging: charging,
                             appActive: appActive, lowPower: lowPower, configuration: configuration)
        observeBatteryChanges()
        persist(force: true)
    }
    func setAppActive(_ active: Bool, configuration: ReliabilityConfiguration) {
        appActive = active
        observe(forceSave: true, configuration: configuration)
    }
    func observe(forceSave: Bool = false, configuration: ReliabilityConfiguration? = nil) {
        guard running else { return }
        if let configuration { self.configuration = configuration }
        run?.observe(now: Date(), battery: battery, charging: charging,
                     appActive: appActive, lowPower: lowPower, configuration: self.configuration)
        persist(force: forceSave)
    }
    func confirmed(configuration: ReliabilityConfiguration) {
        guard running else { return }
        self.configuration = configuration
        run?.confirm(at: Date(), battery: battery, charging: charging,
                     appActive: appActive, lowPower: lowPower, configuration: configuration)
        persist()
    }
    func failed(configuration: ReliabilityConfiguration) {
        guard running else { return }
        self.configuration = configuration
        run?.failed(at: Date(), battery: battery, charging: charging,
                    appActive: appActive, lowPower: lowPower, configuration: configuration)
        persist(force: true)
    }
    func finish() {
        guard running else { return }
        run?.finish(at: Date(), battery: battery, charging: charging)
        batteryObservers.forEach { NotificationCenter.default.removeObserver($0) }
        batteryObservers.removeAll()
        persist(force: true)
        archiveCurrent()
    }
    func clear() { if let run, !run.running { removeResult(id: run.id) } }
    func removeResult(id: Date) {
        guard !(run?.id == id && running) else { return }
        history.remove(id: id)
        if run?.id == id { run = nil; UserDefaults.standard.removeObject(forKey: key) }
        persistHistory()
    }
    private func archiveCurrent() {
        guard let run, !run.running else { return }
        history.record(run)
        persistHistory()
    }
    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(history) else { return }
        UserDefaults.standard.set(data, forKey: historyKey)
    }
    private func observeBatteryChanges() {
        guard batteryObservers.isEmpty else { return }
        batteryObservers = [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.observe(forceSave: true) }
            }
        }
    }
    private func persist(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastSave) >= 10, let run,
              let data = try? JSONEncoder().encode(run) else { return }
        UserDefaults.standard.set(data, forKey: key)
        lastSave = Date()
    }
}
