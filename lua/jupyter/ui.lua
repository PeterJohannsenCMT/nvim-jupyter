local api = vim.api

local M = {}

local ns = api.nvim_create_namespace("nvim-jupyter-ui")
M.ns = ns

-- Per-buffer state
local inline_mark = {}        -- [bufnr][row] = extmark_id
local row_state   = {}        -- [bufnr][row] = { saw_cr = bool }
M._row_state = row_state      -- expose for finish_row()

local function get_row_state(bufnr, row)
  local sb = row_state[bufnr]; if not sb then sb = {}; row_state[bufnr] = sb end
  local rs = sb[row]; if not rs then rs = { saw_cr = false }; sb[row] = rs end
  return rs
end

local function get_cfg()
  local inline = {
    strip_ansi = true,
    maxlen     = 300,
    prefix     = " ⟶ ",
    hl_normal  = "MoltenOutputWin",
    hl_error   = "DiagnosticError",
  }
  local ok, cfg = pcall(require, "jupyter.config")
  if ok and type(cfg) == "table" and type(cfg.inline) == "table" then
    for k, v in pairs(cfg.inline) do inline[k] = v end
  end
  return { inline = inline }
end

-- ANSI
local ANSI_CSI       = "\27%[[0-?]*[ -/]*[@-~]"
local ANSI_ERASE_EOL = "\27%[[0-?]*%d?K"

local function sanitize_for_inline(text)
  local cfg = get_cfg().inline
  local raw = tostring(text or "")
  local s   = raw:gsub("\r\n", "\n")

  local has_cr = s:find("\r", 1, true) ~= nil
  local frame
  if has_cr then
    frame = (s:match("[^\r]*$") or s)
    frame = (frame:match("[^\n]*$") or frame)
  else
    local last_non_empty = nil
    for line in (s .. "\n"):gmatch("([^\n]*)\n") do
      if not line:match("^%s*$") then last_non_empty = line end
    end
    frame = last_non_empty or ""
  end

  local has_erase = frame:find(ANSI_ERASE_EOL) ~= nil
  if cfg.strip_ansi then frame = frame:gsub(ANSI_CSI, "") end

  if (has_cr and frame:match("^%s*$")) or (has_erase and frame:match("^%s*$")) then
    return "", has_cr, raw
  end

  frame = frame:gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  local maxlen = tonumber(cfg.maxlen) or 0
  if maxlen > 0 and #frame > maxlen then frame = frame:sub(1, maxlen - 1) .. "…" end
  return frame, has_cr, raw
end

local function clear_inline_mark(bufnr, row)
  local bm = inline_mark[bufnr]
  if bm and bm[row] then
    pcall(api.nvim_buf_del_extmark, bufnr, ns, bm[row]); bm[row] = nil
  else
    local marks = api.nvim_buf_get_extmarks(bufnr, ns, { row, 0 }, { row, 0 }, { details = false })
    for _, mk in ipairs(marks) do api.nvim_buf_del_extmark(bufnr, ns, mk[1]) end
  end
  if row_state[bufnr] then row_state[bufnr][row] = nil end
end

-- Backward-compatible: ui.clear_row(row) or ui.clear_row(bufnr, row)
function M.clear_row(a, b)
  local bufnr, row
  if b == nil and type(a) == "number" then bufnr, row = api.nvim_get_current_buf(), a else bufnr, row = a, b end
  if not (bufnr and api.nvim_buf_is_valid(bufnr)) then return end
  clear_inline_mark(bufnr, row)
end

function M.clear_all(bufnr)
  if bufnr and api.nvim_buf_is_valid(bufnr) then
    api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    inline_mark[bufnr] = {}
    row_state[bufnr]   = {}
  end
end

-- Replace-only inline virtual text
function M.show_inline(bufnr, row, text, opts)
  if not (bufnr and api.nvim_buf_is_valid(bufnr)) then return end

  local cleaned, has_cr, raw = sanitize_for_inline(text)
  clear_inline_mark(bufnr, row)

  local want_fallback = (cleaned == "" or cleaned == nil)
  if want_fallback then cleaned = "Done!" end

  local raw_stripped = (raw or ""):gsub(ANSI_CSI, "")
  local only_crlf = raw_stripped ~= "" and raw_stripped:gsub("[\r\n]", "") == ""

  local st = get_row_state(bufnr, row)
  -- Don't short-circuit when we intend to show the fallback
  if st.saw_cr and only_crlf and not want_fallback then
    st.saw_cr = false
    return
  end
  if has_cr then st.saw_cr = true end

  local cfg = get_cfg().inline
  local is_err = opts and opts.error or false
  local hl = is_err and cfg.hl_error or cfg.hl_normal
  if type(hl) ~= "string" or hl == "" then
    -- Ensure we pass a *group name*, not a table
    hl = "Comment"
  end

  local chunk = { (cfg.prefix or " ⟶ ") .. cleaned, hl }

  local ext_opts
  if vim.fn.has("nvim-0.9") == 1 then
    -- Prefer virt_lines; use col=0 (not -1)
    ext_opts = {
      virt_lines = { { chunk } },  -- list-of-lines, each line = list-of-chunks
      virt_lines_above = false,
      hl_mode = "combine",
    }
    id = api.nvim_buf_set_extmark(bufnr, ns, row, 0, ext_opts)
  else
    -- Fallback for older Neovim: show at EOL on the same row
    ext_opts = {
      virt_text = { chunk },
      virt_text_pos = "eol",
      hl_mode = "combine",
    }
    id = api.nvim_buf_set_extmark(bufnr, ns, row, -1, ext_opts)
  end

  if is_err then
    -- vim.notify ignores {hl=...} in many UIs; ensure red by level
    vim.notify(cleaned, vim.log.levels.ERROR)
  end

  inline_mark[bufnr] = inline_mark[bufnr] or {}
  inline_mark[bufnr][row] = id
end

-- Clear inline on completion only if we saw a progress-style CR
function M.finish_row(a, b)
  local bufnr, row
  if b == nil and type(a) == "number" then bufnr, row = api.nvim_get_current_buf(), a else bufnr, row = a, b end
  if not (bufnr and api.nvim_buf_is_valid(bufnr)) then return end
  local sb = row_state[bufnr]
  local st = sb and sb[row]
  if st and st.saw_cr then
    M.clear_row(bufnr, row)
  end
  if st then st.saw_cr = false end
end

-- Signs -----------------------------------------------------------------------
local signs_defined = false
local function ensure_signs()
  if signs_defined then return end
  signs_defined = true
  pcall(vim.fn.sign_define, "JupyterRun", { text = "●", texthl = "DiagnosticWarn" })
  pcall(vim.fn.sign_define, "JupyterOK",  { text = "✓", texthl = "DiagnosticOk" })
  pcall(vim.fn.sign_define, "JupyterErr", { text = "✗", texthl = "DiagnosticError" })
end

function M.place_sign(kind, bufnr, row)
  ensure_signs()
  local name = (kind == "run" and "JupyterRun") or (kind == "ok" and "JupyterOK") or "JupyterErr"
  local id = row + 1
  pcall(vim.fn.sign_unplace, "nvim-jupyter", { buffer = bufnr, id = id })
  pcall(vim.fn.sign_place, id, "nvim-jupyter", name, bufnr, { lnum = row + 1, priority = 10 })
end

function M.clear_signs(bufnr)
  pcall(vim.fn.sign_unplace, "nvim-jupyter", { buffer = bufnr })
end

-- Clear inline virtual text (our namespace) for a row range [srow, erow]
function M.clear_range(bufnr, srow, erow)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  if not (srow and erow) then return end
  if erow < srow then srow, erow = erow, srow end
  -- wipe extmarks in range for our namespace only
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, srow, erow + 1)
  -- drop cached per-row state in that range
  if M._row_state and M._row_state[bufnr] then
    for r = srow, erow do M._row_state[bufnr][r] = nil end
  end
  if vim.tbl_isempty(M._row_state[bufnr] or {}) then
    M._row_state[bufnr] = {}
  end
end

-- Clear only our signs in [srow, erow]
function M.clear_signs_range(bufnr, srow, erow)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  if not (srow and erow) then return end
  if erow < srow then srow, erow = erow, srow end
  local placed = vim.fn.sign_getplaced(bufnr, { group = "nvim-jupyter" }) or {}
  local items = placed[1] and placed[1].signs or {}
  for _, s in ipairs(items) do
    local r0 = (s.lnum or 1) - 1
    if r0 >= srow and r0 <= erow then
      pcall(vim.fn.sign_unplace, "nvim-jupyter", { buffer = bufnr, id = s.id })
    end
  end
end

return M
