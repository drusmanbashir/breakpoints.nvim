-- Gutter tooltips: the pointer resting on a line's gutter names each sign drawn there.
-- Each sign's owner registers the text for its own namespace; this module only finds and shows it.
local M = {}

local describers = {}
local tip = { win = nil, buf = nil, key = nil }

--- `describe(bufnr, lnum)` returns the lines for the sign its namespace draws on that line, or nil.
function M.register(ns_name, describe)
	describers[ns_name] = describe
end

local function close()
	if tip.win and vim.api.nvim_win_is_valid(tip.win) then
		vim.api.nvim_win_close(tip.win, true)
	end
	tip.win, tip.key = nil, nil
end
M.close = close

--- Tooltip lines for every registered sign on the line, highest priority first.
function M.lines_at(bufnr, lnum)
	local names = {}
	for name, id in pairs(vim.api.nvim_get_namespaces()) do
		names[id] = name
	end
	local signs = vim.api.nvim_buf_get_extmarks(bufnr, -1, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true, type = "sign" })
	table.sort(signs, function(a, b)
		return (a[4].priority or 0) > (b[4].priority or 0)
	end)
	local out, seen = {}, {}
	for _, sign in ipairs(signs) do
		local name = names[sign[4].ns_id]
		if name and describers[name] and not seen[name] then
			seen[name] = true
			vim.list_extend(out, describers[name](bufnr, lnum) or {})
		end
	end
	return out
end

local function show(pos, lines)
	local key = table.concat({ pos.winid, pos.line, table.concat(lines, "\n") }, "\0")
	if key == tip.key and tip.win and vim.api.nvim_win_is_valid(tip.win) then
		return
	end
	close()
	if not (tip.buf and vim.api.nvim_buf_is_valid(tip.buf)) then
		tip.buf = vim.api.nvim_create_buf(false, true)
	end
	vim.api.nvim_buf_set_lines(tip.buf, 0, -1, false, lines)
	local width = 1
	for _, line in ipairs(lines) do
		width = math.max(width, vim.fn.strdisplaywidth(line))
	end
	-- One row below and one column right of the pointer, so the sign under it stays visible.
	tip.win = vim.api.nvim_open_win(tip.buf, false, {
		relative = "win",
		win = pos.winid,
		row = pos.winrow,
		col = pos.wincol,
		width = width,
		height = #lines,
		style = "minimal",
		border = "rounded",
		focusable = false,
		noautocmd = true,
		zindex = 250,
	})
	tip.key = key
end

local function update()
	local pos = vim.fn.getmousepos()
	if pos.winid == 0 or pos.winid == tip.win or pos.line == 0 then
		return close()
	end
	local info = vim.fn.getwininfo(pos.winid)[1]
	if not info or pos.wincol > info.textoff or vim.api.nvim_win_get_config(pos.winid).relative ~= "" then
		return close()
	end
	local lines = M.lines_at(vim.api.nvim_win_get_buf(pos.winid), pos.line)
	if #lines == 0 then
		return close()
	end
	show(pos, lines)
end

--- Turns on pointer-move events and follows them; the default <MouseMove> mapping is left alone.
function M.install()
	vim.o.mousemoveevent = true
	local move = vim.keycode("<MouseMove>")
	vim.on_key(function(key, typed)
		if key == move or typed == move then
			vim.schedule(update)
		end
	end, vim.api.nvim_create_namespace("BreakpointsGutterHover"))
	vim.api.nvim_create_autocmd({ "WinScrolled", "BufLeave", "InsertEnter", "FocusLost" }, {
		group = vim.api.nvim_create_augroup("BreakpointsGutterHover", { clear = true }),
		callback = function() close() end,
	})
end

return M
