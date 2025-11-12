local api = vim.api

local M = {}

M.outbuf = "jupyteroutput"

---Apply the custom outbuf filetype to a buffer.
---@param bufnr integer|nil
function M.apply_outbuf(bufnr)
  bufnr = bufnr or api.nvim_get_current_buf()
  if not (bufnr and api.nvim_buf_is_valid(bufnr)) then
    return
  end
  api.nvim_set_option_value("filetype", M.outbuf, { buf = bufnr })
end

return M
