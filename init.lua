-- Devin CLI integration for TTT.
--
-- Two lanes:
--   * Interactive sessions: `devin` running in an integrated terminal tab
--     (label "dv"). Seeded sessions pass context as a single argv prompt so
--     multi-line code never hits the PTY as keystrokes.
--   * Quick ask: `devin -p -- "<prompt>"` runs non-interactively and the
--     answer opens in a read-only editor tab.
--
-- Settings (settings.json):
--   "devin.model": model flag passed to spawned sessions, e.g. "opus".

local ttt = require("ttt")
local term = require("ttt.terminal")
local editor = require("ttt.editor")
local sys = require("ttt.system")
local settings = require("ttt.settings")
local storage = require("ttt.storage")
local fs = require("ttt.fs")

-- The plugin's own namespace: command ids, status item, terminal label.
local PLUGIN_ID = "agenttt"

-- Everything agent-specific lives here: the binary, its subcommand flags,
-- display names, and the settings namespace. To retarget the plugin at a
-- different agent, edit this table (and the manifest's system.exec
-- allowlist) — nothing below hardcodes the agent.
local AGENT = {
  ns = "devin",                 -- settings prefix and status text
  label = "Devin",              -- user-facing name
  cmd = "devin",                -- binary on PATH
  acp_args = { "acp" },         -- starts the ACP stdio server
  print_args = { "-p" },        -- one-shot print mode
  continue_args = { "-c" },     -- resume most recent conversation
  model_flag = "--model",       -- model selection flag
  doctor_args = { "doctor" },   -- self-diagnostic subcommand
  version_args = { "version" }, -- version probe
}

local LABEL = PLUGIN_ID
local HISTORY_KEY = "ask_history"
local HISTORY_MAX = 8

local state = {
  checked = false,   -- whether we probed for the devin binary
  version = nil,     -- devin version string, or nil when not found
  asking = false,    -- a quick-ask request is in flight
  last_line = "",    -- last quick-ask question, for the panel
}

local acp            -- ACP session table; assigned in the ACP section below

-- ---------------------------------------------------------------- helpers --

local function agent_version()
  if state.checked then return state.version end
  state.checked = true
  local res = sys.exec(AGENT.cmd, AGENT.version_args)
  if res and res.exit_code == 0 then
    state.version = (res.stdout:gsub("%s+$", ""))
  end
  return state.version
end

local function model_args()
  local m = settings.get(AGENT.ns .. ".model")
  if type(m) == "string" and m ~= "" then
    return { AGENT.model_flag, m }
  end
  return {}
end

local function append(dst, src)
  for _, v in ipairs(src) do dst[#dst + 1] = v end
  return dst
end

local function update_status()
  local n = 0
  if term.list then
    for _, t in ipairs(term.list() or {}) do
      if t.label == LABEL then n = n + 1 end
    end
  end
  local text = AGENT.ns
  if acp and (acp.status == "prompting") then
    text = AGENT.ns .. " ● streaming"
  elseif acp and (acp.status == "connecting" or acp.status == "sessioning") then
    text = AGENT.ns .. " ○ connecting"
  elseif n > 0 then
    text = AGENT.ns .. ":" .. n
  end
  ttt.set_status_item("right", PLUGIN_ID, text, {
    on_click = function() ttt.show_panel("bottom") end,
  })
end

local function live_terminals()
  local out = {}
  if not term.list then return out end
  for _, t in ipairs(term.list() or {}) do
    if t.label == LABEL then out[#out + 1] = t end
  end
  return out
end

local function last_terminal()
  local ts = live_terminals()
  return ts[#ts] and ts[#ts].id or nil
end

local function notify_err(msg)
  ttt.log("error", AGENT.ns .. ": " .. msg)
  ttt.notify(AGENT.label .. ": " .. msg, "error")
end

-- ------------------------------------------------------------- context --

local function file_ctx()
  if not editor.file_path then return nil end
  local path = editor.file_path()
  if not path or path == "" then return nil end
  return path
end

-- Directory a spawned session should run in: the active file's directory
-- when one is open (devin can then read it with relative paths), else the
-- workspace root (empty string lets term.spawn pick it).
local function session_cwd()
  local path = file_ctx()
  if path then
    return path:match("^(.*)/[^/]*$") or ""
  end
  return ""
end

local function cursor_line()
  local c = editor.cursor and editor.cursor()
  return c and c.line or nil
end

local function selection_ctx()
  local sel = editor.selection and editor.selection()
  if not (sel and sel.active) then return nil end
  return {
    path = editor.file_path() or "",
    lang = editor.language() or "",
    first = math.min(sel.start_line, sel.end_line),
    last = math.max(sel.start_line, sel.end_line),
    text = editor.selection_text() or "",
  }
end

-- Full context block used to seed a brand-new session.
local function seeded_prompt(ctx, question)
  if ctx.text and ctx.text ~= "" then
    return string.format(
      "In `%s` (lines %d-%d):\n\n```%s\n%s\n```\n\n%s",
      ctx.path, ctx.first, ctx.last, ctx.lang, ctx.text, question or "")
  end
  return string.format("Regarding `%s`: %s", ctx.path, question or "")
end

-- Compact one-line reference sent into an already-running session; Devin can
-- read the file itself, so only the coordinates and the question go over the
-- PTY.
local function reference_line(ctx, question)
  return string.format("%s:%d-%d — %s", ctx.path, ctx.first, ctx.last, question or "")
end

-- First message of every new session: tells devin which file is open and
-- where the cursor/selection sits, like the IDE integrations do. After this
-- "this file" / "this line" just work in conversation.
local function seed_prompt()
  local ctx = selection_ctx()
  if ctx then
    return string.format(
      "Editor context: I'm looking at `%s` lines %d-%d:\n\n```%s\n%s\n```\n\nNo action needed yet — I'll send a task next.",
      ctx.path, ctx.first, ctx.last, ctx.lang, ctx.text)
  end
  local path = file_ctx()
  if not path then return nil end
  local ln = cursor_line()
  if ln then
    return string.format(
      "Editor context: I have `%s` open at line %d. When I say \"this file\" or \"this code\", that's what I mean. No action needed yet — I'll send a task next.",
      path, ln)
  end
  return string.format(
    "Editor context: I have `%s` open. No action needed yet — I'll send a task next.",
    path)
end

-- ------------------------------------------------------------- sessions --

-- Spawn `devin` in a terminal tab. `prompt`, when given, is passed as a
-- single argv element after `--`, so embedded newlines are safe.
local function spawn_session(prompt)
  local args = model_args()
  if prompt then append(args, { "--", prompt }) end
  local id, err = term.spawn({
    shell = AGENT.cmd,
    args = args,
    label = LABEL,
    cwd = session_cwd(),
  })
  if not id then
    notify_err("spawn failed: " .. tostring(err))
    return nil
  end
  ttt.log(AGENT.ns .. ": spawned terminal " .. id)
  update_status()
  term.focus(id)
  return id
end

local function new_session()
  if not agent_version() then
    notify_err("`" .. AGENT.cmd .. "` binary not found on PATH")
    return
  end
  spawn_session(seed_prompt())
end

local function continue_session()
  if not agent_version() then
    notify_err("`" .. AGENT.cmd .. "` binary not found on PATH")
    return
  end
  local id, err = term.spawn({
    shell = AGENT.cmd,
    args = AGENT.continue_args,
    label = LABEL,
    cwd = session_cwd(),
  })
  if not id then
    notify_err("spawn failed: " .. tostring(err))
    return
  end
  update_status()
  term.focus(id)
end

local function focus_session()
  local id = last_terminal()
  if id then
    term.focus(id)
  else
    new_session()
  end
end

local function send_to_session(text)
  local id = last_terminal()
  if not id then return false end
  local ok, err = term.send(id, text .. "\n")
  if not ok then
    notify_err("send failed: " .. tostring(err))
    return false
  end
  term.focus(id)
  return true
end

-- -------------------------------------------------------------- dialogs --

local function ask_dialog(title, placeholder, on_submit)
  local text = ""
  ttt.open_dialog({
    title = title,
    width = 72,
    height = 6,
    render = function(p)
      p:input({
        autofocus = true,
        wrap = true,
        max_rows = 3,
        placeholder = placeholder or ("Ask " .. AGENT.label .. "…"),
        on_change = function(t) text = t end,
        on_submit = function(t)
          ttt.close_dialog()
          on_submit(t)
        end,
      })
      p:hstack({
        gap = 1,
        render = function(b)
          b:label({ text = "", style = "muted" })
          b:button({ label = "&Ask", on_click = function()
            ttt.close_dialog()
            on_submit(text)
          end })
        end,
      })
    end,
  })
end

-- ------------------------------------------------------------ quick ask --

local function push_history(q)
  local h = storage.get(HISTORY_KEY) or {}
  table.insert(h, 1, q)
  while #h > HISTORY_MAX do h[#h] = nil end
  storage.set(HISTORY_KEY, h)
end

local function open_answer(question, body)
  local first = question:match("([^\n]*)") or question
  local lines = { "# " .. first, "" }
  for line in (body .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line
  end
  local title = AGENT.label .. ": " .. first:sub(1, 30)
  ttt.open_readonly(title, lines, PLUGIN_ID .. "-answer.md")
end

local function run_print(question, allow_untrusted)
  local args = model_args()
  append(args, AGENT.print_args)
  if allow_untrusted then
    append(args, { "--respect-workspace-trust", "false" })
  end
  append(args, { "--", question })
  sys.exec_async(AGENT.cmd, args, function(res)
    state.asking = false
    local out = (res.stdout or "") .. (res.stderr or "")
    if res.exit_code ~= 0 then
      if not allow_untrusted and out:lower():find("trust") then
        ttt.log(AGENT.ns .. ": retrying with --respect-workspace-trust false")
        state.asking = true
        run_print(question, true)
        return
      end
      open_answer(question, "**" .. AGENT.cmd .. " exited with code " ..
        tostring(res.exit_code) .. "**\n\n```\n" .. out .. "\n```")
      return
    end
    open_answer(question, res.stdout ~= "" and res.stdout or "_(no output)_")
  end)
end

local function quick_ask(question)
  if not question or question:match("^%s*$") then return end
  if not agent_version() then
    notify_err("`" .. AGENT.cmd .. "` binary not found on PATH")
    return
  end
  if state.asking then
    ttt.notify(AGENT.label .. ": a quick-ask is already running", "warn")
    return
  end
  state.asking = true
  state.last_line = question
  push_history(question)
  ttt.log(AGENT.ns .. ": quick ask → " .. question)
  run_print(question, false)
end

-- ------------------------------------------------------------- commands --

-- Attach the open file's path to a question so `devin -p` — which runs in
-- ttt's cwd, not the project — still knows what we're looking at. The
-- absolute path is enough; devin reads the file itself.
local function with_context(question)
  local ctx = selection_ctx()
  if ctx then
    return seeded_prompt(ctx, question)
  end
  local path = file_ctx()
  if path then
    local ln = cursor_line()
    if ln then
      return string.format("In `%s` around line %d: %s", path, ln, question)
    end
    return string.format("In `%s`: %s", path, question)
  end
  return question
end

-- Single-line `path:ref — msg` for sends into a running session. ref is the
-- selection range, the cursor line, or just the path when neither exists.
local function session_line(msg)
  local ctx = selection_ctx()
  if ctx then return reference_line(ctx, msg) end
  local path = file_ctx()
  if not path then return msg end
  local ln = cursor_line()
  local ref = ln and string.format("%s:%d", path, ln) or path
  return string.format("%s — %s", ref, msg)
end

local function cmd_quick_ask()
  local ctx = selection_ctx()
  local placeholder = ctx and "Ask about the selection…" or ("Ask " .. AGENT.label .. "…")
  ask_dialog(AGENT.label .. " — Quick Ask", placeholder, function(q)
    quick_ask(with_context(q))
  end)
end

local function cmd_ask_selection()
  local ctx = selection_ctx()
  if not ctx then
    ttt.notify(AGENT.label .. ": no active selection", "warn")
    return
  end
  ask_dialog(AGENT.label .. " — Ask About Selection", "What about this code?", function(q)
    if not send_to_session(reference_line(ctx, q)) then
      spawn_session(seeded_prompt(ctx, q))
    end
  end)
end

local function cmd_ask_file()
  local path = file_ctx()
  if not path then
    ttt.notify(AGENT.label .. ": no file open", "warn")
    return
  end
  ask_dialog(AGENT.label .. " — Ask About File", path, function(q)
    local ctx = { path = path }
    if not send_to_session(string.format("%s — %s", path, q)) then
      spawn_session(seeded_prompt(ctx, q))
    end
  end)
end

local function cmd_send()
  ask_dialog(AGENT.label .. " — Send to Session", "Message…", function(q)
    local line = session_line(q)
    if not send_to_session(line) then
      spawn_session(q)
    end
  end)
end

local function cmd_doctor()
  if not agent_version() then
    notify_err("`" .. AGENT.cmd .. "` binary not found on PATH")
    return
  end
  ttt.notify(AGENT.label .. ": running doctor…")
  sys.exec_async(AGENT.cmd, AGENT.doctor_args, function(res)
    local out = (res.stdout or "")
    if res.stderr and res.stderr ~= "" then
      out = out .. "\n\n-- stderr --\n" .. res.stderr
    end
    local lines = {}
    for line in (out .. "\n"):gmatch("([^\n]*)\n") do
      lines[#lines + 1] = line
    end
    ttt.open_readonly(AGENT.label .. " Doctor", lines)
  end)
end

-- One-line summary of the context quick-ask will attach, shown under the
-- input so it's obvious Devin can see the file.
local function ctx_hint()
  local ctx = selection_ctx()
  if ctx then
    return string.format("ctx: %s:%d-%d", ctx.path, ctx.first, ctx.last)
  end
  local path = file_ctx()
  if not path then return nil end
  local ln = cursor_line()
  return "ctx: " .. (ln and string.format("%s:%d", path, ln) or path)
end

-- ----------------------------------------------------------------- ACP --
--
-- Real Agent Client Protocol lane: `devin acp` on piped stdio via
-- sys.spawn, newline-delimited JSON-RPC. initialize → session/new →
-- session/prompt; agent_message_chunk notifications stream the answer.

local json = require("ttt.json")

acp = {
  proc = nil,
  buf = "",
  next_id = 0,
  pending = {},        -- id -> callback(result, err)
  session_id = nil,
  status = "off",      -- off | connecting | sessioning | ready | prompting | dead
  conv = "",           -- markdown conversation shown in the bottom panel
  tools = {},          -- toolCallId -> {title, status, kind, last_path}
  plan = {},           -- {content, status} checklist from plan updates
  edits = {},          -- path -> {old, new} most recent diff per file
  edit_order = {},     -- paths in the order first touched
}

local function acp_log(level, msg)
  ttt.log(level, "acp: " .. msg)
end

local function acp_status(text)
  acp.status = text
  ttt.log("acp: " .. text)
  update_status()
end

local function acp_send(method, params, on_result)
  if not acp.proc then return end
  acp.next_id = acp.next_id + 1
  acp.pending[acp.next_id] = on_result
  local msg = json.encode({ jsonrpc = "2.0", id = acp.next_id, method = method, params = params })
  local ok, err = acp.proc:write(msg .. "\n")
  if not ok then
    acp.pending[acp.next_id] = nil
    acp_log("error", "write failed: " .. tostring(err))
  end
end

local function acp_fail(msg)
  acp_status("dead")
  acp.conv = acp.conv .. "\n\n**ACP error:** " .. msg .. "\n"
end

-- A response to an inbound agent request (permission prompts, fs calls).
local function acp_respond(id, result)
  if not acp.proc then return end
  local ok, err = acp.proc:write(json.encode({
    jsonrpc = "2.0", id = id, result = result,
  }) .. "\n")
  if not ok then acp_log("error", "respond failed: " .. tostring(err)) end
end

-- A server->client notification (no id, no reply expected).
local function acp_notify(method, params)
  if not acp.proc then return end
  acp.proc:write(json.encode({ jsonrpc = "2.0", method = method, params = params }) .. "\n")
end

local function acp_start_session()
  acp_status("sessioning")
  local cwd = session_cwd()
  acp_send("session/new", { cwd = cwd ~= "" and cwd or nil, mcpServers = {} },
    function(res, err)
      if err then acp_fail("session/new: " .. tostring(err)) return end
      acp.session_id = res and res.sessionId
      if not acp.session_id then
        acp_fail("no sessionId in session/new result")
        return
      end
      acp_status("ready")
    end)
end

local function acp_on_toolcall(u)
  local id = u.toolCallId or ""
  local t = acp.tools[id] or {}
  acp.tools[id] = t
  t.title = u.title or t.title
  t.status = u.status or t.status
  t.kind = u.kind or t.kind

  -- Follow the agent: open files it works on. locations arrive on both
  -- tool_call and tool_call_update.
  for _, loc in ipairs(u.locations or {}) do
    if loc.path then
      ttt.open_file(loc.path, loc.line)
      t.last_path = loc.path
    end
  end

  -- Edit diffs ride in the content array; surface each in a diff tab and
  -- remember it for "Review changes" in the sidebar.
  for _, c in ipairs(u.content or {}) do
    if c.type == "diff" and c.path and c.newText then
      local old_lines, new_lines = {}, {}
      for l in ((c.oldText or "") .. "\n"):gmatch("([^\n]*)\n") do old_lines[#old_lines + 1] = l end
      for l in (c.newText .. "\n"):gmatch("([^\n]*)\n") do new_lines[#new_lines + 1] = l end
      ttt.open_diff(AGENT.label .. ": " .. c.path, old_lines, new_lines, c.path)
      if not acp.edits[c.path] then
        acp.edit_order[#acp.edit_order + 1] = c.path
      end
      acp.edits[c.path] = { old = old_lines, new = new_lines }
    end
  end

  -- One-line activity trail in the conversation.
  if not t.logged then
    t.logged = true
    local label = t.title ~= nil and t.title or (t.kind or "tool call")
    acp.conv = acp.conv .. "\n\n*`" .. label .. "`* "
  elseif t.status == "completed" or t.status == "failed" then
    acp.conv = acp.conv .. (t.status == "completed" and "✓ " or "✗ ")
    t.status = "logged_" .. t.status
  end
end

-- session/request_permission arrives as an inbound request (it has an id
-- and needs a result back, not just a notification). Present the agent's
-- options as dialog buttons; Escape answers "cancelled".
local function acp_on_permission(req_id, params)
  local tool = params.toolCall or {}
  local title = tool.title or "run a tool"
  local options = params.options or {}
  local picked = false

  local function choose(opt)
    picked = true
    ttt.close_dialog()
    acp_respond(req_id, { outcome = { outcome = "selected", optionId = opt.optionId } })
    acp.conv = acp.conv .. "\n\n*permission " ..
      ((opt.kind or ""):find("allow") and "granted" or "denied") ..
      ": " .. title .. "*\n"
  end

  ttt.open_dialog({
    title = AGENT.label .. " wants to " .. title,
    width = 64,
    height = 5 + #options,
    on_close = function()
      if not picked then
        acp_respond(req_id, { outcome = { outcome = "cancelled" } })
      end
    end,
    render = function(p)
      p:label({ text = title, style = "bold" })
      local loc = tool.locations and tool.locations[1]
      if loc and loc.path then
        p:label({ text = loc.path .. (loc.line and (":" .. loc.line) or ""), style = "muted" })
      end
      p:label({ text = "" })
      p:hstack({
        gap = 1,
        render = function(b)
          for _, opt in ipairs(options) do
            b:button({ label = opt.name or opt.optionId, on_click = function() choose(opt) end })
          end
          b:button({ label = "Deny", on_click = function()
            picked = true
            ttt.close_dialog()
            acp_respond(req_id, { outcome = { outcome = "cancelled" } })
          end })
        end,
      })
    end,
  })
end

-- The agent called a method on us. We advertise no fs/terminal capabilities,
-- so anything unexpected gets a JSON-RPC method-not-found rather than hanging.
local function acp_on_request(tbl)
  if tbl.method == "session/request_permission" then
    acp_on_permission(tbl.id, tbl.params or {})
    return
  end
  acp_log("warn", "unhandled agent request: " .. tostring(tbl.method))
  if acp.proc then
    acp.proc:write(json.encode({
      jsonrpc = "2.0", id = tbl.id,
      error = { code = -32601, message = "method not found" },
    }) .. "\n")
  end
end

local function acp_on_plan(entries)
  acp.plan = {}
  for _, e in ipairs(entries) do
    acp.plan[#acp.plan + 1] = { content = e.content or "", status = e.status or "pending" }
  end
end

local function acp_on_message(tbl)
  -- Responses to our requests.
  if tbl.id ~= nil and tbl.method == nil and acp.pending[tbl.id] then
    local cb = acp.pending[tbl.id]
    acp.pending[tbl.id] = nil
    cb(tbl.result, tbl.error and (tbl.error.message or "rpc error") or nil)
    return
  end
  -- Requests from the agent (permission prompts and friends).
  if tbl.id ~= nil and tbl.method ~= nil then
    acp_on_request(tbl)
    return
  end
  if tbl.method == "session/update" and tbl.params then
    local u = tbl.params.update
    if not u then return end
    if u.sessionUpdate == "agent_message_chunk" and u.content and u.content.type == "text" then
      if acp.in_thought then
        acp.conv = acp.conv .. "*\n\n"
        acp.in_thought = false
      end
      acp.conv = acp.conv .. u.content.text
    elseif u.sessionUpdate == "agent_thought_chunk" and u.content and u.content.type == "text" then
      if not acp.in_thought then
        acp.conv = acp.conv .. "\n\n*"
        acp.in_thought = true
      end
      acp.conv = acp.conv .. u.content.text
    elseif u.sessionUpdate == "plan" then
      acp_on_plan(u.entries or {})
    elseif u.sessionUpdate == "tool_call" or u.sessionUpdate == "tool_call_update" then
      acp_on_toolcall(u)
    end
  end
end

local function acp_on_chunk(chunk)
  acp.buf = acp.buf .. chunk
  while true do
    local i = acp.buf:find("\n")
    if not i then break end
    local line = acp.buf:sub(1, i - 1):gsub("%s+$", "")
    acp.buf = acp.buf:sub(i + 1)
    if line ~= "" then
      local ok, tbl = pcall(json.decode, line)
      if ok and type(tbl) == "table" then
        acp_on_message(tbl)
      else
        acp_log("warn", "non-json line: " .. line:sub(1, 120))
      end
    end
  end
end

local function acp_connect()
  if acp.proc or not sys.spawn then return end
  acp_status("connecting")
  local proc, err = sys.spawn(AGENT.cmd, {
    args = AGENT.acp_args,
    on_stdout = acp_on_chunk,
    on_stderr = function() end, -- devin logs chatter here; swallow it
    on_exit = function(code)
      acp.proc = nil
      acp.session_id = nil
      acp_fail(AGENT.cmd .. " acp exited with code " .. tostring(code))
    end,
  })
  if not proc then
    acp_fail("spawn: " .. tostring(err))
    return
  end
  acp.proc = proc
  acp_send("initialize", {
    protocolVersion = 1,
    clientCapabilities = { fs = { readTextFile = false, writeTextFile = false }, terminal = false },
  }, function(res, err)
    if err then acp_fail("initialize: " .. tostring(err)) return end
    acp_start_session()
  end)
end

-- Slash-command presets usable in any ask input: "/fix" expands to a
-- standing instruction so the whole line stays the user's question.
local SLASH = {
  explain = "Explain this code.",
  fix = "Fix this code.",
  refactor = "Refactor this code for clarity.",
  test = "Write tests for this code.",
  docs = "Add documentation comments to this code.",
}

-- Expand @path mentions in a question: each mentioned file's contents are
-- appended as a fenced block so the agent sees the code without needing
-- its own fs capabilities. Unreadable or out-of-scope paths are skipped.
local function expand_mentions(prompt)
  local out = prompt
  for token in prompt:gmatch("@(%S+)") do
    if fs.exists(token) then
      local content = fs.read(token)
      if content and content ~= "" then
        out = out .. string.format("\n\nContents of `%s`:\n\n```\n%s\n```", token, content)
      end
    end
  end
  return out
end

local function expand_slash(q)
  local cmd, rest = q:match("^/(%a+)%s*(.*)")
  local preset = cmd and SLASH[cmd]
  if not preset then return q end
  if rest and rest ~= "" then
    return preset .. " Additional context: " .. rest
  end
  return preset
end

local function acp_ask(question, prompt)
  if not question or question:match("^%s*$") then return end
  question = expand_slash(question)
  acp_connect()
  if ttt.show_panel then ttt.show_panel("bottom") end
  acp.conv = acp.conv .. "\n\n**You:** " .. question .. "\n\n"
  prompt = expand_mentions(prompt or with_context(question))
  state.last_line = question
  push_history(question)
  -- The prompt rides once session/new resolves; pend on status.
  acp.pending_prompt = prompt
end

local function acp_cancel()
  if acp.status ~= "prompting" or not acp.session_id then return end
  acp_notify("session/cancel", { sessionId = acp.session_id })
  acp.conv = acp.conv .. "\n\n*cancelled*\n"
  acp_status("ready")
end

-- Forward pending prompts once the session is ready; (re)enter prompting.
local function acp_pump()
  if acp.status == "ready" and acp.pending_prompt then
    local prompt = acp.pending_prompt
    acp.pending_prompt = nil
    acp_status("prompting")
    acp.conv = acp.conv .. "**" .. AGENT.label .. ":** "
    acp_send("session/prompt", {
      sessionId = acp.session_id,
      prompt = { { type = "text", text = prompt } },
    }, function(res, err)
      if err then
        acp.conv = acp.conv .. "\n\n*error: " .. tostring(err) .. "*\n"
      end
      acp_status("ready")
      if settings.get(AGENT.ns .. ".notify_done") ~= false then
        ttt.notify(AGENT.label .. ": response complete", "info")
      end
    end)
  end
end

-- Pump from a light interval; render_panel also calls it each frame.
ttt.set_interval(500, acp_pump)

-- --------------------------------------------------------------- panel --

-- Plan entries render as a checklist above the streamed conversation.
local function plan_md()
  if #acp.plan == 0 then return "" end
  local lines = { "**Plan**" }
  for _, e in ipairs(acp.plan) do
    local box = "☐"
    if e.status == "completed" then box = "☑"
    elseif e.status == "in_progress" then box = "◐" end
    lines[#lines + 1] = box .. " " .. e.content
  end
  return table.concat(lines, "\n") .. "\n\n"
end

local function session_items()
  local items = {}
  for _, t in ipairs(live_terminals()) do
    items[#items + 1] = {
      id = t.id,
      label = string.format("%s  %dx%d", t.id, t.cols, t.rows),
      icon = "●",
    }
  end
  if #items == 0 then
    items[1] = { id = "_none", label = "no sessions — press New", muted = true }
  end
  return items
end

local function render_panel(panel)
  update_status()
  panel:vstack({
    gap = 1,
    render = function(p)
      local v = agent_version()
      if v then
        p:label({ text = "● " .. v, style = "success" })
      else
        p:label({ text = "○ " .. AGENT.cmd .. " not found on PATH", style = "danger" })
      end

      p:hstack({
        gap = 1,
        height = 1,
        render = function(b)
          b:button({ label = "&New", on_click = new_session })
          b:button({ label = "&Continue", on_click = continue_session })
          if acp.status == "prompting" then
            b:button({ label = "■ &Stop", on_click = acp_cancel })
          end
        end,
      })

      p:input({
        placeholder = "Ask " .. AGENT.label .. " (ACP)…",
        clear_on_submit = true,
        on_submit = function(q) acp_ask(q) end,
      })
      local hint = ctx_hint()
      if hint then
        p:label({ text = hint, style = "muted" })
      end
      if state.asking then
        p:label({ text = "asking " .. AGENT.ns .. "…", style = "muted" })
      end

      p:divider()
      p:label({ text = "Sessions", style = "muted" })
      p:list({
        items = session_items(),
        on_select = function(node)
          if node.id ~= "_none" then term.focus(node.id) end
        end,
        on_command = function(cmd, node)
          if node.id == "_none" then return end
          if cmd == "focus" then
            term.focus(node.id)
          elseif cmd == "close" then
            term.close(node.id)
          elseif cmd == "send" then
            ask_dialog(AGENT.label .. " — Send to " .. node.id, "Message…", function(q)
              term.send(node.id, session_line(q) .. "\n")
              term.focus(node.id)
            end)
          end
        end,
        node_menu = {
          { label = "Focus", command = "focus" },
          { label = "Send message…", command = "send" },
          { separator = true },
          { label = "Close session", command = "close" },
        },
      })

      if #acp.edit_order > 0 then
        p:divider()
        p:label({ text = "Changed files", style = "muted" })
        p:list({
          items = (function()
            local items = {}
            for i, path in ipairs(acp.edit_order) do
              items[i] = { id = path, label = path, icon = "±" }
            end
            return items
          end)(),
          on_select = function(node)
            local e = acp.edits[node.id]
            if e then ttt.open_diff(AGENT.label .. ": " .. node.id, e.old, e.new, node.id) end
          end,
          node_menu = {
            { label = "Show diff", command = "diff" },
            { label = "Open file", command = "open" },
          },
          on_command = function(cmd, node)
            if cmd == "open" then
              ttt.open_file(node.id)
            elseif cmd == "diff" then
              local e = acp.edits[node.id]
              if e then ttt.open_diff(AGENT.label .. ": " .. node.id, e.old, e.new, node.id) end
            end
          end,
        })
      end

      local history = storage.get(HISTORY_KEY) or {}
      if #history > 0 then
        p:divider()
        p:label({ text = "Recent asks", style = "muted" })
        p:list({
          items = (function()
            local items = {}
            for i, q in ipairs(history) do
              items[i] = { id = "h" .. i, label = q, muted = true }
            end
            return items
          end)(),
          on_select = function(node)
            local h = storage.get(HISTORY_KEY) or {}
            local i = tonumber(node.id:sub(2))
            if h[i] then quick_ask(h[i]) end
          end,
        })
      end
    end,
  })
end

-- ----------------------------------------------------------- registration --

editor.register_context_menu(function(line, col, word)
  local items = {}
  local ctx = selection_ctx()
  if ctx then
    local function preset(label, instruction)
      items[#items + 1] = {
        label = label,
        on_select = function() acp_ask(label, seeded_prompt(ctx, instruction)) end,
      }
    end
    items[#items + 1] = {
      label = "Ask " .. AGENT.label .. " about selection…",
      on_select = function()
        ask_dialog(AGENT.label .. " — Ask About Selection", "What about this code?", function(q)
          acp_ask(q, seeded_prompt(ctx, q))
        end)
      end,
    }
    preset(AGENT.label .. ": Explain", "Explain this code.")
    preset(AGENT.label .. ": Refactor", "Refactor this code for clarity.")
    preset(AGENT.label .. ": Add tests", "Write tests for this code.")
    items[#items + 1] = { separator = true }
    items[#items + 1] = {
      label = "Send selection to session…",
      on_select = function()
        ask_dialog(AGENT.label .. " — Send to Session", "Message…", function(q)
          if not send_to_session(reference_line(ctx, q)) then
            spawn_session(seeded_prompt(ctx, q))
          end
        end)
      end,
    }
  elseif word and word ~= "" then
    local path = file_ctx()
    items[#items + 1] = {
      label = "Ask " .. AGENT.label .. " about '" .. word .. "'",
      on_select = function()
        ask_dialog(AGENT.label .. " — Ask", "Ask about '" .. word .. "'…", function(q)
          local where = path and string.format("In `%s` around line %d, ", path, line) or ""
          acp_ask(q, string.format("%swhat is `%s`? %s", where, word, q))
        end)
      end,
    }
  end
  if #items > 0 then
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = AGENT.label .. ": New session", on_select = new_session }
  end
  return items
end)

ttt.register({
  bottom = {
    title = AGENT.label,
    render = function(panel)
      acp_pump()
      panel:vstack({
        render = function(p)
          if acp.status == "prompting" then
            p:hstack({
              gap = 1, height = 1,
              render = function(b)
                b:label({ text = "streaming…", style = "muted" })
                b:button({ label = "■ &Stop", on_click = acp_cancel })
              end,
            })
          end
          local text = plan_md() .. acp.conv
          if text == "" then
            p:label({ text = AGENT.label .. " ACP — " .. acp.status ..
              " — ask with '" .. AGENT.label .. ": ACP Ask' or the sidebar input", style = "muted" })
          else
            p:markdown({ text = text, follow = true })
          end
        end,
      })
    end,
  },
  sidebar = {
    title = AGENT.label,
    render = render_panel,
    actions = {
      { label = "New Session", command = "new" },
      { label = "Continue Session", command = "continue" },
      { label = "Quick Ask…", command = "ask" },
      { label = "Stop Agent", command = "stop" },
      { separator = true },
      { label = "Review Changes", command = "review" },
      { label = "Reset ACP Session", command = "reset" },
      { separator = true },
      { label = "Doctor", command = "doctor" },
    },
    on_action = function(cmd)
      if cmd == "new" then new_session()
      elseif cmd == "continue" then continue_session()
      elseif cmd == "ask" then cmd_quick_ask()
      elseif cmd == "stop" then acp_cancel()
      elseif cmd == "review" then ttt.exec_command(PLUGIN_ID .. ".review")
      elseif cmd == "reset" then ttt.exec_command(PLUGIN_ID .. ".acp_reset")
      elseif cmd == "doctor" then cmd_doctor()
      end
    end,
  },
  commands = {
    { id = PLUGIN_ID .. ".new",           title = AGENT.label .. ": New Session",              handler = new_session },
    { id = PLUGIN_ID .. ".continue",      title = AGENT.label .. ": Continue Previous Session", handler = continue_session },
    { id = PLUGIN_ID .. ".focus",         title = AGENT.label .. ": Focus Session",            handler = focus_session },
    { id = PLUGIN_ID .. ".ask",           title = AGENT.label .. ": Quick Ask",                handler = cmd_quick_ask },
    { id = PLUGIN_ID .. ".ask_selection", title = AGENT.label .. ": Ask About Selection",      handler = cmd_ask_selection },
    { id = PLUGIN_ID .. ".ask_file",      title = AGENT.label .. ": Ask About Current File",   handler = cmd_ask_file },
    { id = PLUGIN_ID .. ".send",          title = AGENT.label .. ": Send Message to Session",  handler = cmd_send },
    { id = PLUGIN_ID .. ".doctor",        title = AGENT.label .. ": Doctor",                   handler = cmd_doctor },
    { id = PLUGIN_ID .. ".acp_ask",       title = AGENT.label .. ": ACP Ask",                  handler = function()
      ask_dialog(AGENT.label .. " — ACP Ask", ("Ask " .. AGENT.label .. "…"), acp_ask)
    end },
    { id = PLUGIN_ID .. ".acp_stop",      title = AGENT.label .. ": Stop Agent",               handler = acp_cancel },
    { id = PLUGIN_ID .. ".review",        title = AGENT.label .. ": Review Changes",           handler = function()
      if #acp.edit_order == 0 then
        ttt.notify(AGENT.label .. ": no changes recorded this session", "warn")
        return
      end
      for _, path in ipairs(acp.edit_order) do
        local e = acp.edits[path]
        if e then ttt.open_diff(AGENT.label .. ": " .. path, e.old, e.new, path) end
      end
    end },
    { id = PLUGIN_ID .. ".acp_reset",     title = AGENT.label .. ": Reset ACP Session",        handler = function()
      if acp.proc then acp.proc:kill() end
      acp = {
        proc = nil, buf = "", next_id = 0, pending = {}, session_id = nil,
        status = "off", conv = "", tools = {}, plan = {}, edits = {}, edit_order = {},
      }
      ttt.notify(AGENT.label .. ": ACP session reset")
      update_status()
    end },
  },
  keybindings = {
    { key = "ctrl+shift+d", command = PLUGIN_ID .. ".ask" },
  },
})

update_status()
ttt.log(PLUGIN_ID .. " plugin loaded")
