-- WorldEntryUI.lau
-- Client-side world entry/travel UI (press Travel button or NPC interaction).
-- Standalone panel with TextBox input, ENTER button, and recent worlds list.
-- Fires RequestTravelWorld to server — all routing handled server-side.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage.Shared)
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)

local WorldEntryUI = {}

--[[
	===== CONSTANTS =====
]]

local PANEL_WIDTH = 340
local PANEL_HEIGHT = 380
local MAX_RECENT = 5
local BUTTON_COOLDOWN = 5 -- seconds before button re-enables

-- Colors
local BG_COLOR = Color3.fromRGB(20, 20, 20)
local ACCENT_COLOR = Color3.fromRGB(100, 180, 255)
local GREEN_BTN = Color3.fromRGB(50, 180, 50)
local GRAY_BTN = Color3.fromRGB(80, 80, 80)
local TEXT_COLOR = Color3.fromRGB(220, 220, 220)
local LABEL_COLOR = Color3.fromRGB(160, 160, 160)

--[[
	===== STATE =====
]]

local localPlayer = Players.LocalPlayer
local screenGui: ScreenGui? = nil
local panel: Frame? = nil
local textBox: TextBox? = nil
local enterBtn: TextButton? = nil
local recentList: ScrollingFrame? = nil
local newWorldLabel: TextLabel? = nil
local overlay: Frame? = nil

local isOpen = false
local buttonDisabled = false
local recentWorlds: { string } = {}
local remoteConnections: { RBXScriptConnection } = {}

--[[
	===== HELPERS =====
]]

-- Normalize world name: uppercase, alphanumeric + underscore only, max 20
local function normalizeWorld(name: string): string
	return string.upper(string.gsub(name, "[^%w_]", ""))
end

-- Update enter button state based on input validity
local function updateButtonState()
	if not enterBtn or not textBox then return end

	local raw = textBox.Text
	local normalized = normalizeWorld(raw)

	-- Only allow valid characters in the box
	if raw ~= normalized then
		textBox.Text = normalized
	end

	local isValid = #normalized >= 3

	if isValid then
		-- Check not numbers only
		local onlyNumbers = tonumber(normalized) ~= nil
		isValid = not onlyNumbers
	end

	if isValid and not buttonDisabled then
		enterBtn.BackgroundColor3 = GREEN_BTN
		enterBtn.TextTransparency = 0
	else
		enterBtn.BackgroundColor3 = GRAY_BTN
		if buttonDisabled then
			enterBtn.TextTransparency = 0.5
		else
			enterBtn.TextTransparency = 0
		end
	end

	-- Show/hide "NEW WORLD" hint
	if newWorldLabel then
		if #normalized >= 3 then
			-- Check if world is in recent list
			local isRecent = false
			for _, w in ipairs(recentWorlds) do
				if w == normalized then
					isRecent = true
					break
				end
			end
			newWorldLabel.Visible = not isRecent
		else
			newWorldLabel.Visible = false
		end
	end
end

-- Shake the TextBox briefly (invalid input feedback)
local function shakeTextBox()
	if not textBox then return end

	local originalPos = textBox.Position
	local shake1 = TweenService:Create(
		textBox,
		TweenInfo.new(0.04, Enum.EasingStyle.Linear),
		{ Position = originalPos + UDim2.new(0, 6, 0, 0) }
	)
	local shake2 = TweenService:Create(
		textBox,
		TweenInfo.new(0.04, Enum.EasingStyle.Linear),
		{ Position = originalPos - UDim2.new(0, 6, 0, 0) }
	)
	local shake3 = TweenService:Create(
		textBox,
		TweenInfo.new(0.04, Enum.EasingStyle.Linear),
		{ Position = originalPos + UDim2.new(0, 3, 0, 0) }
	)
	local restore = TweenService:Create(
		textBox,
		TweenInfo.new(0.04, Enum.EasingStyle.Linear),
		{ Position = originalPos }
	)

	shake1:Play()
	shake1.Completed:Once(function()
		shake2:Play()
		shake2.Completed:Once(function()
			shake3:Play()
			shake3.Completed:Once(function()
				restore:Play()
			end)
		end)
	end)
end

-- Update recent worlds display
local function updateRecentList()
	if not recentList then return end

	-- Clear existing entries
	for _, child in ipairs(recentList:GetChildren()) do
		if child:IsA("TextButton") then
			child:Destroy()
		end
	end

	-- Show/hide based on recent worlds
	local labelAbove = recentList.Parent and recentList.Parent:FindFirstChild("RecentLabel")
	if labelAbove then
		labelAbove.Visible = #recentWorlds > 0
	end
	recentList.Visible = #recentWorlds > 0

	-- Populate
	local y = 0
	for _, worldName in ipairs(recentWorlds) do
		local btn = Instance.new("TextButton")
		btn.Name = "Recent_" .. worldName
		btn.Size = UDim2.new(1, -10, 0, 28)
		btn.Position = UDim2.new(0, 5, 0, y)
		btn.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
		btn.BorderSizePixel = 0
		btn.Text = worldName
		btn.TextColor3 = ACCENT_COLOR
		btn.TextSize = 14
		btn.Font = Enum.Font.SourceSansBold
		btn.AutoButtonColor = false
		btn.Parent = recentList

		-- Hover effect
		btn.MouseEnter:Connect(function()
			btn.BackgroundColor3 = Color3.fromRGB(55, 55, 70)
		end)
		btn.MouseLeave:Connect(function()
			btn.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
		end)

		-- Click fills TextBox
		btn.MouseButton1Click:Connect(function()
			print(`[WorldEntryUI] Recent world clicked: {worldName}`)
			if textBox then
				textBox.Text = worldName
			end
		end)

		y = y + 32
	end
end

-- Add a world to recent list
local function addRecentWorld(worldName: string)
	local normalized = normalizeWorld(worldName)
	if normalized == "START" then return end

	-- Remove if already exists (to move to front)
	for i, w in ipairs(recentWorlds) do
		if w == normalized then
			table.remove(recentWorlds, i)
			break
		end
	end

	-- Insert at front
	table.insert(recentWorlds, 1, normalized)

	-- Trim to max
	while #recentWorlds > MAX_RECENT do
		table.remove(recentWorlds)
	end

	updateRecentList()
	print(`[WorldEntryUI] Recent worlds updated: {table.concat(recentWorlds, ", ")}`)
end

-- Fire travel request
local function fireTravel()
	if buttonDisabled then return end
	if not textBox then return end

	local raw = textBox.Text
	local worldName = normalizeWorld(raw)

	-- Validate minimum 3 characters
	if #worldName < 3 then
		print(`[WorldEntryUI] Invalid input: "{worldName}" too short ({#worldName} chars)`)
		shakeTextBox()
		return
	end

	-- Validate not numbers only
	if tonumber(worldName) ~= nil then
		print(`[WorldEntryUI] Invalid input: "{worldName}" is numbers only`)
		shakeTextBox()
		return
	end

	-- Disable button to prevent double-fire
	buttonDisabled = true
	if enterBtn then
		enterBtn.BackgroundColor3 = GRAY_BTN
		enterBtn.TextTransparency = 0.5
	end

	print(`[WorldEntryUI] Firing RequestTravelWorld: "{worldName}"`)
	RemoteEvents.RequestTravelWorld:FireServer(worldName)

	-- Re-enable after cooldown
	task.delay(BUTTON_COOLDOWN, function()
		buttonDisabled = false
		updateButtonState()
	end)
end

--[[
	===== UI CONSTRUCTION =====
]]

local function buildUI()
	-- Don't create twice
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "WorldEntryGUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

	-- Dark overlay (click to close)
	overlay = Instance.new("Frame")
	overlay.Name = "WorldEntryOverlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.4
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 90
	overlay.Parent = screenGui

	overlay.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			WorldEntryUI.Close()
		end
	end)

	-- Main panel
	panel = Instance.new("Frame")
	panel.Name = "WorldEntryPanel"
	panel.Size = UDim2.new(0, PANEL_WIDTH, 0, PANEL_HEIGHT)
	panel.Position = UDim2.new(0.5, -PANEL_WIDTH / 2, 0.5, -PANEL_HEIGHT / 2)
	panel.BackgroundColor3 = BG_COLOR
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.ZIndex = 91
	panel.Parent = screenGui

	-- Initial position off-screen for fade-in
	panel.Position = UDim2.new(0.5, -PANEL_WIDTH / 2, 0.5, -PANEL_HEIGHT / 2)

	-- Title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 40)
	title.Position = UDim2.new(0, 0, 0, 10)
	title.BackgroundTransparency = 1
	title.Text = "TRAVEL"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 24
	title.Font = Enum.Font.SourceSansBold
	title.TextXAlignment = Enum.TextXAlignment.Center
	title.ZIndex = 92
	title.Parent = panel

	-- Close button (X)
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.Size = UDim2.new(0, 28, 0, 28)
	closeBtn.Position = UDim2.new(1, -34, 0, 6)
	closeBtn.BackgroundTransparency = 1
	closeBtn.Text = "✕"
	closeBtn.TextColor3 = Color3.fromRGB(180, 180, 180)
	closeBtn.TextSize = 18
	closeBtn.Font = Enum.Font.SourceSansBold
	closeBtn.ZIndex = 92
	closeBtn.Parent = panel

	closeBtn.MouseButton1Click:Connect(function()
		WorldEntryUI.Close()
	end)

	-- TextBox for world name input
	textBox = Instance.new("TextBox")
	textBox.Name = "WorldInput"
	textBox.Size = UDim2.new(1, -40, 0, 36)
	textBox.Position = UDim2.new(0, 20, 0, 60)
	textBox.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
	textBox.BorderSizePixel = 1
	textBox.BorderColor3 = Color3.fromRGB(60, 60, 80)
	textBox.Text = ""
	textBox.TextColor3 = Color3.fromRGB(255, 255, 255)
	textBox.TextSize = 18
	textBox.Font = Enum.Font.SourceSansBold
	textBox.TextXAlignment = Enum.TextXAlignment.Center
	textBox.PlaceholderText = "ENTER WORLD NAME..."
	textBox.PlaceholderColor3 = Color3.fromRGB(100, 100, 110)
	textBox.ClearTextOnFocus = false
	textBox.ZIndex = 92
	textBox.Parent = panel

	-- Auto-capitalize and strip invalid chars on EVERY keystroke
	textBox.Changed:Connect(function(prop: string)
		if prop == "Text" then
			updateButtonState()
		end
	end)

	-- Also validate on FocusLost (final check)
	textBox.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			fireTravel()
		end
		updateButtonState()
	end)

	-- "NEW WORLD" hint label
	newWorldLabel = Instance.new("TextLabel")
	newWorldLabel.Name = "NewWorldHint"
	newWorldLabel.Size = UDim2.new(1, -40, 0, 20)
	newWorldLabel.Position = UDim2.new(0, 20, 0, 100)
	newWorldLabel.BackgroundTransparency = 1
	newWorldLabel.Text = "NEW WORLD — WILL BE CREATED"
	newWorldLabel.TextColor3 = LABEL_COLOR
	newWorldLabel.TextSize = 12
	newWorldLabel.Font = Enum.Font.SourceSans
	newWorldLabel.TextXAlignment = Enum.TextXAlignment.Center
	newWorldLabel.Visible = false
	newWorldLabel.ZIndex = 92
	newWorldLabel.Parent = panel

	-- ENTER button
	enterBtn = Instance.new("TextButton")
	enterBtn.Name = "EnterButton"
	enterBtn.Size = UDim2.new(1, -80, 0, 40)
	enterBtn.Position = UDim2.new(0, 40, 0, 125)
	enterBtn.BackgroundColor3 = GRAY_BTN
	enterBtn.BorderSizePixel = 0
	enterBtn.Text = "ENTER"
	enterBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	enterBtn.TextSize = 18
	enterBtn.Font = Enum.Font.SourceSansBold
	enterBtn.ZIndex = 92
	enterBtn.Parent = panel

	enterBtn.MouseButton1Click:Connect(function()
		fireTravel()
	end)

	-- Recent worlds label
	local recentLabel = Instance.new("TextLabel")
	recentLabel.Name = "RecentLabel"
	recentLabel.Size = UDim2.new(1, -40, 0, 20)
	recentLabel.Position = UDim2.new(0, 20, 0, 180)
	recentLabel.BackgroundTransparency = 1
	recentLabel.Text = "RECENT WORLDS"
	recentLabel.TextColor3 = Color3.fromRGB(140, 140, 150)
	recentLabel.TextSize = 12
	recentLabel.Font = Enum.Font.SourceSansBold
	recentLabel.TextXAlignment = Enum.TextXAlignment.Center
	recentLabel.ZIndex = 92
	recentLabel.Visible = false
	recentLabel.Parent = panel

	-- Recent worlds list
	recentList = Instance.new("ScrollingFrame")
	recentList.Name = "RecentList"
	recentList.Size = UDim2.new(1, -20, 0, 140)
	recentList.Position = UDim2.new(0, 10, 0, 205)
	recentList.BackgroundTransparency = 1
	recentList.BorderSizePixel = 0
	recentList.ScrollBarThickness = 4
	recentList.ScrollBarImageColor3 = Color3.fromRGB(60, 60, 70)
	recentList.CanvasSize = UDim2.new(0, 0, 0, 0)
	recentList.Visible = false
	recentList.ZIndex = 92
	recentList.Parent = panel

	updateRecentList()
	updateButtonState()

	print("[WorldEntryUI] UI built")
end

--[[
	===== PUBLIC API =====
]]

function WorldEntryUI.Open()
	if isOpen then
		print("[WorldEntryUI] Already open")
		return
	end

	print("[WorldEntryUI] Opening panel")
	buildUI()

	if not panel then return end

	isOpen = true

	-- Fade in
	panel.Visible = true
	local fadeIn = TweenService:Create(
		panel,
		TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ BackgroundTransparency = 0.1 }
	)
	fadeIn:Play()

	-- Auto-focus TextBox
	if textBox then
		task.wait(0.05)
		textBox:CaptureFocus()
	end
end

function WorldEntryUI.Close()
	if not isOpen then return end

	print("[WorldEntryUI] Closing panel")

	isOpen = false

	-- Fade out
	if panel then
		local fadeOut = TweenService:Create(
			panel,
			TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ BackgroundTransparency = 1 }
		)
		fadeOut:Play()
		fadeOut.Completed:Once(function()
			if screenGui then
				screenGui:Destroy()
				screenGui = nil
			end
			panel = nil
			overlay = nil
			textBox = nil
			enterBtn = nil
			recentList = nil
			newWorldLabel = nil
		end)
	end
end

function WorldEntryUI.Toggle()
	if isOpen then
		WorldEntryUI.Close()
	else
		WorldEntryUI.Open()
	end
end

function WorldEntryUI.Init()
	print("[WorldEntryUI] Initialized")

	-- Listen for WorldLoaded to add to recent worlds and close panel
	local wlConn = RemoteEvents.WorldLoaded.OnClientEvent:Connect(function(worldName: string)
		print(`[WorldEntryUI] WorldLoaded received: "{worldName}"`)
		addRecentWorld(worldName)
		if isOpen then
			WorldEntryUI.Close()
		end
	end)
	table.insert(remoteConnections, wlConn)

	-- Listen for Escape to close
	local escConn = UserInputService.InputBegan:Connect(function(input: InputObject, isProcessed: boolean)
		if isProcessed then return end
		if input.KeyCode == Enum.KeyCode.Escape then
			if isOpen then
				WorldEntryUI.Close()
			end
		end
	end)
	table.insert(remoteConnections, escConn)

	-- Listen for NPCInteractResult (WAYFARER NPC opens this panel)
	local npcConn = RemoteEvents.NPCInteractResult.OnClientEvent:Connect(function(npcType: string, data: table)
		print(`[WorldEntryUI] NPCInteractResult received: npcType={npcType}`)
		if npcType == "WAYFARER" then
			print("[WorldEntryUI] WAYFARER NPC triggered — opening world entry UI")
			WorldEntryUI.Open()
		end
	end)
	table.insert(remoteConnections, npcConn)

	print("[WorldEntryUI] Init complete — connected to WorldLoaded, Escape, NPCInteractResult")
end

function WorldEntryUI.Destroy()
	for _, conn in ipairs(remoteConnections) do
		conn:Disconnect()
	end
	remoteConnections = {}

	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	panel = nil
	isOpen = false
	print("[WorldEntryUI] Destroyed")
end

return WorldEntryUI
