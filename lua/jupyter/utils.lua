---@diagnostic disable: undefined-global
local M = {}

local marker_state_cache = {}

local function is_sub_marker_line(s)
  return type(s) == "string" and s:match("^%s*#%s*#%s*%%")
end

local function is_parent_marker_line(s)
  return type(s) == "string" and not is_sub_marker_line(s) and s:match("^%s*#%s*%%")
end

-- A cell marker can either be a parent cell ("#%%") or a sub-cell ("##%%")
local function is_marker_line(s)
  return is_parent_marker_line(s) or is_sub_marker_line(s)
end

local function marker_label_text(line, kind)
  if type(line) ~= "string" then
    return ""
  end
  local pattern
  if kind == "sub" then
    pattern = "^%s*#%s*#%s*%%%%%s*(.*)$"
  else
    pattern = "^%s*#%s*%%%%%s*(.*)$"
  end
  return vim.trim(line:match(pattern) or "")
end

local function letter_for_index(idx)
  if not idx or idx < 1 then
    return ""
  end
  local letters = {}
  while idx > 0 do
    local rem = (idx - 1) % 26
    table.insert(letters, 1, string.char(string.byte("a") + rem))
    idx = math.floor((idx - 1) / 26)
  end
  return table.concat(letters)
end

local function compute_marker_state(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local base_levels = {}
  local markers_by_row = {}
  local ordered_rows = {}
  local parent_rows = {}
  local parent_index = 0
  local sub_counts = {}
  local current_parent = nil
  local current_parent_row = nil
  local current_sub_index = nil

  for idx, line in ipairs(lines) do
    local row0 = idx - 1
    if is_parent_marker_line(line) then
      parent_index = parent_index + 1
      current_parent = parent_index
      current_parent_row = row0
      current_sub_index = nil
      sub_counts[current_parent] = 0
      local marker = {
        type = "parent",
        row = row0,
        parent_index = current_parent,
        parent_row = row0,
        sub_index = nil,
        text = marker_label_text(line, "parent"),
      }
      markers_by_row[row0] = marker
      table.insert(ordered_rows, row0)
      table.insert(parent_rows, row0)
      base_levels[row0] = 0
    elseif is_sub_marker_line(line) then
      if not current_parent then
        parent_index = parent_index + 1
        current_parent = parent_index
        current_parent_row = row0
      end
      sub_counts[current_parent] = (sub_counts[current_parent] or 0) + 1
      current_sub_index = sub_counts[current_parent]
      local marker = {
        type = "sub",
        row = row0,
        parent_index = current_parent,
        parent_row = current_parent_row,
        sub_index = current_sub_index,
        text = marker_label_text(line, "sub"),
        letter = letter_for_index(current_sub_index),
      }
      markers_by_row[row0] = marker
      table.insert(ordered_rows, row0)
      base_levels[row0] = 0
    else
      if current_sub_index then
        base_levels[row0] = 2
      elseif current_parent then
        base_levels[row0] = 1
      else
        base_levels[row0] = 0
      end
    end
  end

  local parent_next = {}
  for idx, row in ipairs(parent_rows) do
    parent_next[row] = parent_rows[idx + 1]
  end

  return {
    markers = markers_by_row,
    order = ordered_rows,
    base_levels = base_levels,
    parent_total = parent_index,
    parent_next = parent_next,
    parent_rows = parent_rows,
  }
end

function M.get_marker_state(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return { markers = {}, order = {}, base_levels = {}, parent_total = 0 }
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local cached = marker_state_cache[bufnr]
  if cached and cached.tick == tick then
    return cached.state
  end
  local state = compute_marker_state(bufnr)
  marker_state_cache[bufnr] = { tick = tick, state = state }
  return state
end

function M.invalidate_marker_cache(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  marker_state_cache[bufnr] = nil
end

function M.marker_type(line)
  if is_sub_marker_line(line) then
    return "sub"
  elseif is_parent_marker_line(line) then
    return "parent"
  end
  return nil
end

function M.subcell_letter(idx)
  return letter_for_index(idx)
end

-- Return marker info for the cell that contains the cursor.
-- If there is no marker (e.g. a file without any #%% markers), returns nil.
function M.current_cell_marker(opts)
  opts = opts or {}
  local include_subcells = opts.include_subcells ~= false
  local _, _, meta = M.find_code_block({ include_subcells = include_subcells })
  if not meta or not meta.marker then
    return nil
  end
  return meta.marker
end

-- Return the label text for the current cell marker (text after #%%/##%%).
-- Returns nil if there is no current marker; returns an empty string if the marker
-- is present but has no trailing text.
function M.get_current_cell_title(opts)
  local marker = M.current_cell_marker(opts)
  if not marker then
    return nil
  end
  return marker.text or ""
end

-- Return 0-based (s, e), inclusive, for the cell that contains the cursor.
-- Policy:
--   • "#%%" denotes a parent cell and "##%%" denotes a sub-cell.
--   • Either marker will delimit cells. Blank lines do not split a cell.
--   • If the cursor is on a marker line, select the cell BELOW that marker.
--   • If the buffer has NO markers, return nil, nil (caller should no-op).
function M.find_code_block(opts)
  opts = opts or {}
  local include_subcells = opts.include_subcells == true
  local bufnr = vim.api.nvim_get_current_buf()
  local cur = vim.api.nvim_win_get_cursor(0)[1] - 1
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then
    return nil, nil
  end

  local state = M.get_marker_state(bufnr)
  local markers = state.order
  if #markers == 0 then
    return nil, nil
  end

  local function next_marker_after(pos, filter)
    for _, m in ipairs(markers) do
      if m > pos then
        if not filter or filter(m) then
          return m
        end
      end
    end
    return nil
  end
  local function prev_marker_before(pos)
    local prev = nil
    for _, m in ipairs(markers) do
      if m < pos then prev = m else break end
    end
    return prev
  end

  local function fold_parent_bounds()
    if not include_subcells then
      return nil
    end
    local lnum = cur + 1
    local fold_start = vim.fn.foldclosed(lnum)
    if fold_start == -1 then
      return nil
    end
    local fold_end = vim.fn.foldclosedend(lnum)
    if not fold_end or fold_end == -1 then
      return nil
    end
    local start0 = math.max(fold_start - 1, 0)
    local marker_info = state.markers[start0]
    if not marker_info or marker_info.type ~= "parent" then
      return nil
    end
    local s = math.min(start0 + 1, math.max(line_count - 1, 0))
    local e = math.max(s, math.min(fold_end - 1, line_count - 1))
    local next_parent = state.parent_next and state.parent_next[start0] or nil
    return s, e, { marker_row = start0, marker = marker_info, next_marker_row = next_parent }
  end

  local fold_s, fold_e, fold_meta = fold_parent_bounds()
  if fold_s then
    return fold_s, fold_e, fold_meta
  end

  local current_line = vim.api.nvim_buf_get_lines(bufnr, cur, cur + 1, false)[1] or ""
  local marker_row
  if is_marker_line(current_line) then
    marker_row = cur
    local s = math.min(cur + 1, math.max(line_count - 1, 0))
    local marker_info = state.markers[marker_row]
    local search_anchor = cur
    local filter
    if include_subcells and marker_info and marker_info.type == "parent" then
      search_anchor = marker_row
      filter = function(row)
        local info = state.markers[row]
        return info and info.type == "parent"
      end
    end
    local nm = next_marker_after(search_anchor, filter)
    local e = nm and (nm - 1) or (line_count - 1)
    return s, e, { marker_row = marker_row, marker = marker_info, next_marker_row = nm }
  else
    marker_row = prev_marker_before(cur)
    local s = marker_row and (marker_row + 1) or 0
    local marker_info = marker_row and state.markers[marker_row] or nil
    local search_anchor = cur
    local filter
    if include_subcells and marker_info and marker_info.type == "parent" then
      search_anchor = marker_row
      filter = function(row)
        local info = state.markers[row]
        return info and info.type == "parent"
      end
    end
    local nm = next_marker_after(search_anchor, filter)
    local e = nm and (nm - 1) or (line_count - 1)
    return s, e, { marker_row = marker_row, marker = marker_info, next_marker_row = nm }
  end
end

-- Return the 0-based row of the **first code line of the next cell** after `row0` (0-based),
-- or nil if there is no next cell. This is "line after the next marker".
function M.first_line_of_next_cell_from(row0)
  local bufnr = vim.api.nvim_get_current_buf()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then
    return nil
  end
  local state = M.get_marker_state(bufnr)
  for _, marker_row in ipairs(state.order) do
    if marker_row > row0 then
      local start = math.min(marker_row + 1, math.max(line_count - 1, 0))
      return start
    end
  end
  return nil
end

local function marker_label(marker)
  if not marker then
    return ""
  end

  local idx = marker.parent_index and tostring(marker.parent_index) or ""
  local suffix = (marker.type == "sub" and marker.letter) and marker.letter or ""
  local numbering = (idx .. suffix):gsub("%s+", "")

  local fallback
  if marker.type == "sub" then
    fallback = numbering ~= "" and ("Subcell " .. numbering) or "Subcell"
  else
    fallback = numbering ~= "" and ("Cell " .. numbering) or "Cell"
  end

  local title = (marker.text and marker.text ~= "") and marker.text or fallback
  if numbering ~= "" then
    return string.format("Cell %s: %s", numbering, title)
  end
  return title
end

-- Populate the quickfix list with all cell/subcell markers in a buffer.
-- options:
--   bufnr: target buffer (default: current)
--   open: whether to open quickfix after populating (default: true)
--   title: optional quickfix title
function M.populate_cell_quickfix(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local state = M.get_marker_state(bufnr)
  if not state or #state.order == 0 then
    vim.notify("Jupyter: no cell markers found in buffer", vim.log.levels.WARN)
    return
  end

  local items = {}
  for _, row in ipairs(state.order) do
    local marker = state.markers[row]
    if marker then
      local prefix = marker.type == "sub" and "  " or ""
      table.insert(items, {
        bufnr = bufnr,
        lnum = row + 1,
        col = 1,
        text = prefix .. marker_label(marker),
      })
    end
  end

  local title = opts.title
    or string.format("Jupyter cells: %s", vim.api.nvim_buf_get_name(bufnr))
  vim.fn.setqflist({}, " ", { title = title, items = items })
  if opts.open ~= false then
    pcall(vim.cmd, "copen")
  end
  return items
end

return M
