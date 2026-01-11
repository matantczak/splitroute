import Cocoa
import Darwin

private enum DefaultsKey {
  static let repoPath = "SplitrouteRepoPath"
  static let selectedService = "SplitrouteSelectedService" // legacy
  static let selectedServices = "SplitrouteSelectedServices"
  static let authMode = "SplitrouteAuthMode"
  static let autoOffDeadline = "SplitrouteAutoOffDeadline"
  static let autoOffService = "SplitrouteAutoOffService" // legacy
  static let autoOffServices = "SplitrouteAutoOffServices"
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

private final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSPopoverDelegate {
  private let runner = SplitrouteRunner()

  private var statusItem: NSStatusItem?
  private var outputPopover: NSPopover?
  private var autoOffTimer: Timer?
  private var isBusy = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)

    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    if let button = statusItem?.button {
      button.image = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: "splitroute")
      button.image?.isTemplate = true
      button.toolTip = "splitroute"
    }

    rebuildMenu()

    NSWorkspace.shared.notificationCenter.addObserver(
      self,
      selector: #selector(handleWake),
      name: NSWorkspace.didWakeNotification,
      object: nil
    )

    rescheduleAutoOffTimer()
    checkAutoOffIfNeeded(reason: "launch")
  }

  func menuWillOpen(_ menu: NSMenu) {
    rebuildMenu()
  }

  private func defaults() -> UserDefaults { .standard }

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

  private func autoOffDeadline() -> Date? {
    let ts = defaults().double(forKey: DefaultsKey.autoOffDeadline)
    if ts <= 0 { return nil }
    return Date(timeIntervalSince1970: ts)
  }

  private func setAutoOff(deadline: Date?, services: [String]?) {
    if let deadline, let services {
      defaults().set(deadline.timeIntervalSince1970, forKey: DefaultsKey.autoOffDeadline)
      defaults().set(services, forKey: DefaultsKey.autoOffServices)
    } else {
      defaults().removeObject(forKey: DefaultsKey.autoOffDeadline)
      defaults().removeObject(forKey: DefaultsKey.autoOffServices)
      defaults().removeObject(forKey: DefaultsKey.autoOffService)
    }
    rescheduleAutoOffTimer()
  }

  private func autoOffServices() -> [String]? {
    if let list = defaults().array(forKey: DefaultsKey.autoOffServices) as? [String] {
      return list
    }
    if let legacy = defaults().string(forKey: DefaultsKey.autoOffService), !legacy.isEmpty {
      return [legacy]
    }
    return nil
  }

  private func rescheduleAutoOffTimer() {
    autoOffTimer?.invalidate()
    autoOffTimer = nil

    guard let deadline = autoOffDeadline() else { return }
    let interval = deadline.timeIntervalSinceNow
    if interval <= 0 { return }

    autoOffTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
      self?.checkAutoOffIfNeeded(reason: "timer")
    }
  }

  @objc private func handleWake() {
    checkAutoOffIfNeeded(reason: "wake")
  }

  private func checkAutoOffIfNeeded(reason: String) {
    guard let deadline = autoOffDeadline(), Date() >= deadline else { return }
    guard let services = autoOffServices(), !services.isEmpty else {
      setAutoOff(deadline: nil, services: nil)
      return
    }

    setAutoOff(deadline: nil, services: nil)
    runPrivileged(actionName: "Auto-OFF (\(reason))", script: .off, services: services) { _ in [] }
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

    let titleItem = NSMenuItem(title: "splitroute", action: nil, keyEquivalent: "")
    titleItem.isEnabled = false
    menu.addItem(titleItem)

    if let deadline = autoOffDeadline() {
      let formatter = DateFormatter()
      formatter.dateStyle = .none
      formatter.timeStyle = .short
      let item = NSMenuItem(title: "Auto-OFF: \(formatter.string(from: deadline))", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)

      let cancel = NSMenuItem(title: "Cancel Auto-OFF", action: #selector(cancelAutoOff), keyEquivalent: "")
      cancel.target = self
      menu.addItem(cancel)
    } else {
      let item = NSMenuItem(title: "Auto-OFF: (none)", action: nil, keyEquivalent: "")
      item.isEnabled = false
      menu.addItem(item)
    }

    menu.addItem(.separator())

    let onNow = NSMenuItem(title: "ON", action: #selector(turnOnNow), keyEquivalent: "o")
    onNow.target = self
    menu.addItem(onNow)

    let onFor = NSMenuItem(title: "ON for…", action: nil, keyEquivalent: "")
    let onForMenu = NSMenu()
    onForMenu.addItem(makeOnForItem(title: "15 minutes", seconds: 15 * 60))
    onForMenu.addItem(makeOnForItem(title: "1 hour", seconds: 60 * 60))
    onForMenu.addItem(makeOnForItem(title: "4 hours", seconds: 4 * 60 * 60))
    onForMenu.addItem(makeOnForItem(title: "Until end of day", seconds: secondsUntilEndOfDay()))
    onFor.submenu = onForMenu
    menu.addItem(onFor)

    let off = NSMenuItem(title: "OFF", action: #selector(turnOff), keyEquivalent: "f")
    off.target = self
    menu.addItem(off)

    let refresh = NSMenuItem(title: "REFRESH", action: #selector(refreshNow), keyEquivalent: "r")
    refresh.target = self
    menu.addItem(refresh)

    let status = NSMenuItem(title: "STATUS (no curl)", action: #selector(showStatus), keyEquivalent: "s")
    status.target = self
    menu.addItem(status)

    let verify = NSMenuItem(title: "VERIFY active services (no curl)", action: #selector(verifyActiveServices), keyEquivalent: "")
    verify.target = self
    menu.addItem(verify)

    menu.addItem(.separator())

    let repoItem = NSMenuItem(title: "Set Repo Path…", action: #selector(chooseRepoPath), keyEquivalent: ",")
    repoItem.target = self
    menu.addItem(repoItem)

    if let paths = getRepoRoot().map({ SplitroutePaths(repoRoot: $0) }) {
      let serviceItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
      serviceItem.submenu = buildServiceMenu(paths: paths)
      menu.addItem(serviceItem)

      let openHosts = NSMenuItem(title: "Open hosts.txt (selected)", action: #selector(openHostsFile), keyEquivalent: "")
      openHosts.target = self
      menu.addItem(openHosts)

      let openDns = NSMenuItem(title: "Open dns_domains.txt (selected)", action: #selector(openDnsDomainsFile), keyEquivalent: "")
      openDns.target = self
      menu.addItem(openDns)
    }

    let helpItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
    helpItem.submenu = buildHelpMenu()
    menu.addItem(helpItem)

    let authItem = NSMenuItem(title: "Auth", action: nil, keyEquivalent: "")
    authItem.submenu = buildAuthMenu()
    menu.addItem(authItem)

    menu.addItem(.separator())

    let quit = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)

    if isBusy {
      for item in menu.items {
        if item.submenu != nil { continue }
        if item.action != #selector(quitApp) && item.action != #selector(openHostsFile) && item.action != #selector(openDnsDomainsFile) && item.action != #selector(chooseRepoPath) {
          item.isEnabled = false
        }
      }
    }

    statusItem?.menu = menu
  }

  private func makeOnForItem(title: String, seconds: TimeInterval) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: #selector(turnOnFor), keyEquivalent: "")
    item.target = self
    item.representedObject = NSNumber(value: seconds)
    return item
  }

  private func secondsUntilEndOfDay() -> TimeInterval {
    let cal = Calendar.current
    let now = Date()
    guard let end = cal.date(bySettingHour: 23, minute: 59, second: 0, of: now) else { return 0 }
    return max(0, end.timeIntervalSince(now))
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
    menu.addItem(helpMenuItem(title: "ON - wlacza", action: #selector(showHelpOn)))
    menu.addItem(helpMenuItem(title: "OFF - wylacza", action: #selector(showHelpOff)))
    menu.addItem(helpMenuItem(title: "REFRESH - odswieza", action: #selector(showHelpRefresh)))
    menu.addItem(helpMenuItem(title: "STATUS - sprawdza", action: #selector(showHelpStatus)))
    menu.addItem(helpMenuItem(title: "VERIFY - szybki test", action: #selector(showHelpVerify)))
    menu.addItem(.separator())
    menu.addItem(helpMenuItem(title: "Services - wybor uslug", action: #selector(showHelpServices)))
    menu.addItem(helpMenuItem(title: "PODSUMOWANIE - co to znaczy", action: #selector(showHelpSummary)))
    menu.addItem(helpMenuItem(title: "Najczestsze problemy", action: #selector(showHelpTroubleshooting)))
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
    alert.informativeText = "Enter a domain like example.com or www.example.com."

    let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
    input.placeholderString = "example.com"
    alert.accessoryView = input
    alert.addButton(withTitle: "Create")
    alert.addButton(withTitle: "Cancel")

    NSApp.activate(ignoringOtherApps: true)
    let response = alert.runModal()
    guard response == .alertFirstButtonReturn else { return }

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

    do {
      try createServiceFiles(serviceDir: serviceDir, baseDomain: baseDomain)
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

  @objc private func selectAuthMode(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String, let mode = AuthMode(rawValue: raw) else { return }
    setAuthMode(mode)
    rebuildMenu()
  }

  @objc private func showHelpQuickStart() {
    let body = """
1) Polacz hotspot Wi-Fi i normalny internet.
2) Wejdz w Services i zaznacz uslugi (lub Add Service).
3) Kliknij ON.
4) STATUS/VERIFY pokaze, czy dziala.
5) Gdy cos nie dziala -> REFRESH.
6) OFF wylacza i przywraca normalne polaczenie.
"""
    showHelp(title: "Quick start", body: body)
  }

  @objc private func showHelpOn() {
    let body = """
ON = wlacza.
- Od tej chwili ruch do tych stron idzie przez hotspot.
- Wymaga hasla admina (sudo).
"""
    showHelp(title: "ON", body: body)
  }

  @objc private func showHelpOff() {
    let body = """
OFF = wylacza.
- Wszystko wraca na normalna trase.
"""
    showHelp(title: "OFF", body: body)
  }

  @objc private func showHelpRefresh() {
    let body = """
REFRESH = odswieza.
- Uzyj po zmianie sieci lub gdy strona nie dziala.
"""
    showHelp(title: "REFRESH", body: body)
  }

  @objc private func showHelpStatus() {
    let body = """
STATUS = sprawdza.
- Nic nie zmienia.
- Pokazuje, czy ruch idzie przez hotspot.
"""
    showHelp(title: "STATUS", body: body)
  }

  @objc private func showHelpVerify() {
    let body = """
VERIFY = szybki test.
- Sprawdza jedna strone dla kazdej uslugi.
"""
    showHelp(title: "VERIFY", body: body)
  }

  @objc private func showHelpServices() {
    let body = """
Services = lista uslug.
- Zaznaczenia sa zapamietywane.
- Add Service dodaje nowa usluge (domena + www).
- Gdy cos nie dziala, czasem trzeba dopisac hosty w hosts.txt.
"""
    showHelp(title: "Services", body: body)
  }

  @objc private func showHelpSummary() {
    let body = """
OK: wszystko dziala.
UWAGA: dziala, ale cos moze byc ograniczone.
PROBLEM: cos nie dziala (np. brak hotspotu lub DNS).
"""
    showHelp(title: "PODSUMOWANIE", body: body)
  }

  @objc private func showHelpTroubleshooting() {
    let body = """
Najczestsze problemy i szybkie kroki:
- Hotspot nieaktywny: polacz z hotspotem, kliknij REFRESH.
- DNS nie zwraca IP: wlacz DNS override i kliknij REFRESH.
- Czesc adresow poza hotspotem: dopisz hosty do hosts.txt i kliknij REFRESH.
"""
    showHelp(title: "Problemy", body: body)
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
    setAutoOff(deadline: nil, services: nil)
    runPrivileged(actionName: "ON", script: .on, services: services) { _ in [] }
  }

  @objc private func turnOnFor(_ sender: NSMenuItem) {
    guard let seconds = (sender.representedObject as? NSNumber)?.doubleValue else { return }
    guard let paths = ensureRepoRootOrPrompt() else { return }
    let services = selectedServices(paths: paths)
    guard !services.isEmpty else {
      showInfo(title: "No services selected", text: "Select at least one service to turn ON.")
      return
    }
    let deadline = Date().addingTimeInterval(seconds)
    setAutoOff(deadline: deadline, services: services)
    runPrivileged(actionName: "ON (auto-off)", script: .on, services: services) { _ in [] }
  }

  @objc private func cancelAutoOff() {
    setAutoOff(deadline: nil, services: nil)
    rebuildMenu()
  }

  @objc private func turnOff() {
    guard let paths = ensureRepoRootOrPrompt() else { return }
    let services = selectedServices(paths: paths)
    guard !services.isEmpty else {
      showInfo(title: "No services selected", text: "Select at least one service to turn OFF.")
      return
    }
    setAutoOff(deadline: nil, services: nil)
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

  @objc private func showStatus() {
    guard let paths = ensureRepoRootOrPrompt() else { return }
    let services = selectedServices(paths: paths)
    guard !services.isEmpty else {
      showInfo(title: "No services selected", text: "Select at least one service to check status.")
      return
    }
    runPrivileged(actionName: "STATUS", script: .checkNoCurl, services: services) { _ in self.scriptArgs(kind: .checkNoCurl) }
  }

  @objc private func verifyActiveServices() {
    guard let paths = ensureRepoRootOrPrompt() else { return }
    let services = selectedServices(paths: paths)
    guard !services.isEmpty else {
      showInfo(title: "No services selected", text: "Select at least one service to verify.")
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
      showInfo(title: "VERIFY unavailable", text: "No valid hosts found in dns_domains.txt or hosts.txt for selected services.")
      return
    }

    var prefix = ""
    if !skipped.isEmpty {
      prefix = "SKIPPED (no hosts): \(skipped.joined(separator: ", "))\n\n"
    }

    let ordered = services.filter { targets.keys.contains($0) }
    runPrivileged(actionName: "VERIFY", script: .checkNoCurl, services: ordered, outputPrefix: prefix) { svc in
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
