import Cocoa
import Darwin
import Network
import UserNotifications

private enum DefaultsKey {
  static let repoPath = "SplitrouteRepoPath"
  static let selectedService = "SplitrouteSelectedService" // legacy
  static let selectedServices = "SplitrouteSelectedServices"
  static let authMode = "SplitrouteAuthMode"
}

private enum AuthMode: String {
  case touchIdSudo = "touchid_sudo"
  case passwordPrompt = "password_prompt"
}

private struct CommandResult {
  var exitCode: Int32
  var output: String
}

private final class OutputPopoverViewController: NSViewController {
  private let titleText: String
  private let attributedText: NSAttributedString
  private let onClose: () -> Void

  init(title: String, text: NSAttributedString, onClose: @escaping () -> Void) {
    self.titleText = title
    self.attributedText = text
    self.onClose = onClose
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func loadView() {
    let titleLabel = NSTextField(labelWithString: titleText)
    titleLabel.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
    titleLabel.textColor = .labelColor
    titleLabel.lineBreakMode = .byTruncatingTail

    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.isRichText = true
    textView.textColor = .labelColor
    textView.backgroundColor = .textBackgroundColor
    textView.textStorage?.setAttributedString(attributedText)
    textView.minSize = .init(width: 0, height: 0)
    textView.maxSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainerInset = .init(width: 8, height: 8)
    textView.textContainer?.containerSize = .init(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = true

    let scrollView = NSScrollView()
    scrollView.borderType = .bezelBorder
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.documentView = textView

    let okButton = NSButton(title: "OK", target: self, action: #selector(closeAction))
    okButton.bezelStyle = .rounded
    okButton.keyEquivalent = "\r"

    let buttonRow = NSStackView(views: [NSView(), okButton])
    buttonRow.orientation = .horizontal
    buttonRow.alignment = .centerY
    buttonRow.distribution = .fill

    let stack = NSStackView(views: [titleLabel, scrollView, buttonRow])
    stack.orientation = .vertical
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

    let container = NSView()
    container.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      stack.topAnchor.constraint(equalTo: container.topAnchor),
      stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    view = container
    preferredContentSize = NSSize(width: 620, height: 440)
  }

  @objc private func closeAction() {
    onClose()
  }
}

private struct SplitroutePaths {
  var repoRoot: URL
  var scriptsDir: URL { repoRoot.appendingPathComponent("scripts", isDirectory: true) }
  var servicesDir: URL { repoRoot.appendingPathComponent("services", isDirectory: true) }
  var onScript: URL { scriptsDir.appendingPathComponent("splitroute_on.sh") }
  var offScript: URL { scriptsDir.appendingPathComponent("splitroute_off.sh") }
  var checkScript: URL { scriptsDir.appendingPathComponent("splitroute_check.sh") }
}

private func shellEscape(_ s: String) -> String {
  "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

private func appleScriptEscape(_ s: String) -> String {
  s
    .replacingOccurrences(of: "\\", with: "\\\\")
    .replacingOccurrences(of: "\"", with: "\\\"")
    .replacingOccurrences(of: "\n", with: "\\n")
}

private func sudoPamHasTouchId() -> Bool {
  guard let data = FileManager.default.contents(atPath: "/etc/pam.d/sudo"),
        let text = String(data: data, encoding: .utf8)
  else { return false }

  for line in text.split(separator: "\n") {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
    if trimmed.contains("pam_tid.so") { return true }
  }
  return false
}

private final class SplitrouteRunner {
  private let defaultPath = "/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

  func runViaAppleScriptAsRoot(scriptURL: URL, service: String, extraArgs: [String] = []) -> Result<CommandResult, Error> {
    let cmd = [
      "PATH=\(shellEscape(defaultPath))",
      "SERVICE=\(shellEscape(service))",
      shellEscape(scriptURL.path),
    ] + extraArgs.map(shellEscape) + ["2>&1"]

    let shellCommand = cmd.joined(separator: " ")
    let appleScript = """
    do shell script "\(appleScriptEscape(shellCommand))" with administrator privileges
    """

    var error: NSDictionary?
    guard let script = NSAppleScript(source: appleScript) else {
      return .failure(NSError(domain: "SplitrouteMenuBar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create AppleScript"]))
    }
    let output = script.executeAndReturnError(&error).stringValue ?? ""
    if let error {
      let message = (error[NSAppleScript.errorMessage] as? String) ?? "AppleScript error"
      return .failure(NSError(domain: "SplitrouteMenuBar", code: 2, userInfo: [NSLocalizedDescriptionKey: message]))
    }
    return .success(.init(exitCode: 0, output: output))
  }

  func runViaSudoWithPTY(scriptURL: URL, service: String, extraArgs: [String] = [], timeoutSeconds: TimeInterval = 90) -> Result<CommandResult, Error> {
    let envArgs = [
      "PATH=\(defaultPath)",
      "SERVICE=\(service)",
    ]

    let args = ["--", "/usr/bin/env"] + envArgs + [scriptURL.path] + extraArgs
    return runPTY(executable: "/usr/bin/sudo", arguments: args, timeoutSeconds: timeoutSeconds)
  }

  private func runPTY(executable: String, arguments: [String], timeoutSeconds: TimeInterval) -> Result<CommandResult, Error> {
    var masterFD: Int32 = -1
    var slaveFD: Int32 = -1
    if openpty(&masterFD, &slaveFD, nil, nil, nil) != 0 {
      return .failure(NSError(domain: "SplitrouteMenuBar", code: 10, userInfo: [NSLocalizedDescriptionKey: "openpty failed"]))
    }

    let masterHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: true)
    let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardInput = slaveHandle
    process.standardOutput = slaveHandle
    process.standardError = slaveHandle

    var outData = Data()
    let lock = NSLock()
    masterHandle.readabilityHandler = { (handle: FileHandle) in
      let chunk = handle.availableData
      if chunk.isEmpty { return }
      lock.lock()
      outData.append(chunk)
      lock.unlock()
    }

    let done = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in done.signal() }

    do {
      try process.run()
    } catch {
      masterHandle.readabilityHandler = nil
      return .failure(error)
    }
    try? slaveHandle.close()

    let waitResult = done.wait(timeout: .now() + timeoutSeconds)
    if waitResult == .timedOut {
      process.terminate()
      _ = done.wait(timeout: .now() + 5)
      masterHandle.readabilityHandler = nil
      return .failure(NSError(domain: "SplitrouteMenuBar", code: 11, userInfo: [NSLocalizedDescriptionKey: "Command timed out (sudo may be waiting for password input)."]))
    }

    masterHandle.readabilityHandler = nil
    let remaining = (try? masterHandle.readToEnd()) ?? Data()
    lock.lock()
    outData.append(remaining)
    lock.unlock()

    let text = String(data: outData, encoding: .utf8) ?? ""
    return .success(.init(exitCode: process.terminationStatus, output: text))
  }
}

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate {
  private let runner = SplitrouteRunner()

  private var statusItem: NSStatusItem?
  private var outputPopover: NSPopover?
  private var isBusy = false
  private var pathMonitor: NWPathMonitor?
  private var lastPathDescription = ""
  private var networkDebounceWork: DispatchWorkItem?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem?.button {
      button.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "splitroute")
      button.image?.isTemplate = true
      button.toolTip = "splitroute"
    }

    updateStatusIcon()
    rebuildMenu()
    requestNotificationAuthorizationIfNeeded()
    cleanupStaleSplitrouteStateIfNeeded()
    startNetworkMonitor()
  }

  func menuWillOpen(_ menu: NSMenu) {
    updateStatusIcon()
    rebuildMenu()
  }

  private func defaults() -> UserDefaults { .standard }

  // MARK: - Status icon

  private func isRoutingActive() -> Bool {
    if !servicesFromStateFiles(suffix: "_routes.txt").isEmpty { return true }
    if !servicesFromManagedResolvers().isEmpty { return true }
    return false
  }

  private func servicesFromStateFiles(suffix: String) -> [String] {
    let tmpDir = URL(fileURLWithPath: "/tmp", isDirectory: true)
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: tmpDir,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else { return [] }

    var services = Set<String>()
    for entry in entries {
      guard let service = serviceNameFromStateFile(entry.lastPathComponent, suffix: suffix) else { continue }
      services.insert(service)
    }
    return services.sorted()
  }

  private func serviceNameFromStateFile(_ name: String, suffix: String) -> String? {
    let prefix = "splitroute_"
    guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { return nil }

    let start = name.index(name.startIndex, offsetBy: prefix.count)
    let end = name.index(name.endIndex, offsetBy: -suffix.count)
    guard start < end else { return nil }

    let service = String(name[start..<end])
    guard !service.isEmpty else { return nil }
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    guard service.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
    return service
  }

  private func servicesFromManagedResolvers() -> [String] {
    let resolverDir = URL(fileURLWithPath: "/etc/resolver", isDirectory: true)
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: resolverDir,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }

    var services = Set<String>()
    for entry in entries {
      guard (try? entry.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
      guard let text = try? String(contentsOf: entry, encoding: .utf8) else { continue }

      for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let markerRange = line.range(of: "splitroute_managed:") else { continue }
        let suffix = line[markerRange.upperBound...]
        guard let token = suffix.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "#" }).first else { continue }
        let service = String(token)
        guard !service.isEmpty else { continue }
        services.insert(service)
      }
    }
    return services.sorted()
  }

  private func requestNotificationAuthorizationIfNeeded() {
    let center = UNUserNotificationCenter.current()
    center.getNotificationSettings { settings in
      guard settings.authorizationStatus == .notDetermined else { return }
      center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
  }

  private func cleanupStaleSplitrouteStateIfNeeded() {
    guard getRepoRoot() != nil else { return }

    let routeStateServices = servicesFromStateFiles(suffix: "_routes.txt")
    let resolverStateServices = servicesFromStateFiles(suffix: "_resolvers.txt")
    let resolverServices = servicesFromManagedResolvers()

    let staleServices = Set(routeStateServices + resolverStateServices + resolverServices).sorted()
    guard !staleServices.isEmpty else { return }

    runPrivileged(actionName: "RESET stale state", script: .off, services: staleServices) { _ in [] }
  }

  private func isHotspotReachable() -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/sbin/ipconfig")
    proc.arguments = ["getoption", "en0", "router"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
      proc.waitUntilExit()
    } catch { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let gw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return !gw.isEmpty
  }

  private func routeGoesToWifi(host: String) -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/sbin/route")
    proc.arguments = ["-n", "get", host]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
      try proc.run()
      proc.waitUntilExit()
    } catch { return false }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let output = String(data: data, encoding: .utf8) ?? ""
    for line in output.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmed.hasPrefix("interface:") {
        let iface = trimmed.replacingOccurrences(of: "interface:", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        return iface == "en0"
      }
    }
    return false
  }

  private func updateStatusIcon() {
    guard let button = statusItem?.button else { return }
    let active = isRoutingActive()

    if !active {
      button.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "splitroute — OFF")
      button.image?.isTemplate = true
      button.toolTip = "splitroute — OFF"
      return
    }

    let hotspot = isHotspotReachable()
    if hotspot {
      let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "splitroute — ON")
      let config = NSImage.SymbolConfiguration(paletteColors: [.systemGreen])
      button.image = img?.withSymbolConfiguration(config)
      button.image?.isTemplate = false
      button.toolTip = "splitroute — ON"
    } else {
      let img = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "splitroute — no hotspot")
      let config = NSImage.SymbolConfiguration(paletteColors: [.systemYellow])
      button.image = img?.withSymbolConfiguration(config)
      button.image?.isTemplate = false
      button.toolTip = "splitroute — ON (no hotspot)"
    }
  }

  // MARK: - Network monitor (event-driven, no polling)

  private func startNetworkMonitor() {
    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      let desc = path.availableInterfaces.map { $0.name }.sorted().joined(separator: ",")
      DispatchQueue.main.async {
        self?.handleNetworkPathUpdate(interfaceDesc: desc)
      }
    }
    monitor.start(queue: DispatchQueue(label: "splitroute.network-monitor"))
    pathMonitor = monitor
  }

  private func handleNetworkPathUpdate(interfaceDesc: String) {
    guard interfaceDesc != lastPathDescription else { return }
    let wasFirst = lastPathDescription.isEmpty
    lastPathDescription = interfaceDesc

    updateStatusIcon()

    // Skip notification on first observation (launch)
    guard !wasFirst else { return }
    guard isRoutingActive() else { return }

    // Debounce: wait 5s before showing notification
    networkDebounceWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      self?.showNetworkChangeNotification()
    }
    networkDebounceWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
  }

  private func showNetworkChangeNotification() {
    let center = UNUserNotificationCenter.current()
    center.delegate = self

    let content = UNMutableNotificationContent()
    content.title = "splitroute"
    content.body = "Network change detected. Refresh routing?"
    content.categoryIdentifier = "NETWORK_CHANGE"

    let refreshAction = UNNotificationAction(identifier: "REFRESH", title: "Refresh", options: [])
    let category = UNNotificationCategory(identifier: "NETWORK_CHANGE", actions: [refreshAction], intentIdentifiers: [], options: [])
    center.setNotificationCategories([category])

    let request = UNNotificationRequest(identifier: "network-change-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
    center.add(request)
  }

  // MARK: - Repo & services

  private func getRepoRoot() -> URL? {
    if let s = defaults().string(forKey: DefaultsKey.repoPath), !s.isEmpty {
      let url = URL(fileURLWithPath: s, isDirectory: true)
      if FileManager.default.fileExists(atPath: url.appendingPathComponent("scripts/splitroute_on.sh").path) {
        return url
      }
    }

    var url = Bundle.main.bundleURL.deletingLastPathComponent()
    for _ in 0..<8 {
      let candidate = url.appendingPathComponent("scripts/splitroute_on.sh").path
      if FileManager.default.fileExists(atPath: candidate) { return url }
      url.deleteLastPathComponent()
    }
    return nil
  }

  private func setRepoRoot(_ url: URL) {
    defaults().set(url.path, forKey: DefaultsKey.repoPath)
  }

  private func storedSelectedServices() -> [String]? {
    if let list = defaults().array(forKey: DefaultsKey.selectedServices) as? [String] {
      return list
    }
    if let legacy = defaults().string(forKey: DefaultsKey.selectedService), !legacy.isEmpty {
      return [legacy]
    }
    return nil
  }

  private func selectedServices(paths: SplitroutePaths) -> [String] {
    let services = allServices(paths: paths)
    guard let stored = storedSelectedServices() else { return services }
    let storedSet = Set(stored)
    return services.filter { storedSet.contains($0) }
  }

  private func setSelectedServices(_ services: [String]) {
    defaults().set(services, forKey: DefaultsKey.selectedServices)
    defaults().removeObject(forKey: DefaultsKey.selectedService)
  }

  private func authMode() -> AuthMode {
    if let raw = defaults().string(forKey: DefaultsKey.authMode), let m = AuthMode(rawValue: raw) {
      return m
    }
    return sudoPamHasTouchId() ? .touchIdSudo : .passwordPrompt
  }

  private func setAuthMode(_ mode: AuthMode) {
    defaults().set(mode.rawValue, forKey: DefaultsKey.authMode)
  }

  private enum ScriptKind {
    case on
    case off
    case checkNoCurl
    case refresh
  }

  private func scriptURL(paths: SplitroutePaths, kind: ScriptKind) -> URL {
    switch kind {
    case .on, .refresh: return paths.onScript
    case .off: return paths.offScript
    case .checkNoCurl: return paths.checkScript
    }
  }

  private func scriptArgs(kind: ScriptKind) -> [String] {
    switch kind {
    case .checkNoCurl:
      return ["--no-curl"]
    case .on, .off, .refresh:
      return []
    }
  }

  private func ensureRepoRootOrPrompt() -> SplitroutePaths? {
    if let root = getRepoRoot() {
      return .init(repoRoot: root)
    }
    chooseRepoPath(nil)
    return nil
  }

  private func allServices(paths: SplitroutePaths) -> [String] {
    guard let entries = try? FileManager.default.contentsOfDirectory(at: paths.servicesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
      return []
    }
    let dirs = entries.compactMap { url -> String? in
      let name = url.lastPathComponent
      guard !name.hasPrefix("_") else { return nil }
      guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return nil }
      return name
    }
    return dirs.sorted()
  }

  private func rebuildMenu() {
    let menu = NSMenu()
    menu.delegate = self

    let active = isRoutingActive()
    let titleLabel = active ? "splitroute — ON" : "splitroute — OFF"
    let titleItem = NSMenuItem(title: titleLabel, action: nil, keyEquivalent: "")
    titleItem.isEnabled = false
    menu.addItem(titleItem)

    menu.addItem(.separator())

    // ON / OFF
    if active {
      let off = NSMenuItem(title: "Turn OFF", action: #selector(turnOff), keyEquivalent: "f")
      off.target = self
      menu.addItem(off)
    } else {
      let on = NSMenuItem(title: "Turn ON", action: #selector(turnOnNow), keyEquivalent: "o")
      on.target = self
      menu.addItem(on)
    }

    let refresh = NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r")
    refresh.target = self
    menu.addItem(refresh)

    menu.addItem(.separator())

    let check = NSMenuItem(title: "Check connections", action: #selector(checkConnections), keyEquivalent: "s")
    check.target = self
    menu.addItem(check)

    menu.addItem(.separator())

    // Services submenu
    if let paths = getRepoRoot().map({ SplitroutePaths(repoRoot: $0) }) {
      let serviceItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
      serviceItem.submenu = buildServiceMenu(paths: paths)
      menu.addItem(serviceItem)
    }

    // Settings submenu
    let settingsItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
    settingsItem.submenu = buildSettingsMenu()
    menu.addItem(settingsItem)

    menu.addItem(.separator())

    let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
    helpItem.submenu = buildHelpMenu()
    menu.addItem(helpItem)

    let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)

    if isBusy {
      for item in menu.items {
        if item.submenu != nil { continue }
        if item.action != #selector(quitApp) && item.action != #selector(chooseRepoPath) {
          item.isEnabled = false
        }
      }
    }

    statusItem?.menu = menu
  }

  private func buildSettingsMenu() -> NSMenu {
    let menu = NSMenu()

    let authItem = NSMenuItem(title: "Authorization", action: nil, keyEquivalent: "")
    authItem.submenu = buildAuthMenu()
    menu.addItem(authItem)

    menu.addItem(.separator())

    let repoItem = NSMenuItem(title: "Set Repo Path…", action: #selector(chooseRepoPath), keyEquivalent: ",")
    repoItem.target = self
    menu.addItem(repoItem)

    return menu
  }

  private func buildServiceMenu(paths: SplitroutePaths) -> NSMenu {
    let menu = NSMenu()
    let services = allServices(paths: paths)
    let selected = Set(selectedServices(paths: paths))

    let addItem = NSMenuItem(title: "Add Service…", action: #selector(addServicePrompt), keyEquivalent: "")
    addItem.target = self
    menu.addItem(addItem)

    let selectAll = NSMenuItem(title: "Select all", action: #selector(selectAllServices), keyEquivalent: "")
    selectAll.target = self
    menu.addItem(selectAll)

    let selectNone = NSMenuItem(title: "Select none", action: #selector(selectNoServices), keyEquivalent: "")
    selectNone.target = self
    menu.addItem(selectNone)

    menu.addItem(.separator())

    if services.isEmpty {
      let item = NSMenuItem(title: "(no services found)", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
      return menu
    }

    for s in services {
      let item = NSMenuItem(title: s, action: #selector(toggleService(_:)), keyEquivalent: "")
      item.target = self
      item.state = selected.contains(s) ? .on : .off
      item.representedObject = s
      menu.addItem(item)
    }

    menu.addItem(.separator())

    let openHosts = NSMenuItem(title: "Edit hosts.txt…", action: #selector(openHostsFile), keyEquivalent: "")
    openHosts.target = self
    menu.addItem(openHosts)

    let openDns = NSMenuItem(title: "Edit dns_domains.txt…", action: #selector(openDnsDomainsFile), keyEquivalent: "")
    openDns.target = self
    menu.addItem(openDns)

    return menu
  }

  private func buildAuthMenu() -> NSMenu {
    let menu = NSMenu()
    let current = authMode()

    let tid = NSMenuItem(title: "Touch ID (sudo)", action: #selector(selectAuthMode(_:)), keyEquivalent: "")
    tid.target = self
    tid.representedObject = AuthMode.touchIdSudo.rawValue
    tid.state = (current == .touchIdSudo) ? .on : .off
    menu.addItem(tid)

    let pw = NSMenuItem(title: "Password prompt (system dialog)", action: #selector(selectAuthMode(_:)), keyEquivalent: "")
    pw.target = self
    pw.representedObject = AuthMode.passwordPrompt.rawValue
    pw.state = (current == .passwordPrompt) ? .on : .off
    menu.addItem(pw)

    if current == .touchIdSudo && !sudoPamHasTouchId() {
      let warn = NSMenuItem(title: "Note: pam_tid not enabled in /etc/pam.d/sudo", action: nil, keyEquivalent: "")
      warn.isEnabled = false
      menu.addItem(.separator())
      menu.addItem(warn)
    }

    return menu
  }

  private func helpMenuItem(title: String, action: Selector) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    return item
  }

  private func buildHelpMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(helpMenuItem(title: "Quick start", action: #selector(showHelpQuickStart)))
    menu.addItem(.separator())
    menu.addItem(helpMenuItem(title: "Turn ON — enables routing", action: #selector(showHelpOn)))
    menu.addItem(helpMenuItem(title: "Turn OFF — disables routing", action: #selector(showHelpOff)))
    menu.addItem(helpMenuItem(title: "Refresh — updates IP addresses", action: #selector(showHelpRefresh)))
    menu.addItem(helpMenuItem(title: "Check — tests connections", action: #selector(showHelpStatus)))
    menu.addItem(.separator())
    menu.addItem(helpMenuItem(title: "Services — selecting services", action: #selector(showHelpServices)))
    menu.addItem(helpMenuItem(title: "Summary — what results mean", action: #selector(showHelpSummary)))
    menu.addItem(helpMenuItem(title: "Troubleshooting", action: #selector(showHelpTroubleshooting)))
    return menu
  }

  @objc private func toggleService(_ sender: NSMenuItem) {
    guard let s = sender.representedObject as? String else { return }
    guard let paths = ensureRepoRootOrPrompt() else { return }
    let services = allServices(paths: paths)
    var selected = Set(selectedServices(paths: paths))
    if selected.contains(s) {
      selected.remove(s)
    } else {
      selected.insert(s)
    }
    let ordered = services.filter { selected.contains($0) }
    setSelectedServices(ordered)
    rebuildMenu()
  }

  @objc private func selectAllServices() {
    guard let paths = ensureRepoRootOrPrompt() else { return }
    setSelectedServices(allServices(paths: paths))
    rebuildMenu()
  }

  @objc private func selectNoServices() {
    setSelectedServices([])
    rebuildMenu()
  }

  @objc private func addServicePrompt() {
    guard let paths = ensureRepoRootOrPrompt() else { return }

    let alert = NSAlert()
    alert.messageText = "Add Service"
    alert.informativeText = "Enter a domain (e.g. example.com or www.example.com)."

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    input.placeholderString = "example.com"
    alert.accessoryView = input
    alert.addButton(withTitle: "Discover hosts")
    alert.addButton(withTitle: "Create basic")
    alert.addButton(withTitle: "Cancel")

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    guard response != .alertThirdButtonReturn else { return }

    guard let baseDomain = normalizeDomainInput(input.stringValue) else {
      showInfo(title: "Invalid domain", text: "Please enter a domain like example.com or www.example.com.")
      return
    }

    let serviceName = baseDomain
    let serviceDir = paths.servicesDir.appendingPathComponent(serviceName, isDirectory: true)
    if FileManager.default.fileExists(atPath: serviceDir.path) {
      let services = allServices(paths: paths)
      var selected = Set(selectedServices(paths: paths))
      selected.insert(serviceName)
      let ordered = services.filter { selected.contains($0) }
      setSelectedServices(ordered)
      rebuildMenu()
      showInfo(title: "Service exists", text: "Service '\(serviceName)' already exists and is now selected.")
      runPrivileged(actionName: "ON", script: .on, services: [serviceName]) { _ in [] }
      return
    }

    if response == .alertFirstButtonReturn {
      // Smart Host Discovery (opt-in)
      let privacyAlert = NSAlert()
      privacyAlert.messageText = "Host Discovery"
      privacyAlert.informativeText = "To discover subdomains, the app will:\n\u{2022} Query crt.sh (public certificate transparency log)\n\u{2022} Check ~10 common DNS prefixes (api, www, auth, etc.)\n\nThis sends network requests. Continue?"
      privacyAlert.addButton(withTitle: "Continue")
      privacyAlert.addButton(withTitle: "Cancel")
      guard privacyAlert.runModal() == .alertFirstButtonReturn else { return }

      DispatchQueue.global(qos: .userInitiated).async {
        self.discoverSubdomains(baseDomain: baseDomain) { subdomains in
          DispatchQueue.main.async {
            if subdomains.isEmpty {
              self.showInfo(title: "No hosts found", text: "Could not discover subdomains. Creating basic service.")
              do {
                try self.createServiceFiles(serviceDir: serviceDir, baseDomain: baseDomain)
              } catch {
                self.showInfo(title: "Create failed", text: error.localizedDescription)
                return
              }
              self.selectAndEnableService(serviceName, paths: paths)
            } else {
              self.showDiscoveryResults(baseDomain: baseDomain, subdomains: subdomains, paths: paths)
            }
          }
        }
      }
    } else {
      // Basic create (no discovery)
      do {
        try createServiceFiles(serviceDir: serviceDir, baseDomain: baseDomain)
      } catch {
        showInfo(title: "Create failed", text: "Could not create service files: \(error.localizedDescription)")
        return
      }
      selectAndEnableService(serviceName, paths: paths)
    }
  }

  private func selectAndEnableService(_ serviceName: String, paths: SplitroutePaths) {
    let services = allServices(paths: paths)
    var selected = Set(selectedServices(paths: paths))
    selected.insert(serviceName)
    let ordered = services.filter { selected.contains($0) }
    setSelectedServices(ordered)
    rebuildMenu()
    runPrivileged(actionName: "ON", script: .on, services: [serviceName]) { _ in [] }
  }

  @objc private func selectAuthMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let mode = AuthMode(rawValue: raw) else { return }
    setAuthMode(mode)
    rebuildMenu()
  }

  @objc private func showHelpQuickStart() {
    let body = """
1) Connect your hotspot (Wi-Fi) and main internet (LAN).
2) Go to Services and select which services to route.
3) Click Turn ON.
4) Use Check connections to verify routing.
5) If something stops working → Refresh.
6) Turn OFF restores normal routing.
"""
    showHelp(title: "Quick start", body: body)
  }

  @objc private func showHelpOn() {
    let body = """
Turn ON enables split-routing.
- Traffic to selected services goes through your hotspot.
- Requires admin password (sudo).
"""
    showHelp(title: "Turn ON", body: body)
  }

  @objc private func showHelpOff() {
    let body = """
Turn OFF disables split-routing.
- All traffic returns to default route.
"""
    showHelp(title: "Turn OFF", body: body)
  }

  @objc private func showHelpRefresh() {
    let body = """
Refresh re-resolves all hostnames and updates routes.
- Use after a network change or when a service stops working.
"""
    showHelp(title: "Refresh", body: body)
  }

  @objc private func showHelpStatus() {
    let body = """
Check connections verifies routing for each service.
- Does not change anything.
- Shows whether traffic goes through hotspot.
"""
    showHelp(title: "Check connections", body: body)
  }

  @objc private func showHelpServices() {
    let body = """
Services lets you choose which services to route through your hotspot.
- Selections are remembered between sessions.
- Add Service creates a new service from a domain name.
- If something doesn't work, try adding more hosts in hosts.txt.
"""
    showHelp(title: "Services", body: body)
  }

  @objc private func showHelpSummary() {
    let body = """
OK: everything works — traffic goes through hotspot.
WARNING: works, but something may be limited.
PROBLEM: not working (e.g. hotspot disconnected or DNS issue).
"""
    showHelp(title: "Summary", body: body)
  }

  @objc private func showHelpTroubleshooting() {
    let body = """
Common issues and quick fixes:
- Hotspot not connected: connect to hotspot, click Refresh.
- DNS not resolving: enable DNS override and click Refresh.
- Some addresses not routed: add more hosts to hosts.txt, click Refresh.
"""
    showHelp(title: "Troubleshooting", body: body)
  }

  @objc private func chooseRepoPath(_ sender: Any?) {
    let panel = NSOpenPanel()
    panel.title = "Select splitroute repo folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false

    if panel.runModal() == .OK, let url = panel.url {
      let needed = url.appendingPathComponent("scripts/splitroute_on.sh").path
      if FileManager.default.fileExists(atPath: needed) {
        setRepoRoot(url)
        rebuildMenu()
      } else {
        showInfo(title: "Invalid folder", text: "Selected folder does not look like splitroute repo (missing scripts/splitroute_on.sh).")
      }
    }
  }

  @objc private func openHostsFile() {
    guard let paths = ensureRepoRootOrPrompt() else { return }
    let services = selectedServices(paths: paths)
    guard !services.isEmpty else {
      showInfo(title: "No services selected", text: "Select at least one service to open its hosts.txt.")
      return
    }
    for svc in services {
      let file = paths.servicesDir.appendingPathComponent("\(svc)/hosts.txt")
      NSWorkspace.shared.open(file)
    }
  }

  @objc private func openDnsDomainsFile() {
    guard let paths = ensureRepoRootOrPrompt() else { return }
    let services = selectedServices(paths: paths)
    guard !services.isEmpty else {
      showInfo(title: "No services selected", text: "Select at least one service to open its dns_domains.txt.")
      return
    }
    for svc in services {
      let file = paths.servicesDir.appendingPathComponent("\(svc)/dns_domains.txt")
      NSWorkspace.shared.open(file)
    }
  }

  @objc private func turnOnNow() {
    guard let paths = ensureRepoRootOrPrompt() else { return }
    let services = selectedServices(paths: paths)
    guard !services.isEmpty else {
      showInfo(title: "No services selected", text: "Select at least one service to turn ON.")
      return
    }
    runPrivileged(actionName: "ON", script: .on, services: services) { _ in [] }
  }

  @objc private func turnOff() {
    guard let paths = ensureRepoRootOrPrompt() else { return }
    let services = selectedServices(paths: paths)
    guard !services.isEmpty else {
      showInfo(title: "No services selected", text: "Select at least one service to turn OFF.")
      return
    }
    runPrivileged(actionName: "OFF", script: .off, services: services) { _ in [] }
  }

  @objc private func refreshNow() {
    guard let paths = ensureRepoRootOrPrompt() else { return }
    let services = selectedServices(paths: paths)
    guard !services.isEmpty else {
      showInfo(title: "No services selected", text: "Select at least one service to refresh.")
      return
    }
    runPrivileged(actionName: "REFRESH", script: .refresh, services: services) { _ in [] }
  }

  @objc private func checkConnections() {
    guard let paths = ensureRepoRootOrPrompt() else { return }
    let services = selectedServices(paths: paths)
    guard !services.isEmpty else {
      showInfo(title: "No services selected", text: "Select at least one service to check.")
      return
    }

    var targets: [String: String] = [:]
    var skipped: [String] = []
    for svc in services {
      if let host = primaryHostForService(service: svc, paths: paths) {
        targets[svc] = host
      } else {
        skipped.append(svc)
      }
    }

    guard !targets.isEmpty else {
      showInfo(title: "Check unavailable", text: "No valid hosts found in dns_domains.txt or hosts.txt for selected services.")
      return
    }

    var prefix = ""
    if !skipped.isEmpty {
      prefix = "SKIPPED (no hosts): \(skipped.joined(separator: ", "))\n\n"
    }

    let ordered = services.filter { targets.keys.contains($0) }
    runPrivileged(actionName: "CHECK", script: .checkNoCurl, services: ordered, outputPrefix: prefix) { svc in
      let host = targets[svc] ?? ""
      return ["--no-curl", "--host", host]
    }
  }

  @objc private func quitApp() {
    NSApp.terminate(nil)
  }

  private func runPrivileged(
    actionName: String,
    script: ScriptKind,
    services: [String],
    outputPrefix: String = "",
    extraArgsProvider: @escaping (String) -> [String]
  ) {
    guard !isBusy else { return }
    guard let paths = ensureRepoRootOrPrompt() else { return }

    isBusy = true
    rebuildMenu()

    let url = scriptURL(paths: paths, kind: script)
    let mode = authMode()
    var seen = Set<String>()
    let ordered = services.filter { seen.insert($0).inserted }

    DispatchQueue.global(qos: .userInitiated).async {
      var combined = outputPrefix
      var summaries: [SummaryItem] = []
      for svc in ordered {
        let result: Result<CommandResult, Error>
        let extraArgs = extraArgsProvider(svc)
        switch mode {
        case .touchIdSudo:
          result = self.runner.runViaSudoWithPTY(scriptURL: url, service: svc, extraArgs: extraArgs)
        case .passwordPrompt:
          result = self.runner.runViaAppleScriptAsRoot(scriptURL: url, service: svc, extraArgs: extraArgs)
        }

        summaries.append(self.summarizeResult(script: script, service: svc, result: result, extraArgs: extraArgs))

        if !combined.isEmpty {
          if !combined.hasSuffix("\n") { combined.append("\n") }
          combined.append("\n")
        }
        combined.append("===== \(svc) =====\n")
        switch result {
        case .success(let res):
          combined.append(res.output.isEmpty ? "(no output)" : res.output)
        case .failure(let err):
          combined.append("ERROR: \(err.localizedDescription)")
        }
      }

      DispatchQueue.main.async {
        self.isBusy = false
        self.updateStatusIcon()
        self.rebuildMenu()

        let title: String
        if ordered.count == 1, let svc = ordered.first {
          title = "\(actionName) — \(svc)"
        } else {
          title = "\(actionName) — \(ordered.count) services"
        }
        let output = combined.isEmpty ? "(no output)" : combined
        let attributed = self.formatOutput(summaries: summaries, details: output)
        self.showOutput(title: title, output: attributed)
      }
    }
  }

  // MARK: - UNUserNotificationCenterDelegate

  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    if response.actionIdentifier == "REFRESH" {
      DispatchQueue.main.async {
        self.refreshNow()
      }
    }
    completionHandler()
  }

  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    completionHandler([.banner, .sound])
  }

  // MARK: - Smart Host Discovery

  private func discoverSubdomains(baseDomain: String, completion: @escaping ([String]) -> Void) {
    let urlString = "https://crt.sh/?q=%25.\(baseDomain)&output=json"
    guard let url = URL(string: urlString) else {
      completion([])
      return
    }

    var request = URLRequest(url: url, timeoutInterval: 10)
    request.httpMethod = "GET"

    URLSession.shared.dataTask(with: request) { data, _, error in
      guard error == nil, let data = data else {
        completion([])
        return
      }

      var subdomains = Set<String>()
      if let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
        for entry in json.prefix(200) {
          guard let nameValue = entry["name_value"] as? String else { continue }
          for name in nameValue.split(separator: "\n") {
            let host = String(name).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if host.isEmpty || host.contains("*") { continue }
            if host == baseDomain || host.hasSuffix(".\(baseDomain)") {
              subdomains.insert(host)
            }
          }
        }
      }

      // Also probe common prefixes via DNS
      let prefixes = ["api", "www", "auth", "cdn", "app", "chat", "login", "static", "docs", "console"]
      for prefix in prefixes {
        let candidate = "\(prefix).\(baseDomain)"
        if subdomains.contains(candidate) { continue }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/dig")
        proc.arguments = ["+short", "A", candidate, "+time=1", "+tries=1"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
          try proc.run()
          proc.waitUntilExit()
        } catch { continue }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let ips = out.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ips.isEmpty && ips.contains(".") {
          subdomains.insert(candidate)
        }
      }

      let sorted = ([baseDomain] + subdomains.filter { $0 != baseDomain }.sorted()).prefix(50)
      completion(Array(sorted))
    }.resume()
  }

  private func showDiscoveryResults(baseDomain: String, subdomains: [String], paths: SplitroutePaths) {
    let alert = NSAlert()
    alert.messageText = "Discovered hosts for \(baseDomain)"
    alert.informativeText = "Select which hosts to include:"

    let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 250))
    scrollView.hasVerticalScroller = true
    scrollView.autohidesScrollers = true

    let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: max(250, subdomains.count * 22 + 10)))
    var buttons: [NSButton] = []
    var y = contentView.frame.height - 22
    for host in subdomains {
      let btn = NSButton(checkboxWithTitle: host, target: nil, action: nil)
      btn.state = .on
      btn.frame = NSRect(x: 5, y: y, width: 370, height: 20)
      contentView.addSubview(btn)
      buttons.append(btn)
      y -= 22
    }
    contentView.frame.size.height = CGFloat(subdomains.count * 22 + 10)

    scrollView.documentView = contentView
    alert.accessoryView = scrollView
    alert.addButton(withTitle: "Create & Turn ON")
    alert.addButton(withTitle: "Cancel")

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

    let selectedHosts = zip(subdomains, buttons).compactMap { host, btn -> String? in
      btn.state == .on ? host : nil
    }
    guard !selectedHosts.isEmpty else { return }

    let serviceName = baseDomain
    let serviceDir = paths.servicesDir.appendingPathComponent(serviceName, isDirectory: true)

    do {
      try FileManager.default.createDirectory(at: serviceDir, withIntermediateDirectories: true)

      let hostsText = (["# discovered"] + selectedHosts).joined(separator: "\n") + "\n"
      try hostsText.write(to: serviceDir.appendingPathComponent("hosts.txt"), atomically: true, encoding: .utf8)

      let dnsText = "\(baseDomain)\n"
      try dnsText.write(to: serviceDir.appendingPathComponent("dns_domains.txt"), atomically: true, encoding: .utf8)
    } catch {
      showInfo(title: "Create failed", text: "Could not create service files: \(error.localizedDescription)")
      return
    }

    let services = allServices(paths: paths)
    var selected = Set(selectedServices(paths: paths))
    selected.insert(serviceName)
    let ordered = services.filter { selected.contains($0) }
    setSelectedServices(ordered)
    rebuildMenu()
    runPrivileged(actionName: "ON", script: .on, services: [serviceName]) { _ in [] }
  }

  private func showInfo(title: String, text: String) {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.alertStyle = .warning
    alert.runModal()
  }

  private func showOutput(title: String, output: NSAttributedString) {
    guard let button = statusItem?.button else {
      showInfo(title: title, text: output.string)
      return
    }

    if let popover = outputPopover, popover.isShown {
      popover.performClose(nil)
    }

    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    let controller = OutputPopoverViewController(title: title, text: output) { [weak self] in
      self?.outputPopover?.performClose(nil)
      self?.outputPopover = nil
    }
    popover.contentViewController = controller
    outputPopover = popover
    popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    NSApp.activate(ignoringOtherApps: true)
  }

  private func showHelp(title: String, body: String) {
    let attributed = formatHelp(title: title, body: body)
    showOutput(title: "Help — \(title)", output: attributed)
  }

  func popoverDidClose(_ notification: Notification) {
    outputPopover = nil
  }

  private enum SummaryLevel {
    case ok
    case warn
    case error
  }

  private struct SummaryItem {
    var service: String
    var level: SummaryLevel
    var message: String
  }

  private func summarizeResult(
    script: ScriptKind,
    service: String,
    result: Result<CommandResult, Error>,
    extraArgs: [String]
  ) -> SummaryItem {
    switch result {
    case .failure(let err):
      return .init(service: service, level: .error, message: "Nie udalo sie wykonac polecenia: \(err.localizedDescription)")
    case .success(let res):
      if res.exitCode != 0 || outputIndicatesFailure(res.output) {
        let msg = failureMessage(from: res.output) ?? "Polecenie zakonczone bledem."
        return .init(service: service, level: .error, message: msg)
      }

      if script == .checkNoCurl {
        let (level, message) = summarizeCheckOutput(res.output)
        if let host = extractHost(from: extraArgs) {
          return .init(service: service, level: level, message: "Sprawdzono: \(host). \(message)")
        }
        return .init(service: service, level: level, message: message)
      }

      let message: String
      switch script {
      case .on:
        message = "Reguly wlaczone (ruch tej uslugi powinien isc przez hotspot)."
      case .off:
        message = "Reguly wylaczone (ruch wraca na domyslna trase)."
      case .refresh:
        message = "Reguly odswiezone (odnowiono IP dla hostow)."
      case .checkNoCurl:
        message = "Sprawdzono status."
      }
      return .init(service: service, level: .ok, message: message)
    }
  }

  private func outputIndicatesFailure(_ output: String) -> Bool {
    let lower = output.lowercased()
    if lower.contains("missing hosts file") { return true }
    if lower.contains("brak pliku") { return true }
    if lower.contains("bramy ipv4") { return true }
    if lower.contains("run with sudo") { return true }
    if lower.contains("niepraw") { return true }
    if lower.contains("unknown command") { return true }
    return false
  }

  private func failureMessage(from output: String) -> String? {
    let lower = output.lowercased()
    if lower.contains("brak pliku host") || lower.contains("missing hosts file") {
      return "Brak pliku hosts.txt dla tej uslugi. Sprawdz katalog services/<nazwa>."
    }
    if lower.contains("bramy ipv4") {
      return "Brak bramy hotspotu. Polacz z hotspotem Wi-Fi i sprobuj ponownie."
    }
    if lower.contains("run with sudo") {
      return "Brak uprawnien administratora (sudo)."
    }
    if lower.contains("niepraw") {
      return "Nieprawidlowa nazwa uslugi."
    }
    return nil
  }

  private func summarizeCheckOutput(_ output: String) -> (SummaryLevel, String) {
    let analysis = analyzeCheckOutput(output)
    let total = analysis.totalRoutes

    var level: SummaryLevel = .ok
    var message: String

    let wifiStatusKnown = analysis.wifiStatus != nil
    let hotspotDown = analysis.hotspotDownCount > 0
      || (analysis.gw4LineSeen && analysis.gw4Missing)
      || (wifiStatusKnown && analysis.wifiStatus != "active")

    if total == 0 {
      if hotspotDown {
        level = .error
        message = "Hotspot Wi-Fi nie jest podlaczony."
      } else {
        level = .warn
        message = "Nie udalo sie odczytac wyniku testu."
      }
    } else if hotspotDown {
      level = .error
      message = "Hotspot Wi-Fi nie jest podlaczony."
    } else if analysis.noDnsCount > 0 {
      level = .error
      message = "Nie udalo sie znalezc adresu tej strony."
    } else if analysis.notWifiCount > 0 {
      level = .error
      message = "Ruch nie idzie przez hotspot."
    } else {
      if analysis.okCount > 0 {
        if analysis.noV6Count > 0 {
          message = "Dziala (IPv4). IPv6 niedostepne."
        } else {
          message = "Dziala."
        }
      } else if analysis.noV6Count > 0 {
        level = .warn
        message = "IPv6 niedostepne, brak IPv4."
      } else {
        level = .warn
        message = "Brak pewnych danych o routingu."
      }
    }

    return (level, message)
  }

  private struct CheckAnalysis {
    var wifiIf: String?
    var wifiStatus: String?
    var wifiStatusLineSeen = false
    var gw4: String?
    var gw4LineSeen = false
    var gw4Missing = false
    var totalRoutes = 0
    var okCount = 0
    var notWifiCount = 0
    var noDnsCount = 0
    var noV6Count = 0
    var hotspotDownCount = 0
    var otherStatuses: [String: Int] = [:]
    var dnsBlocked = false
  }

  private func analyzeCheckOutput(_ output: String) -> CheckAnalysis {
    var analysis = CheckAnalysis()
    enum Section { case route, other }
    var section: Section = .other

    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map { sanitizeLine(String($0)) }
    for line in lines {
      if line.hasPrefix("== ") {
        if line.contains("Route table check") {
          section = .route
        } else {
          section = .other
        }
        continue
      }

      if line.hasPrefix("WIFI_IF=") {
        analysis.wifiStatusLineSeen = true
        if let eq = line.firstIndex(of: "=") {
          let rest = line[line.index(after: eq)...]
          let iface = rest.split(separator: " ").first.map(String.init)
          analysis.wifiIf = iface
        }
        if let range = line.range(of: "status: ") {
          let after = line[range.upperBound...]
          if let end = after.firstIndex(of: ")") {
            analysis.wifiStatus = String(after[..<end])
          }
        }
      }

      if line.hasPrefix("GW4(") {
        analysis.gw4LineSeen = true
        if let eq = line.firstIndex(of: "=") {
          let gw = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
          if gw.isEmpty || gw == "<brak>" {
            analysis.gw4Missing = true
          } else {
            analysis.gw4 = gw
          }
        }
      }

      if line.contains("146.112.61.") {
        analysis.dnsBlocked = true
      }

      guard section == .route else { continue }
      let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
      guard parts.count >= 6 else { continue }
      let status = String(parts.last ?? "")
      if status == "status" { continue }

      analysis.totalRoutes += 1
      if status == "OK" {
        analysis.okCount += 1
      } else if status == "NO_DNS" {
        analysis.noDnsCount += 1
      } else if status == "HOTSPOT_DOWN" {
        analysis.hotspotDownCount += 1
      } else if status.hasPrefix("NO_V6_ON_") {
        analysis.noV6Count += 1
      } else if status.hasPrefix("NOT_") {
        analysis.notWifiCount += 1
      } else {
        analysis.otherStatuses[status, default: 0] += 1
      }
    }

    return analysis
  }

  private func hotspotDownMessage(wifiIf: String, wifiStatus: String?, gw4: String?) -> String {
    var parts: [String] = ["Hotspot nieaktywny."]
    if let wifiStatus {
      parts.append("Wi-Fi \(wifiIf) status: \(wifiStatus).")
    }
    if let gw4 {
      parts.append("GW4: \(gw4).")
    }
    parts.append("Polacz z hotspotem i kliknij REFRESH.")
    return parts.joined(separator: " ")
  }

  private func sanitizeLine(_ line: String) -> String {
    var out = line.replacingOccurrences(of: "\r", with: "")
    let pattern = "\u{001B}\\[[0-9;]*[A-Za-z]"
    out = out.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    return out
  }

  private func extractHost(from args: [String]) -> String? {
    guard let idx = args.firstIndex(of: "--host"), idx + 1 < args.count else { return nil }
    return args[idx + 1]
  }

  private func formatOutput(summaries: [SummaryItem], details: String) -> NSAttributedString {
    let fontSize = NSFont.smallSystemFontSize
    let regular = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let color = NSColor.labelColor

    let result = NSMutableAttributedString()
    func append(_ text: String, font: NSFont) {
      result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }

    append("PODSUMOWANIE\n", font: bold)
    if summaries.isEmpty {
      append("Brak danych.\n", font: regular)
    } else {
      for item in summaries {
        let status: String
        switch item.level {
        case .ok: status = "OK"
        case .warn: status = "UWAGA"
        case .error: status = "PROBLEM"
        }
        append("- \(item.service): ", font: regular)
        append(status, font: bold)
        append(" - \(item.message)\n", font: regular)
      }
    }

    append("\nSZCZEGOLY TECHNICZNE\n", font: bold)
    append(details, font: regular)
    return result
  }

  private func formatHelp(title: String, body: String) -> NSAttributedString {
    let fontSize = NSFont.systemFontSize
    let regular = NSFont.systemFont(ofSize: fontSize)
    let bold = NSFont.boldSystemFont(ofSize: fontSize)
    let color = NSColor.labelColor

    let result = NSMutableAttributedString()
    func append(_ text: String, font: NSFont) {
      result.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    }

    append("INSTRUKCJA\n", font: bold)
    append("\(title)\n\n", font: bold)
    append(body, font: regular)
    return result
  }

  private func normalizeDomainInput(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    var candidate = trimmed
    if !candidate.contains("://") {
      candidate = "https://\(candidate)"
    }

    var host: String?
    if let url = URL(string: candidate), let urlHost = url.host {
      host = urlHost
    } else {
      host = trimmed.split(separator: "/").first.map(String.init)
    }

    guard var value = host?.lowercased(), !value.isEmpty else { return nil }
    if value.hasPrefix("www.") {
      value = String(value.dropFirst(4))
    }
    value = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
    guard !value.isEmpty else { return nil }

    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")
    guard value.rangeOfCharacter(from: allowed.inverted) == nil else { return nil }
    return value
  }

  private func primaryHostForService(service: String, paths: SplitroutePaths) -> String? {
    let dnsFile = paths.servicesDir.appendingPathComponent("\(service)/dns_domains.txt")
    if let host = firstHostLine(from: dnsFile) {
      return host
    }
    let hostsFile = paths.servicesDir.appendingPathComponent("\(service)/hosts.txt")
    return firstHostLine(from: hostsFile)
  }

  private func firstHostLine(from file: URL) -> String? {
    guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
    for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      if line.isEmpty || line.hasPrefix("#") { continue }
      if let token = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).first {
        return String(token)
      }
    }
    return nil
  }

  private func createServiceFiles(serviceDir: URL, baseDomain: String) throws {
    try FileManager.default.createDirectory(at: serviceDir, withIntermediateDirectories: true)

    var hosts = ["# core", baseDomain]
    let www = "www.\(baseDomain)"
    if www != baseDomain {
      hosts.append(www)
    }
    let hostsText = hosts.joined(separator: "\n") + "\n"
    try hostsText.write(to: serviceDir.appendingPathComponent("hosts.txt"), atomically: true, encoding: .utf8)

    let dnsText = "\(baseDomain)\n"
    try dnsText.write(to: serviceDir.appendingPathComponent("dns_domains.txt"), atomically: true, encoding: .utf8)
  }
}

@main
struct SplitrouteMenuBarMain {
  static func main() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
  }
}
