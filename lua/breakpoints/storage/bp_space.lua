-- Breakpoint space of a file: its git root, else the shared no-project space. The one owner of that rule.
local M = {}

local merge = require("breakpoints.storage.bp_merge")

-- Bucket key of the no-project space. Real keys are absolute paths, so it cannot collide.
M.NO_PROJECT = "<no-project>"


local uv = vim.uv or vim.loop

-- dir -> { top, marks }. A memo holds only while dir's git boundaries are unchanged.
local roots = {}

local function absolute(path)
	return type(path) == "string" and path:sub(1, 1) == "/"
end

local function trim(dir)
	return (vim.fn.fnamemodify(dir, ":p"):gsub("/$", ""))
end

-- Git toplevel of dir, or nil outside a work tree.
function M.git_toplevel(dir)
	if not absolute(dir) then
		return nil
	end
	local out = vim.fn.systemlist({ "git", "-C", dir, "rev-parse", "--show-toplevel" })
	if vim.v.shell_error ~= 0 then
		return nil
	end
	local top = out[1]
	if type(top) ~= "string" or top == "" then
		return nil
	end
	return trim(top)
end

-- Filesystem-only fingerprint of dir's git boundaries; never runs git.
local function boundaries(dir)
	local start = dir == "" and "/" or dir
	local real = uv.fs_realpath(start)
	local walk = real or start
	local marks = { real or ("?" .. start) }
	repeat
		local marker = (walk == "/" and "" or walk) .. "/.git"
		local info = uv.fs_lstat(marker)
		if info then
			marks[#marks + 1] = walk
			marks[#marks + 1] = info.type
			if info.type == "link" then
				marks[#marks + 1] = uv.fs_realpath(marker) or "unresolved"
				info = uv.fs_stat(marker)
			end
			if info and info.type == "directory" then
				local head = uv.fs_stat(marker .. "/HEAD")
				marks[#marks + 1] = "HEAD:" .. (head and head.type or "missing")
			elseif info and info.type == "file" then
				local file = io.open(marker, "rb")
				local contents = file and file:read("*a") or nil
				if file then file:close() end
				marks[#marks + 1] = contents and (#contents .. ":" .. contents) or "unreadable"
			end
		end
		local up = vim.fs.dirname(walk)
		local top = up == walk
		walk = up
	until top
	return table.concat(marks, "\0")
end

-- Asks git again when the boundaries changed since the memo was made.
local function revalidated(dir)
	local marks = boundaries(dir)
	local memo = roots[dir]
	if not memo or memo.marks ~= marks then
		memo = { top = M.git_toplevel(dir) or false, marks = marks }
		roots[dir] = memo
	end
	return memo.top
end

function M.of_dir(dir)
	if not absolute(dir) then
		return M.NO_PROJECT
	end
	return revalidated(trim(dir)) or M.NO_PROJECT
end

function M.editor()
	return M.of_dir(vim.fn.getcwd())
end

function M.of_file(path)
	
	return M.of_dir(vim.fn.fnamemodify(path, ":h"))
end

function M.is_key(key)
	return key == M.NO_PROJECT or absolute(key)
end

-- Moves entries stored under a space their file does not belong to; the next save writes them there.
function M.refile(store)
	
	local moves = {}
	for key, bucket in pairs(store) do
		for path in pairs(bucket) do
			local space = M.of_file(path)
			if space ~= key then
				moves[#moves + 1] = { from = key, to = space, path = path }
			end
		end
	end
	for _, move in ipairs(moves) do
		local entries = store[move.from][move.path]
		store[move.from][move.path] = nil
		if not next(store[move.from]) then
			store[move.from] = nil
		end
		store[move.to] = store[move.to] or {}
		local target = store[move.to][move.path] or {}
		local seen = {}
		for _, entry in ipairs(target) do
			seen[entry.id or ""] = true
		end
		for _, entry in ipairs(entries) do
			if not (entry.id and seen[entry.id]) then
				target[#target + 1] = entry
			end
		end
		merge.sort_entries(target)
		store[move.to][move.path] = target
	end
	return #moves > 0
end

return M


