--!strict
-- WrenchUI.lua (client)
-- Popup panel displayed when wrenching a tile (pressing E on a tile).
-- Shows tile information (fg, bg, hp, tree growth), door destination management,
-- and world lock admin management.
--
-- Architecture:
--   - Server fires WrenchData RemoteEvent → WrenchUI receives it and opens the panel
--   - Panel is a ScreenGui Frame positioned near the wrenched tile
--   - Auto-closes when player moves >3 tiles from the wrenched position
--   - Closes on pressing E again or clicking outside
--   - Fires RequestSetDoorDestination / RequestAddAdmin / RequestRemoveAdmin to server

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local Shared = require(ReplicatedStorage.Shared)
local WorldConfig = Shared.WorldConfig
local ItemDatabase = Shared.ItemDatabase
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)

local WrenchUI = {}

--[[
	===== CONSTANTS =====
]]

local PANEL_WIDTH = 300
local PANEL_HEIGHT = 320
local PADDING = 8
local ROW_HEIGHT = 24
local FONT = Enum.Font.SourceSans
local FONT_SIZE = 16
local CLOSE_DISTANCE = 3  -- tiles, auto-close if player moves this far from wrenched tile

-- Colors
local BG_COLOR = Color3.fromRGB(30, 30, 35)
local BORDER_COLOR = Color3.fromRGB(60, 60, 70)
local TEXT_COLOR = Color3.fromRGB(220, 220, 220)
local HIGHLIGHT_COLOR = Color3.fromRGB(50, 50, 60)
local ACCENT_COLOR = Color3.fromRGB(100, 180, 255)
local SUCCESS_COLOR = Color3.fromRGB(100, 200, 100)
local ERROR_COLOR = Color3.fromRGB(255, 100, 100)
local BUTTON_COLOR = Color3.fromRGB(50, 50, 60)
local BUTTON_HOVER = Color3.fromRGB(70, 70, 80)
local INPUT_BG = Color3.fromRGB(20, 20, 25)

--[[
	===== STATE =====
]]

local localPlayer = Players.LocalPlayer

local gui: ScreenGui? = nil
local panel: Frame? = nil
local isOpen = false

-- Current wrenched tile data
local wrenchedData = nil  -- table from WrenchData

-- Track position for auto-close
local wrenchedTileX = -1
local wrenchedTileY = -1

-- Player position tracking (updated via RenderStepped)
local playerTileX = 0
local playerTileY = 0

-- Module references
local worldRenderer = nil

--[[
	===== HELPER FUNCTIONS =====
]]

local function createLabel(text: string, textColor: Color3?, fontSize: number?): TextLabel
	local label = Instance.new("TextLabel")
	label.Text = text
	label.TextColor3 = textColor or TEXT_COLOR
	label.TextSize = fontSize or FONT_SIZE
	label.Font = FONT
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -PADDING * 2, 0, ROW_HEIGHT)
	label.Position = UDim2.new(0, PADDING, 0, 0)
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextYAlignment = Enum.TextYAlignment.Center
	return label
end

local function createButton(text: string, color: Color3?): TextButton
	local btn = Instance.new("TextButton")
	btn.Text = text
	btn.TextColor3 = Color3.fromRGB(255, 255, 255)
	btn.TextSize = 14
	btn.Font = FONT
	btn.BackgroundColor3 = color or BUTTON_COLOR
	btn.BorderSizePixel = 0
	btn.Size = UDim2.new(0, 80, 0, ROW_HEIGHT)
	btn.AutoButtonColor = false
	return btn
end

local function createTextBox(placeholder: string): TextBox
	local box = Instance.new("TextBox")
	box.Text = ""
	box.PlaceholderText = placeholder
	box.PlaceholderColor3 = Color3.fromRGB(120, 120, 130)
	box.TextColor3 = TEXT_COLOR
	box.TextSize = 14
	box.Font = FONT
	box.BackgroundColor3 = INPUT_BG
	box.BorderSizePixel = 1
	box.BorderColor3 = BORDER_COLOR
	box.Size = UDim2.new(1, -PADDING * 2 - 85, 0, ROW_HEIGHT)
	box.Position = UDim2.new(0, PADDING, 0, 0)
	box.TextXAlignment = Enum.TextXAlignment.Left
	box.ClearTextOnFocus = true
	return box
end

--[[
	Get the item name for a tile fg/bg ID.
	Returns "Empty" or "Unknown" for missing items.
]]
local function getItemDisplayName(itemId: number): string
	if itemId == 0 or itemId == nil then
		return "Empty"
	end
	local item = ItemDatabase.GetItem(itemId)
	if item then
		return item.name or ("Item #" .. itemId)
	end
	return "Item #" .. itemId
end

--[[
	Get the item type name for display.
]]
local function getItemTypeName(itemId: number): string
	if itemId == 0 or itemId == nil then
		return "None"
	end
	local item = ItemDatabase.GetItem(itemId)
	if item and item.type ~= nil then
		local name = WorldConfig.GetItemTypeName(item.type)
		if name then
			return name
		end
		return "Type " .. tostring(item.type)
	end
	return "Unknown"
end

--[[
	===== UI CONSTRUCTION =====
]]

local function buildPanel()
	if not gui then
		gui = Instance.new("ScreenGui")
		gui.Name = "WrenchUIGUI"
		gui.ResetOnSpawn = false
		gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		gui.Parent = localPlayer:WaitForChild("PlayerGui")
	end

	-- Close on overlay click (click outside panel)
	local overlay = Instance.new("Frame")
	overlay.Name = "WrenchOverlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.Position = UDim2.new(0, 0, 0, 0)
	overlay.BackgroundTransparency = 0.7
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BorderSizePixel = 0
	overlay.Active = true
	overlay.Selectable = false
	overlay.Parent = gui

	-- Close overlay on click
	overlay.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch then
			WrenchUI.Close()
		end
	end)

	-- Main panel frame
	panel = Instance.new("Frame")
	panel.Name = "WrenchPanel"
	panel.Size = UDim2.new(0, PANEL_WIDTH, 0, PANEL_HEIGHT)
	panel.BackgroundColor3 = BG_COLOR
	panel.BorderSizePixel = 1
	panel.BorderColor3 = BORDER_COLOR
	panel.Active = true
	panel.Selectable = true
	panel.Parent = gui

	-- Close button (X)
	local closeBtn = Instance.new("ImageButton")
	closeBtn.Name = "CloseButton"
	closeBtn.Size = UDim2.new(0, 20, 0, 20)
	closeBtn.Position = UDim2.new(1, -25, 0, 5)
	closeBtn.BackgroundTransparency = 1
	closeBtn.Image = "rbxasset://textures/ui/close.png"
	closeBtn.ImageColor3 = Color3.fromRGB(180, 180, 180)
	closeBtn.Parent = panel
	closeBtn.MouseButton1Click:Connect(function()
		WrenchUI.Close()
	end)

	-- Container for dynamic content (cleared and rebuilt on each open)
	local contentContainer = Instance.new("ScrollingFrame")
	contentContainer.Name = "ContentContainer"
	contentContainer.Size = UDim2.new(1, 0, 1, -30)
	contentContainer.Position = UDim2.new(0, 0, 0, 30)
	contentContainer.BackgroundTransparency = 1
	contentContainer.BorderSizePixel = 0
	contentContainer.ScrollBarThickness = 6
	contentContainer.ScrollBarImageColor3 = BORDER_COLOR
	contentContainer.CanvasSize = UDim2.new(0, 0, 0, 0)
	contentContainer.ClipsDescendants = true
	contentContainer.Parent = panel
end

--[[
	Populate the panel with current wrench data.
]]
local function populatePanel()
	if not panel then return end

	local container = panel:FindFirstChild("ContentContainer") :: ScrollingFrame?
	if not container then return end

	-- Clear existing content
	for _, child in ipairs(container:GetChildren()) do
		child:Destroy()
	end

	if not wrenchedData then return end

	local data = wrenchedData
	local currentY = 0

	--[[
		SECTION: Tile Info
	]]
	local titleLabel = createLabel("--- Tile Info ---", ACCENT_COLOR, 14)
	titleLabel.Position = UDim2.new(0, PADDING, 0, currentY)
	titleLabel.Parent = container
	currentY = currentY + ROW_HEIGHT

	-- Foreground block
	local fgInfo = `Foreground: {getItemDisplayName(data.fg)}`
	if data.hp and data.hp > 0 then
		local itemDef = data.fg and ItemDatabase.GetItem(data.fg)
		local maxHp = (itemDef and itemDef.hp) or "?"
		fgInfo = fgInfo .. `  |  HP: {data.hp}/{maxHp}`
	end
	local fgLabel = createLabel(fgInfo)
	fgLabel.Position = UDim2.new(0, PADDING + 8, 0, currentY)
	fgLabel.TextSize = 14
	fgLabel.Parent = container
	currentY = currentY + ROW_HEIGHT

	-- Foreground type
	local typeLabel = createLabel(`Type: {getItemTypeName(data.fg)}`)
	typeLabel.Position = UDim2.new(0, PADDING + 8, 0, currentY)
	typeLabel.TextSize = 14
	typeLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
	typeLabel.Parent = container
	currentY = currentY + ROW_HEIGHT

	-- Background block
	local bgLabel = createLabel(`Background: {getItemDisplayName(data.bg)}`)
	bgLabel.Position = UDim2.new(0, PADDING + 8, 0, currentY)
	bgLabel.TextSize = 14
	bgLabel.Parent = container
	currentY = currentY + ROW_HEIGHT

	--[[
		SECTION: Tree Info
	]]
	if data.treeInfo then
		local sepLabel = createLabel("--- Tree Growth ---", ACCENT_COLOR, 14)
		sepLabel.Position = UDim2.new(0, PADDING, 0, currentY)
		sepLabel.Parent = container
		currentY = currentY + ROW_HEIGHT

		local seedItem = ItemDatabase.GetItem(data.treeInfo.seedId)
		local seedName = seedItem and seedItem.name or ("Seed #" .. data.treeInfo.seedId)
		local growthLabel = createLabel(`Seed: {seedName} | {data.treeInfo.growthPercent}% grown`)
		growthLabel.Position = UDim2.new(0, PADDING + 8, 0, currentY)
		growthLabel.TextSize = 14
		growthLabel.Parent = container
		currentY = currentY + ROW_HEIGHT

		-- Progress bar
		local progressBg = Instance.new("Frame")
		progressBg.Name = "ProgressBg"
		progressBg.Size = UDim2.new(1, -PADDING * 2 - 16, 0, 8)
		progressBg.Position = UDim2.new(0, PADDING + 8, 0, currentY)
		progressBg.BackgroundColor3 = Color3.fromRGB(40, 40, 45)
		progressBg.BorderSizePixel = 0
		progressBg.Parent = container

		local progressFill = Instance.new("Frame")
		progressFill.Name = "ProgressFill"
		progressFill.Size = UDim2.new(data.treeInfo.growthPercent / 100, 0, 1, 0)
		progressFill.BackgroundColor3 = Color3.fromRGB(100, 220, 100)
		progressFill.BorderSizePixel = 0
		progressFill.Parent = progressBg

		currentY = currentY + 14
	end

	--[[
		SECTION: Door Management
	]]
	if data.isDoor then
		local sepLabel = createLabel("--- Door Settings ---", ACCENT_COLOR, 14)
		sepLabel.Position = UDim2.new(0, PADDING, 0, currentY)
		sepLabel.Parent = container
		currentY = currentY + ROW_HEIGHT

		if data.isMainDoor then
			-- Main Door is always locked to START
			local mainDoorLabel = createLabel("Main Door → Always goes to START", Color3.fromRGB(255, 200, 100), 14)
			mainDoorLabel.Position = UDim2.new(0, PADDING + 8, 0, currentY)
			mainDoorLabel.Parent = container
			currentY = currentY + ROW_HEIGHT
		else
			-- Current destination
			local destLabel = createLabel(`Destination: {data.doorDestination or "Not set (default: START)"}`, nil, 14)
			destLabel.Position = UDim2.new(0, PADDING + 8, 0, currentY)
			destLabel.Parent = container
			currentY = currentY + ROW_HEIGHT

			-- Only show edit controls if player is world owner
			if data.lockInfo and data.lockInfo.isOwner then
				-- Text input row
				local inputRow = Instance.new("Frame")
				inputRow.Name = "DoorInputRow"
				inputRow.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
				inputRow.Position = UDim2.new(0, 0, 0, currentY)
				inputRow.BackgroundTransparency = 1
				inputRow.Parent = container

				local destInput = createTextBox("World name (e.g. MYWORLD)")
				destInput.Parent = inputRow

				local confirmBtn = createButton("Set", SUCCESS_COLOR)
				confirmBtn.Position = UDim2.new(1, -85, 0, 0)
				confirmBtn.Parent = inputRow

				-- Button hover effects
				confirmBtn.MouseEnter:Connect(function()
					confirmBtn.BackgroundColor3 = Color3.fromRGB(120, 220, 120)
				end)
				confirmBtn.MouseLeave:Connect(function()
					confirmBtn.BackgroundColor3 = SUCCESS_COLOR
				end)

				confirmBtn.MouseButton1Click:Connect(function()
					local dest = string.upper(string.gsub(destInput.Text, "[^%w_]", ""))
					if #dest == 0 then
						warn("[WrenchUI] Invalid destination world name")
						return
					end
					if #dest > 20 then
						dest = string.sub(dest, 1, 20)
					end
					RemoteEvents.RequestSetDoorDestination:FireServer(data.tileX, data.tileY, dest)
					WrenchUI.Close()
				end)

				currentY = currentY + ROW_HEIGHT + 4
			end
		end
	end

	--[[
		SECTION: Lock / Admin Management
	]]
	if data.lockInfo and data.lockInfo.isLocked then
		local sepLabel = createLabel("--- World Lock ---", ACCENT_COLOR, 14)
		sepLabel.Position = UDim2.new(0, PADDING, 0, currentY)
		sepLabel.Parent = container
		currentY = currentY + ROW_HEIGHT

		local ownerLabel = createLabel(`Owner: User #{data.lockInfo.ownerUserId}`, nil, 14)
		ownerLabel.Position = UDim2.new(0, PADDING + 8, 0, currentY)
		ownerLabel.Parent = container
		currentY = currentY + ROW_HEIGHT

		if data.lockInfo.isOwner then
			-- Admin list
			local adminListLabel = createLabel("Admins:", nil, 14)
			adminListLabel.Position = UDim2.new(0, PADDING + 8, 0, currentY)
			adminListLabel.Parent = container
			currentY = currentY + ROW_HEIGHT

			if data.lockInfo.admins and #data.lockInfo.admins > 0 then
				for _, adminId in ipairs(data.lockInfo.admins) do
					local adminRow = Instance.new("Frame")
					adminRow.Name = "AdminRow"
					adminRow.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
					adminRow.Position = UDim2.new(0, 0, 0, currentY)
					adminRow.BackgroundTransparency = 1
					adminRow.Parent = container

					local adminLabel = createLabel(`  • User #{adminId}`, nil, 14)
					adminLabel.Size = UDim2.new(1, -90, 0, ROW_HEIGHT)
					adminLabel.Parent = adminRow

					local removeBtn = createButton("Remove", ERROR_COLOR)
					removeBtn.Position = UDim2.new(1, -85, 0, 0)
					removeBtn.Size = UDim2.new(0, 75, 0, ROW_HEIGHT - 2)
					removeBtn.Parent = adminRow

					removeBtn.MouseEnter:Connect(function()
						removeBtn.BackgroundColor3 = Color3.fromRGB(255, 120, 120)
					end)
					removeBtn.MouseLeave:Connect(function()
						removeBtn.BackgroundColor3 = ERROR_COLOR
					end)

					removeBtn.MouseButton1Click:Connect(function()
						RemoteEvents.RequestRemoveAdmin:FireServer(adminId)
						WrenchUI.Close()
					end)

					currentY = currentY + ROW_HEIGHT
				end
			else
				local noAdminsLabel = createLabel("  No admins", Color3.fromRGB(150, 150, 150), 14)
				noAdminsLabel.Position = UDim2.new(0, PADDING + 8, 0, currentY)
				noAdminsLabel.Parent = container
				currentY = currentY + ROW_HEIGHT
			end

			-- Add admin row
			local addRow = Instance.new("Frame")
			addRow.Name = "AddAdminRow"
			addRow.Size = UDim2.new(1, 0, 0, ROW_HEIGHT)
			addRow.Position = UDim2.new(0, 0, 0, currentY)
			addRow.BackgroundTransparency = 1
			addRow.Parent = container

			local addInput = createTextBox("User ID to add")
			addInput.Parent = addRow

			local addBtn = createButton("Add", ACCENT_COLOR)
			addBtn.Position = UDim2.new(1, -85, 0, 0)
			addBtn.Parent = addRow

			addBtn.MouseEnter:Connect(function()
				addBtn.BackgroundColor3 = Color3.fromRGB(120, 200, 255)
			end)
			addBtn.MouseLeave:Connect(function()
				addBtn.BackgroundColor3 = ACCENT_COLOR
			end)

			addBtn.MouseButton1Click:Connect(function()
				local targetId = tonumber(addInput.Text)
				if targetId and targetId > 0 then
					RemoteEvents.RequestAddAdmin:FireServer(targetId)
					WrenchUI.Close()
				end
			end)

			currentY = currentY + ROW_HEIGHT + 4
		else
			local notOwnerLabel = createLabel("You are not the world owner", Color3.fromRGB(200, 200, 100), 14)
			notOwnerLabel.Position = UDim2.new(0, PADDING + 8, 0, currentY)
			notOwnerLabel.Parent = container
			currentY = currentY + ROW_HEIGHT
		end
	end

	-- Update canvas size
	container.CanvasSize = UDim2.new(0, 0, 0, currentY + 10)

	-- Update panel height to fit content (capped at 500)
	local newHeight = math.min(currentY + 40, 500)
	panel.Size = UDim2.new(0, PANEL_WIDTH, 0, newHeight)
end

--[[
	Position the panel near the wrenched tile on screen.
]]
local function positionPanel()
	if not panel then return end

	-- Get camera position in world studs
	local camera = Workspace.CurrentCamera
	if not camera then return end
	local camPos = camera.CFrame.Position
	local camOffX = camPos.X
	local camOffY = camPos.Y

	-- Convert tile coordinates to world studs, then to screen pixel offset
	local TILE_SIZE = WorldConfig.TILE_SIZE or 32

	local screenX = wrenchedTileX * TILE_SIZE - camOffX
	local screenY = wrenchedTileY * TILE_SIZE - camOffY

	-- Position panel to the right of the tile (or left if near edge)
	local viewportSize = panel.Parent and (panel.Parent :: ScreenGui).AbsoluteSize or Vector2.new(1920, 1080)
	local panelX = screenX + TILE_SIZE + 8
	if panelX + PANEL_WIDTH > viewportSize.X then
		panelX = screenX - PANEL_WIDTH - 8
	end
	if panelX < 4 then panelX = 4 end

	local panelY = screenY
	if panelY + panel.AbsoluteSize.Y > viewportSize.Y then
		panelY = viewportSize.Y - panel.AbsoluteSize.Y - 4
	end
	if panelY < 4 then panelY = 4 end

	panel.Position = UDim2.new(0, panelX, 0, panelY)
end

--[[
	===== PUBLIC API =====
]]

--[[
	Open the WrenchUI with data from a wrenched tile.
	@param data: table — WrenchData table from server
]]
function WrenchUI.Open(data: table)
	if not data then return end

	-- Store data
	wrenchedData = data
	wrenchedTileX = data.tileX
	wrenchedTileY = data.tileY

	-- Build GUI if not created yet
	if not gui or not panel then
		buildPanel()
	end

	-- Repopulate panel with current data
	populatePanel()

	-- Position panel near the wrenched tile
	positionPanel()

	-- Show GUI
	gui.Enabled = true
	isOpen = true

	-- Print for debug
	print(`[WrenchUI] Opened — tile ({data.tileX},{data.tileY}) fg={data.fg}`)
end

--[[
	Close the WrenchUI panel.
]]
function WrenchUI.Close()
	if gui then
		gui.Enabled = false
	end
	isOpen = false
	wrenchedData = nil
	wrenchedTileX = -1
	wrenchedTileY = -1
end

--[[
	Check if the wrench UI is currently open.
	@return boolean
]]
function WrenchUI.IsOpen(): boolean
	return isOpen
end

--[[
	Update player position for auto-close tracking.
	Called from RenderStepped.
	@param tileX: number
	@param tileY: number
]]
function WrenchUI.UpdatePlayerPosition(tileX: number, tileY: number)
	if not isOpen then return end
	if wrenchedTileX < 0 or wrenchedTileY < 0 then return end

	local dist = math.max(math.abs(tileX - wrenchedTileX), math.abs(tileY - wrenchedTileY))
	if dist > CLOSE_DISTANCE then
		WrenchUI.Close()
	end
end

--[[
	Initialize WrenchUI.
	Listens for WrenchData from server and E key to close.
]]
function WrenchUI.Init()
	worldRenderer = require(script.Parent.Parent.WorldRenderer)
	-- PlayerController was deleted in architecture correction; use InputController instead
	-- playerController = require(script.Parent.PlayerController)

	-- Create GUI hidden initially
	buildPanel()
	gui.Enabled = false

	-- Listen for WrenchData from server
	RemoteEvents.WrenchData.OnClientEvent:Connect(function(data: table)
		-- Toggle: if already open and same tile, close it
		if isOpen and wrenchedTileX == data.tileX and wrenchedTileY == data.tileY then
			WrenchUI.Close()
			return
		end
		WrenchUI.Open(data)
	end)

	-- Listen for E key to close if wrench UI is open
	UserInputService.InputBegan:Connect(function(inputObject: InputObject, isProcessed: boolean)
		if isProcessed then return end
		if inputObject.UserInputType == Enum.UserInputType.Keyboard
			and inputObject.KeyCode == Enum.KeyCode.E then
			if isOpen then
				WrenchUI.Close()
			end
		end
	end)

	-- Track player position every frame for auto-close
	RunService.RenderStepped:Connect(function()
		if isOpen and worldRenderer then
			local px, py = worldRenderer.GetPlayerTile()
			WrenchUI.UpdatePlayerPosition(px, py)
		end
	end)

	print("[WrenchUI] Initialized")
end

--[[
	Clean up resources.
]]
function WrenchUI.Destroy()
	if gui then
		gui:Destroy()
		gui = nil
	end
	panel = nil
	isOpen = false
	wrenchedData = nil
	print("[WrenchUI] Destroyed")
end

return WrenchUI
