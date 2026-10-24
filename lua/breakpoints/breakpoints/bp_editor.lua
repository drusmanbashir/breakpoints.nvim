local M = {}

local record = require("breakpoints.storage.bp_record")

local ctx

local LABELS = { "Condition: ", "Log message: ", "Hit count: ", "Remove once hit: " }
local label_ns = vim.api.nvim_create_namespace("BreakpointsBox")

local box

local function store()
	return require("breakpoints.storage.breakpoints_store")
end

function M.setup(context)
	ctx = context
end

local function focus_list()
	if ctx and ctx.focus_list then return ctx.focus_list() end
	record.say("No breakpoint on this line")
end

local function box_lines()
	return vim.api.nvim_buf_get_lines(box.buf, 0, -1, false)
end

local function close(saved)
	local open = box
	if not open or open.closing then
		return
	end
	open.closing = true
	local changed = vim.api.nvim_buf_is_valid(open.buf)
		and not vim.deep_equal(vim.api.nvim_buf_get_lines(open.buf, 0, -1, false), open.initial)
	box = nil
	vim.cmd("stopinsert")
	if vim.api.nvim_win_is_valid(open.win) then
		vim.api.nvim_win_close(open.win, true)
	end
	if not saved and changed then
		record.say("breakpoint properties not saved")
	end
end

-- Validate, update, then close; a refusal keeps the box open.
local function save()
	local lines = box_lines()
	if #lines ~= 4 then
		record.say("breakpoint properties refused: the box must keep its 4 lines", vim.log.levels.WARN)
		return false
	end
	local props = {
		condition = lines[1],
		log_message = lines[2],
		hit_condition = lines[3],
		remove_once = lines[4]:find("[x]", 1, true) ~= nil,
	}
	local entry, err = store().update(box.id, props)
	if not entry then
		record.say(err, vim.log.levels.WARN)
		return false
	end
	close(true)
	return true
end

local function toggle_once()
	local row = vim.api.nvim_win_get_cursor(0)[1]
	if row ~= 4 then
		return false
	end
	local text = box_lines()[4] or ""
	vim.api.nvim_buf_set_lines(box.buf, 3, 4, false, { text:find("[x]", 1, true) and "[ ]" or "[x]" })
	return true
end

local function paint_labels(buf)
	for row, label in ipairs(LABELS) do
		vim.api.nvim_buf_set_extmark(buf, label_ns, row - 1, 0, {
			virt_text = { { label, "Comment" } },
			virt_text_pos = "inline",
			right_gravity = false,
		})
	end
end

local function install_maps(buf)
	local function map(modes, lhs, fn)
		vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "Breakpoints: properties " .. lhs })
	end
	map({ "n", "i" }, "<CR>", save)
	map({ "n", "i" }, "<Esc>", function()
		close(false)
	end)
	map("n", "q", function()
		close(false)
	end)
	map("n", "<Space>", toggle_once)
	-- A fed key lands after the rest of the typeahead.
	vim.keymap.set("i", "<Space>", function()
		return vim.api.nvim_win_get_cursor(0)[1] == 4 and "<Cmd>lua require('breakpoints.breakpoints.bp_editor')._toggle_once()<CR>" or " "
	end, { buffer = buf, expr = true, nowait = true, silent = true, desc = "Breakpoints: toggle remove once" })
	for _, lhs in ipairs(record.props_keys()) do
		map(lhs == record.PROPS_KEY and { "n" } or { "n", "i" }, lhs, function()
			if not save() then
				return
			end
			if ctx and ctx.focus_list then ctx.focus_list() end
		end)
	end
	vim.api.nvim_create_autocmd("WinLeave", {
		buffer = buf,
		once = true,
		callback = function()
			vim.schedule(function()
				close(false)
			end)
		end,
	})
end

local function open_box(entry, path, line)
	close(false)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = "wipe"
	local initial = {
		entry.condition or "",
		entry.log_message or "",
		entry.hit_condition or "",
		entry.remove_once and "[x]" or "[ ]",
	}
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, initial)
	paint_labels(buf)
	local title = string.format("Breakpoint %s:%d", vim.fn.fnamemodify(path, ":t"), line)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "cursor",
		row = 1,
		col = 0,
		width = math.max(48, vim.fn.strdisplaywidth(title) + 4),
		height = 4,
		style = "minimal",
		border = "rounded",
		title = " " .. title .. " ",
	})
	box = { win = win, buf = buf, id = entry.id, path = path, line = line, initial = initial }
	install_maps(buf)
	vim.api.nvim_win_set_cursor(win, { 1, #initial[1] })
	vim.cmd("startinsert!")
end

function M._toggle_once()
	if box then
		toggle_once()
	end
end

function M.props_or_panel()
	local path = vim.api.nvim_buf_get_name(0)
	if path == "" or vim.bo.buftype ~= "" then
		return focus_list()
	end
	path = vim.fn.fnamemodify(path, ":p")
	local line = vim.api.nvim_win_get_cursor(0)[1]
	local entry = store().find_at(path, line)
	if not entry then
		return focus_list()
	end
	open_box(entry, path, line)
end

function M.props_by_id(args)
	if type(args) ~= "table" or type(args.id) ~= "string" then
		return "breakpoint_props refused: no id"
	end
	local at = type(args.path) == "string" and type(args.line) == "number" and store().find_at(args.path, args.line) or nil
	if at and at.id == args.id then
		open_box(at, vim.fn.fnamemodify(args.path, ":p"), at.line)
		return true
	end
	for _, bucket in pairs(store().all()) do
		for path, entries in pairs(bucket) do
			for _, entry in ipairs(entries) do
				if entry.id == args.id then
					open_box(entry, path, entry.line)
					return true
				end
			end
		end
	end
	record.say("breakpoint properties not opened: that breakpoint is no longer saved", vim.log.levels.WARN)
	return "breakpoint_props refused: unknown id"
end

return M
