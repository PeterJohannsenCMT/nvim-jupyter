local M = {}

-- Compatibility shims across Neovim versions
local H = vim.health or {}
local start = H.start or H.report_start or function(_) end
local ok    = H.ok    or H.report_ok    or function(_) end
local warn  = H.warn  or H.report_warn  or function(_) end
local err   = H.error or H.report_error or function(_) end

-- Run a command; prefer vim.system (0.10+), fallback to system()
local function run(cmd_argv)
  if vim.system then
    local res = vim.system(cmd_argv, { text = true }):wait()
    return res.code or 1, (res.stdout or ""), (res.stderr or "")
  else
    -- naive fallback; quote carefully if you modify
    local cmd = table.concat(cmd_argv, " ")
    local out = vim.fn.system(cmd)
    return vim.v.shell_error, out or "", ""
  end
end

local function find_bridge()
  -- mirrors kernel.lua logic, simplified
  local src = debug.getinfo(1, "S").source
  if src:sub(1,1) == "@" then src = src:sub(2) end
  local base = src:match("^(.*)/lua/health/.*$") or vim.fn.fnamemodify(src, ":h:h:h")
  local p = base .. "/python/bridge.py"
  if vim.loop.fs_stat(p) then return p end
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    local q = rtp .. "/python/bridge.py"
    if vim.loop.fs_stat(q) then return q end
  end
  return nil
end

function M.check()
  start("nvim-jupyter")

  -- Config presence
  local cfg = {}
  local ok_mod, mod = pcall(require, "jupyter")
  if ok_mod and type(mod.get_config) == "function" then
    cfg = mod.get_config()
    ok("config loaded")
  else
    warn("config not loaded via require('jupyter').setup(...) (using defaults)")
  end

  -- Python & jupyter_client
  local py = (cfg.python_cmd and tostring(cfg.python_cmd)) or "python3"
  local code, out, errout = run({ py, "-c", "import sys, jupyter_client; print(sys.version.split()[0]); print(jupyter_client.__version__)" })
  if code == 0 then
    local lines = {}
    for s in (out or ""):gmatch("[^\r\n]+") do table.insert(lines, s) end
    ok(("python ok: %s; jupyter_client: %s"):format(lines[1] or "?", lines[2] or "?"))
  else
    err(("python_cmd failed (%s): %s"):format(py, (errout ~= "" and errout or out):gsub("%s+$","")))
  end

  -- bridge.py discoverability
  local bridge = find_bridge()
  if bridge then
    ok("bridge.py found at " .. bridge)
  else
    warn("bridge.py not found on runtimepath; set require('jupyter').setup{ bridge_script = '/abs/path/bridge.py' }")
  end

  -- Optional: baleia
  local ok_baleia = pcall(require, "baleia")
  if ok_baleia then ok("baleia.nvim present (ANSI colors in output pane)")
  else warn("baleia.nvim not found (output pane will be monochrome)") end
end

return M
