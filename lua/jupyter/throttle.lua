-- lua/jupyter/throttle.lua
local uv, schedule = vim.loop, vim.schedule
local M = {}

---------------------------------------------------------------------------
-- Tunables – raise or lower to taste
---------------------------------------------------------------------------
local HIGH_WATER   = 800   --- msgs ∕ s → enter bulk mode
local FLUSH_LINES  = 200   --- max lines per flush
local FLUSH_MS     = 40    --- max latency (ms) before a queued flush
---------------------------------------------------------------------------

-- Will be set by kernel.lua once the output buffer exists
M.append = nil   ---@type fun(seq:integer,text:string)|nil

---------------------------------------------------------------------------
-- Internal state
---------------------------------------------------------------------------
local bulk, pending, n_pending = false, {}, 0
local per_sec, last_sec        = 0, uv.now()
local flush_timer, rate_timer  = nil, nil

---------------------------------------------------------------------------
local function flush()
  if n_pending == 0 or not M.append then return end
  local batch = pending
  pending, n_pending = {}, 0
  schedule(function()
    for _, item in ipairs(batch) do
      M.append(item.seq, item.text)
    end
  end)
end

local function ensure_timers()
  if not flush_timer or flush_timer:is_closing() then
    flush_timer = uv.new_timer()
    flush_timer:start(FLUSH_MS, FLUSH_MS, flush)
  end
  if not rate_timer or rate_timer:is_closing() then
    rate_timer = uv.new_timer()
    rate_timer:start(100, 100, function()
      local now = uv.now()
      if now - last_sec >= 1000 then
        bulk, per_sec, last_sec = (per_sec >= HIGH_WATER), 0, now
      end
    end)
  end
end

-- Initialize timers
ensure_timers()

---------------------------------------------------------------------------
function M.tick()
  ensure_timers()
  per_sec = per_sec + 1
end

---@param seq  integer
---@param text string
function M.push(seq, text)
  ensure_timers()
  if not bulk or not M.append then       -- normal path
    if M.append then M.append(seq, text) end
    return
  end
  pending[#pending + 1] = { seq = seq, text = text }
  n_pending = n_pending + 1
  if n_pending >= FLUSH_LINES then flush() end
end

-- Cleanup function to stop timers when needed
function M.stop()
  if flush_timer and not flush_timer:is_closing() then
    flush_timer:stop()
    flush_timer:close()
    flush_timer = nil
  end
  if rate_timer and not rate_timer:is_closing() then
    rate_timer:stop()
    rate_timer:close()
    rate_timer = nil
  end
end

return M
