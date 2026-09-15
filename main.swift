import SwiftUI

let battBin = "/opt/homebrew/opt/batt/bin/batt"

// Wraps a string in POSIX single quotes so the shell treats it as one literal
// argument. Critical here: the admin path runs through `do shell script ... with
// administrator privileges`, i.e. as root, and these args come from text fields.
func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

func runCommand(_ binary: String, _ args: [String], needsAdmin: Bool = true) -> String {
    let cmdString = ([binary] + args).map(shellQuote).joined(separator: " ")

    if needsAdmin {
        let escaped = cmdString.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        if let scriptObject = NSAppleScript(source: script) {
            let output = scriptObject.executeAndReturnError(&error)
            if let error = error {
                let msg = error[NSAppleScript.errorMessage] as? String ?? "Unknown error"
                return "Error: \(msg)"
            }
            return output.stringValue ?? ""
        }
        return "Error: could not build AppleScript"
    } else {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}

func runBatt(_ args: [String], needsAdmin: Bool = true) -> String {
    runCommand(battBin, args, needsAdmin: needsAdmin)
}

// Fallback for "block all sleep" when batt has no sleep hooks on this Mac: pmset's
// disablesleep is the closest system-level equivalent (there is no charging-only variant).
func runPmset(_ args: [String]) -> String {
    runCommand("/usr/bin/pmset", args, needsAdmin: true)
}

struct BattStatus: Decodable {
    struct Charging: Decodable {
        let useAdapter: Bool
        let pluggedIn: Bool
    }
    struct Battery: Decodable {
        let currentChargePercent: Int
        let state: String
        let chargeRateWatts: Double?
        let voltageVolts: Double?
    }
    struct MagSafeLed: Decodable {
        let enabled: Bool
        let mode: String
    }
    struct Configuration: Decodable {
        let enabled: Bool
        let upperLimitPercent: Int
        let lowerLimitPercent: Int
        let preventIdleSleep: Bool
        let disableChargingPreSleep: Bool
        let preventSystemSleep: Bool
        let controlMagSafeLed: MagSafeLed
    }
    struct Compatibility: Decodable {
        let chargingControl: Bool
        let sleepHooks: Bool
        let magSafeLED: Bool
        let adapterControl: Bool
        let calibration: Bool
    }
    let charging: Charging
    let battery: Battery
    let configuration: Configuration
    let compatibility: Compatibility?
}

// The hardware features batt's daemon detects; each command is gated by one (batt v0.8.0 cmd/batt).
enum Capability {
    case chargingControl, sleepHooks, magSafeLED, adapterControl, calibration
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let command: String
    let output: String
}

class BattModel: ObservableObject {
    @Published var log: [LogEntry] = []
    @Published var isBusy = false
    @Published var status: BattStatus?
    @Published var daemonReachable = true
    @Published var lastError: String?
    @Published var pmsetSleepDisabled = false

    func run(_ args: [String], needsAdmin: Bool = true) {
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runBatt(args, needsAdmin: needsAdmin)
            DispatchQueue.main.async {
                self.log.insert(LogEntry(command: "batt " + args.joined(separator: " "), output: result.isEmpty ? "(no output)" : result), at: 0)
                self.isBusy = false
                if result.hasPrefix("Error:") && !result.contains("User canceled") {
                    self.lastError = result
                }
                self.refreshStatus()
            }
        }
    }

    func refreshStatus() {
        DispatchQueue.global(qos: .utility).async {
            let raw = runBatt(["status", "--json"], needsAdmin: false)
            let decoded = raw.data(using: .utf8).flatMap { try? JSONDecoder().decode(BattStatus.self, from: $0) }
            // "SleepDisabled 1" in `pmset -g` reflects `pmset disablesleep 1`; readable without sudo.
            let pmsetOutput = runCommand("/usr/bin/pmset", ["-g"], needsAdmin: false)
            let sleepDisabled = pmsetOutput.split(separator: "\n").contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("SleepDisabled 1") }
            DispatchQueue.main.async {
                self.daemonReachable = decoded != nil
                if let decoded { self.status = decoded }
                self.pmsetSleepDisabled = sleepDisabled
            }
        }
    }

    // Like batt's own client: everything counts as supported until the daemon reports otherwise.
    func supports(_ capability: Capability?) -> Bool {
        guard let capability, let c = status?.compatibility else { return true }
        switch capability {
        case .chargingControl: return c.chargingControl
        case .sleepHooks: return c.sleepHooks
        case .magSafeLED: return c.magSafeLED
        case .adapterControl: return c.adapterControl
        case .calibration: return c.calibration
        }
    }

    func toggle(_ command: String, _ on: Bool) {
        run([command, on ? "enable" : "disable"])
    }

    // "Block all sleep while charging" falls back to `pmset disablesleep` when batt has
    // no sleep hooks on this Mac — the closest system-level equivalent, though it blocks
    // sleep unconditionally rather than only while charging.
    func toggleSystemSleepBlock(_ on: Bool) {
        if supports(.sleepHooks) {
            toggle("prevent-system-sleep", on)
            return
        }
        isBusy = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runPmset(["disablesleep", on ? "1" : "0"])
            DispatchQueue.main.async {
                self.log.insert(LogEntry(command: "pmset disablesleep \(on ? "1" : "0")", output: result.isEmpty ? "(no output)" : result), at: 0)
                self.isBusy = false
                if result.hasPrefix("Error:") && !result.contains("User canceled") {
                    self.lastError = result
                }
                self.refreshStatus()
            }
        }
    }
}

enum Page: String, Identifiable {
    case battery, adapter, chargeLimit, sleep, magsafe, calibration, log, about
    var id: String { rawValue }

    static let features: [Page] = [.battery, .adapter, .chargeLimit, .sleep, .magsafe, .calibration]

    var title: String {
        switch self {
        case .battery: return "Battery"
        case .adapter: return "Power Adapter"
        case .chargeLimit: return "Charge Limit"
        case .sleep: return "Sleep"
        case .magsafe: return "MagSafe LED"
        case .calibration: return "Calibration"
        case .log: return "Activity Log"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .battery: return "battery.100percent.bolt"
        case .adapter: return "powerplug.fill"
        case .chargeLimit: return "slider.horizontal.3"
        case .sleep: return "moon.fill"
        case .magsafe: return "lightbulb.fill"
        case .calibration: return "arrow.triangle.2.circlepath"
        case .log: return "list.bullet.rectangle"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .battery: return .green
        case .adapter: return .orange
        case .chargeLimit: return .teal
        case .sleep: return .indigo
        case .magsafe: return .yellow
        case .calibration: return .blue
        case .log, .about: return .gray
        }
    }

    var capability: Capability? {
        switch self {
        case .adapter: return .adapterControl
        case .chargeLimit: return .chargingControl
        case .sleep: return .sleepHooks
        case .magsafe: return .magSafeLED
        case .calibration: return .calibration
        case .battery, .log, .about: return nil
        }
    }
}

struct SidebarRow: View {
    let page: Page
    var dimmed = false

    var body: some View {
        Label {
            Text(page.title).foregroundStyle(dimmed ? .secondary : .primary)
        } icon: {
            Image(systemName: page.symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(dimmed ? Color.gray.opacity(0.35) : page.tint))
        }
    }
}

struct ContentView: View {
    @StateObject private var model = BattModel()
    @State private var selection: Page? = .battery

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    ForEach(Page.features.filter { model.supports($0.capability) }) { SidebarRow(page: $0).tag($0) }
                }
                let unsupported = Page.features.filter { !model.supports($0.capability) }
                if !unsupported.isEmpty {
                    Section("Not supported on this Mac") {
                        ForEach(unsupported) { SidebarRow(page: $0, dimmed: true).tag($0) }
                    }
                }
                Section {
                    SidebarRow(page: .log).tag(Page.log)
                    SidebarRow(page: .about).tag(Page.about)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            detail
                .navigationTitle(selection?.title ?? "BattGUI")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        HStack(spacing: 6) {
                            if model.isBusy { ProgressView().controlSize(.small) }
                            Circle().fill(model.daemonReachable ? Color.green : Color.red).frame(width: 7, height: 7)
                            Text(model.daemonReachable ? "batt daemon running" : "batt daemon not reachable")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
        }
        .environmentObject(model)
        .task {
            while !Task.isCancelled {
                model.refreshStatus()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .alert("Command failed", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
    }

    @ViewBuilder private var detail: some View {
        switch selection ?? .battery {
        case .battery: BatteryPage(selection: $selection)
        case .adapter: AdapterPage()
        case .chargeLimit: ChargeLimitPage()
        case .sleep: SleepPage()
        case .magsafe: MagSafePage()
        case .calibration: CalibrationPage()
        case .log: LogPage()
        case .about: AboutPage()
        }
    }
}

struct UnsupportedNotice: View {
    var body: some View {
        Label("batt reports this feature isn't supported on this Mac, so these controls are turned off.", systemImage: "exclamationmark.circle")
            .foregroundStyle(.secondary)
    }
}

struct NativeChargeLimitNote: View {
    var body: some View {
        if ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 4, patchVersion: 0)) {
            HStack(spacing: 16) {
                Text("This Mac's firmware doesn't let batt control charging. macOS has its own charge limit you can use instead.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open Battery Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                }
            }
        }
    }
}

struct BatteryGlyph: View {
    let percent: Int

    var body: some View {
        let color: Color = percent <= 20 ? .red : .green
        HStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(color, lineWidth: 3)
                .frame(width: 96, height: 48)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(color)
                        .frame(width: max(6, 80 * CGFloat(percent) / 100), height: 32)
                        .padding(.leading, 8)
                }
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4, height: 16)
        }
    }
}

struct BatteryPage: View {
    @EnvironmentObject private var model: BattModel
    @Binding var selection: Page?

    var body: some View {
        Form {
            if let s = model.status {
                Section {
                    HStack(spacing: 24) {
                        BatteryGlyph(percent: s.battery.currentChargePercent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(s.battery.currentChargePercent)%").font(.system(size: 34, weight: .bold))
                            Text("\(s.battery.state.capitalized) · \(s.charging.pluggedIn ? "Plugged in" : "On battery")")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Grid(alignment: .trailing, horizontalSpacing: 20, verticalSpacing: 4) {
                            if let v = s.battery.voltageVolts {
                                GridRow { Text("Voltage").foregroundStyle(.secondary); Text(String(format: "%.2f V", v)) }
                            }
                            if let w = s.battery.chargeRateWatts {
                                GridRow { Text("Charge rate").foregroundStyle(.secondary); Text(String(format: "%.1f W", w)) }
                            }
                        }
                        .font(.callout)
                    }
                    .padding(.vertical, 8)
                }

                Section("Power") {
                    Toggle(isOn: Binding(get: { s.charging.useAdapter }, set: { model.run(["adapter", $0 ? "enable" : "disable"]) })) {
                        Text("Use wall power")
                        Text("Turn off to run on battery while the charger stays plugged in.")
                    }
                    .disabled(!model.supports(.adapterControl))
                }

                Section {
                    LabeledContent("Stop charging at", value: "\(s.configuration.upperLimitPercent)%")
                        .disabled(!model.supports(.chargingControl))
                    if model.supports(.chargingControl) {
                        Button("Change Charge Limit…") { selection = .chargeLimit }
                    } else {
                        NativeChargeLimitNote()
                    }
                } header: {
                    HStack {
                        Text("Charge limit")
                        Spacer()
                        if !model.supports(.chargingControl) {
                            Text("Not supported on this Mac").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Section {
                    Label(model.daemonReachable ? "Loading battery status…" : "Couldn't reach the batt daemon. Start it with `sudo brew services start batt`.",
                          systemImage: model.daemonReachable ? "hourglass" : "exclamationmark.triangle")
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AdapterPage: View {
    @EnvironmentObject private var model: BattModel

    var body: some View {
        let supported = model.supports(.adapterControl)
        Form {
            if !supported { Section { UnsupportedNotice() } }
            Section {
                Toggle(isOn: Binding(get: { model.status?.charging.useAdapter ?? true }, set: { model.run(["adapter", $0 ? "enable" : "disable"]) })) {
                    Text("Use wall power")
                    Text("Cuts or restores power from the charger as if you'd unplugged it, so the battery can drain while the cable stays connected.")
                }
                LabeledContent("Charger", value: model.status?.charging.pluggedIn == true ? "Connected" : "Not connected")
            } footer: {
                Text("In clamshell mode (lid closed with an external display), cutting power puts your Mac to sleep. That's a macOS limitation.")
            }
            .disabled(!supported)
        }
        .formStyle(.grouped)
    }
}

struct ChargeLimitPage: View {
    @EnvironmentObject private var model: BattModel
    @State private var limit: Double = 80
    @State private var disableFor = ""
    @State private var lowerDelta = "2"

    var body: some View {
        let supported = model.supports(.chargingControl)
        Form {
            if !supported { Section { NativeChargeLimitNote() } }

            Section {
                HStack {
                    Slider(value: $limit, in: 10...100, step: 1) { Text("Stop charging at") }
                    Text("\(Int(limit))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                }
                HStack {
                    Spacer()
                    Button("Set Limit") { model.run(["limit", "\(Int(limit))"]) }
                }
            } header: {
                Text("Charge limit")
            } footer: {
                Text("Keeping the battery around 80% slows long-term wear. Setting 100% turns the limit off.")
            }
            .disabled(!supported)

            Section {
                Button("Charge to 100% Now") { model.run(["disable"]) }
                HStack {
                    TextField("For how long", text: $disableFor, prompt: Text("30m, 2h, 1d"))
                    Button("Charge to 100% Temporarily") { model.run(["disable", "--for=\(disableFor)"]) }
                        .disabled(disableFor.isEmpty)
                }
            } header: {
                Text("Full charge")
            } footer: {
                Text("A temporary full charge restores your limit automatically when the time runs out.")
            }
            .disabled(!supported)

            Section {
                HStack {
                    TextField("Resume charging below the limit by", text: $lowerDelta, prompt: Text("2"))
                    Text("%").foregroundStyle(.secondary)
                    Button("Set") { model.run(["lower-limit-delta", lowerDelta]) }
                }
            } header: {
                Text("Lower limit")
            } footer: {
                if let c = model.status?.configuration {
                    Text("Charging stops at \(c.upperLimitPercent)% and starts again at \(c.lowerLimitPercent)%.")
                }
            }
            .disabled(!supported)
        }
        .formStyle(.grouped)
        .onAppear { if let upper = model.status?.configuration.upperLimitPercent { limit = Double(upper) } }
    }
}

struct SleepPage: View {
    @EnvironmentObject private var model: BattModel

    var body: some View {
        let supported = model.supports(.sleepHooks)
        let c = model.status?.configuration
        Form {
            if !supported { Section { UnsupportedNotice() } }
            Section {
                Toggle(isOn: Binding(get: { c?.disableChargingPreSleep ?? false }, set: { model.toggle("disable-charging-pre-sleep", $0) })) {
                    Text("Stop charging before sleep")
                    Text("macOS pauses batt while your Mac sleeps, so this stops charging first and the battery can't pass your limit overnight.")
                }
                Toggle(isOn: Binding(get: { c?.preventIdleSleep ?? false }, set: { model.toggle("prevent-idle-sleep", $0) })) {
                    Text("Stay awake while charging")
                    Text("Keeps your Mac from idling to sleep until it reaches the limit. Closing the lid still sleeps.")
                }
            }
            .disabled(!supported)

            Section {
                Toggle(isOn: Binding(
                    get: { supported ? (c?.preventSystemSleep ?? false) : model.pmsetSleepDisabled },
                    set: { model.toggleSystemSleepBlock($0) }
                )) {
                    Text("Block all sleep while charging (experimental)")
                    if supported {
                        Text("Also blocks lid-close and menu sleep until the limit is reached. Don't combine with the two options above.")
                    } else {
                        Text("batt can't do this on this Mac, so this uses macOS's own sleep setting (pmset) instead. Unlike batt's version, it blocks sleep all the time, not just while charging — turn it back off when you don't need it.")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct MagSafePage: View {
    @EnvironmentObject private var model: BattModel

    var body: some View {
        let supported = model.supports(.magSafeLED)
        Form {
            if !supported { Section { UnsupportedNotice() } }
            Section {
                LabeledContent("Current mode", value: model.status?.configuration.controlMagSafeLed.mode.capitalized ?? "Unknown")
                HStack {
                    Spacer()
                    Button("Show Charging Status") { model.run(["magsafe-led", "enable"]) }
                    Button("Leave to macOS") { model.run(["magsafe-led", "disable"]) }
                    Button("Always Off") { model.run(["magsafe-led", "always-off"]) }
                }
            } footer: {
                Text("When batt controls the LED, green means the limit is reached and orange means charging.")
            }
            .disabled(!supported)
        }
        .formStyle(.grouped)
    }
}

struct CalibrationPage: View {
    @EnvironmentObject private var model: BattModel
    @State private var dischargeThreshold = ""
    @State private var holdDuration = ""
    @State private var cron = ""
    @State private var postpone = "1h"

    var body: some View {
        let supported = model.supports(.calibration)
        Form {
            if !supported { Section { UnsupportedNotice() } }
            Section {
                HStack {
                    Button("Start") { model.run(["calibration", "start"]) }
                    Button("Pause") { model.run(["calibration", "pause"]) }
                    Button("Resume") { model.run(["calibration", "resume"]) }
                    Button("Cancel") { model.run(["calibration", "cancel"]) }
                    Spacer()
                    Button("Show Status") { model.run(["calibration", "status"], needsAdmin: false) }
                }
            } header: {
                Text("Calibration")
            } footer: {
                Text("Discharges, charges, holds at 100%, then restores your limit, so the reported percentage stays accurate.")
            }
            .disabled(!supported)

            Section("Settings") {
                HStack {
                    TextField("Discharge down to", text: $dischargeThreshold, prompt: Text("15"))
                    Text("%").foregroundStyle(.secondary)
                    Button("Set") { model.run(["calibration", "discharge-threshold", dischargeThreshold]) }.disabled(dischargeThreshold.isEmpty)
                }
                HStack {
                    TextField("Hold at 100% for", text: $holdDuration, prompt: Text("120"))
                    Text("min").foregroundStyle(.secondary)
                    Button("Set") { model.run(["calibration", "hold-duration", holdDuration]) }.disabled(holdDuration.isEmpty)
                }
            }
            .disabled(!supported)

            Section {
                HStack {
                    TextField("Cron schedule", text: $cron, prompt: Text("0 10 1 * *"))
                    Button("Set") { model.run(["schedule", cron]) }.disabled(cron.isEmpty)
                }
                HStack {
                    TextField("Postpone next run by", text: $postpone, prompt: Text("1h"))
                    Button("Postpone") { model.run(["schedule", "postpone", postpone]) }
                }
                HStack {
                    Spacer()
                    Button("Show Schedule") { model.run(["schedule", "show"], needsAdmin: false) }
                    Button("Skip Next Run") { model.run(["schedule", "skip"]) }
                    Button("Turn Off Schedule") { model.run(["schedule", "disable"]) }
                }
            } header: {
                Text("Schedule")
            } footer: {
                Text("Cron format is minute hour day month weekday. \"0 10 1 * *\" runs at 10:00 on the first of each month.")
            }
            .disabled(!supported)
        }
        .formStyle(.grouped)
    }
}

struct LogPage: View {
    @EnvironmentObject private var model: BattModel

    var body: some View {
        Form {
            Section {
                HStack {
                    Button("Show Full Status") { model.run(["status"], needsAdmin: false) }
                    Spacer()
                    Button("Clear") { model.log.removeAll() }.disabled(model.log.isEmpty)
                }
            }
            if model.log.isEmpty {
                Section { Text("Commands you run will show up here.").foregroundStyle(.secondary) }
            }
            ForEach(model.log) { entry in
                Section {
                    Text(entry.output)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } header: {
                    HStack {
                        Text(entry.command).font(.system(.callout, design: .monospaced))
                        Spacer()
                        Text(entry.date, style: .time).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutPage: View {
    @State private var version = "…"

    var body: some View {
        Form {
            Section {
                LabeledContent("batt", value: version)
                LabeledContent("BattGUI", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                Link("batt on GitHub", destination: URL(string: "https://github.com/charlie0129/batt")!)
            } footer: {
                Text("BattGUI is a front-end for batt. Features are turned off automatically when batt reports your Mac doesn't support them.")
            }
        }
        .formStyle(.grouped)
        .task {
            let output = await Task.detached { runBatt(["version"], needsAdmin: false) }.value
            version = output.split(separator: "\n").first.map { $0.replacingOccurrences(of: "Client: ", with: "") } ?? output
        }
    }
}

// The bundle icon is static, so the Dock tile of the running app is swapped to match the
// System Settings "Icon & widget style" (as Apple's own adaptive icons do).
final class DockIconController: NSObject {
    private let light = Bundle.main.url(forResource: "AppIcon", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    private let dark = Bundle.main.url(forResource: "AppIcon-Dark", withExtension: "icns").flatMap(NSImage.init(contentsOf:))
    private var appearanceObservation: NSKeyValueObservation?

    func start() {
        update()
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in self?.update() }
        // Undocumented notification names, found in the macOS 27 shared cache.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(update),
            name: Notification.Name("NSWorkspaceIconAppearanceConfigurationDidChangeNotification"), object: nil)
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(update),
            name: Notification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    }

    @objc private func update() {
        DispatchQueue.main.async {
            NSApp.applicationIconImage = self.wantsDarkIcon ? self.dark : self.light
        }
    }

    private var wantsDarkIcon: Bool {
        // AppleIconAppearanceTheme is {Regular,Clear,Tinted}{Light,Dark,Automatic}.
        CFPreferencesAppSynchronize(kCFPreferencesAnyApplication)
        let theme = CFPreferencesCopyAppValue("AppleIconAppearanceTheme" as CFString, kCFPreferencesAnyApplication) as? String ?? ""
        if theme.hasSuffix("Dark") { return true }
        if theme.hasSuffix("Light") { return false }
        return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dockIcon = DockIconController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        dockIcon.start()
    }
}

@main
struct BattGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 1000, height: 680)
        .windowResizability(.contentMinSize)
    }
}
