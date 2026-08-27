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

  function loadConfig() {
    root.configReadDone = false
    configReadProc.command = ["cat", root.configFile]
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
    configWriteProc.command = [
      "sh", "-c", 'mkdir -p "$1" && printf \'%s\' "$2" > "$3"',
      "sh", root.configDir, text, root.configFile
    ]
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
    historyReadProc.command = ["cat", root.historyFile]
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
    var userLine = JSON.stringify({ role: "user", content: question })
    var asstLine = JSON.stringify({ role: "assistant", content: answer })
    historyWriteProc.command = [
      "sh", "-c", 'mkdir -p "$1" && printf \'%s\\n\' "$2" "$3" >> "$4"',
      "sh", root.historyDir, userLine, asstLine, root.historyFile
    ]
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

    // Prefer the environment variable (as the terminal `ask` does); fall back
    // to a key file at ~/.config/ask/key so the panel also works when the
    // desktop shell was started without the variable exported.
    var key = Quickshell.env("DEEPSEEK_API_KEY") || ""
    if (key) {
      root.sendWithKey(question, key)
      return
    }

    root.keyReadDone = false
    keyReadProc.command = ["cat", root.keyFile]
    keyReadProc.running = true
  }

  function onKeyRead(text) {
    if (root.keyReadDone) return
    root.keyReadDone = true
    var key = String(text || "").trim()
    if (!key) {
      root.busy = false
      root.setLastAnswer("Error: DEEPSEEK_API_KEY is not set and no key file found at " + root.keyFile + ".", true)
      Qt.callLater(function() { inputField.forceActiveFocus() })
      return
    }
    root.sendWithKey(root.lastQuestion, key)
  }

  function sendWithKey(question, key) {
    var history = root.saveHistory ? AskModel.parseHistory(root._historyText) : []
    var msgs = AskModel.buildMessages(root.config, history, question)
    var body = JSON.stringify(AskModel.buildRequest(root.config, msgs))

    apiProc.command = [
      "curl", "-s", "https://api.deepseek.com/chat/completions",
      "-H", "Content-Type: application/json",
      "-H", "Authorization: Bearer " + key,
      "-d", body
    ]
    apiProc.running = true
  }

  function tryFinishApi() {
    if (root.apiStdoutDone && root.apiExited) root.finishApi(root.apiExitCode)
  }

  function finishApi(exitCode) {
    // Guarded by apiStdoutDone/apiExited so a single response is processed
    // exactly once regardless of stream-finished vs exited signal order.
    root.busy = false
    if (exitCode !== 0 && root.apiStdout === "") {
      root.setLastAnswer("Request failed (exit " + exitCode + ").\n" + (root.apiStderr || ""), true)
    } else {
      var result = AskModel.parseResponse(root.apiStdout)
      if (result.answer !== undefined) {
        root.setLastAnswer(result.answer, false)
        if (root.saveHistory) {
          root.writeHistory(root.lastQuestion, result.answer)
          // Keep the in-memory history in sync so the next question's
          // context includes this exchange without needing a reload.
          root._historyText += JSON.stringify({ role: "user", content: root.lastQuestion }) + "\n"
          root._historyText += JSON.stringify({ role: "assistant", content: result.answer }) + "\n"
        }
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
    var envKey = Quickshell.env("DEEPSEEK_API_KEY") || ""
    if (envKey) {
      root.apiKeyStatus = "The DEEPSEEK_API_KEY environment variable is set and takes priority. You can still save a key below as a fallback."
    } else {
      root.apiKeyStatus = "No DEEPSEEK_API_KEY environment variable. The key is read from " + root.keyFile + "."
    }
    root.apiKeyReadDone = false
    apiKeyReadProc.command = ["cat", root.keyFile]
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
    keyWriteProc.command = [
      "sh", "-c", 'mkdir -p "$1" && printf \'%s\' "$2" > "$3" && chmod 600 "$3"',
      "sh", root.configDir, key, root.keyFile
    ]
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
    id: apiProc
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
    onExited: function(code) {
      root.apiExitCode = code
      root.apiExited = true
      root.tryFinishApi()
    }
  }

  Process {
    id: historyWriteProc
  }

  Process {
    id: configWriteProc
  }

  Process {
    id: keyWriteProc
  }

  Process {
    id: clearProc
    onExited: function(code) {
      // Empty handler: a Process without any signal handler is not reliably
      // started, so keep this hook to guarantee the rm actually runs.
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
            if (root.currentTab === "settings" || root.currentTab === "api") {
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
                  Dropdown {
                    width: Style.space(220)
                    height: Style.spacing.controlHeight
                    value: root.s_model
                    options: ["deepseek-v4-flash", "deepseek-v4-pro"]
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    onChanged: root.s_model = value
                  }
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
                    onChanged: root.s_reasoning_effort = value
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
                    onMoved: root.s_temperature = value
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
                    onMoved: root.s_top_p = value
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
                    onChanged: root.s_response_format = value
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
                  text: "Enter your DeepSeek API key. It is stored in " + root.keyFile + " with owner-only permissions (chmod 600). If the DEEPSEEK_API_KEY environment variable is set, it takes priority."
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
