-- One extmark per drawn breakpoint, carrying its sign.
local M = {}

M.NS_NAME = "Breakpoints"
local ns = vim.api.nvim_create_namespace(M.NS_NAME)
M.ns = ns

local marks = {}

local function buffer_marks(bufnr)
	marks[bufnr] = marks[bufnr] or {}
	return marks[bufnr]
end

local function line_count(bufnr)
	return vim.api.nvim_buf_line_count(bufnr)
end

-- Above the stop (30) and selected-caller (25) signs: their line highlight marks the line, the dot stays visible.
local PRIORITY = 31

local function set(bufnr, row1, style, ext)
	return vim.api.nvim_buf_set_extmark(bufnr, ns, row1 - 1, 0, {
		id = ext,
		sign_text = style.text,
		sign_hl_group = style.hl,
		priority = PRIORITY,
		right_gravity = true,
		invalidate = true,
		undo_restore = true,
	})
end

local function position(bufnr, ext)
	local ok, pos = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, ns, ext, { details = true })
	if not ok or type(pos) ~= "table" or pos[1] == nil then
		return nil
	end
	local details = pos[3] or {}
	return { row = pos[1] + 1, invalid = details.invalid == true, text = details.sign_text, hl = details.sign_hl_group }
end

function M.place(bufnr, id, row1, style)
	if row1 > line_count(bufnr) then
		return nil
	end
	buffer_marks(bufnr)[id] = { ext = set(bufnr, row1, style) }
	return true
end

-- An invalid mark keeps its invalid state for the next save to read.
function M.restyle(bufnr, id, style)
	local mark = buffer_marks(bufnr)[id]
	local pos = mark and position(bufnr, mark.ext)
	if not pos or pos.invalid then
		return
	end
	set(bufnr, pos.row, style, mark.ext)
end

function M.remove(bufnr, id)
	local mark = buffer_marks(bufnr)[id]
	if mark then
		pcall(vim.api.nvim_buf_del_extmark, bufnr, ns, mark.ext)
		buffer_marks(bufnr)[id] = nil
	end
end

function M.list(bufnr)
	local out = {}
	for id, mark in pairs(marks[bufnr] or {}) do
		local pos = position(bufnr, mark.ext)
		if pos then
			out[#out + 1] = {
				id = id,
				row = pos.row,
				invalid = pos.invalid,
				text = pos.text and vim.trim(pos.text) or nil,
				hl = pos.hl,
			}
		end
	end
	table.sort(out, function(a, b)
		if a.row ~= b.row then
			return a.row < b.row
		end
		return a.id < b.id
	end)
	return out
end

function M.at(bufnr, row1)
	for _, mark in ipairs(M.list(bufnr)) do
		if mark.row == row1 and not mark.invalid then
			return mark
		end
	end
end

function M.drop_buffer(bufnr)
	if vim.api.nvim_buf_is_valid(bufnr) then
		pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns, 0, -1)
	end
	marks[bufnr] = nil
end

return M


