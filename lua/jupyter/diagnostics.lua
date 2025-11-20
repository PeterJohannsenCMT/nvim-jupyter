local M = {}

local wrapped = false

local function is_doc_lookup_line(line)
  if not line then return false end
  local trimmed = line:match("^%s*(.-)%s*$")
  if not trimmed or trimmed == "" then return false end
  if trimmed:sub(1, 1) == "#" then return false end
  return trimmed:match("%?%??$") ~= nil
end

local function is_magic_line(line)
  if not line then return false end
  local trimmed = line:match("^%s*(.-)%s*$")
  if not trimmed or trimmed == "" then return false end
  if trimmed:sub(1, 1) == "#" then return false end
  return trimmed:sub(1, 1) == "%"
end

local function should_ignore_diagnostic(line)
  return is_doc_lookup_line(line) or is_magic_line(line)
end

local function filter_pyright_diagnostics(err, result, ctx, config, original)
  if not result or type(result) ~= "table" then
    return original(err, result, ctx, config)
  end
  local diagnostics = result.diagnostics
  if not diagnostics or #diagnostics == 0 then
    return original(err, result, ctx, config)
  end
  local client = ctx and ctx.client_id and vim.lsp.get_client_by_id(ctx.client_id)
  if not client or client.name ~= "pyright" then
    return original(err, result, ctx, config)
  end
  local uri = result.uri
  if not uri then
    return original(err, result, ctx, config)
  end
  local bufnr = vim.uri_to_bufnr(uri)
  if not (bufnr and vim.api.nvim_buf_is_loaded(bufnr)) then
    return original(err, result, ctx, config)
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if not lines or #lines == 0 then
    return original(err, result, ctx, config)
  end

  local filtered = {}
  for _, diag in ipairs(diagnostics) do
    local lnum = diag.range and diag.range["start"] and diag.range["start"].line
    local suppress = false
    if lnum then
      local line = lines[lnum + 1]
      if should_ignore_diagnostic(line) then
        suppress = true
      end
    end
    if not suppress then
      table.insert(filtered, diag)
    end
  end

  if #filtered == #diagnostics then
    return original(err, result, ctx, config)
  end

  local new_result = {
    uri = result.uri,
    diagnostics = filtered,
    version = result.version,
  }
  return original(err, new_result, ctx, config)
end

function M.setup()
  if wrapped then return end
  local original = vim.lsp.handlers["textDocument/publishDiagnostics"]
  if type(original) ~= "function" then return end
  vim.lsp.handlers["textDocument/publishDiagnostics"] = function(err, result, ctx, config)
    return filter_pyright_diagnostics(err, result, ctx, config, original)
  end
  wrapped = true
end

M.setup()

return M
