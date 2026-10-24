-- Merges one save of one file into fresh disk state, by id. Pure: returns the mark actions to apply.
local M = {}

local record = require("breakpoints.storage.bp_record")

local function sort_entries(entries)
	table.sort(entries, function(a, b)
		if a.line ~= b.line then
			return a.line < b.line
		end
		return tostring(a.id) < tostring(b.id)
	end)
end

-- Which candidate keeps a row: one already on it, then the lower line.
local function better(a, b, row)
	local a1, b1 = a.pre == row, b.pre == row
	if a1 ~= b1 then
		return a1
	end
	if a.pre ~= b.pre then
		return a.pre < b.pre
	end
	return tostring(a.id) < tostring(b.id)
end

-- Merges a saved buffer's marks into `state` in place.
---@return table result {changed, said = {lines}, drop = {ids of marks to delete}}
function M.merge(state, path, list)
	local result = { changed = false, said = {}, drop = {} }
	local disk = {}
	for root, bucket in pairs(state) do
		for _, entry in ipairs(bucket[path] or {}) do
			disk[entry.id or ""] = { root = root, entry = entry }
		end
	end
	local removed, marked, candidates = {}, {}, {}
	local function candidate(c)
		local key = c.root .. "\0" .. c.row
		candidates[key] = candidates[key] or {}
		table.insert(candidates[key], c)
	end
	for _, mark in ipairs(list) do
		local found = disk[mark.id]
		marked[mark.id] = true
		if not found then
			result.drop[#result.drop + 1] = mark.id
		elseif mark.invalid then
			removed[mark.id] = true
			result.drop[#result.drop + 1] = mark.id
		else
			candidate({ kind = "stored", id = mark.id, root = found.root, row = mark.row, pre = found.entry.line })
		end
	end
	for id, found in pairs(disk) do
		if not marked[id] then
			candidate({ kind = "disk", id = id, root = found.root, row = found.entry.line, pre = found.entry.line })
		end
	end
	local lines = {}
	for _, group in pairs(candidates) do
		local keep = group[1]
		for i = 2, #group do
			if better(group[i], keep, group[i].row) then
				keep = group[i]
			end
		end
		for _, c in ipairs(group) do
			if c ~= keep then
				result.said[#result.said + 1] = string.format("breakpoint from line %d merged into line %d", c.pre, c.row)
				removed[c.id] = true
				if marked[c.id] then
					result.drop[#result.drop + 1] = c.id
				end
			end
		end
		if keep.kind == "stored" then
			lines[keep.id] = keep.row
		end
	end
	for root, bucket in pairs(state) do
		local entries = bucket[path]
		if entries then
			local kept = {}
			for _, entry in ipairs(entries) do
				if removed[entry.id or ""] then
					result.changed = true
				else
					local line = lines[entry.id or ""]
					if line and line ~= entry.line then
						entry.line = line
						result.changed = true
					end
					kept[#kept + 1] = entry
				end
			end
			sort_entries(kept)
			bucket[path] = #kept > 0 and kept or nil
			if not next(bucket) then
				state[root] = nil
			end
		end
	end
	return result
end

-- Moves `from`'s records to `to` in place, keeping ids and properties. Refused, with `state` untouched, when `to` is occupied or in another space.
---@return table|nil moved, string|nil refusal
function M.rename(state, from, to, from_space, to_space)
	local held, occupied = {}, false
	for _, bucket in pairs(state) do
		vim.list_extend(held, bucket[from] or {})
		occupied = occupied or bucket[to] ~= nil
	end
	if #held == 0 then
		return nil
	end
	local name = function(path) return vim.fn.fnamemodify(path, ":t") end
	if occupied or from_space ~= to_space then
		return nil, string.format("breakpoints stay with %s: %s %s", name(from), name(to),
			occupied and "already has breakpoints" or "is in another project")
	end
	for key, bucket in pairs(state) do
		bucket[from] = nil
		if not next(bucket) then
			state[key] = nil
		end
	end
	sort_entries(held)
	state[to_space] = state[to_space] or {}
	state[to_space][to] = held
	return held
end

M.sort_entries = sort_entries

return M


