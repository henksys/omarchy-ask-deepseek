// AskModel.js - config/history/request/response logic for the Ask panel.
// Mirrors the JSON handling of the bash version of `ask` (which used python3
// heredocs). All functions are pure JS so the QML UI stays about drawing.

// Strip `//` comment lines from the JSONC config file. Comments must be on
// their own line (same rule as the bash version).
function stripComments(text) {
  var lines = String(text || "").split("\n")
  var out = []
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim().indexOf("//") === 0) continue
    out.push(lines[i])
  }
  return out.join("\n")
}

// Parse the config file text into an object.
// Returns null on parse failure.
function parseConfig(text) {
  try {
    return JSON.parse(stripComments(text))
  } catch (e) {
    return null
  }
}

// The same defaults the bash version writes on first run.
function defaultConfig() {
  return {
    role: "You are a helpful assistant.",
    model: "deepseek-v4-flash",
    temperature: 1,
    top_p: 1,
    thinking: "enabled",
    reasoning_effort: "high",
    response_format: "text",
    save_history: "n"
  }
}

// Serialize a config object back to plain JSON text. Written without // 
// comments; the bash version parses it fine (it just strips comment lines).
function serializeConfig(cfg) {
  return JSON.stringify(cfg, null, 2) + "\n"
}

// Merge a parsed config with defaults so missing keys never break the UI.
function withDefaults(cfg) {
  var def = defaultConfig()
  var merged = {}
  for (var key in def) merged[key] = def[key]
  if (cfg) for (var k in cfg) merged[k] = cfg[k]
  return merged
}

// Parse history.jsonl (one JSON object per line) into an array of messages.
function parseHistory(text) {
  var out = []
  var lines = String(text || "").split("\n")
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i].trim()
    if (!line) continue
    try {
      out.push(JSON.parse(line))
    } catch (e) {
      // skip malformed lines
    }
  }
  return out
}

// Group a history.jsonl text into exchanges: each user message followed by
// its assistant answer becomes one thread {question, answer}. An assistant
// message without a preceding user (or a trailing unanswered question) still
// yields a thread so nothing is dropped.
function parseThreads(text) {
  var hist = parseHistory(text)
  var threads = []
  var current = null
  for (var i = 0; i < hist.length; i++) {
    var m = hist[i]
    if (m.role === "user") {
      current = { question: String(m.content || ""), answer: "" }
      threads.push(current)
    } else if (m.role === "assistant") {
      if (current && current.answer === "") {
        current.answer = String(m.content || "")
        current = null
      } else {
        threads.push({ question: "", answer: String(m.content || "") })
      }
    }
  }
  return threads
}

// Build the API `messages` array: system role, then history, then the
// new user question. Same shape as the bash version.
function buildMessages(cfg, history, question) {
  var messages = []
  var role = String(cfg.role || "").trim()
  if (role) messages.push({ role: "system", content: role })
  for (var i = 0; i < history.length; i++) {
    var m = history[i]
    if (m && m.role && m.content) messages.push(m)
  }
  messages.push({ role: "user", content: question })
  return messages
}

// Build the DeepSeek request body from the config and messages.
function buildRequest(cfg, messages) {
  function num(v, fallback) {
    var n = parseFloat(v)
    return isNaN(n) ? fallback : n
  }
  var thinking = { type: String(cfg.thinking || "enabled") }
  if (thinking.type === "enabled") {
    thinking.reasoning_effort = String(cfg.reasoning_effort || "high")
  }
  return {
    model: String(cfg.model || "deepseek-v4-flash"),
    messages: messages,
    temperature: num(cfg.temperature, 1),
    top_p: num(cfg.top_p, 1),
    thinking: thinking,
    response_format: { type: String(cfg.response_format || "text") }
  }
}

// Parse the raw API response body.
// Returns one of:
//   { answer: "..." }
//   { error: "..." }
//   { unexpected: <parsed object> }
function parseResponse(raw) {
  var data = null
  try {
    data = JSON.parse(raw)
  } catch (e) {
    return { error: "Invalid response from API:\n" + raw }
  }
  if (data && Array.isArray(data.choices) && data.choices.length > 0) {
    var content = data.choices[0].message && data.choices[0].message.content
    if (typeof content === "string") return { answer: content }
    return { error: "API response had no text content." }
  }
  if (data && data.error) {
    return { error: "API error: " + (data.error.message || JSON.stringify(data.error)) }
  }
  return { unexpected: data }
}

if (typeof module !== "undefined") {
  module.exports = {
  stripComments: stripComments,
  parseConfig: parseConfig,
  defaultConfig: defaultConfig,
  serializeConfig: serializeConfig,
  withDefaults: withDefaults,
  parseHistory: parseHistory,
  parseThreads: parseThreads,
  buildMessages: buildMessages,
  buildRequest: buildRequest,
  parseResponse: parseResponse
  }
}
