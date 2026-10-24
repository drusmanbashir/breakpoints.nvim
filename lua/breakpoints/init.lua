local M = require("breakpoints.storage.breakpoints_store")
local setup_store = M.setup
local ready = false
local record = require("breakpoints.storage.bp_record")
local editor = require("breakpoints.breakpoints.bp_editor")
local attach_store = M.attach

function M.attach(host)
  attach_store(host)
  editor.setup(host)
end

local function say_error(ok, err)
  if not ok and err then record.say(err, vim.log.levels.WARN) end
end

function M.toggle_breakpoint(row)
  local ok, err = M.toggle_at(vim.api.nvim_get_current_buf(), row or vim.api.nvim_win_get_cursor(0)[1])
  say_error(ok, err)
  return ok, err
end

function M.clear_file()
  local ok, err = M.clear_buffer(vim.api.nvim_get_current_buf())
  say_error(ok, err)
  return ok, err
end

function M.log_point()
  local buf = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(buf)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if row > vim.api.nvim_buf_line_count(buf) then return record.say("No breakpoints past EOF", vim.log.levels.WARN) end
  if path:sub(1, 1) ~= "/" then return record.say("unnamed buffer has no absolute path", vim.log.levels.WARN) end
  local entry = M.find_at(path, row)
  if entry and entry.log_message then return M.remove_by_id(entry.id) end
  vim.ui.input({ prompt = "Log message: " }, function(message)
    if not message or vim.trim(message) == "" then return end
    local ok, err
    if entry then
      local props = vim.deepcopy(entry)
      props.log_message = message
      ok, err = M.update(entry.id, props)
    else
      ok, err = M.toggle_at(buf, row, { log_message = vim.trim(message) })
    end
    say_error(ok, err)
  end)
end

function M.setup()
  if ready then return end
  ready = true
  for name, link in pairs({ BreakpointsBreakpoint = "DiagnosticError", BreakpointsLogPoint = "Function", BreakpointsMuted = "Comment" }) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
  setup_store()
  require("breakpoints.ui.gutter_hover").install()
  local function map(lhs, action, desc)
    vim.keymap.set("n", lhs, action, { silent = true, desc = "Breakpoints: " .. desc })
  end
  for _, lhs in ipairs({ "<F2>", "<leader>dt", "<C-F8>", "<F32>" }) do map(lhs, M.toggle_breakpoint, "toggle breakpoint") end
  for _, lhs in ipairs({ "<S-F2>", "<F14>" }) do map(lhs, M.clear_file, "clear this file's breakpoints and log points") end
  map("<F3>", M.log_point, "toggle log point")
  for _, lhs in ipairs(record.props_keys()) do map(lhs, editor.props_or_panel, "properties / Breakpoints") end
end

return M
