import QtQuick
import QtQml.Models
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "AskModel.js" as AskModel

// Ask - chat with DeepSeek from the desktop.
// Works both as an Omarchy shell plugin (summoned via the shell IPC) and as
// a standalone panel for testing (see shell.qml in this directory).
Item {
  id: root

  property string omarchyPath: Quickshell.env("OMARCHY_PATH")
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME")
  readonly property string configDir: home + "/.config/ask"
  readonly property string configFile: configDir + "/config"
  readonly property string keyFile: configDir + "/key"
  readonly property string historyDir: home + "/.local/share/ask"
  readonly property string historyFile: historyDir + "/history.jsonl"

  property bool opened: false
  property bool loaded: false
  property bool busy: false
  property string currentTab: "ask"
  property var config: ({})
  property string lastQuestion: ""
  property string apiStdout: ""
  property string apiStderr: ""
  property bool apiStdoutDone: false
  property bool apiExited: false
  property int apiExitCode: 0
  property bool keyReadDone: false
  property bool configReadDone: false
  property bool historyReadDone: false
  property bool savedFlash: false
  property bool restoredFlash: false
  property bool clearedFlash: false
  property bool copiedFlash: false
  property int scrollTicks: 0
  property string _historyText: ""

  // Settings-form scratch state (bound by the Settings tab controls).
  property string s_role: ""
  property string s_model: "deepseek-v4-flash"
  property real s_temperature: 1
  property real s_top_p: 1
  property bool s_thinking: true
  property string s_reasoning_effort: "high"
  property string s_response_format: "text"
  property bool s_save_history: false

  // API tab state.
  property string s_api_key: ""
  property string apiKeyStatus: ""
  property string apiKeyFlashText: ""
  property bool apiKeyReadDone: false
  property string _pendingConfig: ""
  property string _pendingKey: ""
  property string _pendingHistory: ""
  property string _pendingHeader: ""
  property string _pendingBody: ""
  property string _pendingRequestType: ""
  readonly property string headerFile: configDir + "/.header"

  // Model list state (fetched live from the DeepSeek /models endpoint).
  property var modelOptions: ["deepseek-v4-flash", "deepseek-v4-pro"]
  property bool modelLoading: false
  property string modelsError: ""
  property bool modelsKeyReadDone: false

  readonly property bool saveHistory: String(root.config.save_history || "n").toLowerCase() === "y"

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  readonly property int cornerRadius: Style.cornerRadius
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(40), Style.font.title + Style.spacing.controlPaddingY * 2)

  // About half the desktop size.
  readonly property int cardWidth: Math.max(Style.space(320), Math.min(Style.space(920), Math.round(panel.width * 0.5)))
  readonly property int cardHeight: Math.max(Style.space(240), Math.min(Style.space(760), Math.round(panel.height * 0.55)))

  // ---- Lifecycle (same shape contract as Omarchy plugins) ----

  function open(payloadJson) {
    root.currentTab = "ask"
    root.opened = true
    root.sweepTempFiles()
    if (!root.loaded) {
      root.loadConfig()
    } else if (root.saveHistory) {
      root.loadHistoryIfEnabled()
    } else {
      threadModel.clear()
    }
    Qt.callLater(function() { inputField.forceActiveFocus() })
  }

  function close() {
    root.opened = false
  }

  function dismiss() {
    root.opened = false
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "henk.ask")
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  // ---- Config ----

  // Descriptor-based safe read: open with O_NOFOLLOW, verify a regular file,
  // and cap the bytes. No check-then-open race, no symlink/FIFO following.
  function safeReadCommand(path, cap) {
    return [
      "python3", "-c",
      "import os, stat, sys\n" +
      "p = sys.argv[1]\n" +
      "lim = int(sys.argv[2])\n" +
      "try:\n" +
      "    fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW)\n" +
      "except OSError:\n" +
      "    sys.exit(1)\n" +
      "try:\n" +
      "    st = os.fstat(fd)\n" +
      "    if not stat.S_ISREG(st.st_mode):\n" +
      "        sys.exit(1)\n" +
      "    data = os.read(fd, lim)\n" +
      "    sys.stdout.buffer.write(data)\n" +
      "finally:\n" +
      "    os.close(fd)\n",
      path, String(cap)
    ]
  }

  // Content is delivered over stdin (never argv/env); write to an
  // unpredictable same-directory temp file (0600) then atomically move it into
  // place (replaces a pre-planted symlink instead of following it). A trap
  // removes the temp if the write is interrupted (e.g. the shell restarts),
  // so stale .tmp.* files do not accumulate.
  function secureWriteStdinCommand(dir, target) {
    return [
      "bash", "-c",
      "install -d -m 700 \"$1\" && tmp=$(mktemp \"$1/.tmp.XXXXXX\") && trap 'rm -f \"$tmp\"' EXIT INT TERM HUP && chmod 600 \"$tmp\" && cat > \"$tmp\" && chmod 600 \"$tmp\" && mv -f \"$tmp\" \"$2\" && chmod 600 \"$2\"",
      "bash", dir, target
    ]
  }

  // Remove leftover temp files from interrupted writes. Anything older than a
  // minute is stale (writes take milliseconds), so an in-flight write is never
  // affected.
  function sweepTempFiles() {
    sweepProc.command = [
      "sh", "-c", 'find "$1" "$2" -maxdepth 1 -type f -name ".tmp.*" -mmin +1 -delete 2>/dev/null',
      "sh", root.configDir, root.historyDir
    ]
    sweepProc.running = true
  }

  function loadConfig() {
    root.configReadDone = false
    configReadProc.command = root.safeReadCommand(root.configFile, 1048576)
    configReadProc.running = true
  }

  function onConfigRead(text) {
    if (root.configReadDone) return
    root.configReadDone = true
    var parsed = AskModel.parseConfig(text)
    if (parsed && typeof parsed === "object") {
      root.config = AskModel.withDefaults(parsed)
    } else {
      // No usable config yet: adopt defaults and write the default file.
      root.config = AskModel.withDefaults(null)
      writeConfig(false)
    }
    root.loaded = true
    root.loadHistoryIfEnabled()
  }

  function writeConfig(showSaved) {
    var text = AskModel.serializeConfig(root.config)
    root._pendingConfig = text
    configWriteProc.stdinEnabled = true
    configWriteProc.command = root.secureWriteStdinCommand(root.configDir, root.configFile)
    configWriteProc.running = true
    if (showSaved) {
      root.savedFlash = true
      savedTimer.restart()
    }
  }

  // ---- History ----

  function loadHistoryIfEnabled() {
    threadModel.clear()
    if (!root.saveHistory) {
      root._historyText = ""
      return
    }
    root.historyReadDone = false
    historyReadProc.command = root.safeReadCommand(root.historyFile, 8388608)
    historyReadProc.running = true
  }

  function onHistoryRead(text) {
    if (root.historyReadDone) return
    root.historyReadDone = true
    root._historyText = text
    var threads = AskModel.parseThreads(text)
    threadModel.clear()
    for (var i = 0; i < threads.length; i++) {
      threadModel.append({
        question: threads[i].question,
        answer: threads[i].answer,
        isError: false
      })
    }
    root.scrollToEnd()
  }

  function writeHistory(question, answer) {
    // Keep history in memory and rewrite the whole file atomically over stdin;
    // no append redirection, so no check-then-open race on the history file.
    root._historyText += JSON.stringify({ role: "user", content: question }) + "\n"
    root._historyText += JSON.stringify({ role: "assistant", content: answer }) + "\n"
    root._pendingHistory = root._historyText
    historyWriteProc.stdinEnabled = true
    historyWriteProc.command = root.secureWriteStdinCommand(root.historyDir, root.historyFile)
    historyWriteProc.running = true
  }

  // ---- Chat ----

  function scrollToEnd() {
    // Retry positionViewAtEnd a few times: the new delegate's height is only
    // known after the ListView lays it out, so a single call can fire before
    // the content grows and leave the view short of the end.
    root.scrollTicks = 0
    scrollTimer.restart()
  }

  // Open a new thread for the just-asked question (answer filled in later).
  function addQuestion(question) {
    threadModel.append({ question: question, answer: "", isError: false })
    root.scrollToEnd()
  }

  // Fill in the answer of the most recent thread, or the error text.
  function setLastAnswer(answer, isError) {
    var index = threadModel.count - 1
    if (index < 0) return
    threadModel.setProperty(index, "answer", answer)
    threadModel.setProperty(index, "isError", !!isError)
    root.scrollToEnd()
  }

  function clearHistory() {
    threadModel.clear()
    root._historyText = ""
    clearProc.command = ["sh", "-c", 'rm -f "$1"', "sh", root.historyFile]
    clearProc.running = true
    root.clearedFlash = true
    clearedTimer.restart()
  }

  // Copy a message to the clipboard (double-click on a question/answer).
  function copyAnswer(text) {
    Quickshell.clipboardText = String(text || "")
    root.copiedFlash = true
    copiedTimer.restart()
  }

  function send() {
    var question = inputField.text.trim()
    if (question === "" || root.busy) return
    root.lastQuestion = question
    inputField.text = ""

    // One-shot mode: only the current exchange is shown.
    if (!root.saveHistory) threadModel.clear()

    root.addQuestion(question)
    root.busy = true
    root.apiStdout = ""
    root.apiStderr = ""
    root.apiStdoutDone = false
    root.apiExited = false
    root.apiExitCode = 0

    // The API key always comes from ~/.config/ask/key, managed in the API tab.
    root.keyReadDone = false
    keyReadProc.command = root.safeReadCommand(root.keyFile, 4096)
    keyReadProc.running = true
  }

  function onKeyRead(text) {
    if (root.keyReadDone) return
    root.keyReadDone = true
    var key = String(text || "").trim()
    if (!key) {
      root.busy = false
      root.setLastAnswer("Error: no API key set. Open the API tab and enter your DeepSeek API key.", true)
      Qt.callLater(function() { inputField.forceActiveFocus() })
      return
    }
    // The key is handed to the header-writer over its stdin (never argv/env);
    // curl then reads the header from the resulting 0600 file, and the request
    // body goes to curl over stdin. curl enforces connect/time/size limits and
    // HTTPS-only so a stalled/oversized response or redirect cannot leak or
    // hang the shell.
    root._pendingHeader = "Authorization: Bearer " + key
    root._pendingRequestType = "chat"
    root._pendingBody = root.buildRequestBody(root.lastQuestion)
    headerWriteProc.stdinEnabled = true
    headerWriteProc.command = root.secureWriteStdinCommand(root.configDir, root.headerFile)
    headerWriteProc.running = true
  }

  function buildRequestBody(question) {
    var history = root.saveHistory ? AskModel.parseHistory(root._historyText) : []
    var msgs = AskModel.buildMessages(root.config, history, question)
    return JSON.stringify(AskModel.buildRequest(root.config, msgs))
  }

  function launchPendingRequest() {
    if (root._pendingRequestType === "models") {
      modelsProc.command = [
        "bash", "-c",
        "curl -s --connect-timeout 10 --max-time 30 --max-filesize 1048576 --proto '=https' -X GET -H \"@$1\" -H 'Accept: application/json' https://api.deepseek.com/models",
        "bash", root.headerFile
      ]
      modelsProc.running = true
      modelsWatchdog.restart()
      return
    }
    apiProc.stdinEnabled = true
    apiProc.command = [
      "bash", "-c",
      "curl -s --connect-timeout 10 --max-time 120 --max-filesize 10485760 --proto '=https' -H \"@$1\" -H 'Content-Type: application/json' https://api.deepseek.com/chat/completions -d @-",
      "bash", root.headerFile
    ]
    apiProc.running = true
    apiWatchdog.restart()
  }

  function tryFinishApi() {
    if (root.apiStdoutDone && root.apiExited) root.finishApi(root.apiExitCode)
  }

  function finishApi(exitCode) {
    // Guarded by apiStdoutDone/apiExited so a single response is processed
    // exactly once regardless of stream-finished vs exited signal order.
    root.busy = false
    apiWatchdog.stop()
    if (exitCode !== 0 && root.apiStdout === "") {
      var msg
      if (exitCode === 2) msg = "Error: no API key set. Open the API tab and enter your DeepSeek API key."
      else if (exitCode === 28) msg = "Request timed out."
      else if (exitCode === 63) msg = "Response too large."
      else if (exitCode === 18) msg = "Incomplete response from the API."
      else msg = "Request failed (exit " + exitCode + ").\n" + (root.apiStderr || "")
      root.setLastAnswer(msg, true)
    } else {
      var result = AskModel.parseResponse(root.apiStdout)
      if (result.answer !== undefined) {
        root.setLastAnswer(result.answer, false)
        if (root.saveHistory) root.writeHistory(root.lastQuestion, result.answer)
      } else if (result.error !== undefined) {
        root.setLastAnswer(result.error, true)
      } else {
        root.setLastAnswer("Unexpected API response:\n" + JSON.stringify(result.unexpected, null, 2), true)
      }
    }
    root.apiStdout = ""
    root.apiStderr = ""
    Qt.callLater(function() { inputField.forceActiveFocus() })
  }

  // ---- Settings form ----

  function loadSettings() {
    root.s_role = String(root.config.role || "")
    root.s_model = String(root.config.model || "deepseek-v4-flash")
    root.s_temperature = parseFloat(root.config.temperature) || 1
    root.s_top_p = parseFloat(root.config.top_p) || 1
    root.s_thinking = String(root.config.thinking || "enabled").toLowerCase() === "enabled"
    root.s_reasoning_effort = String(root.config.reasoning_effort || "high")
    root.s_response_format = String(root.config.response_format || "text")
    root.s_save_history = String(root.config.save_history || "n").toLowerCase() === "y"
  }

  function saveSettings() {
    root.config = {
      role: root.s_role.trim(),
      model: root.s_model,
      temperature: root.s_temperature,
      top_p: root.s_top_p,
      thinking: root.s_thinking ? "enabled" : "disabled",
      reasoning_effort: root.s_reasoning_effort,
      response_format: root.s_response_format,
      save_history: root.s_save_history ? "y" : "n"
    }
    root.writeConfig(true)
    root.loadHistoryIfEnabled()
  }

  // Restore the default config: overwrite the form, write it to the config
  // file, and apply it immediately. History defaults to disabled, so the
  // history file is also deleted.
  function restoreDefaults() {
    root.config = AskModel.defaultConfig()
    root.loadSettings()
    root.writeConfig(false)
    root.loadHistoryIfEnabled()
    clearProc.command = ["sh", "-c", 'rm -f "$1"', "sh", root.historyFile]
    clearProc.running = true
    root.restoredFlash = true
    restoredTimer.restart()
  }

  // ---- API tab ----

  function loadApiSettings() {
    root.apiKeyStatus = "The key is read from " + root.keyFile + "."
    root.apiKeyReadDone = false
    apiKeyReadProc.command = root.safeReadCommand(root.keyFile, 4096)
    apiKeyReadProc.running = true
  }

  function onApiKeyFileRead(text) {
    if (root.apiKeyReadDone) return
    root.apiKeyReadDone = true
    root.s_api_key = String(text || "").trim()
  }

  function saveApiKey() {
    var key = root.s_api_key.trim()
    if (key === "") {
      root.apiKeyStatus = "Enter an API key first."
      return
    }
    root._pendingKey = key
    keyWriteProc.stdinEnabled = true
    keyWriteProc.command = root.secureWriteStdinCommand(root.configDir, root.keyFile)
    keyWriteProc.running = true
    root.apiKeyStatus = "Saved to " + root.keyFile + " with owner-only permissions (600)."
    root.apiKeyFlashText = "Saved"
    apiKeyTimer.restart()
  }

  function removeApiKey() {
    root.s_api_key = ""
    clearProc.command = ["sh", "-c", 'rm -f "$1"', "sh", root.keyFile]
    clearProc.running = true
    root.apiKeyStatus = "Stored key removed."
    root.apiKeyFlashText = "Removed"
    apiKeyTimer.restart()
  }

  // ---- Model list ----

  function staticModelOptions() {
    return ["deepseek-v4-flash", "deepseek-v4-pro"]
  }

  function loadModels() {
    root.modelLoading = true
    root.modelsError = ""
    root.modelsKeyReadDone = false
    modelsKeyProc.command = root.safeReadCommand(root.keyFile, 4096)
    modelsKeyProc.running = true
  }

  function onModelsKeyRead(text) {
    if (root.modelsKeyReadDone) return
    root.modelsKeyReadDone = true
    var key = String(text || "").trim()
    if (!key) {
      root.modelLoading = false
      root.modelsError = "Set an API key in the API tab to load the model list."
      root.modelOptions = root.staticModelOptions()
      return
    }
    root._pendingHeader = "Authorization: Bearer " + key
    root._pendingRequestType = "models"
    headerWriteProc.stdinEnabled = true
    headerWriteProc.command = root.secureWriteStdinCommand(root.configDir, root.headerFile)
    headerWriteProc.running = true
  }

  function onModelsResponse(text) {
    root.modelLoading = false
    modelsWatchdog.stop()
    var ids = []
    try {
      var data = JSON.parse(text)
      if (data && Array.isArray(data.data) && data.data.length > 0) {
        for (var i = 0; i < data.data.length; i++) {
          if (data.data[i].id) ids.push(String(data.data[i].id))
        }
      }
    } catch (e) {
      ids = []
    }
    if (ids.length === 0) {
      root.modelsError = "Could not fetch the model list."
      root.modelOptions = root.staticModelOptions()
      return
    }
    // Keep the currently selected model visible even if it is no longer
    // listed by the API.
    if (ids.indexOf(root.s_model) === -1) ids.unshift(root.s_model)
    root.modelOptions = ids
  }

  // ---- IO processes ----

  Process {
    id: configReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onConfigRead(String(text || ""))
    }
    onExited: function(code) {
      if (code !== 0 && !root.configReadDone) root.onConfigRead("")
    }
  }

  Process {
    id: historyReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onHistoryRead(String(text || ""))
    }
    onExited: function(code) {
      if (code !== 0 && !root.historyReadDone) root.onHistoryRead("")
    }
  }

  Process {
    id: keyReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onKeyRead(String(text || ""))
    }
    onExited: function(code) {
      if (code !== 0 && !root.keyReadDone) root.onKeyRead("")
    }
  }

  Process {
    id: apiKeyReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onApiKeyFileRead(String(text || ""))
    }
    onExited: function(code) {
      if (code !== 0 && !root.apiKeyReadDone) root.onApiKeyFileRead("")
    }
  }

  Process {
    id: modelsKeyProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onModelsKeyRead(String(text || ""))
    }
    onExited: function(code) {
      if (code !== 0 && !root.modelsKeyReadDone) root.onModelsKeyRead("")
    }
  }

  Process {
    id: modelsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.onModelsResponse(String(text || ""))
    }
    onExited: function(code) {
      modelsWatchdog.stop()
      if (root.modelLoading) {
        root.modelLoading = false
        root.modelsError = "Could not fetch the model list."
        root.modelOptions = root.staticModelOptions()
      }
    }
  }

  Process {
    id: apiProc
    stdinEnabled: true
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.apiStdout = String(text || "")
        root.apiStdoutDone = true
        root.tryFinishApi()
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.apiStderr = String(text || "").trim()
    }
    onStarted: function() {
      apiProc.write(root._pendingBody)
      apiProc.stdinEnabled = false
    }
    onExited: function(code) {
      root.apiExitCode = code
      root.apiExited = true
      root.tryFinishApi()
    }
  }

  Process {
    id: historyWriteProc
    stdinEnabled: true
    onStarted: function() {
      historyWriteProc.write(root._pendingHistory)
      historyWriteProc.stdinEnabled = false
    }
  }

  Process {
    id: configWriteProc
    stdinEnabled: true
    onStarted: function() {
      configWriteProc.write(root._pendingConfig)
      configWriteProc.stdinEnabled = false
    }
  }

  Process {
    id: keyWriteProc
    stdinEnabled: true
    onStarted: function() {
      keyWriteProc.write(root._pendingKey)
      keyWriteProc.stdinEnabled = false
    }
  }

  Process {
    id: headerWriteProc
    stdinEnabled: true
    onStarted: function() {
      headerWriteProc.write(root._pendingHeader)
      headerWriteProc.stdinEnabled = false
    }
    onExited: function(code) {
      if (code !== 0) {
        if (root._pendingRequestType === "models") {
          root.modelLoading = false
          root.modelsError = "Could not prepare the model request."
          root.modelOptions = root.staticModelOptions()
        } else {
          root.busy = false
          root.setLastAnswer("Could not prepare the request.", true)
          Qt.callLater(function() { inputField.forceActiveFocus() })
        }
        return
      }
      root.launchPendingRequest()
    }
  }

  Process {
    id: clearProc
    onExited: function(code) {
      // Empty handler: a Process without any signal handler is not reliably
      // started, so keep this hook to guarantee the rm actually runs.
    }
  }

  Process {
    id: sweepProc
    onExited: function(code) {
      // Empty handler: a Process without any signal handler is not reliably
      // started, so keep this hook to guarantee the sweep actually runs.
    }
  }

  // One row per exchange: { question, answer, isError }. Grouping each
  // question with its answer keeps the conversation readable as a thread.
  property ListModel threadModel: ListModel {}

  Timer {
    id: scrollTimer
    interval: 60
    repeat: true
    onTriggered: {
      chatList.positionViewAtEnd()
      root.scrollTicks++
      if (root.scrollTicks >= 6) scrollTimer.stop()
    }
  }

  Timer {
    id: savedTimer
    interval: 1600
    onTriggered: root.savedFlash = false
  }

  Timer {
    id: restoredTimer
    interval: 1600
    onTriggered: root.restoredFlash = false
  }

  Timer {
    id: clearedTimer
    interval: 1600
    onTriggered: root.clearedFlash = false
  }

  Timer {
    id: copiedTimer
    interval: 1600
    onTriggered: root.copiedFlash = false
  }

  // Watchdogs: curl enforces its own --max-time / --max-filesize, but these
  // guarantee the Process is torn down even if it never exits (e.g. failed to
  // start) so the shell can never hang on a request.
  Timer {
    id: apiWatchdog
    interval: 130000
    onTriggered: {
      if (!root.busy) return
      apiProc.signal(9)
      root.busy = false
      root.apiStdout = ""
      root.apiStderr = ""
      root.setLastAnswer("Request timed out.", true)
      Qt.callLater(function() { inputField.forceActiveFocus() })
    }
  }

  Timer {
    id: modelsWatchdog
    interval: 35000
    onTriggered: {
      root.modelLoading = false
      root.modelsError = "Could not fetch the model list (timed out)."
      root.modelOptions = root.staticModelOptions()
    }
  }

  Timer {
    id: apiKeyTimer
    interval: 1600
    onTriggered: root.apiKeyFlashText = ""
  }

  // ---- Window ----

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "henk-ask"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onPressed: function(event) {
          if (event.key === Qt.Key_Escape) {
            if (root.currentTab === "settings" || root.currentTab === "api" || root.currentTab === "about") {
              root.currentTab = "ask"
              event.accepted = true
              return
            }
            root.dismiss()
            event.accepted = true
          }
        }

        Item {
          anchors.fill: parent
          anchors.topMargin: card.contentTopInset
          anchors.rightMargin: card.contentRightInset
          anchors.bottomMargin: card.contentBottomInset
          anchors.leftMargin: card.contentLeftInset

        // ---- Header: tabs + close ----
        Item {
          id: header
          anchors.top: parent.top
          anchors.left: parent.left
          anchors.right: parent.right
          height: root.headerHeight

          Button {
            id: askTabButton
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "Ask"
            fontFamily: Style.font.family
            fontSize: Style.font.title
            selected: root.currentTab === "ask"
            focusable: true
            onClicked: root.currentTab = "ask"
          }

          Button {
            id: settingsTabButton
            anchors.left: askTabButton.right
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: "Settings"
            fontFamily: Style.font.family
            fontSize: Style.font.title
            selected: root.currentTab === "settings"
            focusable: true
            onClicked: {
              root.loadSettings()
              root.loadModels()
              root.currentTab = "settings"
            }
          }

          Button {
            id: apiTabButton
            anchors.left: settingsTabButton.right
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: "API"
            fontFamily: Style.font.family
            fontSize: Style.font.title
            selected: root.currentTab === "api"
            focusable: true
            onClicked: {
              root.loadApiSettings()
              root.currentTab = "api"
            }
          }

          Button {
            id: aboutTabButton
            anchors.left: apiTabButton.right
            anchors.leftMargin: Style.spacing.md
            anchors.verticalCenter: parent.verticalCenter
            text: "About"
            fontFamily: Style.font.family
            fontSize: Style.font.title
            selected: root.currentTab === "about"
            focusable: true
            onClicked: root.currentTab = "about"
          }

          Button {
            id: closeButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Close"
            fontFamily: Style.font.family
            fontSize: Style.font.body
            focusable: true
            onClicked: root.dismiss()
          }
        }

        PanelSeparator {
          id: separator
          anchors.top: header.bottom
          anchors.left: parent.left
          anchors.right: parent.right
        }

        Item {
          id: contentArea
          anchors.top: separator.bottom
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          anchors.topMargin: Style.spacing.xl

          // ---- Ask tab ----
          Item {
            id: askContent
            anchors.fill: parent
            visible: root.currentTab === "ask"

            ListView {
              id: chatList
              anchors.top: parent.top
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: inputRow.top
              anchors.bottomMargin: Style.spacing.xxl
              clip: true
              spacing: Style.spacing.xxs
              boundsBehavior: Flickable.StopAtBounds
              model: threadModel
              delegate: threadDelegate
            }

            Row {
              id: inputRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              spacing: Style.spacing.xxl
              height: Style.spacing.controlHeight

              TextField {
                id: inputField
                width: parent.width - sendButton.width - clearButton.width - parent.spacing * 2
                height: Style.spacing.controlHeight
                placeholderText: root.busy ? "Waiting for DeepSeek..." : "Ask DeepSeek..."
                enabled: !root.busy
                onAccepted: root.send()
              }

              Button {
                id: sendButton
                width: Style.space(96)
                height: Style.spacing.controlHeight
                text: root.busy ? "..." : "Send"
                fontFamily: Style.font.family
                fontSize: Style.font.body
                focusable: true
                enabled: !root.busy
                onClicked: root.send()
              }

              Button {
                id: clearButton
                width: Style.space(96)
                height: Style.spacing.controlHeight
                text: "Clear"
                fontFamily: Style.font.family
                fontSize: Style.font.body
                focusable: true
                enabled: !root.busy && threadModel.count > 0
                onClicked: root.clearHistory()
              }
            }

            Rectangle {
              visible: root.clearedFlash
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: inputRow.top
              anchors.bottomMargin: Style.spacing.md
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.foreground, root.accent)
              implicitWidth: clearedLabel.implicitWidth + Style.spacing.xxl * 2
              implicitHeight: clearedLabel.implicitHeight + Style.spacing.xxs * 2
              z: 3

              Text {
                id: clearedLabel
                anchors.centerIn: parent
                text: "History cleared"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }

            Rectangle {
              visible: root.copiedFlash
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.bottom: inputRow.top
              anchors.bottomMargin: Style.spacing.md
              radius: Style.cornerRadius
              color: Style.hoverFillFor(root.foreground, root.accent)
              implicitWidth: copiedLabel.implicitWidth + Style.spacing.xxl * 2
              implicitHeight: copiedLabel.implicitHeight + Style.spacing.xxs * 2
              z: 3

              Text {
                id: copiedLabel
                anchors.centerIn: parent
                text: "Copied to clipboard"
                color: root.foreground
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }
            }
          }

          // ---- Settings tab ----
          Item {
            id: settingsContent
            anchors.fill: parent
            visible: root.currentTab === "settings"

            Flickable {
              id: settingsScroll
              anchors.fill: parent
              contentHeight: settingsColumn.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: settingsColumn
                width: settingsScroll.width
                spacing: Style.spacing.panelGap

                // Role
                Column {
                  width: parent.width
                  spacing: Style.spacing.labelGap
                  Text {
                    text: "Role / system prompt"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                  }
                  TextField {
                    width: parent.width
                    text: root.s_role
                    placeholderText: "You are a helpful assistant."
                    onTextEdited: root.s_role = text
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Model"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Button {
                    id: modelsRefreshButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Refresh"
                    fontFamily: Style.font.family
                    fontSize: Style.font.caption
                    focusable: true
                    enabled: !root.modelLoading
                    onClicked: root.loadModels()
                  }
                  Dropdown {
                    width: Style.space(220)
                    height: Style.spacing.controlHeight
                    value: root.s_model
                    options: root.modelOptions
                    anchors.right: modelsRefreshButton.left
                    anchors.rightMargin: Style.spacing.xxl
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: function(v) { root.s_model = v }
                  }
                }

                Text {
                  visible: root.modelLoading || root.modelsError !== ""
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: root.modelLoading ? "Loading models..." : root.modelsError
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Thinking"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  ToggleSwitch {
                    checked: root.s_thinking
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: root.s_thinking = !root.s_thinking
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Reasoning effort"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Dropdown {
                    width: Style.space(220)
                    height: Style.spacing.controlHeight
                    value: root.s_reasoning_effort
                    options: ["low", "high", "max"]
                    enabled: root.s_thinking
                    opacity: root.s_thinking ? 1 : 0.5
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: function(v) { root.s_reasoning_effort = v }
                  }
                }

                PanelSectionHeader {
                  text: "Sampling"
                }

                Item {
                  width: parent.width
                  height: Style.space(26)
                  Text {
                    text: "Temperature"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  PanelSlider {
                    id: tempSlider
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(120)
                    anchors.right: tempValue.left
                    anchors.rightMargin: Style.spacing.xxl
                    anchors.verticalCenter: parent.verticalCenter
                    minimum: 0
                    maximum: 2
                    step: 0.05
                    value: root.s_temperature
                    onMoved: function(v) { root.s_temperature = v }
                  }
                  Text {
                    id: tempValue
                    text: root.s_temperature.toFixed(2)
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Item {
                  width: parent.width
                  height: Style.space(26)
                  Text {
                    text: "Top P"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  PanelSlider {
                    id: topPSlider
                    anchors.left: parent.left
                    anchors.leftMargin: Style.space(120)
                    anchors.right: topPValue.left
                    anchors.rightMargin: Style.spacing.xxl
                    anchors.verticalCenter: parent.verticalCenter
                    minimum: 0
                    maximum: 1
                    step: 0.01
                    value: root.s_top_p
                    onMoved: function(v) { root.s_top_p = v }
                  }
                  Text {
                    id: topPValue
                    text: root.s_top_p.toFixed(2)
                    color: root.foreground
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Output format"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  Dropdown {
                    width: Style.space(220)
                    height: Style.spacing.controlHeight
                    value: root.s_response_format
                    options: [
                      { value: "text", label: "text" },
                      { value: "json_object", label: "json_object" }
                    ]
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: function(v) { root.s_response_format = v }
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight
                  Text {
                    text: "Save conversation history"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                  }
                  ToggleSwitch {
                    checked: root.s_save_history
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onToggled: root.s_save_history = !root.s_save_history
                  }
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "With history enabled, follow-up questions keep context and the chat shows past exchanges from " + root.historyFile + ". Disabled keeps each question one-shot."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                PanelSeparator {
                  width: parent.width
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight

                  Button {
                    id: saveButton
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Save settings"
                    fontFamily: Style.font.family
                    fontSize: Style.font.body
                    focusable: true
                    onClicked: root.saveSettings()
                  }

                  Text {
                    visible: root.savedFlash
                    text: "Saved"
                    color: Style.selectedStateColor(root.foreground, root.accent)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.left: saveButton.right
                    anchors.leftMargin: Style.spacing.xxl
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Button {
                    id: restoreButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Restore defaults"
                    fontFamily: Style.font.family
                    fontSize: Style.font.body
                    focusable: true
                    onClicked: root.restoreDefaults()
                  }

                  Text {
                    visible: root.restoredFlash
                    text: "Restored"
                    color: Style.selectedStateColor(root.foreground, root.accent)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.right: restoreButton.left
                    anchors.rightMargin: Style.spacing.xxl
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Item { width: 1; height: Style.spacing.xs }
              }
            }
          }

          // ---- API tab ----
          Item {
            id: apiContent
            anchors.fill: parent
            visible: root.currentTab === "api"

            Flickable {
              id: apiScroll
              anchors.fill: parent
              contentHeight: apiColumn.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: apiColumn
                width: apiScroll.width
                spacing: Style.spacing.panelGap

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "Enter your DeepSeek API key. It is stored in " + root.keyFile + " with owner-only permissions (chmod 600)."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }

                Column {
                  width: parent.width
                  spacing: Style.spacing.labelGap
                  Text {
                    text: "DeepSeek API key"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pointSize: 9
                    font.bold: true
                  }
                  TextField {
                    id: apiKeyField
                    width: parent.width
                    text: root.s_api_key
                    placeholderText: "sk-..."
                    password: true
                    onTextEdited: root.s_api_key = text
                  }
                }

                Item {
                  width: parent.width
                  height: Style.spacing.controlHeight

                  Button {
                    id: saveKeyButton
                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Save API key"
                    fontFamily: Style.font.family
                    fontSize: Style.font.body
                    focusable: true
                    onClicked: root.saveApiKey()
                  }

                  Text {
                    visible: root.apiKeyFlashText !== ""
                    text: root.apiKeyFlashText
                    color: Style.selectedStateColor(root.foreground, root.accent)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                    anchors.left: saveKeyButton.right
                    anchors.leftMargin: Style.spacing.xxl
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Button {
                    id: removeKeyButton
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: "Remove stored key"
                    fontFamily: Style.font.family
                    fontSize: Style.font.body
                    focusable: true
                    onClicked: root.removeApiKey()
                  }
                }

                PanelSeparator {
                  width: parent.width
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: root.apiKeyStatus
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                }
              }
            }
          }

          // ---- About tab ----
          Item {
            id: aboutContent
            anchors.fill: parent
            visible: root.currentTab === "about"

            Flickable {
              id: aboutScroll
              anchors.fill: parent
              contentHeight: aboutColumn.height
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: aboutColumn
                width: aboutScroll.width
                spacing: Style.spacing.panelGap

                Text {
                  text: (root.manifest && root.manifest.name) || "Ask DeepSeek"
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.heading
                  font.bold: true
                }

                Text {
                  text: "Version " + ((root.manifest && root.manifest.version) || "?")
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  text: "Released: " + ((root.manifest && root.manifest.releaseDate) || "?")
                  color: root.foreground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  text: 'GitHub: <a href="https://github.com/henksys/omarchy-ask-deepseek" style="text-decoration:none">https://github.com/henksys/omarchy-ask-deepseek</a>'
                  textFormat: Text.StyledText
                  color: root.foreground
                  linkColor: Style.selectedStateColor(root.foreground, root.accent)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  onLinkActivated: function(link) { Qt.openUrlExternally(link) }
                }

                PanelSeparator {
                  width: parent.width
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: (root.manifest && root.manifest.description) || "Chat with DeepSeek from your desktop — ask a question and get an answer, with the conversation shown as a scrollable thread."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  text: "Features"
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Column {
                  width: parent.width
                  spacing: Style.spacing.xs

                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "- Threaded conversation: each question paired with its answer"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "- Double-click a question or answer to copy it to the clipboard"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "- Optional conversation history for follow-up context"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "- Live model list from DeepSeek (Settings - Refresh)"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    width: parent.width
                    wrapMode: Text.Wrap
                    text: "- API key stored locally with owner-only permissions (API tab)"
                    color: Qt.darker(root.foreground, 1.4)
                    font.family: Style.font.family
                    font.pixelSize: Style.font.body
                  }
                }

                PanelSeparator {
                  width: parent.width
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "All open source scripting, no use of binaries: the whole UI, the logic, and even the API call (it runs curl and parses JSON — all visible in Ask.qml/AskModel.js). There are no compiled artifacts, no obfuscation."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }

                Text {
                  width: parent.width
                  wrapMode: Text.Wrap
                  text: "Licensed under the MIT License."
                  color: Qt.darker(root.foreground, 1.4)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                }
              }
            }
          }
        }
      }
    }
  }
  }

  // ---- Components ----

  Component {
    id: threadDelegate

    Item {
      id: wrap
      required property var model
      width: chatList.width
      height: contentColumn.height + Style.spacing.xxl

      Column {
        id: contentColumn
        anchors.left: parent.left
        anchors.right: parent.right
        spacing: Style.spacing.xs

        Rectangle {
          id: questionBubble
          anchors.right: parent.right
          width: Math.min(wrap.width * 0.86, questionText.implicitWidth + Style.spacing.xxl * 2)
          height: questionText.height + Style.spacing.xl * 2
          radius: Style.cornerRadius
          color: Style.selectedFillFor(root.foreground, root.accent)

          TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: root.copyAnswer(model.question)
          }

          Text {
            id: questionText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Style.spacing.xxl
            anchors.rightMargin: Style.spacing.xxl
            anchors.topMargin: Style.spacing.xl
            text: model.question
            color: Style.selectedStateColor(root.foreground, root.accent)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
          }
        }

        Rectangle {
          id: answerBubble
          anchors.left: parent.left
          visible: model.answer !== ""
          width: Math.min(wrap.width * 0.86, answerText.implicitWidth + Style.spacing.xxl * 2)
          height: answerText.height + Style.spacing.xl * 2
          radius: Style.cornerRadius
          color: model.isError ? Util.alpha(Color.urgent, 0.22) : Style.hoverFillFor(root.foreground, root.accent)

          TapHandler {
            acceptedButtons: Qt.LeftButton
            onDoubleTapped: root.copyAnswer(model.answer)
          }

          Text {
            id: answerText
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: Style.spacing.xxl
            anchors.rightMargin: Style.spacing.xxl
            anchors.topMargin: Style.spacing.xl
            text: model.answer
            color: model.isError ? Color.urgent : root.foreground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            wrapMode: Text.Wrap
            textFormat: Text.PlainText
          }
        }
      }
    }
  }
}
