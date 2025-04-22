local LogService = game:GetService("LogService")

local AnsiHelper = require(script.Parent.AnsiHelper)

local MESSAGE_TYPE_COLORS = {
	[Enum.MessageType.MessageInfo] = "\27[91m",
	[Enum.MessageType.MessageWarning] = "\27[92m",
	[Enum.MessageType.MessageError] = "\27[93m",
}

local function colorMessageByType(message: string, messageType: Enum.MessageType): string
	local color = MESSAGE_TYPE_COLORS[messageType]
	if color then
		return `{color}{message}\27[39m`
	end
	return message
end

local function throttle(fn: () -> (), delay: number): () -> ()
	local lastCall = 0
	local scheduled = false

	local function throttled(...)
		local args = table.pack(...)

		if not scheduled then
			scheduled = true

			task.defer(function()
				local now = tick()
				if now - lastCall < delay then
					task.wait(delay - (now - lastCall))
				end

				fn(table.unpack(args))
				lastCall = tick()

				scheduled = false
			end)
		end
	end

	return throttled
end

return function(target: Frame)
	local container
	local conn

	local function cleanup()
		if container then
			container:Destroy()
		end
		if conn then
			conn:Disconnect()
		end
	end

	local renderOutputOk, renderOutputErr = pcall(function()
		container = Instance.new("Frame")
		container.Size = UDim2.fromScale(0.7, 0.98)
		container.Position = UDim2.fromScale(0.5, 0.5)
		container.AnchorPoint = Vector2.new(0.5, 0.5)
		container.BackgroundColor3 = Color3.fromRGB(40, 42, 54)
		container.BorderSizePixel = 0
		container.Parent = target

		local corner = Instance.new("UICorner")
		corner.CornerRadius = UDim.new(0, 16)
		corner.Parent = container

		local pad = Instance.new("UIPadding")
		pad.PaddingTop = UDim.new(0, 16)
		pad.PaddingRight = UDim.new(0, 16)
		pad.PaddingBottom = UDim.new(0, 16)
		pad.PaddingLeft = UDim.new(0, 16)
		pad.Parent = container

		local frame = Instance.new("ScrollingFrame")
		frame.AutomaticCanvasSize = Enum.AutomaticSize.Y
		frame.Size = UDim2.fromScale(1, 1)
		frame.Position = UDim2.fromScale(0.5, 0.5)
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.BackgroundTransparency = 1
		frame.BorderSizePixel = 0
		frame.CanvasSize = UDim2.fromScale(0, 0)
		frame.BottomImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
		frame.TopImage = "rbxasset://textures/ui/Scroll/scroll-middle.png"
		frame.ScrollBarThickness = 8
		frame.ScrollBarImageTransparency = 0.5
		frame.ScrollBarImageColor3 = Color3.fromRGB(255, 255, 255)
		frame.Parent = container

		local labelFrame = Instance.new("Frame")
		labelFrame.Size = UDim2.fromScale(1, 1)
		labelFrame.BackgroundTransparency = 1
		labelFrame.Parent = frame

		local list = Instance.new("UIListLayout")
		list.SortOrder = Enum.SortOrder.LayoutOrder
		list.Parent = labelFrame

		local textLabels = {}

		local function makeTextLabel()
			local label = Instance.new("TextLabel")
			label.Size = UDim2.fromScale(0.95, 0)
			label.AutomaticSize = Enum.AutomaticSize.Y
			label.Position = UDim2.fromScale(0.5, 0)
			label.AnchorPoint = Vector2.new(0.5, 0)
			label.BackgroundTransparency = 1
			label.RichText = true
			label.TextYAlignment = Enum.TextYAlignment.Bottom
			label.TextXAlignment = Enum.TextXAlignment.Left
			label.Text = ""
			label.TextSize = 16
			label.TextWrapped = true
			label.ZIndex = 2
			label.FontFace = Font.new("rbxasset://fonts/families/RobotoMono.json")

			-- Set the default text color explicitly (Chalk defaults to white if no color code is applied)
			label.TextColor3 = Color3.fromRGB(240, 240, 239)

			return label
		end

		local outputs = {}
		local currentState = AnsiHelper.defaultState()

		local _label = makeTextLabel()
		_label.Parent = labelFrame
		table.insert(textLabels, _label)
		table.insert(outputs, "")

		local messageQueue = {}

		local function render()
			for i, item in messageQueue do
				messageQueue[i] = colorMessageByType(item.message, item.messageType)
			end
			table.insert(messageQueue, "")
			local msg = table.concat(messageQueue, "\n")
			messageQueue = {}

			local wasAtBottom = frame.CanvasPosition.Y >= frame.AbsoluteCanvasSize.Y - frame.AbsoluteSize.Y - 16
			local renderOk, renderErr = pcall(function()
				local segment, newState = AnsiHelper.ansiToRichTextChunk(msg, currentState)
				currentState = newState

				local displayText = segment .. AnsiHelper.getTemporaryClosingString(currentState)

				local label

				local output = outputs[#outputs]
				local prevLabel = textLabels[#textLabels]

				prevLabel.Text = output .. segment

				if utf8.len(prevLabel.ContentText) > 16384 then
					output = string.sub(output, 1, -2) -- remove trailing newlines
					outputs[#outputs] = output
					prevLabel.Text = output
					label = makeTextLabel()
					label.LayoutOrder = #textLabels + 1
					label.Parent = labelFrame
					table.insert(textLabels, label)
					table.insert(outputs, "")
					output = ""
				else
					label = textLabels[#textLabels]
				end

				label.Text = output .. displayText
				output ..= segment
				outputs[#outputs] = output

				if wasAtBottom then
					frame.CanvasPosition = Vector2.new(0, frame.AbsoluteCanvasSize.Y)
				end
			end)

			if not renderOk then
				conn:Disconnect()
				warn("Error rendering message:", renderErr)
			end
		end

		local renderThrottled = throttle(render, 1 / 60)

		conn = LogService.MessageOut:Connect(function(message, messageType)
			table.insert(messageQueue, { message = message, messageType = messageType })
			renderThrottled()
		end)
	end)

	if not renderOutputOk then
		if conn then
			conn:Disconnect()
		end
		warn(renderOutputErr)
		return cleanup
	end

	task.spawn(function()
		local runJestTests = require(script.Parent.runJestTests)
		runJestTests()
	end)

	return cleanup
end
