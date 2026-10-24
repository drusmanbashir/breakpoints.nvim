-- Editor-owned breakpoint set. Each entry is filed under its file's space (bp_space).
local M = {}

local uv = vim.uv or vim.loop
local record = require("breakpoints.storage.bp_record")
local marks = require("breakpoints.breakpoints.bp_marks")
local merge = require("breakpoints.storage.bp_merge")
local space = require("breakpoints.storage.bp_space")
-- state[space][path] = list of entries.
local state = {}
local setup_done = false
local host

local file = require("breakpoints.storage.bp_file")
local state_dir = file.state_dir
local read_file = file.read
local assign_ids = file.assign_ids
local normalise_entry = record.normalise

local recover
-- kept: the editor's copy before a mutation while the file was unreadable; recovering: refresh reloads only.
local kept, recovering

-- Writes the store; a failure reloads the committed copy via recover.
local function persist(paths, quiet)
	local ok, err = file.persist(state, quiet)
	if ok then
		return true
	end
	recover(paths)
	return nil, err
end

local function absolute(path)
	return type(path) == "string" and path:sub(1, 1) == "/"
end

local function valid_line(line)
	return type(line) == "number" and line % 1 == 0 and line > 0
end


-- Adopts breakpoints.json as saved now: other editors share the file, so a copy from startup would be stale.
-- An unreadable file keeps this editor's copy; recovering never writes.
local function refresh()
	local saved, unread = read_file()
	if saved then
		state, kept = saved, nil
		space.refile(state)
		if assign_ids(state) and not recovering then
			persist(nil, true)
		end
	elseif unread == "missing" then
		state, kept = {}, nil
	elseif recovering then
		state = kept or state
	else
		kept = vim.deepcopy(state)
	end
end

local function source_gone(path)
	local buf = vim.fn.bufnr(path, false)
	if buf >= 0 and vim.api.nvim_buf_is_loaded(buf) then return false end
	local _, _, code = uv.fs_stat(path)
	return code == "ENOENT" or code == "ENOTDIR"
end

-- Drops deleted sources and tells the debugger they are empty; runs before any buffer opens.
local function prune_missing()
	local pruned = {}
	local function prune()
		local changed = false
		for root, bucket in pairs(state) do
			for path in pairs(bucket) do
				if source_gone(path) then
					bucket[path] = nil
					pruned[path] = true
					changed = true
				end
			end
			if not next(bucket) then
				state[root] = nil
			end
		end
		return changed
	end
	if not prune() then
		return false
	end
	refresh()
	prune()
	if not persist(vim.tbl_keys(pruned)) then return false end
	for path in pairs(pruned) do
		vim.api.nvim_exec_autocmds("User", { pattern = "BreakpointsChanged", data = { path = path, lines = {} } })
	end
	return true
end

local function load()
	local nested, unread, where = read_file()
	if unread == "missing" then
		return
	end
	if unread then
		vim.notify("breakpoint store read refused: " .. where .. " is " .. unread, vim.log.levels.ERROR)
		return
	end
	state = nested
	space.refile(state)
	-- Assign ids before any other write.
	if assign_ids(state) then
		persist()
	end
	prune_missing()
end

local function entries_for(path)
	local out = {}
	for _, bucket in pairs(state) do
		vim.list_extend(out, bucket[path] or {})
	end
	merge.sort_entries(out)
	return out
end

local function ensure_bucket(root)
	state[root] = state[root] or {}
	return state[root]
end

local function path_for_buffer(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	return absolute(path) and vim.fn.fnamemodify(path, ":p") or nil
end

local function style_for(path, entry)
	local style = host and host.style and host.style(path, entry)
	return style or { text = record.glyph(entry), hl = entry.log_message and "BreakpointsLogPoint" or "BreakpointsBreakpoint" }
end

-- Reconciles a buffer's marks with the stored entries by id.
local function draw_buffer(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
		return
	end
	local path = path_for_buffer(bufnr)
	local wanted = {}
	for _, entry in ipairs(path and entries_for(path) or {}) do
		wanted[entry.id or ""] = entry
	end
	for _, mark in ipairs(marks.list(bufnr)) do
		local entry = wanted[mark.id]
		if entry then
			if recovering then
				-- Recovery recreates even invalid marks at their committed line.
				marks.remove(bufnr, mark.id)
			else
				marks.restyle(bufnr, mark.id, style_for(path, entry))
				wanted[mark.id] = nil
			end
		else
			marks.remove(bufnr, mark.id)
		end
	end
	for id, entry in pairs(wanted) do
		marks.place(bufnr, id, entry.line, style_for(path, entry))
	end
end

local function draw_all()
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			draw_buffer(bufnr)
		end
	end
end

local function draw_path(path)
	local bufnr = vim.fn.bufnr(path, false)
	if bufnr >= 0 and vim.api.nvim_buf_is_loaded(bufnr) then
		draw_buffer(bufnr)
	end
end

local function sync_with(path, lines)
	vim.api.nvim_exec_autocmds("User", { pattern = "BreakpointsChanged", data = { path = path, lines = vim.deepcopy(lines or {}) } })
end

local function sync(path)
	return sync_with(path, entries_for(path))
end

-- Reloads without writing, redraws the paths and publishes their committed sets.
recover = function(paths)
	recovering = true
	refresh()
	for _, path in ipairs(paths or {}) do
		draw_path(path)
	end
	recovering = false
	for _, path in ipairs(paths or {}) do
		sync(path)
	end
end

local function all_stored_paths(store)
	local paths = {}
	for _, bucket in pairs(store or state) do
		for path in pairs(bucket) do
			paths[path] = true
		end
	end
	return paths
end

-- A stored line past the end of the file does not exist; reading the file drops it.
local function drop_past_eof(bufnr)
	local path = path_for_buffer(bufnr)
	local last = vim.api.nvim_buf_line_count(bufnr)
	local function past(entry)
		return entry.line > last
	end
	if not path or not vim.iter(entries_for(path)):any(past) then
		return
	end
	file.with_lock(function()
		refresh()
		for root, bucket in pairs(state) do
			if bucket[path] then
				local kept = vim.tbl_filter(function(entry) return not past(entry) end, bucket[path])
				bucket[path] = #kept > 0 and kept or nil
				if not next(bucket) then
					state[root] = nil
				end
			end
		end
		if persist({ path }) then
			record.say("breakpoints past the end of " .. vim.fn.fnamemodify(path, ":t") .. " dropped", vim.log.levels.WARN)
			sync(path)
		end
	end)
end

-- Merges a save's marks into fresh disk state; persists only on change, then always redraws and syncs the path.
local function on_write(bufnr)
	local path = path_for_buffer(bufnr)
	if not path then
		return
	end
	local list = marks.list(bufnr)
	refresh()
	if #list == 0 and #entries_for(path) == 0 then
		return
	end
	local result = merge.merge(state, path, list)
	-- Marks follow the merge only once it is on disk.
	if result.changed then
		local saved, err = persist({ path })
		if not saved then return err end
	end
	for _, id in ipairs(result.drop) do
		marks.remove(bufnr, id)
	end
	for _, line in ipairs(result.said) do
		record.say(line, vim.log.levels.WARN)
	end
	draw_buffer(bufnr)
	sync(path)
end

-- A buffer renamed from `from` moves its records to the new path; a refusal moves nothing.
local function on_rename(bufnr, from)
	local to = path_for_buffer(bufnr)
	if not to or to == from then return end
	refresh()
	local moved, refusal = merge.rename(state, from, to, space.of_file(from), space.of_file(to))
	if refusal then record.say(refusal, vim.log.levels.WARN) end
	if moved then
		local saved, err = persist({ from, to })
		if not saved then return err end
	end
	draw_buffer(bufnr)
	if not moved then return end
	sync_with(from, {})
	sync(to)
end

function M.setup()
	if setup_done then
		return
	end
	setup_done = true
	local copy = vim.fn.isdirectory(state_dir) == 0
	local ok, err = pcall(file.with_lock, function()
		if copy then file.copy_legacy() end
		load()
	end)
	if not ok then vim.notify("breakpoint store copy/setup failed: " .. tostring(err), vim.log.levels.ERROR) end
	require("breakpoints.ui.gutter_hover").register(marks.NS_NAME, M.describe)
	local autocmd_group = vim.api.nvim_create_augroup("BreakpointsStore", { clear = true })
	-- A re-read starts from stored lines.
	vim.api.nvim_create_autocmd({ "BufReadPre", "BufUnload" }, {
		group = autocmd_group,
		callback = function(args)
			marks.drop_buffer(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufReadPost", {
		group = autocmd_group,
		callback = function(args)
			drop_past_eof(args.buf)
			draw_buffer(args.buf)
		end,
	})
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = autocmd_group,
		callback = function(args)
			file.with_lock(function() on_write(args.buf) end)
		end,
	})
	-- An unloaded alternate buffer renamed by :saveas owns no marks and is skipped.
	local renaming = {}
	vim.api.nvim_create_autocmd({ "BufFilePre", "BufFilePost" }, { group = autocmd_group, callback = function(args)
		local from = renaming[args.buf]
		renaming[args.buf] = args.event == "BufFilePre" and vim.api.nvim_buf_is_loaded(args.buf) and path_for_buffer(args.buf) or nil
		if from and args.event == "BufFilePost" then file.with_lock(function() on_rename(args.buf, from) end) end
	end })
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(bufnr) then
			draw_buffer(bufnr)
		end
	end
end

function M.toggle(path, line, opts)
	M.setup()
	path = absolute(path) and vim.fn.fnamemodify(path, ":p") or path
	if not absolute(path) then
		return nil, "relative path refused: " .. tostring(path)
	end
	if not valid_line(line) then
		return nil, "invalid breakpoint line refused: " .. tostring(line)
	end
	local bufnr = vim.fn.bufnr(path, false)
	local last = bufnr >= 0 and vim.api.nvim_buf_is_loaded(bufnr) and vim.api.nvim_buf_line_count(bufnr)
		or #vim.fn.readfile(path)
	if line > last then
		return nil, "No breakpoints past EOF"
	end
	refresh()
	local root = space.of_file(path)
	local bucket = ensure_bucket(root)
	local entries = bucket[path] or {}
	local removed = false
	for index, entry in ipairs(entries) do
		if entry.line == line then
			table.remove(entries, index)
			removed = true
			break
		end
	end
	if not removed then
		local entry = normalise_entry(vim.tbl_extend("force", { line = line }, opts or {}, { id = record.new_id() }))
		entries[#entries + 1] = entry
		merge.sort_entries(entries)
	end
	bucket[path] = #entries > 0 and entries or nil
	if not next(bucket) then
		state[root] = nil
	end
	local saved, err = persist({ path }, true)
	if not saved then return nil, err end
	draw_path(path)
	sync(path)
	return removed and "cleared" or "set"
end

local function locate(id)
	for root, bucket in pairs(state) do
		for path, entries in pairs(bucket) do
			for index, entry in ipairs(entries) do
				if entry.id == id then
					return root, path, index, entry
				end
			end
		end
	end
end

local function drop_entry(root, path, index)
	local entries = state[root][path]
	table.remove(entries, index)
	if #entries == 0 then
		state[root][path] = nil
	end
	if not next(state[root]) then
		state[root] = nil
	end
end

-- Removes that entry only; nil means the write failed and was said.
---@return boolean|nil removed, table|nil entry, string|nil failure
function M.remove_by_id(id)
	M.setup()
	refresh()
	local root, path, index, entry = locate(id)
	if not root then
		return false
	end
	drop_entry(root, path, index)
	local saved, failure = persist({ path })
	if not saved then return nil, nil, failure end
	draw_path(path)
	sync(path)
	return true, vim.tbl_extend("force", vim.deepcopy(entry), { path = path })
end

-- Updates the property fields of `id`, validated.
---@return table|nil entry, string|nil refusal_or_failure
function M.update(id, props)
	M.setup()
	refresh()
	local root, path, index, entry = locate(id)
	if not root then
		return nil, record.GONE
	end
	local language = require("breakpoints.storage.bp_language").of_path(path)
	local clean, refusal = record.validate(props)
	if not clean then
		return nil, refusal
	end
	local host_refusal = host and host.validate and host.validate(language, clean)
	if host_refusal then return nil, host_refusal end
	local next_entry = { id = entry.id, line = entry.line }
	for _, field in ipairs(record.PROPS) do
		next_entry[field] = clean[field]
	end
	next_entry = normalise_entry(next_entry)
	state[root][path][index] = next_entry
	local saved, failure = persist({ path }, true)
	if not saved then return nil, failure end
	draw_path(path)
	sync(path)
	return vim.deepcopy(next_entry)
end

-- By mark row in a loaded buffer, else by stored line.
function M.find_at(path, line)
	M.setup()
	path = absolute(path) and vim.fn.fnamemodify(path, ":p") or path
	refresh()
	local bufnr = vim.fn.bufnr(path, false)
	if bufnr >= 0 and vim.api.nvim_buf_is_loaded(bufnr) then
		local mark = marks.at(bufnr, line)
		local entry = mark and select(4, locate(mark.id))
		return entry and vim.deepcopy(entry) or nil
	end
	for _, entry in ipairs(entries_for(path)) do
		if entry.line == line then
			return vim.deepcopy(entry)
		end
	end
end

-- Removes a mark on the row by id; otherwise stores a new breakpoint now, saved buffer or not.
---@return string|nil action, string|nil error
function M.toggle_at(bufnr, row, opts)
	M.setup()
	local path = path_for_buffer(bufnr)
	if not path then
		return nil, "unnamed buffer has no absolute path"
	end
	local mark = marks.at(bufnr, row)
	if mark then
		local removed, _, err = M.remove_by_id(mark.id)
		if removed == nil then
			return "kept"
		end
		if not removed then
			marks.remove(bufnr, mark.id)
		end
		return "cleared", err
	end
	-- Edits may have moved marks off their stored lines; store where they are drawn before toggling by line.
	if vim.bo[bufnr].modified then
		file.with_lock(function() on_write(bufnr) end)
	end
	return M.toggle(path, row, opts)
end

-- Removes every breakpoint drawn in the buffer through the file-level clear.
---@return boolean|nil ok, string|nil error
function M.clear_buffer(bufnr)
	M.setup()
	local path = path_for_buffer(bufnr)
	if not path then
		return nil, "unnamed buffer has no absolute path"
	end
	return M.clear(path)
end

function M.attach(value)
	assert(host == nil, "breakpoints host already attached")
	host = value
	draw_all()
end
M.redraw = draw_all

function M.clear(path)
	M.setup()
	path = absolute(path) and vim.fn.fnamemodify(path, ":p") or path
	if not absolute(path) then
		return nil, "relative path refused: " .. tostring(path)
	end
	refresh()
	for root, paths in pairs(state) do
		if paths[path] then
			paths[path] = nil
			if not next(paths) then
				state[root] = nil
			end
		end
	end
	local saved, failure = persist({ path }, true)
	if not saved then return nil, failure end
	draw_path(path)
	sync_with(path, {})
	return true
end

-- Clears every breakpoint of space `root` (default: the editor's own) and of no other space.

function M.clear_project(root)
	M.setup()
	refresh()
	if root ~= space.NO_PROJECT then
		root = root and absolute(root) and vim.fn.fnamemodify(root, ":p"):gsub("/$", "") or space.editor()
	end
	local bucket = state[root] or {}
	local paths = {}
	for path in pairs(bucket) do
		paths[#paths + 1] = path
	end
	table.sort(paths)
	state[root] = nil
	local saved, failure = persist(paths, true)
	if not saved then return false, failure end
	draw_all()
	for _, path in ipairs(paths) do sync_with(path, {}) end
	return true
end

function M.clear_all()
	M.setup()
	refresh()
	local paths = {}
	for path in pairs(all_stored_paths()) do
		paths[#paths + 1] = path
	end
	table.sort(paths)
	state = {}
	local saved, failure = persist(paths, true)
	if not saved then return false, failure end
	draw_all()
	for _, path in ipairs(paths) do sync_with(path, {}) end
	return true
end

function M.get(path)
	M.setup()
	prune_missing()
	path = absolute(path) and vim.fn.fnamemodify(path, ":p") or path
	if not absolute(path) then
		return nil, "relative path refused: " .. tostring(path)
	end
	return vim.deepcopy(entries_for(path))
end

-- A read-only disk snapshot, also used by a debugger process without installing editor hooks.
function M.all()
	local saved, unread, where = read_file()
	return vim.deepcopy(saved or {}), unread and (where .. " is " .. unread) or nil
end

--- Gutter tooltip for the breakpoint drawn on the row: what it does, its properties, and why it may not stop.
function M.describe(bufnr, row)
	local mark = marks.at(bufnr, row)
	if not mark then
		return nil
	end
	local path = path_for_buffer(bufnr)
	local entry = {}
	for _, item in ipairs(path and entries_for(path) or {}) do
		if item.id == mark.id then
			entry = item
		end
	end
	local lines = { entry.log_message and ("Log point (does not stop): " .. entry.log_message) or "Breakpoint" }
	if entry.condition then lines[#lines + 1] = "Stops only when: " .. entry.condition end
	if entry.hit_condition then lines[#lines + 1] = "Hit count: " .. entry.hit_condition end
	if entry.remove_once then lines[#lines + 1] = "Removed after its first hit" end
	local style = style_for(path, entry)
	if style.note then lines[#lines + 1] = style.note end
	return lines
end

-- Public mutations are serialized through the file lock.
for _, name in ipairs({ "toggle", "remove_by_id", "update", "clear", "clear_project", "clear_all", "get", "all" }) do
	local operation = M[name]
	M[name] = function(...)
		local args = { n = select("#", ...), ... }
		return file.with_lock(function() return operation(unpack(args, 1, args.n)) end)
	end
end



return M


