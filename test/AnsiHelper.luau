local ANSI_COLOR_MAP = {
	["[30m"] = "rgb(0, 0, 0)",
	["[31m"] = "rgb(254, 91, 86)",
	["[32m"] = "rgb(89, 246, 141)",
	["[33m"] = "rgb(255, 255, 164)",
	["[34m"] = "rgb(87, 199, 255)",
	["[35m"] = "rgb(254, 105, 192)",
	["[36m"] = "rgb(153, 236, 254)",
	["[37m"] = "rgb(240, 240, 239)",
}

local BACKGROUND_COLOR_MAP = {
	["[40m"] = Color3.fromRGB(0, 0, 0),
	["[41m"] = Color3.fromRGB(254, 91, 86),
	["[42m"] = Color3.fromRGB(89, 246, 141),
	["[43m"] = Color3.fromRGB(255, 255, 164),
	["[44m"] = Color3.fromRGB(87, 199, 255),
	["[45m"] = Color3.fromRGB(254, 105, 192),
	["[46m"] = Color3.fromRGB(153, 236, 254),
	["[47m"] = Color3.fromRGB(240, 240, 239),
}

local MESSAGE_TYPE_COLORS = {
	["[91m"] = "rgb(0,139,219)", -- blue
	["[92m"] = "rgb(255,115,21)", -- orange
	["[93m"] = "rgb(255,0,0)", -- red
}

local function defaultState()
	return {
		stack = {}, -- stack of styles (font/color/bold/etc)
		visibleCharacterIndex = 0,

		-- Background runs
		backgroundRuns = {},
		currentBackgroundColor = nil,
		backgroundStartIndex = nil,
	}
end

local function styleOpeningTag(style)
	if style.type == "bold" then
		return "<b>"
	elseif style.type == "italic" then
		return "<i>"
	elseif style.type == "underline" then
		return "<u>"
	elseif style.type == "strikethrough" then
		return "<s>"
	elseif style.type == "color" then
		return string.format('<font color="%s">', style.color)
	end
	return ""
end

local function styleClosingTag(style)
	if style.type == "bold" then
		return "</b>"
	elseif style.type == "italic" then
		return "</i>"
	elseif style.type == "underline" then
		return "</u>"
	elseif style.type == "strikethrough" then
		return "</s>"
	elseif style.type == "color" then
		return "</font>"
	end
	return ""
end

local function isStyleActive(state, styleType)
	for _, s in ipairs(state.stack) do
		if s.type == styleType then
			return true
		end
	end
	return false
end

local function pushStyle(state, output, style)
	table.insert(state.stack, style)
	output[#output + 1] = styleOpeningTag(style)
end

local function popStylesUntil(state, output, targetType)
	local popped = {}
	local foundTarget = false
	while #state.stack > 0 do
		local top = state.stack[#state.stack]
		table.remove(state.stack)
		output[#output + 1] = styleClosingTag(top)
		if top.type == targetType then
			foundTarget = true
			break
		else
			table.insert(popped, 1, top)
		end
	end
	return foundTarget, popped
end

local function restoreStyles(state, output, styles)
	for _, st in ipairs(styles) do
		pushStyle(state, output, st)
	end
end

local function disableStyle(state, output, styleType)
	if not isStyleActive(state, styleType) then
		return
	end
	local foundTarget, popped = popStylesUntil(state, output, styleType)
	if foundTarget then
		restoreStyles(state, output, popped)
	end
end

local function resetAll(state, output)
	-- Reset all foreground styles
	while #state.stack > 0 do
		local top = state.stack[#state.stack]
		table.remove(state.stack)
		output[#output + 1] = styleClosingTag(top)
	end

	-- Also reset background if active
	if state.currentBackgroundColor then
		local run = {
			startIndex = state.backgroundStartIndex,
			endIndex = state.visibleCharacterIndex - 1,
			color = state.currentBackgroundColor,
		}
		table.insert(state.backgroundRuns, run)
		state.currentBackgroundColor = nil
		state.backgroundStartIndex = nil
	end
end

local function enableStyle(state, output, styleType, color)
	if styleType == "color" then
		disableStyle(state, output, "color")
		pushStyle(state, output, { type = "color", color = color })
	else
		if not isStyleActive(state, styleType) then
			pushStyle(state, output, { type = styleType })
		end
	end
end

local function enableBackground(state, bgColor)
	if state.currentBackgroundColor == bgColor then
		return
	end

	-- If there's already a background active, close it first
	if state.currentBackgroundColor then
		local run = {
			startIndex = state.backgroundStartIndex,
			endIndex = state.visibleCharacterIndex - 1,
			color = state.currentBackgroundColor,
		}
		table.insert(state.backgroundRuns, run)
		state.currentBackgroundColor = nil
		state.backgroundStartIndex = nil
	end

	state.currentBackgroundColor = bgColor
	state.backgroundStartIndex = state.visibleCharacterIndex
end

local function disableBackground(state)
	if state.currentBackgroundColor then
		local run = {
			startIndex = state.backgroundStartIndex,
			endIndex = state.visibleCharacterIndex - 1,
			color = state.currentBackgroundColor,
		}
		table.insert(state.backgroundRuns, run)
		state.currentBackgroundColor = nil
		state.backgroundStartIndex = nil
	end
end

local function applyCode(code, output, state)
	if code == "[0m" then
		resetAll(state, output)
		return
	end

	local codes = {}
	for c in code:gmatch("%[(.-)m") do
		for sc in c:gmatch("([^;]+)") do
			table.insert(codes, sc)
		end
	end

	for _, c in ipairs(codes) do
		local num = tonumber(c)
		if num == 0 then
			resetAll(state, output)
		elseif num == 1 then
			enableStyle(state, output, "bold")
		elseif num == 22 then
			disableStyle(state, output, "bold")
		elseif num == 3 then
			enableStyle(state, output, "italic")
		elseif num == 23 then
			disableStyle(state, output, "italic")
		elseif num == 4 then
			enableStyle(state, output, "underline")
		elseif num == 24 then
			disableStyle(state, output, "underline")
		elseif num == 9 then
			enableStyle(state, output, "strikethrough")
		elseif num == 29 then
			disableStyle(state, output, "strikethrough")
		elseif num >= 30 and num <= 37 then
			local ansiCode = "[" .. tostring(num) .. "m"
			local color = ANSI_COLOR_MAP[ansiCode]
			if color then
				enableStyle(state, output, "color", color)
			end
		elseif num == 39 then
			-- Reset foreground color
			disableStyle(state, output, "color")
		elseif num >= 40 and num <= 47 then
			local ansiCode = "[" .. tostring(num) .. "m"
			local bgColor = BACKGROUND_COLOR_MAP[ansiCode]
			if bgColor then
				enableBackground(state, bgColor)
			end
		elseif num == 49 then
			-- Reset background
			disableBackground(state)
		elseif num == 91 then
			enableStyle(state, output, "color", MESSAGE_TYPE_COLORS["[91m"])
		elseif num == 92 then
			enableStyle(state, output, "color", MESSAGE_TYPE_COLORS["[92m"])
		elseif num == 93 then
			enableStyle(state, output, "color", MESSAGE_TYPE_COLORS["[93m"])
		end
	end
end

local function ansiToRichTextChunk(text, currentState)
	text = text:gsub("✕", "×")
	text = text:gsub("<", "&lt;")
	text = text:gsub(">", "&gt;")

	if not currentState then
		currentState = defaultState()
	end

	local output = {}
	local last_end = 1
	-- Find all ANSI sequences: \27 followed by [ and then zero or more digits/semicolons, ending with 'm'.
	for start, code, finish in text:gmatch("()(\27%[[%d;]*m)()") do
		-- Add all plain text before this code
		if last_end < start then
			local chunk = text:sub(last_end, start - 1)
			output[#output + 1] = chunk
			currentState.visibleCharacterIndex = currentState.visibleCharacterIndex + #chunk
		end

		-- Apply ANSI code
		applyCode(code:sub(2), output, currentState) -- code:sub(2) to remove the initial ESC character
		last_end = finish
	end

	-- Add remaining text after last ANSI code
	if last_end <= #text then
		local chunk = text:sub(last_end)
		output[#output + 1] = chunk
		currentState.visibleCharacterIndex = currentState.visibleCharacterIndex + #chunk
	end

	return table.concat(output), currentState
end

local function finalizeRichText(currentState)
	local output = {}
	resetAll(currentState, output)
	return table.concat(output)
end

local function getTemporaryClosingString(currentState)
	local savedStack = table.clone(currentState.stack)
	local preview = {}

	while #savedStack > 0 do
		local top = savedStack[#savedStack]
		table.remove(savedStack)
		preview[#preview + 1] = styleClosingTag(top)
	end

	if currentState.currentBackgroundColor then
		local run = {
			startIndex = currentState.backgroundStartIndex,
			endIndex = currentState.visibleCharacterIndex - 1,
			color = currentState.currentBackgroundColor,
		}
		table.insert(currentState.backgroundRuns, run)
		currentState.currentBackgroundColor = nil
		currentState.backgroundStartIndex = nil
	end

	return table.concat(preview)
end

return {
	defaultState = defaultState,
	ansiToRichTextChunk = ansiToRichTextChunk,
	finalizeRichText = finalizeRichText,
	getTemporaryClosingString = getTemporaryClosingString,
}
