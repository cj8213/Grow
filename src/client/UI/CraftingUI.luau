-- CraftingUI.luau
-- Client-side crafting/surgery interface (toggle with C)

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = require(ReplicatedStorage.Shared)
local Constants = Shared.Constants
local BlockDefs = Shared.BlockDefs
local ItemDefs = Shared.ItemDefs
local Remotes = Shared.Remotes

local CraftingUI = {}

local screenGui = nil
local isOpen = false

--[[
	Initialize CraftingUI
]]
function CraftingUI.Init()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "CraftingGUI"
	screenGui.ResetOnSpawn = false

	-- Listen for toggle key (C)
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.C then
			CraftingUI.Toggle()
		end
	end)

	print("[CraftingUI] Initialized")
end

--[[
	Toggle crafting visibility
]]
function CraftingUI.Toggle()
	isOpen = not isOpen

	if isOpen then
		screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		CraftingUI._buildUI()
	else
		screenGui:Destroy()
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "CraftingGUI"
		screenGui.ResetOnSpawn = false
	end
end

--[[
	Build the crafting UI
]]
function CraftingUI._buildUI()
	for _, child in ipairs(screenGui:GetChildren()) do
		child:Destroy()
	end

	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	bg.BackgroundTransparency = 0.5
	bg.Parent = screenGui

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0, 400, 0, 300)
	container.Position = UDim2.new(0.5, -200, 0.5, -150)
	container.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
	container.BorderSizePixel = 0
	container.Parent = screenGui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 30)
	title.BackgroundTransparency = 1
	title.Text = "🔧 Crafting & Surgery"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 18
	title.Font = Enum.Font.SourceSansBold
	title.Parent = container

	-- Recipe list (placeholder)
	local recipeList = Instance.new("UIListLayout")
	recipeList.Padding = UDim.new(0, 5)
	recipeList.Parent = container

	-- Pickaxe recipe
	local pickaxeRecipe = Instance.new("TextButton")
	pickaxeRecipe.Name = "Axe"
	pickaxeRecipe.Size = UDim2.new(1, -20, 0, 30)
	pickaxeRecipe.Position = UDim2.new(0, 10, 0, 40)
	pickaxeRecipe.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
	pickaxeRecipe.Text = "🪓 Axe: 3 Rock Seeds + 2 Dirt Seeds"
	pickaxeRecipe.TextColor3 = Color3.fromRGB(200, 200, 200)
	pickaxeRecipe.TextSize = 14
	pickaxeRecipe.TextXAlignment = Enum.TextXAlignment.Left
	pickaxeRecipe.Parent = container

	pickaxeRecipe.MouseButton1Click:Connect(function()
		Remotes.Functions.RequestCraft:InvokeServer(1)
	end)

	-- Shovel recipe
	local shovelRecipe = Instance.new("TextButton")
	shovelRecipe.Name = "Shovel"
	shovelRecipe.Size = UDim2.new(1, -20, 0, 30)
	shovelRecipe.Position = UDim2.new(0, 10, 0, 80)
	shovelRecipe.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
	shovelRecipe.Text = "🪣 Shovel: 2 Rock Seeds + 1 Dirt Seed"
	shovelRecipe.TextColor3 = Color3.fromRGB(200, 200, 200)
	shovelRecipe.TextSize = 14
	shovelRecipe.TextXAlignment = Enum.TextXAlignment.Left
	shovelRecipe.Parent = container

	shovelRecipe.MouseButton1Click:Connect(function()
		Remotes.Functions.RequestCraft:InvokeServer(2)
	end)

	-- Close button
	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "Close"
	closeBtn.Size = UDim2.new(0, 80, 0, 30)
	closeBtn.Position = UDim2.new(1, -90, 1, -40)
	closeBtn.BackgroundColor3 = Color3.fromRGB(100, 50, 50)
	closeBtn.Text = "Close"
	closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
	closeBtn.TextSize = 14
	closeBtn.Parent = container

	closeBtn.MouseButton1Click:Connect(function()
		CraftingUI.Toggle()
	end)
end

--[[
	Check if crafting is open
]]
function CraftingUI.IsOpen(): boolean
	return isOpen
end

return CraftingUI
