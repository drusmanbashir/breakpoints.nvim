-- The breakpoint record: entry shape, hit-count grammar and property refusals.
local M = {}

local uv = vim.uv or vim.loop



-- Silent aliases only: Kitty's kitty_mod+f8 swallows Ctrl+Shift+F8, so no doc names them.
M.PROPS_KEY = "<leader>dT"
M.PROPS_ALIASES = { "<C-S-F8>", "<F44>" }

function M.props_keys()
	local keys = vim.list_extend({}, M.PROPS_ALIASES)
	do table.insert(keys, 1, M.PROPS_KEY) end
	return keys
end

M.FIELDS = { "id", "line", "condition", "log_message", "hit_condition", "remove_once" }
M.PROPS = { "condition", "log_message", "hit_condition", "remove_once" }

M.COMBO_REFUSAL = "a breakpoint that only logs never stops, so it cannot be removed once hit"
M.GONE = "breakpoint no longer exists"

local function nonempty(value)
	return type(value) == "string" and value ~= "" and value or nil
end

local function valid_line(line)
	return type(line) == "number" and line % 1 == 0 and line > 0
end

-- Hit counts as debugpy parses them: an optional operator, then digits.
function M.valid_hit(text)
	if type(text) ~= "string" then
		return false
	end
	local body = vim.trim(text)
	for _, op in ipairs({ "==", ">=", "<=", ">", "<", "%" }) do
		if body:sub(1, #op) == op then
			body = vim.trim(body:sub(#op + 1))
			break
		end
	end
	return body:match("^%d+$") ~= nil
end

-- Keeps the six fields; drops unknown fields, invalid hit counts and remove_once beside a log message. nil when the line is invalid.
function M.normalise(raw)
	if type(raw) ~= "table" or not valid_line(raw.line) then
		return nil
	end
	local entry = { line = raw.line, id = nonempty(raw.id) }
	entry.condition = nonempty(raw.condition)
	entry.log_message = nonempty(raw.log_message)
	if nonempty(raw.hit_condition) and M.valid_hit(raw.hit_condition) then
		entry.hit_condition = raw.hit_condition
	end
	if raw.remove_once == true and not entry.log_message then
		entry.remove_once = true
	end
	return entry
end

-- Returns the four properties, or nil and one refusal line. Empty strings mean none.
function M.validate(props)
	props = props or {}
	local out = {
		condition = nonempty(props.condition and vim.trim(props.condition)),
		log_message = nonempty(props.log_message and vim.trim(props.log_message)),
		hit_condition = nonempty(props.hit_condition and vim.trim(props.hit_condition)),
		remove_once = props.remove_once == true or nil,
	}
	if out.hit_condition and not M.valid_hit(out.hit_condition) then
		return nil, string.format('hit count "%s" refused: use N, == N, > N, >= N, < N, <= N or %% N', out.hit_condition)
	end
	if out.remove_once and out.log_message then
		return nil, M.COMBO_REFUSAL
	end
	return out
end

local last_id
-- bp-<pid hex>-<hrtime hex>; never reused within the process.
function M.new_id()
	local stamp = uv.hrtime()
	if last_id and stamp <= last_id then
		stamp = last_id + 1
	end
	last_id = stamp
	return string.format("bp-%x-%x", vim.fn.getpid(), stamp)
end

-- Saved intent only: a log point never stops, so it alone looks different; properties show on hover.
function M.glyph(entry)
	return "●"
end

function M.say(text, level)
	vim.notify(text, level or vim.log.levels.INFO)
	return text
end

return M
