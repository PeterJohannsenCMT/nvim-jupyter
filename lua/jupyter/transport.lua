local uv = vim.loop
local M  = {}

local function get_cfg()
  local defaults = { python_cmd = "python3" }
  local ok, cfg = pcall(require, "jupyter.config")
  if ok and type(cfg) == "table" then
    for k, v in pairs(defaults) do if cfg[k] == nil then cfg[k] = v end end
    return cfg
  end
  return defaults
end

local function json_encode(tbl)
  if vim.json and vim.json.encode then return vim.json.encode(tbl) end
  return vim.fn.json_encode(tbl)
end

local function json_decode(line)
  if vim.json and vim.json.decode then
    local ok, res = pcall(vim.json.decode, line)
    if ok then return res end
    return nil, res
  else
    local ok, res = pcall(vim.fn.json_decode, line)
    if ok then return res end
    return nil, res
  end
end

local function make_bridge(stdin, stdout, stderr, handle)
  local bridge = {
    _stdin  = stdin,
    _stdout = stdout,
    _stderr = stderr,
    _handle = handle,
    _cb     = nil,
  }

  local out_buf = ""
  uv.read_start(stdout, function(err, chunk)
    if err then
      vim.schedule(function()
        vim.notify("nvim-jupyter bridge stdout error: " .. tostring(err), vim.log.levels.WARN)
      end)
      return
    end
    if not chunk then return end
    out_buf = out_buf .. chunk
    while true do
      local nl = out_buf:find("\n", 1, true)
      if not nl then break end
      local line = out_buf:sub(1, nl - 1)
      out_buf = out_buf:sub(nl + 1)
      vim.schedule(function()
        local trimmed = line:match("^%s*(.-)%s*$")
        if trimmed ~= "" and trimmed:sub(1,1) == "{" then
          local obj, dec_err = json_decode(trimmed)
          if obj and bridge._cb then
            bridge._cb(obj)
          elseif dec_err then
            vim.notify("nvim-jupyter: JSON decode failed: " .. tostring(dec_err) ..
              "\nline: " .. trimmed, vim.log.levels.WARN)
          end
        elseif trimmed ~= "" then
          vim.notify("[nvim-jupyter] bridge noise: " .. trimmed, vim.log.levels.INFO)
        end
      end)
    end
  end)

  uv.read_start(stderr, function(err, chunk)
    if err then
      vim.schedule(function()
        vim.notify("nvim-jupyter bridge stderr error: " .. tostring(err), vim.log.levels.WARN)
      end)
      return
    end
    if not chunk then return end
    local msg = chunk
    vim.schedule(function()
      vim.notify("[nvim-jupyter] bridge stderr: " .. msg, vim.log.levels.INFO)
    end)
  end)

  function bridge:send(msg)
    if not self._stdin or self._stdin:is_closing() then return end
    self._stdin:write(json_encode(msg) .. "\n")
  end

  function bridge:on_message(cb)
    self._cb = cb
  end

  function bridge:close()
    if self._stdin  and not self._stdin:is_closing()  then self._stdin:close()  end
    if self._stdout and not self._stdout:is_closing() then self._stdout:close() end
    if self._stderr and not self._stderr:is_closing() then self._stderr:close() end
    if self._handle and not self._handle:is_closing() then self._handle:kill("sigterm") end
  end

  return bridge
end

function M.spawn_bridge(script)
  if not script or script == "" then return nil, "spawn_bridge: empty script" end
  if not uv.fs_stat(script) then return nil, ("spawn_bridge: not found: %s"):format(script) end

  local stdin  = uv.new_pipe(false)
  local stdout = uv.new_pipe(false)
  local stderr = uv.new_pipe(false)
  local cfg    = get_cfg()

  local handle, pid = uv.spawn(cfg.python_cmd or "python3", {
    args  = { "-u", script },
    stdio = { stdin, stdout, stderr },
    cwd   = uv.cwd(),
    env   = vim.fn.environ(),
  }, function(code, signal)
    if stdout and not stdout:is_closing() then stdout:close() end
    if stderr and not stderr:is_closing() then stderr:close() end
    if stdin  and not stdin:is_closing()  then stdin:close()  end
    if handle and not handle:is_closing() then handle:close() end
  end)

  if not handle then
    if stdin and not stdin:is_closing() then stdin:close() end
    if stdout and not stdout:is_closing() then stdout:close() end
    if stderr and not stderr:is_closing() then stderr:close() end
    return nil, ("uv.spawn failed (python_cmd=%s, script=%s)"):format(tostring(cfg.python_cmd), script)
  end

  return make_bridge(stdin, stdout, stderr, handle)
end

return M
