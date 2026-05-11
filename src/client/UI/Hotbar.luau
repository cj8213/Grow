-- Hotbar.luau (client)
-- 32-slot unified inventory: quick-access slots (1-4) + ScrollingFrame backpack (5-32).
-- UI is pre-built in StarterGui (Hotbar ScreenGui) — placed via Studio MCP, not Rojo.
-- SlotTemplate is in ReplicatedStorage — placed via Studio MCP, not Rojo.
-- Drag PullHandle to reveal/hide the ScrollingFrame inventory.
-- Selection highlights via UIStroke color (Black → Yellow).

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage.Shared)
local ItemDatabase = Shared.ItemDatabase
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)

local Hotbar = {}

--[[
	===== CONSTANTS =====
]]
local HOTBAR_SLOTS = 4          -- Quick-access slots in the Slots container
local BACKPACK_SLOTS = 28       -- Slots 5-32 in the ScrollingFrame
local TOTAL_SLOTS = 32

local CLICK_THRESHOLD = 5       -- Pixels of drag before it's no longer a click

-- Colors
local HIGHLIGHT_COLOR = Color3.fromRGB(255, 255, 0)
local DEFAULT_STROKE_COLOR = Color3.fromRGB(0, 0, 0)
local EMPTY_COLOR = Color3.fromRGB(100, 100, 100)

--[[
	===== STATE =====
]]
local screenGui: ScreenGui? = nil
local hotbarZone: Frame? = nil
local pullHandle: TextButton? = nil
local slotsContainer: Frame? = nil
local scrollingFrame: ScrollingFrame? = nil
local slotTemplate: Frame? = nil

-- All slot instances indexed 1..TOTAL_SLOTS
local slotInstances: { Frame? } = {}
local slotData: { { itemId: number, count: number }? } = {}

local selectedSlot = 1
local isExpanded = false
local currentSelectedSlotObj: Frame? = nil
local remoteConnections: { RBXScriptConnection } = {}

-- Drag state
local dragging = false
local isClick = false
local dragStartMouseY = 0
local dragStartFrameY = 0

-- Position limits (calculated on Init)
local closedY = 0
local openY = 0

-- Tooltip instance (for hover item names)
local tooltipLabel: TextLabel? = nil

--[[
	===== SLOT CREATION =====
]]

local function createSlot(index: number, parent: Instance): Frame
	local slot = slotTemplate:Clone()
	slot.Name = "Slot" .. index
	slot.Parent = parent

	-- Ensure default stroke is Black
	local stroke = slot:FindFirstChild("UIStroke")
	if stroke then
		stroke.Color = DEFAULT_STROKE_COLOR
	end

	-- Find ImageButton for input and item color display
	local btn = slot:FindFirstChild("ImageButton") :: ImageButton?
	if btn then
		btn.Name = "SlotBtn"
		-- Background shows the item color directly
		btn.BackgroundColor3 = EMPTY_COLOR
		btn.BackgroundTransparency = 0
		btn.BorderSizePixel = 0
		btn.ImageTransparency = 1  -- Hide any default image; we use background color

		-- Hover tooltip: show item name on mouse enter
		btn.MouseEnter:Connect(function()
			if not tooltipLabel then return end
			local data = slotData[index]
			if data and data.itemId and data.itemId > 0 then
				local item = ItemDatabase.GetItem(data.itemId)
				if item and item.name then
					tooltipLabel.Text = item.name
					tooltipLabel.Visible = true
					-- Position tooltip above the slot
					local absPos = btn.AbsolutePosition
					tooltipLabel.Position = UDim2.new(0, absPos.X - screenGui.AbsolutePosition.X + 5, 0, absPos.Y - screenGui.AbsolutePosition.Y - 24)
				end
			end
		end)

		btn.MouseLeave:Connect(function()
			if tooltipLabel then
				tooltipLabel.Visible = false
			end
		end)

		-- Add count label (overlaid on the button)
		local countLabel = Instance.new("TextLabel")
		countLabel.Name = "Count"
		countLabel.Size = UDim2.new(0, 36, 0, 14)
		countLabel.Position = UDim2.new(1, -38, 1, -16)
		countLabel.BackgroundTransparency = 1
		countLabel.Text = ""
		countLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
		countLabel.TextSize = 12
		countLabel.Font = Enum.Font.SourceSansBold
		countLabel.TextXAlignment = Enum.TextXAlignment.Right
		countLabel.ZIndex = 2
		countLabel.Parent = btn

		-- Click to select (hotbar) or swap (backpack)
		btn.MouseButton1Click:Connect(function()
			-- Click on hotbar slot (1-4): select it
			if index <= HOTBAR_SLOTS then
				-- Update selection visuals
				selectedSlot = index
				if currentSelectedSlotObj and currentSelectedSlotObj ~= slot then
					local oldStroke = currentSelectedSlotObj:FindFirstChild("UIStroke")
					if oldStroke then
						oldStroke.Color = DEFAULT_STROKE_COLOR
					end
				end
				local newStroke = slot:FindFirstChild("UIStroke")
				if newStroke then
					newStroke.Color = HIGHLIGHT_COLOR
				end
				currentSelectedSlotObj = slot

				-- CRITICAL: Update InputController's equipped slot so mouse clicks
				-- use the correct item. Without this, InputController stays on slot 1 (Fist).
				local InputController = require(script.Parent.Parent.InputController)
				InputController.SetEquippedSlot(index)
				if slotData[index] then
					InputController.SetEquippedItemId(slotData[index].itemId)
				end

				if RemoteEvents.RequestSetEquippedSlot then
					RemoteEvents.RequestSetEquippedSlot:FireServer(index)
				end
				return
			end

			-- Backpack slot (5-32): swap with selected hotbar slot
			-- Ensure we never swap into slots 1-2 (locked)
			local swapSlot = if selectedSlot <= 2 then 3 else selectedSlot
			RemoteEvents.RequestSwapSlots:FireServer(swapSlot, index)
		end)

		return slot
	end

	return slot
end

--[[
	===== SLOT RENDERING =====
]]

local function updateSlot(index: number)
	local slot = slotInstances[index]
	if not slot then return end

	local btn = slot:FindFirstChild("SlotBtn") :: ImageButton?
	local countLabel = btn and btn:FindFirstChild("Count") :: TextLabel?
	if not btn or not countLabel then return end

	local data = slotData[index]
	if data and data.itemId and data.itemId > 0 then
		local item = ItemDatabase.GetItem(data.itemId)
		local color = item and item.color or EMPTY_COLOR

		-- Image icon system: if item has an imageId, show the icon instead of background color
		if item and item.imageId and item.imageId ~= "" then
			btn.Image = "rbxassetid://" .. item.imageId
			btn.ImageTransparency = 0
			btn.BackgroundColor3 = color
			btn.BackgroundTransparency = 0
		else
			btn.ImageTransparency = 1
			btn.BackgroundColor3 = color
			btn.BackgroundTransparency = 0
		end

		if data.count > 1 then
			countLabel.Text = tostring(data.count)
			countLabel.Visible = true
		else
			countLabel.Text = ""
			countLabel.Visible = false
		end
	else
		btn.ImageTransparency = 1
		btn.BackgroundColor3 = EMPTY_COLOR
		btn.BackgroundTransparency = 0
		countLabel.Text = ""
		countLabel.Visible = false
	end
end

local function renderAllSlots()
	for i = 1, TOTAL_SLOTS do
		updateSlot(i)
	end
end

--[[
	===== INVENTORY LISTENER =====
]]

local function onInventoryUpdated(inventoryTable: { { itemId: number, count: number }? })
	-- Clear all slot data
	for i = 1, TOTAL_SLOTS do
		slotData[i] = nil
	end

	-- Copy from server inventory
	for i = 1, TOTAL_SLOTS do
		local invSlot = inventoryTable[i]
		if invSlot and invSlot.itemId and invSlot.itemId > 0 then
			slotData[i] = { itemId = invSlot.itemId, count = invSlot.count }
		end
	end

	renderAllSlots()
end

--[[
	===== DRAG / EXPAND LOGIC =====
]]

-- Snap to the nearest state with a tween
local function snapToNearestState()
	if not hotbarZone then return end

	local midPoint = (openY + closedY) / 2
	local targetY = if hotbarZone.Position.Y.Scale > midPoint then openY else closedY

	-- isExpanded = targetY equals openY
	isExpanded = (targetY == openY)

	local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(hotbarZone, tweenInfo, {
		Position = UDim2.new(hotbarZone.Position.X.Scale, hotbarZone.Position.X.Offset, targetY, 0)
	})
	tween:Play()
end

--[[
	Toggle between expanded and collapsed.
	This is the primary public API for external callers (InputController Tab key).
]]
function Hotbar.ToggleExpand()
	if not hotbarZone then return end

	isExpanded = not isExpanded
	local targetY = if isExpanded then openY else closedY

	local tweenInfo = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	local tween = TweenService:Create(hotbarZone, tweenInfo, {
		Position = UDim2.new(hotbarZone.Position.X.Scale, hotbarZone.Position.X.Offset, targetY, 0)
	})
	tween:Play()
end

--[[
	Check if the backpack is currently expanded.
]]
function Hotbar.IsExpanded(): boolean
	return isExpanded
end

--[[
	===== PUBLIC API =====
]]

function Hotbar.Init()
	local localPlayer = Players.LocalPlayer
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Poll for the Hotbar ScreenGui in PlayerGui (replicated from StarterGui)
	-- Use a polling loop with 10 second timeout to handle replication timing
	screenGui = nil
	for i = 1, 100 do
		screenGui = playerGui:FindFirstChild("Hotbar") :: ScreenGui?
		if screenGui then
			break
		end
		task.wait(0.1)
	end

	if not screenGui then
		warn("[Hotbar] ScreenGui 'Hotbar' not found in PlayerGui after 10s. Ensure it exists in StarterGui.")
		return
	end

	-- Object references
	hotbarZone = screenGui:FindFirstChild("HotbarZone") :: Frame?
	if not hotbarZone then
		warn("[Hotbar] 'HotbarZone' not found in Hotbar ScreenGui.")
		return
	end

	pullHandle = hotbarZone:FindFirstChild("PullHandle") :: TextButton?
	slotsContainer = hotbarZone:FindFirstChild("Slots") :: Frame?
	scrollingFrame = hotbarZone:FindFirstChild("ScrollingFrame") :: ScrollingFrame?

	-- Get SlotTemplate from ReplicatedStorage
	slotTemplate = ReplicatedStorage:FindFirstChild("SlotTemplate") :: Frame?
	if not slotTemplate then
		warn("[Hotbar] 'SlotTemplate' not found in ReplicatedStorage.")
		return
	end

	-- Create tooltip label (floating above slots)
	tooltipLabel = Instance.new("TextLabel")
	tooltipLabel.Name = "SlotTooltip"
	tooltipLabel.Size = UDim2.new(0, 150, 0, 22)
	tooltipLabel.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	tooltipLabel.BackgroundTransparency = 0.15
	tooltipLabel.BorderSizePixel = 0
	tooltipLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	tooltipLabel.TextSize = 14
	tooltipLabel.Font = Enum.Font.SourceSansBold
	tooltipLabel.TextXAlignment = Enum.TextXAlignment.Left
	tooltipLabel.Visible = false
	tooltipLabel.ZIndex = 10
	tooltipLabel.Parent = screenGui

	-- Wait one frame for the engine to render AbsoluteSize
	task.wait()

	-- Record the closed position (where the designer placed it in Studio)
	closedY = hotbarZone.Position.Y.Scale

	-- Open limit = closed position minus the height of the ScrollingFrame (as scale)
	local screenHeight = screenGui.AbsoluteSize.Y
	if screenHeight > 0 then
		openY = math.max(0, closedY - (scrollingFrame.AbsoluteSize.Y / screenHeight))
	else
		openY = math.max(0, closedY - 0.4)
	end

	-- Ensure scrolling frame is visible
	if scrollingFrame then
		scrollingFrame.Visible = true
	end

	-- Clone 4 hotbar slots into the Slots container
	if slotsContainer then
		for i = 1, HOTBAR_SLOTS do
			local slot = createSlot(i, slotsContainer)
			slotInstances[i] = slot
		end
	end

	-- Create backpack slots (5-32) in the ScrollingFrame
	if scrollingFrame then
		for i = HOTBAR_SLOTS + 1, TOTAL_SLOTS do
			local slot = createSlot(i, scrollingFrame)
			slotInstances[i] = slot
		end
	end

	-- Default selection: slot 1
	local firstSlot = slotInstances[1]
	if firstSlot then
		local stroke = firstSlot:FindFirstChild("UIStroke")
		if stroke then
			stroke.Color = HIGHLIGHT_COLOR
		end
		currentSelectedSlotObj = firstSlot
	end

	-- ── Drag mechanic ──
	if pullHandle then
		pullHandle.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton1
				or input.UserInputType == Enum.UserInputType.Touch then
				dragging = true
				isClick = true
				dragStartMouseY = input.Position.Y
				dragStartFrameY = hotbarZone.Position.Y.Scale
			end
		end)
	end

	UserInputService.InputChanged:Connect(function(input)
		if not dragging then return end
		if input.UserInputType ~= Enum.UserInputType.MouseMovement
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		local deltaY = input.Position.Y - dragStartMouseY

		if math.abs(deltaY) > CLICK_THRESHOLD then
			isClick = false
		end

		local screenHeight = screenGui and screenGui.AbsoluteSize.Y or 600
		local deltaScale = deltaY / screenHeight
		local newY = math.clamp(dragStartFrameY + deltaScale, openY, closedY)

		hotbarZone.Position = UDim2.new(
			hotbarZone.Position.X.Scale,
			hotbarZone.Position.X.Offset,
			newY,
			0
		)
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.MouseButton1
			and input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end

		if not dragging then return end
		dragging = false

		if isClick then
			-- Click toggles: if currently more open than closed, close; otherwise open
			local midPoint = (openY + closedY) / 2
			local targetY = if hotbarZone.Position.Y.Scale > midPoint then openY else closedY
			isExpanded = (targetY == openY)

			local tweenInfo = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
			local tween = TweenService:Create(hotbarZone, tweenInfo, {
				Position = UDim2.new(hotbarZone.Position.X.Scale, hotbarZone.Position.X.Offset, targetY, 0)
			})
			tween:Play()
		else
			-- Dragged: keep the position exactly where the player left it, no snap
			local currentY = hotbarZone.Position.Y.Scale
			isExpanded = (currentY < (openY + closedY) / 2)
		end
	end)

	-- ── Listen for inventory updates ──
	local conn = RemoteEvents.InventoryUpdated.OnClientEvent:Connect(onInventoryUpdated)
	table.insert(remoteConnections, conn)

	-- Initial render
	renderAllSlots()

	-- CRITICAL: Proactively fetch the current inventory from the server.
	-- The Hotbar init polling loop (up to 10s for ScreenGui) means we may have
	-- missed the initial InventoryUpdated events that the server sent during boot.
	-- GetInventory is a RemoteFunction that returns the current state on demand.
	local invSuccess, invResult = pcall(function()
		return RemoteEvents.GetInventory:InvokeServer()
	end)
	if invSuccess and invResult then
		onInventoryUpdated(invResult)
	end

	print("[Hotbar] Initialized (4-slot hotbar + ScrollingFrame backpack)")
end

function Hotbar.SetSelectedSlot(slotIndex: number)
	slotIndex = math.clamp(slotIndex, 1, TOTAL_SLOTS)
	selectedSlot = slotIndex

	-- Update selection visuals via UIStroke
	local slot = slotInstances[slotIndex]
	if not slot then return end

	if currentSelectedSlotObj and currentSelectedSlotObj ~= slot then
		local oldStroke = currentSelectedSlotObj:FindFirstChild("UIStroke")
		if oldStroke then
			oldStroke.Color = DEFAULT_STROKE_COLOR
		end
	end

	local newStroke = slot:FindFirstChild("UIStroke")
	if newStroke then
		newStroke.Color = HIGHLIGHT_COLOR
	end
	currentSelectedSlotObj = slot
end

function Hotbar.UpdateSlot(slotIndex: number, itemId: number, count: number)
	if slotIndex < 1 or slotIndex > TOTAL_SLOTS then return end

	if itemId and itemId > 0 then
		slotData[slotIndex] = { itemId = itemId, count = count }
	else
		slotData[slotIndex] = nil
	end

	updateSlot(slotIndex)
end

function Hotbar.UpdateInventory(inventoryTable: { { itemId: number, count: number }? })
	onInventoryUpdated(inventoryTable)
end

function Hotbar.GetSelectedSlot(): number
	return selectedSlot
end

function Hotbar.GetSlotData(slotIndex: number): { itemId: number, count: number }?
	return slotData[slotIndex]
end

function Hotbar.SetItemIcon(itemId: number, imageId: string)
	-- Update imageId in ItemDatabase cache and re-render all slots showing that item
	if not itemId or itemId <= 0 then return end
	local item = ItemDatabase.GetItem(itemId)
	if item then
		item.imageId = imageId or ""
	end
	-- Re-render all slots that show this item
	for i = 1, TOTAL_SLOTS do
		local data = slotData[i]
		if data and data.itemId == itemId then
			updateSlot(i)
		end
	end
end

function Hotbar.Destroy()
	for _, conn in ipairs(remoteConnections) do
		conn:Disconnect()
	end
	remoteConnections = {}

	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end

	slotInstances = {}
	slotData = {}
	currentSelectedSlotObj = nil
	print("[Hotbar] Destroyed")
end

return Hotbar
