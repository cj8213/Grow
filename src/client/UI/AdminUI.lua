-- AdminUI.lua (client)
-- Simple admin panel: press the `;` key (semicolon) to open/close.
-- Gives you items, locks, and debug tools directly — no chat required.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)

local AdminUI = {}

--[[
	===== CONSTANTS =====
]]

local PANEL_BG = Color3.fromRGB(30, 30, 40)
local BUTTON_BG = Color3.fromRGB(60, 60, 80)
local BUTTON_HOVER = Color3.fromRGB(80, 80, 110)
local TEXT_COLOR = Color3.fromRGB(220, 220, 255)
local ACCENT_COLOR = Color3.fromRGB(100, 200, 255)

--[[
	===== STATE =====
]]

local screenGui: ScreenGui? = nil
local panel: Frame? = nil
local isOpen = false
local localPlayer = Players.LocalPlayer

--[[
	===== BUILD UI =====
]]

local function buildPanel(): Frame
	local p = Instance.new("Frame")
	p.Name = "AdminPanel"
	p.Size = UDim2.new(0, 320, 0, 420)
	p.Position = UDim2.new(0.5, -160, 0.5, -210)
	p.BackgroundColor3 = PANEL_BG
	p.BorderSizePixel = 0
	p.BackgroundTransparency = 0.1

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 8)
	corner.Parent = p

	-- Title bar
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 36)
	title.BackgroundTransparency = 1
	title.Text = "⚙ Admin Panel"
	title.TextColor3 = ACCENT_COLOR
	title.TextSize = 18
	title.Font = Enum.Font.GothamBold
	title.Parent = p

	-- Scrollable list of action buttons
	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "ActionList"
	scroll.Size = UDim2.new(1, -10, 1, -50)
	scroll.Position = UDim2.new(0, 5, 0, 40)
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.ScrollBarThickness = 6
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = p

	-- Layout
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, 4)
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = scroll

	return p, scroll
end

local function addButton(parent: Instance, text: string, callback: () -> ())
	local btn = Instance.new("TextButton")
	btn.Size = UDim2.new(1, 0, 0, 36)
	btn.BackgroundColor3 = BUTTON_BG
	btn.BorderSizePixel = 0
	btn.Text = text
	btn.TextColor3 = TEXT_COLOR
	btn.TextSize = 14
	btn.Font = Enum.Font.Gotham
	btn.TextXAlignment = Enum.TextXAlignment.Left

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 4)
	corner.Parent = btn

	btn.MouseButton1Click:Connect(callback)

	btn.MouseEnter:Connect(function()
		btn.BackgroundColor3 = BUTTON_HOVER
	end)
	btn.MouseLeave:Connect(function()
		btn.BackgroundColor3 = BUTTON_BG
	end)

	btn.Parent = parent
end

local function fireAdminAction(action: string, itemId: number?, count: number?)
	RemoteEvents.RequestAdminAction:FireServer(action, itemId, count or 1)
end

--[[
	===== OPEN / CLOSE =====
]]

function AdminUI.Toggle()
	isOpen = not isOpen
	if panel then
		panel.Visible = isOpen
	end
end

--[[
	===== INIT =====
]]

function AdminUI.Init()
	local playerGui = localPlayer:WaitForChild("PlayerGui")

	-- Build ScreenGui
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "AdminUI"
	screenGui.ResetOnSpawn = false
	screenGui.Parent = playerGui

	local scroll
	panel, scroll = buildPanel()
	panel.Visible = false
	panel.Parent = screenGui

	-- ── Action Buttons ──

	-- Section: Items
	local sectionItems = Instance.new("TextLabel")
	sectionItems.Size = UDim2.new(1, 0, 0, 24)
	sectionItems.BackgroundTransparency = 1
	sectionItems.Text = "  ── GIVE ITEMS ──"
	sectionItems.TextColor3 = ACCENT_COLOR
	sectionItems.TextSize = 12
	sectionItems.Font = Enum.Font.GothamBold
	sectionItems.TextXAlignment = Enum.TextXAlignment.Left
	sectionItems.Parent = scroll

	addButton(scroll, "  Fist (1000)", function() fireAdminAction("give", 1000, 1) end)
	addButton(scroll, "  Wrench (1002)", function() fireAdminAction("give", 1002, 1) end)
	addButton(scroll, "  Dirt Seed ×10 (101)", function() fireAdminAction("give", 101, 10) end)
	addButton(scroll, "  Rock Seed ×10 (102)", function() fireAdminAction("give", 102, 10) end)
	addButton(scroll, "  Cave BG Seed ×5 (103)", function() fireAdminAction("give", 103, 5) end)
	addButton(scroll, "  World Lock (26)", function() fireAdminAction("give", 26, 1) end)
	addButton(scroll, "  Small Lock (27)", function() fireAdminAction("give", 27, 1) end)

	-- Section: Actions
	local sectionActions = Instance.new("TextLabel")
	sectionActions.Size = UDim2.new(1, 0, 0, 24)
	sectionActions.BackgroundTransparency = 1
	sectionActions.Text = "  ── ACTIONS ──"
	sectionActions.TextColor3 = ACCENT_COLOR
	sectionActions.TextSize = 12
	sectionActions.Font = Enum.Font.GothamBold
	sectionActions.TextXAlignment = Enum.TextXAlignment.Left
	sectionActions.Parent = scroll

	addButton(scroll, "  Clear Inventory", function() fireAdminAction("clear") end)
	addButton(scroll, "  Remove ALL Locks (World + Small)", function() fireAdminAction("removelocks") end)
	addButton(scroll, "  Show Lock Zones", function() fireAdminAction("showlocks") end)

	-- Keybind: `;` toggles the panel
	UserInputService.InputBegan:Connect(function(input, isProcessed)
		if isProcessed then return end
		if input.KeyCode == Enum.KeyCode.Semicolon then
			AdminUI.Toggle()
		end
	end)

	print("[AdminUI] Initialized — press ; to open")
end

function AdminUI.Destroy()
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
end

return AdminUI
