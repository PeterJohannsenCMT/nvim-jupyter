---@diagnostic disable: undefined-global, undefined-field

local api = vim.api
local utils = require "jupyter.utils"

local M = {}
local GROUP = "nvim-jupyter"

local ns = api.nvim_create_namespace("nvim-jupyter-ui")
local ns_exec = vim.api.nvim_create_namespace("jupyter_exec")
M.ns = ns

local function highlight_is_defined(name)
  if not name or name == "" then return false end
  local ok, hl = pcall(api.nvim_get_hl, 0, { name = name, link = false })
  if ok and hl and next(hl) ~= nil then
    return true
  end
  return vim.fn.hlexists(name) == 1
end

local SUBCELL_HL_DEFAULTS = {
  { name = "CellLineSubBackground", link = "CellLineBackground" },
  { name = "CellLineSubBG",         link = "CellLineBG" },
}

local function define_subcell_highlights()
  for _, def in ipairs(SUBCELL_HL_DEFAULTS) do
    if def.name and def.link then
      api.nvim_set_hl(0, def.name, { link = def.link, default = true })
    end
  end
end

define_subcell_highlights()
api.nvim_create_autocmd("ColorScheme", {
  callback = define_subcell_highlights,
})

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
    enabled    = true,
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

  -- Check if inline output is enabled
  local cfg = get_cfg().inline
  if cfg.enabled == false then return end

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
-- Store sign info: [bufnr][original_row] = { kind, mark_id }
local sign_marks = {}

local function get_sign_appearance(kind)
  if kind == "run" then
		return "󰦖", "JupyterRunning" -- 
  elseif kind == "ok" then
    return "✓", "DiagnosticOk"
  else  -- "err"
    return "✗", "DiagnosticError"
  end
end

local function determine_sign_row(bufnr, original_row)
  -- If the target row is inside a fold, place sign on the fold start line (#%% marker)
  -- Otherwise, place on the original row

  -- We need to check from the context of a window displaying this buffer
  local wins = vim.fn.win_findbuf(bufnr)
  if #wins > 0 then
    local saved_win = api.nvim_get_current_win()
    local target_win = wins[1]

    -- Temporarily switch to the window to check fold state
    local ok = pcall(api.nvim_set_current_win, target_win)
    if ok then
      local fold_start = vim.fn.foldclosed(original_row + 1)  -- foldclosed uses 1-based line numbers
      pcall(api.nvim_set_current_win, saved_win)

      if fold_start ~= -1 then
        return fold_start - 1  -- Convert back to 0-based (place on #%% line)
      end
    end
  end
  return original_row  -- Place on actual execution line when unfolded
end

function M.place_sign(kind, bufnr, row)
  if not (bufnr and api.nvim_buf_is_valid(bufnr)) then return end

  local sign_text, sign_hl = get_sign_appearance(kind)
  local sign_row = determine_sign_row(bufnr, row)

  -- Remove any existing sign at this original row
  if not sign_marks[bufnr] then sign_marks[bufnr] = {} end
  if sign_marks[bufnr][row] and sign_marks[bufnr][row].mark_id then
    pcall(api.nvim_buf_del_extmark, bufnr, ns_exec, sign_marks[bufnr][row].mark_id)
  end

  -- Place new sign using extmark
  local ok, mark_id = pcall(api.nvim_buf_set_extmark, bufnr, ns_exec, sign_row, 0, {
    sign_text = sign_text,
    sign_hl_group = sign_hl,
    priority = 10,
  })

  if ok then
    sign_marks[bufnr][row] = { kind = kind, mark_id = mark_id }
  end
end

-- Update all sign positions based on current fold state
function M.update_sign_positions(bufnr)
  if not (bufnr and api.nvim_buf_is_valid(bufnr)) then return end
  if not sign_marks[bufnr] then return end

  for original_row, info in pairs(sign_marks[bufnr]) do
    if info.kind and info.mark_id then
      local sign_text, sign_hl = get_sign_appearance(info.kind)
      local new_sign_row = determine_sign_row(bufnr, original_row)

      -- Update the extmark position
      pcall(api.nvim_buf_del_extmark, bufnr, ns_exec, info.mark_id)
      local ok, mark_id = pcall(api.nvim_buf_set_extmark, bufnr, ns_exec, new_sign_row, 0, {
        sign_text = sign_text,
        sign_hl_group = sign_hl,
        priority = 10,
      })

      if ok then
        sign_marks[bufnr][original_row].mark_id = mark_id
      end
    end
  end
end

function M.clear_signs(bufnr)
  -- Clear extmark-based signs
  if sign_marks[bufnr] then
    for row, info in pairs(sign_marks[bufnr]) do
      if info.mark_id then
        pcall(api.nvim_buf_del_extmark, bufnr, ns_exec, info.mark_id)
      end
    end
    sign_marks[bufnr] = {}
  end

  -- Also clear any old-style signs (for backwards compatibility)
  pcall(vim.fn.sign_unplace, GROUP, { buffer = bufnr })
  vim.diagnostic.reset(ns_exec, bufnr)
end

-- Clear every pending sign/diagnostic entry created by this plugin
function M.clear_all_signs()
  local cleared = {}
  for bufnr, _ in pairs(sign_marks) do
    if api.nvim_buf_is_valid(bufnr) then
      M.clear_signs(bufnr)
      cleared[bufnr] = true
    else
      sign_marks[bufnr] = nil
    end
  end

  -- Some buffers may only carry diagnostics (for example after clear_signs_range);
  -- ensure those are wiped as well.
  for _, bufnr in ipairs(api.nvim_list_bufs()) do
    if not cleared[bufnr] and api.nvim_buf_is_valid(bufnr) then
      vim.diagnostic.reset(ns_exec, bufnr)
    end
  end
end

local function remove_diagnostics_in_range(bufnr, srow, erow)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  srow = srow or 0
  erow = erow or vim.api.nvim_buf_line_count(bufnr)
  if erow < srow then srow, erow = erow, srow end

  local existing = vim.diagnostic.get(bufnr, { namespace = ns_exec })
  if not existing or vim.tbl_isempty(existing) then return end

  local keep = {}
  local changed = false
  for _, diagnostic in ipairs(existing) do
    local lnum = diagnostic.lnum or 0
    if lnum >= srow and lnum <= erow then
      changed = true
    else
      keep[#keep + 1] = diagnostic
    end
  end

  if not changed then return end
  if #keep == 0 then
    vim.diagnostic.reset(ns_exec, bufnr)
  else
    vim.diagnostic.set(ns_exec, bufnr, keep)
  end
end

function M.clear_diagnostics_range(bufnr, srow, erow)
  remove_diagnostics_in_range(bufnr, srow, erow)
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

  -- Clear extmark-based signs in range
  if sign_marks[bufnr] then
    for row = srow, erow do
      if sign_marks[bufnr][row] and sign_marks[bufnr][row].mark_id then
        pcall(api.nvim_buf_del_extmark, bufnr, ns_exec, sign_marks[bufnr][row].mark_id)
        sign_marks[bufnr][row] = nil
      end
    end
  end

  -- Also clear any old-style signs (for backwards compatibility)
  local placed = vim.fn.sign_getplaced(bufnr, { group = GROUP}) or {}
  local items = placed[1] and placed[1].signs or {}
  for _, s in ipairs(items) do
    local r0 = (s.lnum or 1) - 1
    if r0 >= srow and r0 <= erow then
      pcall(vim.fn.sign_unplace, GROUP, { buffer = bufnr, id = s.id })
    end
  end
  remove_diagnostics_in_range(bufnr, srow, erow)
end

local ns_bg = vim.api.nvim_create_namespace("cell_line_background")
local ns_sign = vim.api.nvim_create_namespace("cell_signs")
local ns_linehl = vim.api.nvim_create_namespace("cell_line_highlight")

local CELL_HIGHLIGHT_SLOTS = {
  header = {
    parent = "CellLineBackground",
    sub = "CellLineSubBackground",
  },
  border = {
    parent = "CellLineBG",
    sub = "CellLineSubBG",
  },
}

local function get_cell_highlight(marker_type, slot)
  local entry = CELL_HIGHLIGHT_SLOTS[slot]
  if not entry then return nil end
  if marker_type == "sub" then
    local candidate = entry.sub
    if candidate and highlight_is_defined(candidate) then
      return candidate
    end
  end
  return entry.parent
end

local ns = vim.api.nvim_create_namespace('my-virt-lines')

local function get_ui_cfg()
  local defaults = { show_cell_borders = true }
  local ok, cfg = pcall(require, "jupyter.config")
  if ok and type(cfg) == "table" and type(cfg.ui) == "table" then
    for k, v in pairs(cfg.ui) do defaults[k] = v end
  end
  return defaults
end

local function replace_with_mysign(bufnr, lnum)
  -- 1) remove ANY of {JupyterRun,JupyterOK,JupyterErr,MySign} on that line
  --    (because they’re all in the same group)
  pcall(vim.fn.sign_unplace, GROUP, { buffer = bufnr, lnum = lnum })

  -- 2) place exactly one MySign with a stable id for this line
  pcall(vim.fn.sign_place, lnum, GROUP, "MySign", bufnr, { lnum = lnum, priority = 10000 })
end

function M.highlight_cells()

	pcall(vim.fn.sign_define, "MySign", { text = "●", texthl = "CellLineFG" })
  local bufnr = vim.api.nvim_get_current_buf()
  local winid = vim.api.nvim_get_current_win()
  local width = vim.api.nvim_win_get_width(winid)
	vim.api.nvim_buf_clear_namespace(0, ns, 0, -1)
  local cursor_line = vim.api.nvim_win_get_cursor(winid)[1] - 1
  local in_insert_mode = vim.fn.mode() == "i"

  vim.api.nvim_buf_clear_namespace(bufnr, ns_bg, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_sign, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, ns_linehl, 0, -1)

  local ui_cfg = get_ui_cfg()

  -- Check if this is the outbuf - if so, don't add virtual lines
  local is_outbuf = vim.b[bufnr].is_outbuf == true

  local state = utils.get_marker_state(bufnr)
  local marker_rows = state.order or {}
  local marker_map = state.markers or {}
  local parent_total = state.parent_total or 0
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local last_line = math.max(line_count - 1, 0)

	_G.CurrentCell = nil
  for idx, row in ipairs(marker_rows) do
    local marker = marker_map[row]
    if marker then
      if row <= cursor_line then
			_G.CurrentCell = row
		end

      if not (in_insert_mode and row == cursor_line) then
        local label
        if marker.type == "sub" then
          local letter = marker.letter or utils.subcell_letter(marker.sub_index)
          label = string.format("Cell %d%s:", marker.parent_index or idx, letter or "")
        else
          label = string.format("Cell %d:", marker.parent_index or idx)
        end

        local trimmed = vim.trim(marker.text or "")
        local full_display = trimmed == "" and label or (label .. " " .. trimmed)
        local header_hl = get_cell_highlight(marker.type, "header") or "CellLineBackground"
        local border_hl = get_cell_highlight(marker.type, "border") or "CellLineBG"

        local text_width = vim.fn.strdisplaywidth(full_display)
        local padding_len = math.max(0, width - text_width)
        local padding = string.rep(" ", padding_len)
        local padding_top = string.rep("▔", width)
        local padding_bottom = string.rep("▁", width)

        vim.api.nvim_buf_set_extmark(bufnr, ns_sign, row, 0, {
          virt_text = {
            { full_display .. padding, header_hl },
          },
          virt_text_pos = "overlay",
          hl_mode = "combine",
        })

        vim.api.nvim_buf_add_highlight(bufnr, ns_linehl, header_hl, row, 0, -1)

        if ui_cfg.show_cell_borders and not is_outbuf then
          local next_row = marker_rows[idx + 1]
          local content_start = math.min(row + 1, last_line)
          local content_end = next_row and (next_row - 1) or last_line

          if content_start > content_end then
            content_start = row
            content_end = row
          end

          local has_content = content_start > row

          if has_content then
            vim.api.nvim_buf_set_extmark(bufnr, ns, content_start, 0, {
              virt_lines = { { { padding_top, border_hl } } },
              virt_lines_above = true,
            })
            vim.api.nvim_buf_set_extmark(bufnr, ns, content_end, 0, {
              virt_lines = { { { padding_bottom, border_hl } } },
              virt_lines_above = false,
            })
          end
        end
      end
    end
  end
	_G.CellCount = parent_total
end

return M
