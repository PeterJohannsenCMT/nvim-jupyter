-- lua/jupyter/kernel.lua
local transport = require "jupyter.transport"
local ui        = require "jupyter.ui"
local out       = require "jupyter.outbuf"

local M = { bridge = nil, owner_buf = nil }

-- execution bookkeeping
local seq          = 0
local pending      = {}   -- seq -> { row = last line (0-based), start_row = first line, bufnr = originating buffer }
local queue        = {}   -- FIFO of {seq, code}
local inflight     = false
local ready        = false
local had_error    = {}   -- seq -> true if an error was seen before 'done'

local function get_cfg()
  local defaults = {
    kernel_name   = "python3",
    bridge_script = nil,  -- absolute path or nil
    out = { open_on_run = true },
  }
  local ok, cfg = pcall(require, "jupyter.config")
  if ok and type(cfg) == "table" then
    for k, v in pairs(defaults) do if cfg[k] == nil then cfg[k] = v end end
    return cfg
  end
  return defaults
end

local function exists(p) return vim.loop.fs_stat(p) ~= nil end

local function find_bridge_script()
  local cfg = get_cfg()
  if cfg.bridge_script and cfg.bridge_script ~= "" then
    return cfg.bridge_script
  end
  -- Try relative to this file: .../lua/jupyter/kernel.lua -> plugin root
  local src = debug.getinfo(1, "S").source
  if src:sub(1,1) == "@" then src = src:sub(2) end
  local base = src:match("^(.*)/lua/jupyter/.*$") or vim.fn.fnamemodify(src, ":h:h:h")
  if base and exists(base .. "/python/bridge.py") then
    return base .. "/python/bridge.py"
  end
  -- Scan runtimepaths
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    local p = rtp .. "/python/bridge.py"
    if exists(p) then return p end
  end
  return nil
end

local ANSI_ESCAPE = "\27%[[0-?]*[ -/]*[@-~]"

local function compute_start_row(row, code)
  if type(row) ~= "number" then return row end
  if type(code) ~= "string" then return row end
  local newline_count = 0
  for _ in code:gmatch("\n") do newline_count = newline_count + 1 end
  local start_row = row - newline_count
  if start_row < 0 then start_row = 0 end
  return start_row
end

local function extract_error_lineno(msg)
  local tb = msg and msg.traceback
  if not tb then return nil end

  local lines = {}
  if type(tb) == "table" then
    for _, entry in ipairs(tb) do
      if type(entry) == "string" then
        local pieces = vim.split(entry, "\n", { trimempty = true })
        for _, piece in ipairs(pieces) do
          lines[#lines + 1] = piece
        end
      end
    end
  elseif type(tb) == "string" then
    lines = vim.split(tb, "\n", { trimempty = true })
  else
    return nil
  end

  if #lines == 0 then return nil end

  local preferred = { "Cell In%[", "<ipython%-input", "<stdin>", "<string>" }

  local function clean_line(entry)
    return entry:gsub(ANSI_ESCAPE, "")
  end

  local function match_lineno(entry)
    local clean = clean_line(entry)
    local lineno = clean:match("line%s+(%d+)")
    if lineno then return tonumber(lineno) end
    lineno = clean:match("^%s*[-=]+>%s*(%d+)")
    if lineno then return tonumber(lineno) end
    return nil
  end

  for _, pattern in ipairs(preferred) do
    for i = #lines, 1, -1 do
      local clean = clean_line(lines[i])
      if clean:find(pattern) then
        local lineno = clean:match("line%s+(%d+)")
        if lineno then return tonumber(lineno) end
      end
    end
  end

  for i = #lines, 1, -1 do
    local lineno = match_lineno(lines[i])
    if lineno then return lineno end
  end

  return nil
end

local function ensure_bridge()
  if M.bridge then return true end
  local script = find_bridge_script()
  if not script then
    vim.notify("Jupyter: bridge.py not found on runtimepath; set require('jupyter.config').bridge_script",
      vim.log.levels.ERROR)
    return false
  end
  local br, err = transport.spawn_bridge(script)
  if not br then
    vim.notify(("Jupyter: failed to start bridge\nscript: %s\nerror: %s")
      :format(script, tostring(err)), vim.log.levels.ERROR)
    return false
  end
  M.bridge = br
  ready    = false

  br:on_message(function(msg)
    local t = msg.type

    if t == "ready" then
      ready = true
      if not inflight and #queue > 0 then
        inflight = true
        M.bridge:send({ type = "execute", code = queue[1].code, seq = queue[1].seq })
      end
      return

    elseif t == "stream" then
      local s = msg.seq
      out.append_stream(s, msg.text or "")
      local cell  = pending[s]
      local bufnr = (cell and cell.bufnr) or M.owner_buf or vim.api.nvim_get_current_buf()
      local row   = cell and cell.row
      if bufnr and row then
        ui.show_inline(bufnr, row, msg.text or "", { error = (msg.name == "stderr") })
      end
      return

    elseif t == "stdin_request" then

      local prompt = msg.prompt or ""

			vim.ui.input({ prompt = prompt }, function(input)
				M.bridge:send({ type = "stdin_reply", text = input or "" })
			end)

      -- end
      return
    elseif t == "result" then
      out.append(msg.seq, msg.value or "")
      return

    elseif t == "markdown" then
      out.append_markdown(msg.seq, msg.value or "")
      return

    elseif t == "image" then
      out.append(msg.seq, ("[image saved: %s]"):format(msg.path or ""))
      return

    elseif t == "error" then
      local s  = msg.seq
      local tb = msg.traceback or ((msg.ename or "Error") .. ": " .. (msg.evalue or ""))
      out.append(s, tb)

      -- mark seq as errored so 'done' won't place ✓
      had_error[s] = true

			local cell  = pending[s]
			local bufnr = (cell and cell.bufnr) or M.owner_buf or vim.api.nvim_get_current_buf()
			local row   = cell and cell.row
			if bufnr and row then
				local diag_row = row
				local err_line = extract_error_lineno(msg)
				if err_line and err_line >= 1 and cell and cell.start_row then
					diag_row = cell.start_row + err_line - 1
				end
				if cell and cell.start_row then
					if diag_row < cell.start_row then diag_row = cell.start_row end
					if diag_row > row then diag_row = row end
				end
				local line_count = vim.api.nvim_buf_line_count(bufnr)
				if line_count > 0 then
					if diag_row < 0 then diag_row = 0 end
					if diag_row >= line_count then diag_row = line_count - 1 end
				else
					diag_row = 0
				end
				-- concise inline error (keep it visible after completion)
				local inline = (msg.ename or "Error") .. (msg.evalue and (": " .. msg.evalue) or "")
				ui.place_sign("err", bufnr, diag_row)
				ui.show_inline(bufnr, diag_row, inline, { error = true })
				local ns = vim.api.nvim_create_namespace("jupyter_exec")
				local line = vim.api.nvim_buf_get_lines(bufnr, diag_row, diag_row + 1, false)[1] or ""
				local col  = #line
				vim.diagnostic.set(ns, bufnr, {
					{
						lnum = diag_row, col = col,
						end_lnum = diag_row, end_col = 0,
						severity = vim.diagnostic.severity.ERROR,
						message = "Jupyter Cell exited with error: " .. msg.ename,
						source = "jupyter",
					},
				})
			end

      -- advance queue
      inflight = false
      table.remove(queue, 1)
      if ready and #queue > 0 then
        inflight = true
        M.bridge:send({ type = "execute", code = queue[1].code, seq = queue[1].seq })
      end
      return

    elseif t == "done" then
      local s     = msg.seq
      local cell  = pending[s]
      local bufnr = (cell and cell.bufnr) or M.owner_buf or vim.api.nvim_get_current_buf()
      local row   = cell and cell.row

      if bufnr and row then
        if had_error[s] then
          -- keep the error sign and the inline error text as-is
          had_error[s] = nil
        else
          -- success path: ✓ and finish_row (clear progress-only inline)
          ui.place_sign("ok", bufnr, row)
          ui.finish_row(bufnr, row)
        end
      end

      pending[s] = nil

      inflight = false
      table.remove(queue, 1)
      if ready and #queue > 0 then
        inflight = true
        M.bridge:send({ type = "execute", code = queue[1].code, seq = queue[1].seq })
      end
      return

    elseif t == "interrupted" then
      local head = queue[1]
      if head then
        local cell  = pending[head.seq]
        local bufnr = (cell and cell.bufnr) or M.owner_buf or vim.api.nvim_get_current_buf()
        local row   = cell and cell.row
        if bufnr and row then ui.show_inline(bufnr, row, "[interrupt requested]", { error = true }) end
      end
      return

    elseif t == "bye" then
      M.bridge = nil; ready = false; inflight = false; queue = {}
      return
    end
  end)

  -- Start the kernel
  local cfg = get_cfg()
  local cwd = vim.fn.getcwd()
  M.bridge:send({ type = "start", kernel = cfg.kernel_name or "python3", cwd = cwd })
  return true
end

-- Public API ------------------------------------------------------------------

function M.is_running()
  return M.bridge ~= nil
end

function M.stop()
  if not M.bridge then return end
  pcall(function() M.bridge:send({ type = "shutdown" }) end)
  if M.bridge.close then pcall(function() M.bridge:close() end) end
  M.bridge = nil
  ready = false
  inflight = false
  queue = {}
  pending = {}
  had_error = {}
end

function M.interrupt(opts)
  opts = opts or {}
  if M.bridge then
    M.bridge:send({ type = "interrupt" })
  end
end

function M.start()
  return ensure_bridge()
end

function M.restart()
  if not M.bridge then return end
  local cfg = get_cfg()
  local cwd = vim.fn.getcwd()
  M.bridge:send({ type = "restart", kernel = cfg.kernel_name or "python3", cwd = cwd })
end

function M.eval_line()
  if not ensure_bridge() then return end
  local line = vim.api.nvim_get_current_line()
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1  -- 0-based
  M.execute(line, row)
end

function M.eval_selection()
  if not ensure_bridge() then return end
  local start_pos = vim.fn.getpos("'<")
  local end_pos = vim.fn.getpos("'>")
  local start_row, start_col = start_pos[2] - 1, start_pos[3] - 1  -- 0-based
  local end_row, end_col = end_pos[2] - 1, end_pos[3] - 1
  
  local lines = vim.api.nvim_buf_get_lines(0, start_row, end_row + 1, false)
  if #lines == 0 then return end
  
  -- Handle partial line selection
  if #lines == 1 then
    lines[1] = string.sub(lines[1], start_col + 1, end_col + 1)
  else
    lines[1] = string.sub(lines[1], start_col + 1)
    lines[#lines] = string.sub(lines[#lines], 1, end_col + 1)
  end
  
  local code = table.concat(lines, "\n")
  M.execute(code, end_row)
end

function M.cancel_queue()
  queue = {}
  inflight = false
end

-- Execute code from a given source row (0-based)
function M.execute(code, row)
  if not ensure_bridge() then return end

  -- Remember owner buffer to place signs/inline correctly
  M.owner_buf = vim.api.nvim_get_current_buf()
  local start_row = compute_start_row(row, code)

  ui.clear_diagnostics_range(M.owner_buf, start_row, row)
  -- Clear inline at run start to avoid appending on re-run
  -- ui.clear_row(M.owner_buf, row)
  ui.place_sign("run", M.owner_buf, row)

  seq = seq + 1
  local bufnr = M.owner_buf
  pending[seq] = { row = row, start_row = start_row, bufnr = bufnr }
  had_error[seq] = nil

  out.start_cell(seq)  -- open output header now

  table.insert(queue, { seq = seq, code = code })
  if ready and not inflight then
    inflight = true
    M.bridge:send({ type = "execute", code = code, seq = seq })
  end
end

-- Convenience: run the current cell (expects utils.find_code_block())
function M.eval_current_block()
  local s, e = require("jupyter.utils").find_code_block()
  if not s or not e then
    vim.notify("Jupyter: no #%% cell markers found", vim.log.levels.WARN)
    return
  end
  local lines = vim.api.nvim_buf_get_lines(0, s, e + 1, false)
  local empty = true
  for _, L in ipairs(lines) do if not L:match("^%s*$") then empty = false; break end end
  if empty then return end
  local code = table.concat(lines, "\n")
	ui.clear_range(M.owner_buf, s, e+1)
	ui.clear_signs_range(M.owner_buf, s, e+1)

  M.execute(code, e)  -- anchor at end row

	local last_row0 = vim.api.nvim_buf_line_count(0)
	if last_row0 > e+3 then
		vim.api.nvim_win_set_cursor(0, {e+3, 0})
	end
end


-- Convenience: run all above
function M.eval_all_above()
	local current_line = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(0, 0, current_line+1, false)
  local code = table.concat(lines, "\n")
  M.execute(code, current_line - 1)  -- anchor at end row
end

return M
