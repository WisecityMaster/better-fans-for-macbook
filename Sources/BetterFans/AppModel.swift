import AppKit
import Foundation
import FanCore
import OSLog
import ServiceManagement

/// Reads the SMC off the main thread with its own connection. Unprivileged: reads only.
final class Sampler {
    struct Reading {
        var cpu: Double?
        var gpu: Double?
        var fans: [FanReading]
    }

    private let queue = DispatchQueue(label: "betterfans.sampler", qos: .utility)
    private var sensors: SensorReader?

    func read(_ done: @escaping (Reading) -> Void) {
        queue.async {
            if self.sensors == nil, let smc = try? SMC() { self.sensors = SensorReader(smc: smc) }
            let temps = self.sensors?.hottestCPUAndGPU()
            let reading = Reading(cpu: temps?.cpu, gpu: temps?.gpu, fans: self.sensors?.fans() ?? [])
            DispatchQueue.main.async { done(reading) }
        }
    }
}

/// Timeline kept apart from `AppModel` so a new sample only redraws the charts.
@MainActor
final class HistoryStore: ObservableObject {
    /// One hour at the 2 s poll rate is ~1800 samples.
    @Published private(set) var history = TemperatureHistory(window: 3600)

    func append(_ s: HistorySample) { history.append(s) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [Profile]
    @Published var selectedName: String {
        didSet {
            guard selectedName != oldValue else { return }
            if !isPreview { UserDefaults.standard.set(selectedName, forKey: "selectedProfile") }
            sendProfile()
        }
    }
    @Published var cpuTemp: Double?
    @Published var gpuTemp: Double?
    @Published var fans: [FanReading] = []
    @Published var helperStatus: HelperStatus?
    @Published var helperReachable = false
    @Published var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @Published var loginItemError: String?

    let history = HistoryStore()

    private let store = ProfileStore()
    private let sampler = Sampler()
    private let log = Logger(subsystem: "com.whitesound.betterfans", category: "poll")
    private var connection: NSXPCConnection?
    private var timer: Timer?
    private var lastPoll: Date?
    private var pendingSave: DispatchWorkItem?
    private var pendingSend: DispatchWorkItem?
    private let isPreview: Bool

    /// Must stay well under the helper's 10 s watchdog; also the history resolution.
    static let pollInterval: TimeInterval = 2

    init(preview: Bool = false) {
        isPreview = preview
        let loaded = preview ? Profile.builtIns : ProfileStore().load()
        profiles = loaded
        let saved = preview ? nil : UserDefaults.standard.string(forKey: "selectedProfile")
        selectedName = loaded.contains { $0.name == saved } ? saved! : Profile.apple.name
        guard !preview else { return }
        let t = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        t.tolerance = 0.3
        RunLoop.main.add(t, forMode: .common)
        timer = t
        poll()
    }

    // MARK: Derived state

    /// What the curve reacts to: the hottest CPU or GPU sensor.
    var temperature: Double? {
        if helperReachable, let t = helperStatus?.temperature { return t }
        return [cpuTemp, gpuTemp].compactMap { $0 }.max()
    }

    /// Fans are in manual mode but not because of our helper: another app is overriding macOS.
    var otherAppControlling: Bool {
        fans.contains { $0.mode == 1 } && helperStatus?.controlling != true
    }

    var selected: Profile { profiles.first { $0.name == selectedName } ?? .apple }

    var menuBarTitle: String {
        temperature.map { String(format: "%.0f°", $0) } ?? "–°"
    }

    /// Speed the selected profile asks for right now, as % of each fan's range.
    var targetPercent: Double? { selected.percent(at: temperature) }

    func isBuiltIn(_ name: String) -> Bool { Profile.builtIns.contains { $0.name == name } }

    /// A built-in profile the user has edited (stored as a same-name override).
    func isModifiedBuiltIn(_ p: Profile) -> Bool {
        guard let original = Profile.builtIns.first(where: { $0.name == p.name }) else { return false }
        return original != p
    }

    // MARK: Profiles

    /// Updates in memory at once; disk write and helper update are coalesced so dragging
    /// a curve point doesn't hit the disk and the SMC on every mouse event.
    func update(_ profile: Profile) {
        if let i = profiles.firstIndex(where: { $0.name == profile.name }) { profiles[i] = profile } else { profiles.append(profile) }
        scheduleSave()
        if profile.name == selectedName { scheduleSend() }
    }

    /// Copies `profile` under a free name based on `name` and selects it.
    func duplicate(_ profile: Profile, as name: String) {
        let base = name.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return }
        var candidate = base, n = 2
        while profiles.contains(where: { $0.name == candidate }) { candidate = "\(base) \(n)"; n += 1 }
        var p = profile
        p.name = candidate
        update(p)
        selectedName = candidate
    }

    /// Removes a custom profile, or restores a built-in one to its original values.
    func delete(_ name: String) {
        if let original = Profile.builtIns.first(where: { $0.name == name }) {
            update(original)
        } else {
            profiles.removeAll { $0.name == name }
            if selectedName == name { selectedName = Profile.apple.name }
            scheduleSave()
        }
    }

    private func scheduleSave() {
        guard !isPreview else { return }
        pendingSave?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            try? self.store.save(self.profiles.filter { !Profile.builtIns.contains($0) })
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Writes a pending profile edit now (used before quitting, so the last change isn't lost).
    func flushSave() {
        guard let item = pendingSave else { return }
        item.perform()
        item.cancel()
        pendingSave = nil
    }

    private func scheduleSend() {
        pendingSend?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.sendProfile() }
        pendingSend = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    // MARK: Polling

    func poll() {
        let now = Date()
        if let last = lastPoll, now.timeIntervalSince(last) > 8 {
            // A stall this long risks the helper's 10 s watchdog handing fans back to macOS.
            log.warning("poll gap \(now.timeIntervalSince(last), format: .fixed(precision: 1)) s")
        }
        lastPoll = now
        sampler.read { [weak self] r in
            guard let self else { return }
            self.cpuTemp = r.cpu
            self.gpuTemp = r.gpu
            self.fans = r.fans
            self.history.append(HistorySample(time: now, cpu: r.cpu, gpu: r.gpu, rpm: r.fans.map(\.actualRPM)))
        }
        sendProfile()
    }

    func resetToAuto() {
        remote()?.resetToAuto { _ in }
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = "No se pudo cambiar «Abrir al iniciar sesión»: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Toggle binding target: writes go through `setLaunchAtLogin` so failures surface in the menu.
    var launchAtLoginSetting: Bool {
        get { launchAtLogin }
        set { setLaunchAtLogin(newValue) }
    }

    // MARK: Live bindings for the editor
    //
    // Views bind to these (`$model.selectedCurvePoints`) instead of building `Binding(get:set:)`
    // around a profile captured in `body`: a captured getter goes stale between two writes in the
    // same event, which silently dropped the first write (e.g. a point's temperature while dragging).

    var selectedCurvePoints: [CurvePoint] {
        get { if case .curve(let c) = selected.mode { c.points } else { [] } }
        set { var p = selected; p.mode = .curve(Curve(points: newValue)); update(p) }
    }

    var selectedHysteresis: Double {
        get { selected.hysteresis }
        set { var p = selected; p.hysteresis = newValue; update(p) }
    }

    var selectedRampUp: Double {
        get { selected.rampUpRPMPerSec }
        set { var p = selected; p.rampUpRPMPerSec = newValue; update(p) }
    }

    var selectedRampDown: Double {
        get { selected.rampDownRPMPerSec }
        set { var p = selected; p.rampDownRPMPerSec = newValue; update(p) }
    }

    // MARK: XPC

    private func remote() -> FanHelperProtocol? {
        guard !isPreview else { return nil }
        if connection == nil {
            let c = NSXPCConnection(machServiceName: fanHelperMachName, options: .privileged)
            c.remoteObjectInterface = NSXPCInterface(with: FanHelperProtocol.self)
            c.invalidationHandler = { [weak self] in Task { @MainActor in self?.connection = nil; self?.helperReachable = false } }
            c.interruptionHandler = { [weak self] in Task { @MainActor in self?.helperReachable = false } }
            c.resume()
            connection = c
        }
        return connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in self?.helperReachable = false; self?.helperStatus = nil }
        } as? FanHelperProtocol
    }

    private func sendProfile() {
        guard let data = try? JSONEncoder().encode(selected) else { return }
        remote()?.apply(profile: data) { [weak self] reply in
            let status = try? JSONDecoder().decode(HelperStatus.self, from: reply)
            Task { @MainActor in
                self?.helperReachable = status != nil
                self?.helperStatus = status
            }
        }
    }

    // MARK: Preview (snapshots)

    /// Fixed sample state for `--snapshot`: no SMC, no helper, no timer.
    static func preview(selected: String = Profile.quiet.name, helper: Bool = true) -> AppModel {
        let m = AppModel(preview: true)
        m.selectedName = selected
        m.cpuTemp = 84.6
        m.gpuTemp = 71.9
        let controlling = helper && selected != Profile.apple.name
        m.helperReachable = helper
        m.helperStatus = helper ? HelperStatus(controlling: controlling, profile: selected, temperature: 84.6, lastError: nil) : nil
        let mode = controlling ? 1 : 0
        m.fans = [
            FanReading(index: 0, actualRPM: 3912, targetRPM: 3920, minRPM: 2317, maxRPM: 7826, mode: mode),
            FanReading(index: 1, actualRPM: 4087, targetRPM: 3920, minRPM: 2317, maxRPM: 7826, mode: mode),
        ]
        let now = Date()
        for i in stride(from: 1800, through: 4, by: -4) {
            let t = Double(1800 - i)
            let load = 0.5 + 0.5 * sin(t / 260) + (i < 420 && i > 240 ? 0.35 : 0)
            let cpu = 58 + 26 * load + 3 * sin(t / 9)
            let gpu = 52 + 18 * max(0, sin(t / 400)) + 1.5 * sin(t / 13)
            let rpm = 2317 + max(0, (cpu - 65) / 33) * 3500
            m.history.append(HistorySample(time: now.addingTimeInterval(-Double(i)), cpu: cpu, gpu: gpu, rpm: [rpm, rpm * 1.04]))
        }
        m.history.append(HistorySample(time: now, cpu: m.cpuTemp, gpu: m.gpuTemp, rpm: m.fans.map(\.actualRPM)))
        return m
    }
}
