-- Language folder a saved breakpoint file is filed under: the filetype, with C stored under cpp; otherwise `other`.
local M = {}

M.OTHER = "other"

local by_path = {}

local function folder_name(name)
	return type(name) == "string" and name:match("^[%w_][%w_.-]*$") and name or M.OTHER
end

---@param path string absolute source path
---@return string language folder name
function M.of_path(path)
	local known = by_path[path]
	if known then
		return known
	end
	local filetype = vim.filetype.match({ filename = path })
	local language = M.OTHER
	if filetype and filetype ~= "" then
		language = folder_name(filetype == "c" and "cpp" or filetype)
	end
	by_path[path] = language
	return language
end

return M


