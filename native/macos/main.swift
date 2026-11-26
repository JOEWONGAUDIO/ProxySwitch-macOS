import SwiftUI
import ServiceManagement
import SystemConfiguration

private let configFile = URL.applicationSupportDirectory
    .appendingPathComponent("Proxy Switch/proxies.json")

private func resource<T: Decodable>(_ name: String, as type: T.Type) -> T? {
    guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
          let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}
private let languages = resource("languages", as: [String: String].self) ?? [:]
private final class Translation: @unchecked Sendable {
    private let catalog = resource("strings", as: [String: [String: String]].self) ?? [:]
    private let lock = NSLock()
    private var strings: [String: String] = [:]

    func select(_ requested: String?) {
        let system = Locale.preferredLanguages.first?.split(separator: "-").first.map(String.init) ?? "en"
        let language = requested.flatMap { languages[$0] != nil ? $0 : nil } ?? system
        lock.lock()
        strings = language == "zh" ? [:] : catalog[language] ?? catalog["en"] ?? [:]
        lock.unlock()
    }

    func text(_ key: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return strings[key] ?? key
    }
}

private let translation = Translation()
private func tr(_ key: String) -> String { translation.text(key) }

private struct WindowMaterial: NSViewRepresentable {
    final class Backdrop: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.isOpaque = false
            window.backgroundColor = .clear
        }
    }

    func makeNSView(context: Context) -> Backdrop {
        let view = Backdrop()
        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.state = .followsWindowActiveState
        fill(view, with: sidebar)

        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 16
            glass.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.30)
            fill(view, with: glass)
        }
        return view
    }

    private func fill(_ view: NSView, with material: NSView) {
        material.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(material)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            material.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            material.topAnchor.constraint(equalTo: view.topAnchor),
            material.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    func updateNSView(_ view: Backdrop, context: Context) {}
}

struct Profile: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var name: String?
    var host = ""
    var port = 8080
    var authenticationEnabled: Bool? = false
    var httpEnabled: Bool? = true
    var httpsEnabled: Bool? = true
    var socksEnabled: Bool? = true
    var username: String? = ""
    var password: String? = ""
    var address: String { "\(host):\(port)" }
    var displayName: String {
        let label = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return label.isEmpty ? address : label
    }

    func matchesConnection(of other: Profile) -> Bool {
        var profile = self
        profile.name = other.name
        return profile == other
    }
    var protocols: [(String, String, Bool)] {
        [("HTTP", "webproxy", httpEnabled != false),
         ("HTTPS", "securewebproxy", httpsEnabled != false),
         ("SOCKS", "socksfirewallproxy", socksEnabled != false)]
    }
}
struct Options: Codable {
    var launchAtLogin: Bool? = false
    var startMinimized: Bool? = false
    var language: String?
    var appearance: String?
}
struct Store: Codable {
    var profiles: [Profile] = []
    var activeId: String?
    var settings: Options? = Options()
}
struct Failure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
enum Network {
    static func run(_ executable: String, _ args: [String], sensitive: Bool = false) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        var environment = ProcessInfo.processInfo.environment
        environment["LC_ALL"] = "C"
        process.environment = environment
        process.arguments = args
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let message = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let service = args.count > 1 ? " [\(args[1])]" : ""
            let detail = sensitive ? "" : String(message.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600))
            throw Failure(message: tr("网络命令失败") + ": \(args.first ?? executable)\(service) (\(process.terminationStatus))"
                + (detail.isEmpty ? "" : "\n" + detail))
        }
        return message
    }

    static func endpointArguments(_ profile: Profile, command: String, service: String) throws -> [String] {
        let host = profile.host.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in_addr()
        guard inet_pton(AF_INET, host, &address) == 1, (1...65535).contains(profile.port) else {
            throw Failure(message: tr("请检查 IPv4 地址、端口、协议及账号。"))
        }

        var arguments = [command, service, host, String(profile.port)]
        if profile.authenticationEnabled == true {
            guard let username = profile.username, !username.isEmpty else {
                throw Failure(message: tr("请检查 IPv4 地址、端口、协议及账号。"))
            }
            arguments += ["on", username, profile.password ?? ""]
        }
        return arguments
    }

    static func commandServiceName(displayName: String, device: String?, order: String) -> String? {
        let lines = order.split(whereSeparator: \.isNewline).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let servicePattern = #/^\([0-9]+\)\s+(.+)$/#
        let devicePattern = #/,\s*Device:\s*([^\s,)]+)/#
        var services: [(name: String, device: String?)] = []
        for (index, line) in lines.enumerated() {
            guard let match = line.wholeMatch(of: servicePattern) else { continue }
            let next = lines.dropFirst(index + 1).first ?? ""
            let interface = next.firstMatch(of: devicePattern).map { String($0.1) }
            services.append((String(match.1), interface))
        }
        if services.contains(where: { $0.name == displayName && (device == nil || $0.device == device) }) {
            return displayName
        }
        guard let device else { return nil }
        let matching = services.filter { $0.device == device }
        return matching.count == 1 ? matching[0].name : nil
    }

    static func apply(_ profile: Profile?) throws {
        let executable = "/usr/sbin/networksetup"
        guard let dynamic = SCDynamicStoreCreate(nil, "Proxy Switch" as CFString, nil, nil),
              let global = (SCDynamicStoreCopyValue(dynamic, "State:/Network/Global/IPv4" as CFString)
                  ?? SCDynamicStoreCopyValue(dynamic, "State:/Network/Global/IPv6" as CFString)) as? [String: Any],
              let id = global["PrimaryService"] as? String,
              let preferences = SCPreferencesCreate(nil, "Proxy Switch" as CFString, nil),
              let service = SCNetworkServiceCopy(preferences, id as CFString),
              let displayName = SCNetworkServiceGetName(service) as String? else {
            throw Failure(message: tr("找不到当前联网的网络服务。"))
        }
        let device = SCNetworkServiceGetInterface(service).flatMap {
            SCNetworkInterfaceGetBSDName($0) as String?
        } ?? global["PrimaryInterface"] as? String
        let order = try run(executable, ["-listnetworkserviceorder"])
        guard let name = commandServiceName(displayName: displayName, device: device, order: order) else {
            throw Failure(message: tr("找不到当前联网的网络服务。") + " [\(displayName)]")
        }
        let endpoints = try profile.map { profile in
            try profile.protocols.filter { $0.2 }.map { _, key, _ in
                (key, try endpointArguments(profile, command: "-set" + key, service: name))
            }
        } ?? []
        func isOff(_ key: String) -> Bool {
            SCPreferencesSynchronize(preferences)
            guard let current = SCNetworkServiceCopy(preferences, id as CFString),
                  let proxies = SCNetworkServiceCopyProtocol(current, kSCNetworkProtocolTypeProxies)
            else { return false }
            guard let configuration = SCNetworkProtocolGetConfiguration(proxies) as? [String: Any] else {
                return false
            }
            guard let value = configuration[key] else { return true }
            return (value as? NSNumber)?.intValue == 0
        }

        func turnOff(_ command: String, key: String) throws {
            if isOff(key) { return }
            do {
                _ = try run(executable, [command, name, "off"])
            } catch {
                guard isOff(key) else { throw error }
            }
        }

        try turnOff("-setautoproxystate", key: "ProxyAutoConfigEnable")
        try turnOff("-setproxyautodiscovery", key: "ProxyAutoDiscoveryEnable")
        for mode in ["-setftpproxystate", "-setgopherproxystate", "-setstreamingproxystate"] {
            _ = try? run(executable, [mode, name, "off"])
        }
        for (key, arguments) in endpoints {
            _ = try run(executable, arguments, sensitive: profile?.authenticationEnabled == true)
            _ = try run(executable, ["-set" + key + "state", name, "on"])
        }
        for (label, key, enabled) in (profile ?? Profile()).protocols where profile == nil || !enabled {
            try turnOff("-set" + key + "state", key: label + "Enable")
        }
    }
}
@MainActor final class Model: ObservableObject {
    @Published var store = Store()
    var explicitlyOpened = false
    @Published var busy = false
    @Published var enabled = false
    @Published var selected: String?
    @Published var error = ""
    private var storageAvailable = true
    private let file = configFile
    private var monitor: SCDynamicStore?

    init() {
        translation.select(nil)
        if FileManager.default.fileExists(atPath: file.path) {
            do { store = try JSONDecoder().decode(Store.self, from: Data(contentsOf: file)) }
            catch {
                storageAvailable = false
                self.error = tr("读取本地配置失败。")
            }
        }
        translation.select(store.settings?.language)
        var context = SCDynamicStoreContext(version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        monitor = SCDynamicStoreCreate(nil, "Proxy Switch" as CFString, { _, _, info in
            guard let info else { return }
            let model = Unmanaged<Model>.fromOpaque(info).takeUnretainedValue()
            DispatchQueue.main.async { model.refresh() }
        }, &context)
        if let monitor {
            SCDynamicStoreSetNotificationKeys(monitor, ["State:/Network/Global/Proxies"] as CFArray,
                ["Setup:/Network/Service/.*/Proxies"] as CFArray)
            SCDynamicStoreSetDispatchQueue(monitor, .main)
        }
        refresh()
    }
    private func refresh() {
        let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        let modes = ["HTTP", "HTTPS", "SOCKS"]
        let activeModes = modes.filter { (settings[$0 + "Enable"] as? Int) == 1 }
        let auto = ["ProxyAutoConfig", "ProxyAutoDiscovery", "FTP", "Gopher", "RTSP"]
            .contains { (settings[$0 + "Enable"] as? Int) == 1 }
        enabled = !activeModes.isEmpty || auto
        selected = auto || activeModes.isEmpty ? nil : store.profiles.first { profile in
            profile.protocols.filter { $0.2 }.map { $0.0 } == activeModes &&
            activeModes.allSatisfy {
                (settings[$0 + "Proxy"] as? String) == profile.host &&
                (settings[$0 + "Port"] as? Int) == profile.port
            }
        }?.id
    }
    func save(_ updated: Store) throws {
        guard storageAvailable else { throw Failure(message: tr("无法写入本地配置。")) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: file, options: .atomic)
        if store.settings?.language != updated.settings?.language {
            translation.select(updated.settings?.language)
        }
        store = updated
        refresh()
    }
    func apply(_ profile: Profile?, saving updated: Store? = nil) {
        guard !busy else { return }
        guard storageAvailable else { error = tr("无法写入本地配置。"); return }
        busy = true
        Task {
            defer { busy = false; refresh() }
            do {
                try await Task.detached { try Network.apply(profile) }.value
                var next = updated ?? store
                next.activeId = profile?.id
                try save(next)
            } catch { self.error = error.localizedDescription }
        }
    }
}

struct MainView: View {
    @ObservedObject var model: Model
    @State private var editor: Profile?
    @State private var settings = false
    @State private var selectedLanguage = "system"
    @State private var removal: Profile?
    var body: some View {
        VStack(spacing: 12) {
            if let url = Bundle.main.url(forResource: "logo", withExtension: "png"),
               let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: 82, height: 82)
            }
            Text("Proxy Switch").font(.title.bold())
            VStack(spacing: 0) {
                toolbar.padding(12)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        Section {
                            row(nil)
                            ForEach(model.store.profiles) { row($0) }
                        } header: {
                            HStack(spacing: 8) {
                                Color.clear.frame(width: 16, height: 1)
                                columns(tr("类型"), tr("服务器"), tr("认证"))
                                Color.clear.frame(width: 72, height: 1)
                            }
                            .font(.subheadline.bold()).padding(10)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .overlay(alignment: .bottom) { Divider() }
                        }
                    }
                }
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary) }
        }
        .padding(28).frame(minWidth: 640, minHeight: 410)
        .background {
            WindowMaterial().ignoresSafeArea().allowsHitTesting(false)
        }
        .disabled(model.busy)
        .sheet(item: $editor) { profile in
            Editor(profile: profile, editing: model.store.profiles.contains { $0.id == profile.id }) { edited in
                var next = model.store
                if let index = next.profiles.firstIndex(where: { $0.id == edited.id }) {
                    next.profiles[index] = edited
                } else { next.profiles.append(edited) }
                if model.selected == edited.id && !edited.matchesConnection(of: profile) {
                    model.apply(edited, saving: next)
                }
                else {
                    do { try model.save(next) } catch { model.error = error.localizedDescription }
                }
            }
        }
        .sheet(isPresented: $settings) {
            VStack(alignment: .leading, spacing: 16) {
                Text(tr("设置")).font(.title2.bold())
                Toggle(tr("登录系统后自动启动程序"), isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { value in
                        do {
                            if value { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch { model.error = error.localizedDescription }
                    }))
                Toggle(tr("启动时最小化到任务栏"), isOn: Binding(
                    get: { model.store.settings?.startMinimized == true },
                    set: { value in
                        var next = model.store
                        var options = next.settings ?? Options()
                        options.startMinimized = value
                        next.settings = options
                        do { try model.save(next) } catch { model.error = error.localizedDescription }
                    }))
                preferenceMenu(tr("语言"), selection: $selectedLanguage,
                               choices: languages.keys.sorted().map { ($0, languages[$0] ?? $0) })
                preferenceMenu(tr("外观"), selection: preference(\.appearance),
                               choices: [("light", tr("浅色")), ("dark", tr("深色"))])
                HStack {
                    Button(tr("取消")) { settings = false }.keyboardShortcut(.cancelAction)
                    Button(tr("确认")) {
                        var next = model.store
                        var options = next.settings ?? Options()
                        options.language = selectedLanguage
                        next.settings = options
                        do { try model.save(next) } catch { model.error = error.localizedDescription }
                        settings = false
                    }.keyboardShortcut(.defaultAction)
                }
            }.padding(24)
        }
        .alert(tr("操作失败"), isPresented: Binding(get: { !model.error.isEmpty },
                                               set: { if !$0 { model.error = "" } })) {
            Button(tr("好"), role: .cancel) {}
        } message: { Text(model.error) }
        .confirmationDialog(tr("删除这条代理配置？"), isPresented: Binding(
            get: { removal != nil }, set: { if !$0 { removal = nil } }), presenting: removal) { profile in
                Button(tr("删除"), role: .destructive) {
                    var next = model.store
                    next.profiles.removeAll { $0.id == profile.id }
                    if model.selected == profile.id { model.apply(nil, saving: next) }
                    else {
                        do { try model.save(next) } catch { model.error = error.localizedDescription }
                    }
                }
            }
    }
    func preferenceMenu(_ title: String, selection: Binding<String>, choices: [(String, String)]) -> some View {
        let system = tr("跟随系统")
        return HStack {
            Text(title)
            Spacer()
            Menu(choices.first { $0.0 == selection.wrappedValue }?.1 ?? system) {
                Button(system) { selection.wrappedValue = "system" }
                Divider()
                ForEach(choices, id: \.0) { choice in
                    Button(choice.1) { selection.wrappedValue = choice.0 }
                }
            }.accessibilityLabel(title)
        }.frame(minWidth: 280)
    }

    func preference(_ key: WritableKeyPath<Options, String?>) -> Binding<String> {
        Binding(get: { model.store.settings?[keyPath: key] ?? "system" }, set: { value in
            var next = model.store
            var options = next.settings ?? Options()
            options[keyPath: key] = value
            next.settings = options
            do { try model.save(next) } catch { model.error = error.localizedDescription }
        })
    }

    var toolbar: some View {
        HStack {
            Text(tr("代理配置")).font(.headline)
            Spacer()
            if model.busy { ProgressView().controlSize(.small) }
            actions
        }
    }
    var actions: some View {
        HStack {
            Button(tr("设置")) {
                selectedLanguage = model.store.settings?.language ?? "system"
                settings = true
            }
            Button(tr("新增代理"), systemImage: "plus") { editor = Profile() }
        }
    }
    func columns(_ type: String, _ address: String, _ auth: String) -> some View {
        HStack(spacing: 8) {
            Text(address).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(type).lineLimit(1).frame(width: 130, alignment: .leading)
            Text(auth).lineLimit(1).frame(width: 100, alignment: .leading)
        }
    }
    func row(_ profile: Profile?) -> some View {
        let current = profile.map { model.selected == $0.id } ?? !model.enabled
        return HStack(spacing: 8) {
            Button { model.apply(profile) } label: {
                HStack(spacing: 8) {
                    Image(systemName: current ? "checkmark.circle.fill" : "circle").frame(width: 16)
                        .foregroundStyle(current ? Color.accentColor : .secondary)
                    columns(profile?.protocols.filter { $0.2 }.map { $0.0 }.joined(separator: "/") ?? tr("无代理"),
                            profile?.displayName ?? tr("清空系统全局代理"),
                            profile.map { $0.authenticationEnabled == true ? ($0.username ?? "") : tr("否") } ?? "—")
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            HStack(spacing: 6) {
                if let profile {
                    Button { editor = profile } label: { Image(systemName: "pencil") }.help(tr("编辑"))
                    Button { removal = profile } label: { Image(systemName: "trash") }.help(tr("删除"))
                }
            }.frame(width: 72, alignment: .trailing)
        }.padding(10).background(current ? Color.accentColor.opacity(0.10) : .clear)
    }
}

struct Editor: View {
    @Environment(\.dismiss) private var dismiss
    @State var profile: Profile
    let editing: Bool
    let save: (Profile) -> Void
    @State private var port = ""
    var valid: Bool {
        var address = in_addr()
        return inet_pton(AF_INET, profile.host, &address) == 1 &&
            (1...65535).contains(Int(port) ?? 0) && profile.protocols.contains { $0.2 } &&
            (profile.authenticationEnabled != true || !(profile.username ?? "").isEmpty)
    }
    var body: some View {
        Form {
            Text(editing ? tr("编辑代理") : tr("新增代理")).font(.title2.bold())
            TextField(tr("代理名称（选填）"), text: Binding(
                get: { profile.name ?? "" }, set: { profile.name = $0 }))
            TextField(tr("代理服务器 IP 地址"), text: $profile.host)
            TextField(tr("端口"), text: $port)
            HStack {
                Toggle("HTTP", isOn: flag(\.httpEnabled, true))
                Toggle("HTTPS", isOn: flag(\.httpsEnabled, true))
                Toggle("SOCKS", isOn: flag(\.socksEnabled, true))
            }
            Toggle(tr("开启身份认证"), isOn: flag(\.authenticationEnabled, false))
            if profile.authenticationEnabled == true {
                TextField(tr("账号"), text: Binding(get: { profile.username ?? "" }, set: { profile.username = $0 }))
                SecureField(tr("密码"), text: Binding(get: { profile.password ?? "" }, set: { profile.password = $0 }))
            }
            HStack {
                Spacer()
                Button(tr("取消")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(tr("确认")) {
                    guard let value = Int(port), valid else { return }
                    profile.name = profile.name?.trimmingCharacters(in: .whitespacesAndNewlines)
                    profile.port = value
                    save(profile)
                    dismiss()
                }.keyboardShortcut(.defaultAction).disabled(!valid)
            }
        }.padding(24).frame(width: 420).onAppear { port = String(profile.port) }
    }
    func flag(_ key: WritableKeyPath<Profile, Bool?>, _ fallback: Bool) -> Binding<Bool> {
        Binding(get: { profile[keyPath: key] ?? fallback }, set: { profile[keyPath: key] = $0 })
    }
}

@main struct ProxySwitch: App {
    @StateObject private var model = Model()
    @State private var didStart = false
    static func trayImage(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }
    var body: some Scene {
        Window("Proxy Switch", id: "main") {
            MainView(model: model)
                .preferredColorScheme(model.store.settings?.appearance == "dark" ? .dark :
                                     model.store.settings?.appearance == "light" ? .light : nil)
                .onAppear {
                guard !didStart else { return }
                didStart = true
                if !model.explicitlyOpened && model.store.settings?.startMinimized == true {
                    DispatchQueue.main.async { NSApp.windows.first { $0.title == "Proxy Switch" }?.miniaturize(nil) }
                }
            }
        }.windowStyle(.hiddenTitleBar).defaultSize(width: 760, height: 520)
        MenuBarExtra {
            Tray(model: model)
        } label: {
            if let url = Bundle.main.url(forResource: model.enabled ? "tray_proxy_enabledTemplate" : "tray_no_proxyTemplate",
                                        withExtension: "png"), let image = NSImage(contentsOf: url) {
                Image(nsImage: Self.trayImage(image))
            } else {
                Image(systemName: "network")
            }
        }
    }
}
struct Tray: View {
    @ObservedObject var model: Model
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Group {
            Button(model.enabled ? tr("无代理") : tr("✓ 无代理")) { model.apply(nil) }
            ForEach(model.store.profiles) { profile in
                Button((model.selected == profile.id ? "✓ " : "") + profile.displayName) {
                    model.apply(profile)
                }
            }
        }.disabled(model.busy)
        Divider()
        Button(tr("打开主界面")) {
            model.explicitlyOpened = true
            if let window = NSApp.windows.first(where: { $0.title == "Proxy Switch" && $0.isMiniaturized }) {
                window.deminiaturize(nil)
                window.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
            NSApp.activate(ignoringOtherApps: true)
        }
        Button(tr("退出")) { NSApp.terminate(nil) }
    }
}
