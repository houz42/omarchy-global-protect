import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Standalone bar-widget plugin for GlobalProtect VPN, bundling
// its own copy of the `gp-wrapper` CLI wrapper (bin/gp-wrapper) and
// the routing-conflict hook it installs to /etc/vpnc/ (bin/gp-wrapper-
// vpnc-script). All GlobalProtect/anti-GFW logic (SSO auth, singleton lock,
// DNS/IPv6 hardening) lives in bin/gp-wrapper itself -- this plugin is a
// thin status + button UI around it, not a reimplementation. The only
// external runtime dependencies are gpclient and the `vpnc` package (see
// the Requirements section below, each opening a terminal with the exact
// command to run yourself).
Panel {
  id: root
  moduleName: "houz42.global-protect"
  ipcTarget: "houz42.global-protect"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string binDir: Qt.resolvedUrl("bin").toString().replace("file://", "")
  readonly property int refreshIntervalSec: Math.max(5, Number(setting("refreshIntervalSec", 15)))

  // Same STATE_DIR gp-wrapper/gp-status use (${XDG_CACHE_HOME:-~/.cache}/houz42-global-protect).
  readonly property string actionStatusPath: {
    var cacheHome = Quickshell.env("XDG_CACHE_HOME")
    if (!cacheHome || cacheHome === "") cacheHome = Quickshell.env("HOME") + "/.cache"
    return cacheHome + "/houz42-global-protect/action-status"
  }

  // Loaded from the gateway cache `gp-wrapper discover` writes (see
  // gp-gateways), a user-local file outside this plugin's repo. The
  // wrapper records the connected gateway by fqdn (not the short key) in
  // its last-gateway state file, so lookups below match on fqdn.
  property var gateways: []

  // Connected gateway sorted to the top of the list (mirrors the Wi-Fi
  // panel surfacing the active network first), rest in their original order.
  readonly property var sortedGateways: {
    if (!root.connected || root.lastGateway === "") return root.gateways
    var current = null, rest = []
    for (var i = 0; i < root.gateways.length; i++) {
      if (root.gateways[i].fqdn === root.lastGateway) current = root.gateways[i]
      else rest.push(root.gateways[i])
    }
    return current ? [current].concat(rest) : root.gateways
  }

  property bool ready: false
  property bool gatewaysLoaded: false
  property bool gpclientAvailable: false
  property bool vpncAvailable: false
  property bool hookInstalled: false
  property string portal: ""
  readonly property bool requirementsMet: root.gpclientAvailable && root.vpncAvailable && root.hookInstalled && root.portal !== ""
  property bool connected: false
  property string iface: ""
  property string addr: ""
  property string lastGateway: ""
  property bool busy: false
  // Optimistic latch set the instant a connect is LAUNCHED from this panel.
  // gp-wrapper only writes action-status=connecting once it is actually
  // running -- after the sudo check and, on the password path, after the
  // user finishes typing it in the terminal -- so without this the switch
  // looks idle (and accepts more clicks, each launching another gp-wrapper
  // that fights the first over the singleton session) for the whole
  // prompt/startup span. Cleared when a status poll reports connected, when
  // the wrapper's action status falls back to idle (success, failure, or
  // its own timeout), or by pendingWatchdog if the wrapper never even
  // started (e.g. the sudo terminal was closed without a password).
  property bool connectPending: false
  // "idle" | "discovering" | "connecting" -- written by gp-wrapper to a
  // state file gp-status reads back, so the panel can show live progress
  // for the terminal-driven discover/connect flow without needing to
  // watch the terminal itself (see gp-wrapper's _set_action_status).
  property string action: "idle"
  // Any in-flight mutation the switch must freeze and dim for: a panel-
  // launched connect (pending + wrapper-reported), a disconnect (busy), or
  // a wrapper action launched from a terminal (action !== idle with no
  // local pending). Single point every guard and visual below binds to.
  readonly property bool transitioning: root.busy || root.connectPending || root.action !== "idle"

  // Watchdog: absolute deadline for every collector/action Process below.
  // Without one, a hung child (e.g. gp-gateways on a pathological cache
  // file) wedges the refresh path forever -- refreshNow()/loadGateways()
  // early-return while `.running` stays true and nothing ever clears it.
  // Setting running=false kills the process; its short-lived children
  // (jq/ip/tr) die with their pipes.
  component ProcWatchdog: Timer {
    required property Process target
    interval: 10000
    repeat: false
    running: target.running
    onTriggered: {
      console.warn("global-protect: killing hung collector process: " + JSON.stringify(target.command))
      target.running = false
    }
  }

  Component.onDestruction: {
    statusProcess.running = false
    gatewaysProcess.running = false
    sudoCheckProcess.running = false
    setPortalProcess.running = false
    disconnectProcess.running = false
    hardenProcess.running = false
  }

  visible: root.ready
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function gatewayLabel(fqdn) {
    for (var i = 0; i < root.gateways.length; i++) {
      if (root.gateways[i].fqdn === fqdn) return root.gateways[i].label
    }
    return fqdn
  }

  function gatewayLabelForKey(key) {
    for (var i = 0; i < root.gateways.length; i++) {
      if (root.gateways[i].key === key) return root.gateways[i].label
    }
    return key
  }

  function heroMeta() {
    if (!root.requirementsMet) return "Setup needed"
    if (root.busy) return "Working..."
    if (root.action === "discovering") return "Discovering gateways..."
    if (root.connectPending || root.action === "connecting") return "Connecting..."
    return root.connected ? "Connected" : "Disconnected"
  }

  onOpenedChanged: {
    if (opened) refreshNow()
    root.cursorActive = false
    // sortedGateways always puts the connected gateway first (index 0),
    // so index 1 is it -- same convention as the Bluetooth panel opening
    // with its cursor on the already-connected device instead of always
    // resetting to the header. Falls back to the header (0) when nothing
    // is connected, since that's the primary "turn it on" action then.
    root.cursorIndex = root.connected ? 1 : 0
  }

  // Keyboard cursor: a single linear index over [header switch, gateway
  // rows...] -- index 0 is the header/switch, 1..N are root.sortedGateways.
  // Same convention as the other first-party panels (e.g. Bluetooth): the
  // first Up/Down just reveals the cursor without moving it, and Space/
  // Enter is a no-op until the cursor is actually visible (no "invisible
  // toggle" surprise).
  property bool cursorActive: false
  property int cursorIndex: 0
  readonly property int maxCursorIndex: root.requirementsMet ? root.sortedGateways.length : 0

  function moveCursor(dy) {
    if (!root.cursorActive) { root.cursorActive = true; return }
    if (dy === 0) return
    root.cursorIndex = Math.max(0, Math.min(root.maxCursorIndex, root.cursorIndex + dy))
  }

  function setCursor(index) {
    root.cursorActive = true
    root.cursorIndex = index
  }

  function activateCursor() {
    if (!root.cursorActive) return
    if (root.cursorIndex === 0) {
      root.toggleDefault()
      return
    }
    var gw = root.sortedGateways[root.cursorIndex - 1]
    if (!gw) return
    if (root.connected && root.lastGateway === gw.fqdn) root.disconnect()
    else root.connectGateway(gw.key)
  }

  // First-use setup prompt: the very first time this plugin ever sees
  // itself with no portal configured, open the popup unprompted instead of
  // waiting for the user to notice the bar icon and think to click it. A
  // plain `property bool` would reset on every hot-reload/`omarchy restart
  // shell` and re-nag every time -- PersistentProperties survives those
  // (same pattern the first-party battery service uses for its own
  // one-time-ever triggers), so this fires exactly once, ever.
  PersistentProperties {
    id: firstRunPrompt
    reloadableId: "houz42-global-protect-first-run"
    property bool done: false
  }

  Timer {
    id: firstRunFocusTimer
    interval: 150
    onTriggered: if (portalField.visible) portalField.forceActiveFocus()
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshNow()
  }

  // Push-based instead of polling gp-status: watches gp-wrapper's
  // action-status file (inotify-backed via Quickshell's FileView) so
  // "Discovering..."/"Connecting..." in the panel header updates the
  // instant the wrapper writes a new state, not on the next refresh tick.
  // gp-wrapper's own _watch_connect_status guarantees an eventual write
  // back to "idle" (on tunnel-up or after its 3-minute bound), so staleness
  // here just guards the read, not liveness.
  FileView {
    id: actionStatusFile
    path: root.actionStatusPath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.applyActionStatus(text())
    onLoadFailed: root.action = "idle"
  }

  function applyActionStatus(content) {
    var trimmed = String(content || "").trim()
    var word = "idle"
    if (trimmed !== "") {
      var parts = trimmed.split(/\s+/)
      var ts = parseInt(parts[0], 10)
      if (isFinite(ts) && (Date.now() / 1000 - ts) <= 200) word = parts[1] || "idle"
    }
    var wasActive = root.action !== "idle"
    root.action = word
    if (word === "idle") {
      // The wrapper finished one way or the other (tunnel up, failed, or
      // hit its own bound), so the launch latch is done either way. Pull a
      // fresh status right now instead of waiting out the poll interval:
      // on success the panel flips to Connected within a second instead of
      // up to refreshIntervalSec later; on failure it confirms the switch
      // should fall back to off.
      root.connectPending = false
      pendingWatchdog.stop()
      if (wasActive) root.refreshNow()
    }
  }

  // Last-resort clear for connectPending when the wrapper NEVER reports
  // (sudo terminal closed without a password, wrapper killed before it
  // could write). Generous bound: a legit run writes action-status within
  // seconds of launch, and once it has, action !== idle keeps the switch
  // frozen on its own -- this timer firing mid-connect is invisible.
  Timer {
    id: pendingWatchdog
    interval: 5 * 60 * 1000
    repeat: false
    onTriggered: root.connectPending = false
  }

  Process {
    id: statusProcess
    running: false
    command: [root.binDir + "/gp-status"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("global-protect:", text.trim())
    }
  }

  ProcWatchdog { target: statusProcess }

  function refreshNow() {
    if (statusProcess.running) return
    statusProcess.running = true
    root.loadGateways()
  }

  Process {
    id: gatewaysProcess
    running: false
    command: [root.binDir + "/gp-gateways"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyGateways(text)
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("global-protect:", text.trim())
    }
  }

  ProcWatchdog { target: gatewaysProcess }

  function loadGateways() {
    if (gatewaysProcess.running) return
    gatewaysProcess.running = true
  }

  function applyGateways(text) {
    var trimmed = String(text || "").trim()
    if (trimmed === "") return
    var parsed
    try {
      parsed = JSON.parse(trimmed)
    } catch (e) {
      console.warn("global-protect: gateway list collector printed invalid JSON")
      return
    }
    // Schema check, fail closed: this JSON derives from a remote portal's
    // XML via the gateways.tsv cache. gp-gateways already bounds and
    // validates it at the producer; this is the second fence. Any element
    // violating the shape below drops the WHOLE list -- never render
    // partially-trusted data.
    if (!Array.isArray(parsed) || parsed.length > 64) {
      console.warn("global-protect: gateway list failed schema check")
      return
    }
    var clean = []
    for (var i = 0; i < parsed.length; i++) {
      var g = parsed[i]
      if (!g || typeof g.key !== "string" || typeof g.fqdn !== "string" || typeof g.label !== "string") {
        console.warn("global-protect: gateway entry failed schema check")
        return
      }
      if (g.key.length > 64 || g.fqdn.length > 253 || g.label.length > 128) {
        console.warn("global-protect: gateway entry exceeds field bounds")
        return
      }
      if (!/^[a-z0-9]+$/.test(g.key) || !/^[A-Za-z0-9][A-Za-z0-9.-]*$/.test(g.fqdn)) {
        console.warn("global-protect: gateway entry failed charset check")
        return
      }
      clean.push({ key: g.key, fqdn: g.fqdn, label: g.label })
    }
    root.gateways = clean
    root.gatewaysLoaded = true
  }

  function applyStatus(text) {
    var trimmed = String(text || "").trim()
    if (trimmed === "") return
    var payload
    try {
      payload = JSON.parse(trimmed)
    } catch (e) {
      console.warn("global-protect: status collector printed invalid JSON")
      return
    }
    root.ready = true
    root.gpclientAvailable = payload.gpclientAvailable === true
    root.vpncAvailable = payload.vpncAvailable === true
    root.hookInstalled = payload.hookInstalled === true
    root.portal = String(payload.portal || "")
    if (!firstRunPrompt.done && root.portal === "") {
      firstRunPrompt.done = true
      root.open()
      firstRunFocusTimer.restart()
    }
    root.connected = payload.connected === true
    if (root.connected) {
      root.connectPending = false
      pendingWatchdog.stop()
    }
    root.iface = String(payload.iface || "")
    root.addr = String(payload.addr || "")
    root.lastGateway = String(payload.lastGateway || "")
  }

  // The gateway a headline toggle connects to: the last-used one if we have
  // it, else the first entry in the (dynamically loaded) list.
  function defaultGatewayKey() {
    if (root.lastGateway !== "") {
      for (var i = 0; i < root.gateways.length; i++) {
        if (root.gateways[i].fqdn === root.lastGateway) return root.gateways[i].key
      }
    }
    return root.gateways.length > 0 ? root.gateways[0].key : ""
  }

  function toggleDefault() {
    if (root.transitioning) return
    if (root.connected) {
      root.disconnect()
      return
    }
    var key = root.defaultGatewayKey()
    if (key !== "") {
      root.connectGateway(key)
    } else {
      root.discoverAndConnect()
    }
  }

  // gp-wrapper's actions need `sudo`, but a browser window handles the
  // actual SSO login regardless of how gpclient itself was launched -- a
  // terminal was only ever needed for sudo's password prompt (and, before
  // action-status/heroMeta existed, for visibility). Checked fresh before
  // EVERY privileged action (not cached) -- a standing NOPASSWD grant is
  // stable, but a plain cached sudo *timestamp* (the common case: it just
  // happened to be warm when the panel loaded) expires on its own timeout,
  // and a stale "yes" here would send a real password prompt into a
  // headless run with nowhere to go. If it currently doesn't need a
  // password, run headless via a plain detached exec; otherwise fall back
  // to a floating terminal so the prompt has somewhere to go.
  Process {
    id: sudoCheckProcess
    running: false
    property string pendingScript: ""
    command: ["bash", "-lc", "sudo -n true"]
    onExited: function(exitCode) {
      if (exitCode === 0) {
        root.bar.run(sudoCheckProcess.pendingScript)
      } else {
        root.bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(sudoCheckProcess.pendingScript))
      }
    }
  }

  ProcWatchdog { target: sudoCheckProcess }

  function runPrivileged(script) {
    if (sudoCheckProcess.running) return
    sudoCheckProcess.pendingScript = script
    sudoCheckProcess.running = true
    // Only connect flows reach here (connectGateway / discoverAndConnect).
    root.connectPending = true
    pendingWatchdog.restart()
  }

  function connectGateway(key) {
    if (root.transitioning || !root.requirementsMet) return
    var script = "GP_PORTAL=" + Util.shellQuote(root.portal) + " "
      + Util.shellQuote(root.binDir + "/gp-wrapper") + " " + Util.shellQuote(key)
    root.runPrivileged(script)
  }

  // What the power switch runs when turned on with no gateway list yet, and
  // what the GATEWAY refresh button runs: a single connect using gpclient's
  // own --auto-gateway (no prompting, no separate throwaway discovery
  // session) whose own verbose log also gets parsed in the background to
  // (re)populate the cached gateway list -- see gp-wrapper's `connect-auto`.
  function discoverAndConnect() {
    if (root.transitioning || !root.requirementsMet) return
    var script = "GP_PORTAL=" + Util.shellQuote(root.portal) + " "
      + Util.shellQuote(root.binDir + "/gp-wrapper") + " connect-auto"
    root.runPrivileged(script)
  }

  Process {
    id: setPortalProcess
    running: false
    property string value: ""
    command: [root.binDir + "/gp-set-portal", value]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.refreshNow()
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("global-protect:", text.trim())
    }
  }

  ProcWatchdog { target: setPortalProcess }

  function setPortal(value) {
    value = String(value || "").trim()
    if (value === "" || setPortalProcess.running) return
    setPortalProcess.value = value
    setPortalProcess.running = true
  }

  // Each of these opens a visible terminal showing the exact command to
  // run -- it does NOT run it. The user reviews and executes it
  // themselves; the plugin itself never execs a package manager or sudo
  // install on their behalf. Status refreshes once the terminal is closed.
  function installGpclient() {
    root.bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(root.binDir + "/gp-howto-gpclient"))
  }

  function installVpnc() {
    root.bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(root.binDir + "/gp-howto-vpnc"))
  }

  function installHook() {
    root.bar.run("omarchy-launch-floating-terminal-with-presentation " + Util.shellQuote(root.binDir + "/gp-howto-hook"))
  }

  Process {
    id: disconnectProcess
    running: false
    command: [root.binDir + "/gp-disconnect"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.busy = false
        root.refreshNow()
      }
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("global-protect:", text.trim())
    }
  }

  ProcWatchdog { target: disconnectProcess }

  function disconnect() {
    if (root.transitioning || disconnectProcess.running) return
    root.busy = true
    disconnectProcess.running = true
  }

  Process {
    id: hardenProcess
    running: false
    command: [root.binDir + "/gp-harden"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.refreshNow()
    }

    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (text.trim() !== "") console.warn("global-protect:", text.trim())
    }
  }

  ProcWatchdog { target: hardenProcess }

  // Deliberately does NOT set root.busy: this is an idempotent background
  // re-check (see the timer comment below), so it must not freeze/dim the
  // switch or flash "Working..." for a second every 5 minutes. busy is for
  // user-invoked state changes -- disconnect -- only.
  function harden() {
    if (root.transitioning || hardenProcess.running || !root.connected) return
    hardenProcess.running = true
  }

  // Re-harden runs automatically on every connect and (via the resume
  // hook) on every suspend/resume already -- this periodic timer is for
  // everything else that can regress DNS/IPv6 without either of those
  // events firing (Wi-Fi roaming/reassociation, systemd-resolved or
  // NetworkManager getting reset by something unrelated, etc). Both
  // underlying steps are idempotent/no-op when already applied, so running
  // this on a timer instead of leaving it to a manual button is just a
  // cheap periodic check, not repeated work.
  Timer {
    interval: 5 * 60 * 1000
    running: root.connected
    repeat: true
    onTriggered: root.harden()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    foreground: root.connected ? root.foreground : root.dim
    text: ""
    tooltipText: "GlobalProtect VPN: " + (root.connected
      ? "Connected"
      : (root.connectPending || root.action !== "idle" ? "Connecting..." : "Disconnected"))
    onPressed: function(buttonCode) {
      root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(320))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(480))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // The portal field owns keys while focused, same as china-proxy's
      // inline add-host field -- otherwise arrow/enter/escape get
      // intercepted here before the TextField ever sees them.
      blocked: portalField.activeFocus
      onMoveRequested: function(dx, dy) { root.moveCursor(dy) }
      onActivateRequested: root.activateCursor()
      onCloseRequested: root.close()

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: "GlobalProtect VPN"
            meta: root.heroMeta()
            foreground: root.foreground
            fontFamily: root.fontFamily

            trailingControl: Component {
              CursorSurface {
                hasCursor: root.cursorActive && root.cursorIndex === 0
                implicitWidth: toggle.implicitWidth + Style.space(10)
                implicitHeight: toggle.implicitHeight + Style.space(6)
                foreground: root.foreground

                ToggleSwitch {
                  id: toggle
                  anchors.centerIn: parent
                  checked: root.connected
                  foreground: root.foreground
                  // Frozen + shadowed for the whole startup span: busy
                  // swallows further clicks (each would otherwise launch
                  // another gp-wrapper fighting over the singleton
                  // session) and the dim reads as "starting, wait" -- the
                  // hero meta says "Connecting..." alongside it.
                  busy: root.transitioning
                  opacity: root.transitioning ? 0.45 : 1.0
                  interactive: root.connected || root.requirementsMet
                  onToggled: root.toggleDefault()

                  Behavior on opacity { NumberAnimation { duration: 120 } }

                  onContainsMouseChanged: if (containsMouse) root.setCursor(0)

                  PanelToolTip {
                    visible: parent.containsMouse
                    text: root.transitioning
                      ? (root.busy ? "Working..." : "Connecting...")
                      : (root.connected
                          ? "Disconnect"
                          : (root.defaultGatewayKey() !== ""
                              ? "Connect to " + root.gatewayLabelForKey(root.defaultGatewayKey())
                              : "Discover gateways and connect"))
                    fontFamily: root.fontFamily
                  }
                }
              }
            }

            iconComponent: Component {
              Text {
                anchors.centerIn: parent
                text: ""
                color: root.connected ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          PanelSeparator {
            foreground: root.foreground
          }

          Column {
            visible: !root.requirementsMet
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "REQUIREMENTS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              height: Math.max(Style.space(28), portalField.implicitHeight)

              Text {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: (root.portal !== "" ? "✓ " : "✗ ") + "portal"
                color: root.portal !== "" ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              TextField {
                id: portalField
                anchors.right: portalSaveBtn.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(140)
                placeholderText: "gp.example.com"
                foreground: root.foreground
                text: root.portal
                onAccepted: root.setPortal(portalField.text)
              }

              Button {
                id: portalSaveBtn
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Save"
                fontSize: Style.font.caption
                foreground: root.foreground
                fontFamily: root.fontFamily
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.space(2)
                bordered: true
                onClicked: root.setPortal(portalField.text)
              }
            }

            Repeater {
              model: [
                { ok: root.gpclientAvailable, label: "gpclient", detail: "", action: root.installGpclient },
                { ok: root.vpncAvailable, label: "vpnc package", detail: "", action: root.installVpnc },
                { ok: root.hookInstalled, label: "routing hook", detail: "/etc/vpnc/gp-wrapper-vpnc-script", action: root.installHook }
              ]

              Item {
                required property var modelData
                width: parent.width
                height: Style.space(28)

                Text {
                  id: reqLabel
                  anchors.left: parent.left
                  anchors.right: installBtn.visible ? installBtn.left : parent.right
                  anchors.rightMargin: installBtn.visible ? Style.space(8) : 0
                  anchors.verticalCenter: parent.verticalCenter
                  text: (modelData.ok ? "✓ " : "✗ ") + modelData.label
                  color: modelData.ok ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                  elide: Text.ElideRight

                  MouseArea {
                    id: reqHover
                    anchors.fill: parent
                    hoverEnabled: true
                    visible: modelData.detail !== ""
                  }

                  PanelToolTip {
                    visible: modelData.detail !== "" && reqHover.containsMouse
                    text: modelData.detail
                    fontFamily: root.fontFamily
                  }
                }

                Button {
                  id: installBtn
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  visible: !modelData.ok
                  text: "Show"
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  horizontalPadding: Style.spacing.controlPaddingX
                  verticalPadding: Style.space(2)
                  bordered: true
                  onClicked: modelData.action()
                }
              }
            }

            Text {
              width: parent.width
              topPadding: Style.space(4)
              text: "\"Show\" opens a terminal with the command to run -- it won't run it for you."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Column {
            visible: root.requirementsMet
            width: parent.width
            spacing: Style.space(10)

            Item {
              width: parent.width
              height: sectionHeader.implicitHeight

              PanelSectionHeader {
                id: sectionHeader
                text: "GATEWAY"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: ""
                tooltipText: (root.connectPending || root.action !== "idle") ? "Connecting..." : "Discover gateways from the portal and connect (~15-25s)"
                foreground: root.foreground
                fontFamily: root.fontFamily
                enabled: root.action === "idle" && !root.connectPending
                onClicked: root.discoverAndConnect()

                RotationAnimation on rotation {
                  running: root.action !== "idle" || root.connectPending
                  loops: Animation.Infinite
                  from: 0
                  to: 360
                  duration: 900
                }
              }
            }

            Text {
              visible: root.gatewaysLoaded && root.gateways.length === 0
              width: parent.width
              text: "No gateways discovered yet. Click the refresh icon above to fetch them from the portal."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }

            ListView {
              id: gatewayList
              visible: root.gateways.length > 0
              // Rows launch the same connect/disconnect the switch does, so
              // they freeze with it -- clicks are already guarded inside
              // connectGateway/disconnect; this just shows it.
              opacity: root.transitioning ? 0.55 : 1.0
              Behavior on opacity { NumberAnimation { duration: 120 } }
              width: parent.width
              height: Math.min(contentHeight, Style.space(200))
              spacing: Style.space(2)
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentHeight > height
              model: root.sortedGateways

              ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

              delegate: CursorSurface {
                id: gatewayRow
                required property var modelData
                required property int index
                readonly property bool isCurrent: root.connected && root.lastGateway === modelData.fqdn
                width: ListView.view.width
                height: Math.max(Style.space(32), labelColumn.implicitHeight + Style.space(8))
                radius: Style.space(4)
                foreground: root.foreground
                hasCursor: root.cursorActive && root.cursorIndex === gatewayRow.index + 1
                current: gatewayRow.isCurrent

                Column {
                  id: labelColumn
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.right: checkMark.left
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(1)

                  Text {
                    width: parent.width
                    // Portal-controlled string: plain text only, never let
                    // AutoText interpret markup in a gateway description.
                    textFormat: Text.PlainText
                    text: gatewayRow.modelData.label
                    color: gatewayRow.isCurrent ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: gatewayRow.isCurrent
                    elide: Text.ElideRight
                  }

                  Text {
                    width: parent.width
                    visible: gatewayRow.isCurrent && root.addr !== ""
                    textFormat: Text.PlainText
                    text: root.addr
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                  }
                }

                Text {
                  id: checkMark
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  visible: gatewayRow.isCurrent
                  text: "✓"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.bodySmall
                }

                MouseArea {
                  id: rowHover
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onContainsMouseChanged: if (containsMouse) root.setCursor(gatewayRow.index + 1)
                  onClicked: gatewayRow.isCurrent ? root.disconnect() : root.connectGateway(gatewayRow.modelData.key)
                }
              }

              // Keep the keyboard cursor in view when it moves into/through
              // the gateway list -- ListView doesn't do this on its own
              // since nothing sets its built-in currentIndex here.
              Connections {
                target: root
                function onCursorIndexChanged() {
                  if (root.cursorIndex > 0) gatewayList.positionViewAtIndex(root.cursorIndex - 1, ListView.Contain)
                }
              }
            }
          }

        }
      }
    }
  }
}
