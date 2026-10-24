-- One breakpoints.json per language folder, written atomically. The editor is the only writer.
local M = {}

local uv = vim.uv or vim.loop
local record = require("breakpoints.storage.bp_record")
local merge = require("breakpoints.storage.bp_merge")
local space = require("breakpoints.storage.bp_space")
local language_of = require("breakpoints.storage.bp_language").of_path

local function absolute(path)
	return type(path) == "string" and path:sub(1, 1) == "/"
end

local state_dir = vim.fn.stdpath("state") .. "/breakpoints"
local FILE_NAME = "breakpoints.json"
local pid = tostring(vim.fn.getpid())

local function language_path(language)
	return state_dir .. "/" .. language .. "/" .. FILE_NAME
end

local function notify_error(message)
	vim.schedule(function()
		vim.notify("breakpoint store write failed: " .. tostring(message), vim.log.levels.ERROR)
	end)
end

local fs = { fs_open = uv.fs_open, fs_write = uv.fs_write, fs_fsync = uv.fs_fsync, fs_close = uv.fs_close,
	fs_rename = uv.fs_rename, fs_unlink = uv.fs_unlink }

local function saved_languages()
	local found = {}
	local handle = uv.fs_scandir(state_dir)
	while handle do
		local name, kind = uv.fs_scandir_next(handle)
		if not name then
			break
		end
		if kind == "directory" and uv.fs_stat(language_path(name)) then
			found[#found + 1] = name
		end
	end
	table.sort(found)
	return found
end

local function split(state)
	local by_language = {}
	for root, bucket in pairs(state) do
		for path, entries in pairs(bucket) do
			local language = language_of(path)
			local store = by_language[language] or {}
			by_language[language] = store
			store[root] = store[root] or {}
			store[root][path] = entries
		end
	end
	return by_language
end

-- Temp file, fsync, rename; skips an unchanged file. Returns the failure or nil.
local function write_atomic(target, body)
	local current = io.open(target, "r")
	if current then
		local same = current:read("*a") == body
		current:close()
		if same then
			return nil
		end
	end
	vim.fn.mkdir(vim.fs.dirname(target), "p", 448)
	local temp = target .. ".tmp." .. pid
	local fd, err = fs.fs_open(temp, "w", 384)
	if fd then
		local written, write_err = fs.fs_write(fd, body, 0)
		if written ~= #body then
			err = write_err or ("short write: " .. tostring(written) .. " of " .. #body .. " bytes")
		end
		if not err then
			local synced, sync_err = fs.fs_fsync(fd)
			err = not synced and sync_err or nil
		end
		local closed, close_err = fs.fs_close(fd)
		err = err or (not closed and close_err) or nil
		if not err then
			local renamed, rename_err = fs.fs_rename(temp, target)
			err = not renamed and rename_err or nil
		end
		if err then
			fs.fs_unlink(temp)
		end
	end
	return err
end

-- Synchronous, because refresh re-reads the store before each change: the previous write must be on disk.
-- Failure is reported unless quiet; the caller then reports it.
local function persist(state, quiet)
	local by_language = split(state)
	for _, language in ipairs(saved_languages()) do
		by_language[language] = by_language[language] or {}
	end
	local languages = vim.tbl_keys(by_language)
	table.sort(languages)
	local err
	for _, language in ipairs(languages) do
		local store = by_language[language]
		-- An empty table would encode as a JSON array; store files are objects.
		err = write_atomic(language_path(language), (next(store) == nil and "{}" or vim.json.encode(store)) .. "\n")
		if err then
			break
		end
	end
	if not err then
		return true
	end
	if not quiet then
		notify_error(err)
	end
	return nil, "breakpoint store write failed: " .. tostring(err)
end

local normalise_entry = record.normalise

local function normalise_entries(raw_entries)
	if type(raw_entries) ~= "table" then
		return nil
	end
	local entries = {}
	for _, raw in ipairs(raw_entries) do
		local entry = normalise_entry(raw)
		if entry then
			entries[#entries + 1] = entry
		end
	end
	merge.sort_entries(entries)
	return #entries > 0 and entries or nil
end

-- Assigns ids to entries saved before ids existed; true when any was assigned.
local function assign_ids(store)
	local changed = false
	for _, bucket in pairs(store) do
		for _, entries in pairs(bucket) do
			for _, entry in ipairs(entries) do
				if not entry.id then
					entry.id = record.new_id()
					changed = true
				end
			end
		end
	end
	return changed
end

local function load_nested(decoded)
	local nested = {}
	for root, paths in pairs(decoded) do
		if space.is_key(root) and type(paths) == "table" then
			local bucket = {}
			for path, raw_entries in pairs(paths) do
				if absolute(path) then
					local entries = normalise_entries(raw_entries)
					if entries then
						bucket[path] = entries
					end
				end
			end
			if next(bucket) then
				nested[root] = bucket
			end
		end
	end
	return nested
end

-- Store file as the nested shape, or nil and why: missing or invalid.
local function decode(path)
	local fd = io.open(path, "r")
	if not fd then
		return nil, "missing"
	end
	local body = fd:read("*a")
	fd:close()
	local ok, decoded = pcall(vim.json.decode, body)
	if not ok or type(decoded) ~= "table" then
		return nil, "invalid"
	end
	return load_nested(decoded)
end

-- Merges every language folder; a path saved under two folders keeps the first copy of each id.
-- Returns nil, the reason and the unreadable file when one cannot be read.
local function read_file()
	local languages = saved_languages()
	local merged = {}
	for _, language in ipairs(languages) do
		local saved, unread = decode(language_path(language))
		if not saved and unread ~= "missing" then
			return nil, unread, language .. "/" .. FILE_NAME
		end
		for root, bucket in pairs(saved or {}) do
			local into = merged[root] or {}
			merged[root] = into
			for path, entries in pairs(bucket) do
				local list = into[path] or {}
				local seen = {}
				for _, entry in ipairs(list) do
					seen[entry.id or entry] = true
				end
				for _, entry in ipairs(entries) do
					if not (entry.id and seen[entry.id]) then
						list[#list + 1] = entry
					end
				end
				merge.sort_entries(list)
				into[path] = list
			end
		end
	end
	return merged
end

local function source_gone(path)
	local _, _, code = uv.fs_stat(path)
	return code == "ENOENT" or code == "ENOTDIR"
end

-- The OS holds the flock on a stable inode; closing the descriptor releases it. Never unlink this file.
local ffi = require("ffi")
ffi.cdef[[int flock(int fd, int operation);]]
local lock_path = state_dir .. "/breakpoints.json.flock"
local lock_depth = 0
local would_block = uv.os_uname().sysname == "Darwin" and 35 or 11
local function with_lock(operation)
	if lock_depth > 0 then return operation() end
	vim.fn.mkdir(state_dir, "p", 448)
	local fd, open_error = uv.fs_open(lock_path, "a", 384)
	assert(fd, "breakpoint store lock open failed: " .. tostring(open_error))
	local deadline = uv.hrtime() + 5e9
	while ffi.C.flock(fd, 6) ~= 0 do
		local errno = ffi.errno()
		if errno ~= would_block then
			uv.fs_close(fd)
			error("breakpoint store lock failed: errno " .. errno)
		end
		if uv.hrtime() >= deadline then
			uv.fs_close(fd)
			error("breakpoint store busy: lock wait exceeded 5 seconds")
		end
		uv.sleep(10)
	end
	lock_depth = 1
	local function pack(...) return { n = select("#", ...), ... } end
	local result = pack(xpcall(operation, debug.traceback))
	lock_depth = 0
	local released, release_error = uv.fs_close(fd)
	if not released then error("breakpoint store lock cleanup failed: " .. tostring(release_error)) end
	if not result[1] then error(result[2]) end
	return unpack(result, 2, result.n)
end

local function copy_legacy()
	if #saved_languages() > 0 then return end
	local old = vim.fn.stdpath("state") .. "/dap-sidecar"
	for _, source in ipairs(vim.fn.glob(old .. "/*/breakpoints.json", false, true)) do
		local target = language_path(vim.fn.fnamemodify(source, ":h:t"))
		local err = write_atomic(target, table.concat(vim.fn.readfile(source, "b"), "\n"))
		if err then error("breakpoint copy failed: " .. tostring(err)) end
	end
end

M.copy_legacy = copy_legacy
M.with_lock = with_lock
M.source_gone = source_gone
M.state_dir = state_dir
M.language_path = language_path
M.saved_languages = saved_languages
M.persist = persist
M.read = read_file
M.assign_ids = assign_ids
M.normalise_entries = normalise_entries


return M


