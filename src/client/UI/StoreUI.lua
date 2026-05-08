--!strict
-- StoreUI.lua (client)
-- In-game store: press B or click store button to open
-- Shows catalog from GetCatalog RemoteFunction, lets player buy items with gems
-- Shows gem balance at top, quantity selector on buy, success/fail feedback

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage.Shared)
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
local ItemDatabase = Shared.ItemDatabase

local StoreUI = {}

--[[
	===== CONSTANTS =====
]]

local PANEL_WIDTH = 500
local PANEL_HEIGHT = 400
local TILE_SIZE = 32
local ITEM_ROW_HEIGHT = 48
local BUY_COOLDOWN = 1.0 -- seconds between purchases

--[[
	===== STATE =====
]]

local localPlayer = Players.LocalPlayer
local screenGui: ScreenGui? = nil
local panel: Frame? = nil
local itemList: ScrollingFrame? = nil
local gemBalanceLabel: TextLabel? = nil
local isOpen = false

-- Catalog cache (fetched once on open)
local catalog: { { itemId: number, name: string, price: number, description: string, color: Color3?, isSeed: boolean?, parentBlockName: string? } } = {}

-- Quantity picker state (non-persistent, reset each purchase)
local quantityPicker: Frame? = nil
local quantityValue: number = 1
local quantityLabel: TextLabel? = nil
local pendingItemId: number? = nil
local lastBuyTime = 0

--[[
	===== UI CREATION =====
]]

local function createPanel()
	if not screenGui then return end

	-- Dark overlay (click to close)
	local overlay = Instance.new("Frame")
	overlay.Name = "StoreOverlay"
	overlay.Size = UDim2.new(1, 0, 1, 0)
	overlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	overlay.BackgroundTransparency = 0.6
	overlay.BorderSizePixel = 0
	overlay.ZIndex = 50
	overlay.Parent = screenGui

	-- Main panel frame
	panel = Instance.new("Frame")
	panel.Name = "StorePanel"
	panel.Size = UDim2.new(0, PANEL_WIDTH, 0, PANEL_HEIGHT)
	panel.Position = UDim2.new(0.5, -PANEL_WIDTH / 2, 0.5, -PANEL_HEIGHT / 2)
	panel.BackgroundColor3 = Color3.fromRGB(20, 20, 30)
	panel.BackgroundTransparency = 0.1
	panel.BorderSizePixel = 0
	panel.ZIndex = 51
	panel.Parent = screenGui

	-- Title bar
	local titleBar = Instance.new("Frame")
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, 32)
	titleBar.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
	titleBar.BorderSizePixel = 0
	titleBar.ZIndex = 52
	titleBar.Parent = panel

	local titleLabel = Instance.new("TextLabel")
	titleLabel.Name = "Title"
	titleLabel.Size = UDim2.new(1, -40, 1, 0)
	titleLabel.Position = UDim2.new(0, 10, 0, 0)
	titleLabel.BackgroundTransparency = 1
	titleLabel.Text = "✦ STORE ✦"
	titleLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
	titleLabel.TextSize = 18
	titleLabel.Font = Enum.Font.SourceSansBold
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.TextYAlignment = Enum.TextYAlignment.Center
	titleLabel.ZIndex = 53
	titleLabel.Parent = titleBar

	-- Close button
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.Size = UDim2.new(0, 28, 0, 28)
	closeBtn.Position = UDim2.new(1, -32, 0, 2)
	closeBtn.BackgroundColor3 = Color3.fromRGB(80, 30, 30)
	closeBtn.BorderSizePixel = 0
	closeBtn.Text = "✕"
	closeBtn.TextColor3 = Color3.fromRGB(255, 200, 200)
	closeBtn.TextSize = 16
	closeBtn.Font = Enum.Font.SourceSansBold
	closeBtn.ZIndex = 53
	closeBtn.Parent = titleBar
	closeBtn.MouseButton1Click:Connect(function()
		StoreUI.Close()
	end)

	-- Gem balance display (top of panel, below title)
	gemBalanceLabel = Instance.new("TextLabel")
	gemBalanceLabel.Name = "GemBalance"
	gemBalanceLabel.Size = UDim2.new(1, -20, 0, 24)
	gemBalanceLabel.Position = UDim2.new(0, 10, 0, 36)
	gemBalanceLabel.BackgroundTransparency = 0.5
	gemBalanceLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	gemBalanceLabel.Text = "◆ Loading..."
	gemBalanceLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
	gemBalanceLabel.TextSize = 16
	gemBalanceLabel.Font = Enum.Font.SourceSansBold
	gemBalanceLabel.TextXAlignment = Enum.TextXAlignment.Center
	gemBalanceLabel.ZIndex = 52
	gemBalanceLabel.Parent = panel

	-- Item list (scrollable)
	itemList = Instance.new("ScrollingFrame")
	itemList.Name = "ItemList"
	itemList.Size = UDim2.new(1, -10, 1, -70)
	itemList.Position = UDim2.new(0, 5, 0, 65)
	itemList.BackgroundTransparency = 1
	itemList.BorderSizePixel = 0
	itemList.ScrollBarThickness = 8
	itemList.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 100)
	itemList.ZIndex = 52
	itemList.CanvasSize = UDim2.new(0, 0, 0, 0)
	itemList.Parent = panel

	-- Quantity picker frame (hidden initially)
	quantityPicker = Instance.new("Frame")
	quantityPicker.Name = "QuantityPicker"
	quantityPicker.Size = UDim2.new(0, 200, 0, 60)
	quantityPicker.Position = UDim2.new(0.5, -100, 0.5, -30)
	quantityPicker.BackgroundColor3 = Color3.fromRGB(30, 30, 45)
	quantityPicker.BorderSizePixel = 0
	quantityPicker.ZIndex = 60
	quantityPicker.Visible = false
	quantityPicker.Parent = screenGui

	-- Quantity picker background (modal overlay)
	local qtyOverlay = Instance.new("Frame")
	qtyOverlay.Name = "QtyOverlay"
	qtyOverlay.Size = UDim2.new(0, 200, 0, 60)
	qtyOverlay.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	qtyOverlay.BackgroundTransparency = 0.5
	qtyOverlay.BorderSizePixel = 0
	qtyOverlay.ZIndex = 61
	qtyOverlay.Parent = quantityPicker

	-- Quantity controls
	local minusBtn = Instance.new("TextButton")
	minusBtn.Name = "Minus"
	minusBtn.Size = UDim2.new(0, 30, 0, 30)
	minusBtn.Position = UDim2.new(0, 10, 0, 15)
	minusBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
	minusBtn.BorderSizePixel = 0
	minusBtn.Text = "-"
	minusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	minusBtn.TextSize = 20
	minusBtn.Font = Enum.Font.SourceSansBold
	minusBtn.ZIndex = 62
	minusBtn.Parent = quantityPicker
	minusBtn.MouseButton1Click:Connect(function()
		if quantityValue > 1 then
			quantityValue -= 1
			if quantityLabel then
				quantityLabel.Text = tostring(quantityValue)
			end
		end
	end)

	quantityLabel = Instance.new("TextLabel")
	quantityLabel.Name = "Quantity"
	quantityLabel.Size = UDim2.new(0, 60, 0, 30)
	quantityLabel.Position = UDim2.new(0, 50, 0, 15)
	quantityLabel.BackgroundTransparency = 0.5
	quantityLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	quantityLabel.Text = "1"
	quantityLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	quantityLabel.TextSize = 20
	quantityLabel.Font = Enum.Font.SourceSansBold
	quantityLabel.TextXAlignment = Enum.TextXAlignment.Center
	quantityLabel.TextYAlignment = Enum.TextYAlignment.Center
	quantityLabel.ZIndex = 62
	quantityLabel.Parent = quantityPicker

	local plusBtn = Instance.new("TextButton")
	plusBtn.Name = "Plus"
	plusBtn.Size = UDim2.new(0, 30, 0, 30)
	plusBtn.Position = UDim2.new(0, 120, 0, 15)
	plusBtn.BackgroundColor3 = Color3.fromRGB(50, 50, 70)
	plusBtn.BorderSizePixel = 0
	plusBtn.Text = "+"
	plusBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	plusBtn.TextSize = 20
	plusBtn.Font = Enum.Font.SourceSansBold
	plusBtn.ZIndex = 62
	plusBtn.Parent = quantityPicker
	plusBtn.MouseButton1Click:Connect(function()
		if quantityValue < 99 then
			quantityValue += 1
			if quantityLabel then
				quantityLabel.Text = tostring(quantityValue)
			end
		end
	end)

	local confirmQtyBtn = Instance.new("TextButton")
	confirmQtyBtn.Name = "Confirm"
	confirmQtyBtn.Size = UDim2.new(0, 120, 0, 26)
	confirmQtyBtn.Position = UDim2.new(0, 40, 0, 50)
	confirmQtyBtn.BackgroundColor3 = Color3.fromRGB(30, 80, 30)
	confirmQtyBtn.BorderSizePixel = 0
	confirmQtyBtn.Text = "BUY"
	confirmQtyBtn.TextColor3 = Color3.fromRGB(200, 255, 200)
	confirmQtyBtn.TextSize = 14
	confirmQtyBtn.Font = Enum.Font.SourceSansBold
	confirmQtyBtn.ZIndex = 62
	confirmQtyBtn.Parent = quantityPicker
	confirmQtyBtn.MouseButton1Click:Connect(function()
		if pendingItemId then
			StoreUI.BuyItem(pendingItemId, quantityValue)
			pendingItemId = nil
		end
		if quantityPicker then
			quantityPicker.Visible = false
		end
	end)

	-- Update gem balance when GemsUpdated fires
	RemoteEvents.GemsUpdated.OnClientEvent:Connect(function(gemCount: number)
		if gemBalanceLabel then
			gemBalanceLabel.Text = `◆ {gemCount}`
		end
	end)

	-- Listen for StoreResult
	RemoteEvents.StoreResult.OnClientEvent:Connect(function(success: boolean, message: string)
		if success then
			-- Green flash notification on the panel
			StoreUI._flashFeedback(true, message)
		else
			-- Red shake notification
			StoreUI._flashFeedback(false, message)
		end
	end)

	-- Clicking overlay closes panel
	overlay.MouseButton1Click:Connect(function()
		StoreUI.Close()
	end)
end

--[[
	Create a row in the item list for a catalog entry.
]]

local function createItemRow(entry: { itemId: number, name: string, price: number, description: string, color: Color3?, isSeed: boolean?, parentBlockName: string? })
	if not itemList then return end

	local rowHeight = ITEM_ROW_HEIGHT
	local row = Instance.new("Frame")
	row.Name = "ItemRow_" .. entry.itemId
	row.Size = UDim2.new(1, -10, 0, rowHeight)
	row.BackgroundColor3 = Color3.fromRGB(30, 30, 42)
	row.BackgroundTransparency = 0.3
	row.BorderSizePixel = 0
	row.ZIndex = 53
	row.Parent = itemList

	-- Item color square
	local colorSquare = Instance.new("Frame")
	colorSquare.Name = "ColorSquare"
	colorSquare.Size = UDim2.new(0, TILE_SIZE, 0, TILE_SIZE)
	colorSquare.Position = UDim2.new(0, 6, 0.5, -TILE_SIZE / 2)
	colorSquare.BackgroundColor3 = entry.color or Color3.fromRGB(150, 150, 150)
	colorSquare.BorderSizePixel = 1
	colorSquare.BorderColor3 = Color3.fromRGB(60, 60, 80)
	colorSquare.ZIndex = 54
	colorSquare.Parent = row

	-- Item name + description
	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name = "ItemName"
	nameLabel.Size = UDim2.new(0, 250, 0, 18)
	nameLabel.Position = UDim2.new(0, 46, 0, 4)
	nameLabel.BackgroundTransparency = 1
	nameLabel.Text = entry.name
	nameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	nameLabel.TextSize = 14
	nameLabel.Font = Enum.Font.SourceSansBold
	nameLabel.TextXAlignment = Enum.TextXAlignment.Left
	nameLabel.ZIndex = 54
	nameLabel.Parent = row

	local descLabel = Instance.new("TextLabel")
	descLabel.Name = "ItemDesc"
	descLabel.Size = UDim2.new(0, 250, 0, 16)
	descLabel.Position = UDim2.new(0, 46, 0, 22)
	descLabel.BackgroundTransparency = 1
	descLabel.Text = entry.description
	descLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
	descLabel.TextSize = 11
	descLabel.Font = Enum.Font.SourceSans
	descLabel.TextXAlignment = Enum.TextXAlignment.Left
	descLabel.ZIndex = 54
	descLabel.Parent = row

	-- Price label
	local priceLabel = Instance.new("TextLabel")
	priceLabel.Name = "Price"
	priceLabel.Size = UDim2.new(0, 80, 0, 18)
	priceLabel.Position = UDim2.new(0, 310, 0, 6)
	priceLabel.BackgroundTransparency = 1
	priceLabel.Text = `◆ {entry.price}`
	priceLabel.TextColor3 = Color3.fromRGB(255, 215, 0)
	priceLabel.TextSize = 14
	priceLabel.Font = Enum.Font.SourceSansBold
	priceLabel.TextXAlignment = Enum.TextXAlignment.Right
	priceLabel.ZIndex = 54
	priceLabel.Parent = row

	-- Buy button
	local buyBtn = Instance.new("TextButton")
	buyBtn.Name = "BuyButton"
	buyBtn.Size = UDim2.new(0, 70, 0, 28)
	buyBtn.Position = UDim2.new(0, 400, 0.5, -14)
	buyBtn.BackgroundColor3 = Color3.fromRGB(40, 80, 40)
	buyBtn.BorderSizePixel = 0
	buyBtn.Text = "BUY"
	buyBtn.TextColor3 = Color3.fromRGB(200, 255, 200)
	buyBtn.TextSize = 14
	buyBtn.Font = Enum.Font.SourceSansBold
	buyBtn.ZIndex = 55
	buyBtn.Parent = row

	-- Buy button click: show quantity picker
	buyBtn.MouseButton1Click:Connect(function()
		pendingItemId = entry.itemId
		quantityValue = 1
		if quantityLabel then
			quantityLabel.Text = "1"
		end
		if quantityPicker then
			quantityPicker.Visible = true
		end
	end)

	-- Feedback labels (hidden initially)
	local feedbackLabel = Instance.new("TextLabel")
	feedbackLabel.Name = "Feedback"
	feedbackLabel.Size = UDim2.new(0, 200, 0, 20)
	feedbackLabel.Position = UDim2.new(0, 280, 0, 28)
	feedbackLabel.BackgroundTransparency = 1
	feedbackLabel.Text = ""
	feedbackLabel.TextColor3 = Color3.fromRGB(150, 255, 150)
	feedbackLabel.TextSize = 12
	feedbackLabel.Font = Enum.Font.SourceSans
	feedbackLabel.TextXAlignment = Enum.TextXAlignment.Right
	feedbackLabel.ZIndex = 55
	feedbackLabel.Parent = row
end

--[[
	Flash feedback on the store panel (success green flash, failure red shake).
]]

function StoreUI._flashFeedback(success: boolean, message: string)
	if not panel then return end

	-- Create a temporary feedback label in the panel center
	local feedback = Instance.new("TextLabel")
	feedback.Name = "FeedbackFlash"
	feedback.Size = UDim2.new(1, -40, 0, 24)
	feedback.Position = UDim2.new(0, 20, 1, -70)
	feedback.BackgroundTransparency = 0.3
	feedback.BackgroundColor3 = success and Color3.fromRGB(0, 60, 0) or Color3.fromRGB(60, 0, 0)
	feedback.BorderSizePixel = 0
	feedback.Text = message
	feedback.TextColor3 = success and Color3.fromRGB(150, 255, 150) or Color3.fromRGB(255, 150, 150)
	feedback.TextSize = 14
	feedback.Font = Enum.Font.SourceSansBold
	feedback.TextXAlignment = Enum.TextXAlignment.Center
	feedback.TextYAlignment = Enum.TextYAlignment.Center
	feedback.ZIndex = 70
	feedback.Parent = panel

	-- Green flash: fade out after 2s
	if success then
		local fadeOut = TweenService:Create(
			feedback,
			TweenInfo.new(0.5, Enum.EasingStyle.Linear),
			{ BackgroundTransparency = 1, TextTransparency = 1 }
		)
		task.delay(1.5, function()
			fadeOut:Play()
			fadeOut.Completed:Once(function()
				feedback:Destroy()
			end)
		end)
	else
		-- Red shake: brief shake animation then fade
		local originalPos = feedback.Position
		local shake1 = TweenService:Create(
			feedback,
			TweenInfo.new(0.05, Enum.EasingStyle.Linear),
			{ Position = UDim2.new(0, 20, 1, -70) + UDim2.new(0, 5, 0, 0) }
		)
		local shake2 = TweenService:Create(
			feedback,
			TweenInfo.new(0.05, Enum.EasingStyle.Linear),
			{ Position = originalPos }
		)
		shake1:Play()
		shake1.Completed:Once(function()
			shake2:Play()
			task.delay(0.5, function()
				local fadeOut = TweenService:Create(
					feedback,
					TweenInfo.new(0.3, Enum.EasingStyle.Linear),
					{ BackgroundTransparency = 1, TextTransparency = 1 }
				)
				fadeOut:Play()
				fadeOut.Completed:Once(function()
					feedback:Destroy()
				end)
			end)
		end)
	end
end

--[[
	===== PUBLIC API =====
]]

--[[
	Open the store panel.
	Fetches catalog from server and builds UI.
]]

function StoreUI.Open()
	if isOpen then
		StoreUI.Close()
		return
	end

	if not screenGui then
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "StoreGUI"
		screenGui.ResetOnSpawn = false
		screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
		screenGui.Parent = localPlayer:WaitForChild("PlayerGui")
	end

	isOpen = true

	-- Create the panel
	createPanel()

	-- Fetch catalog from server
	local success, result = pcall(function()
		return RemoteEvents.GetCatalog:InvokeServer()
	end)

	if success and result and type(result) == "table" then
		catalog = result

		-- Build item rows
		if itemList then
			-- Clear existing content
			for _, child in ipairs(itemList:GetChildren()) do
				if child:IsA("Frame") then
					child:Destroy()
				end
			end

			-- Layout items in rows
			local yOffset = 0
			for _, entry in ipairs(catalog) do
				createItemRow(entry)
				yOffset += ITEM_ROW_HEIGHT
			end

			-- Update canvas size
			itemList.CanvasSize = UDim2.new(0, 0, 0, yOffset + 10)
		end

		-- Update initial gem balance
		local gemSuccess, gemResult = pcall(function()
			return RemoteEvents.GetInventory:InvokeServer()
		end)
		if not gemSuccess then
			if gemBalanceLabel then
				gemBalanceLabel.Text = "◆ (offline)"
			end
		end
	else
		if gemBalanceLabel then
			gemBalanceLabel.Text = "◆ Failed to load store"
		end
	end
end

--[[
	Close the store panel.
]]

function StoreUI.Close()
	isOpen = false
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	panel = nil
	itemList = nil
	gemBalanceLabel = nil
	quantityPicker = nil
	pendingItemId = nil
end

--[[
	Buy an item from the store.
	@param itemId: number — catalog item ID
	@param quantity: number — how many to buy (1-99)
]]

function StoreUI.BuyItem(itemId: number, quantity: number)
	local now = os.clock()
	if now - lastBuyTime < BUY_COOLDOWN then
		StoreUI._flashFeedback(false, "Please wait before buying again")
		return
	end
	lastBuyTime = now

	RemoteEvents.RequestPurchase:FireServer(itemId, quantity)
	-- Feedback comes from StoreResult remote event
end

--[[
	Initialize StoreUI (registers keybind).
]]

function StoreUI.Init()
	-- Register B key to toggle store
	UserInputService.InputBegan:Connect(function(input: InputObject, isProcessed: boolean)
		if isProcessed then return end
		if input.KeyCode == Enum.KeyCode.B then
			StoreUI.Open()
		end
	end)

	print("[StoreUI] Initialized")
end

--[[
	Clean up.
]]

function StoreUI.Destroy()
	StoreUI.Close()
	print("[StoreUI] Destroyed")
end

return StoreUI
