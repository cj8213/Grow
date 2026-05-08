-- WorldList.luau
-- Client-side world selection screen (toggle with M)

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = require(ReplicatedStorage.Shared)
local Remotes = Shared.Remotes

local WorldList = {}

local screenGui = nil
local isOpen = false

--[[
	Initialize WorldList
]]
function WorldList.Init()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "WorldListGUI"
	screenGui.ResetOnSpawn = false

	-- Listen for toggle key (M)
	UserInputService.InputBegan:Connect(function(input, gameProcessed)
		if gameProcessed then return end
		if input.KeyCode == Enum.KeyCode.M then
			WorldList.Toggle()
		end
	end)

	print("[WorldList] Initialized")
end

--[[
	Toggle world list visibility
]]
function WorldList.Toggle()
	isOpen = not isOpen

	if isOpen then
		screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
		WorldList._buildUI()
	else
		screenGui:Destroy()
		screenGui = Instance.new("ScreenGui")
		screenGui.Name = "WorldListGUI"
		screenGui.ResetOnSpawn = false
	end
end

--[[
	Build the world list UI
]]
function WorldList._buildUI()
	for _, child in ipairs(screenGui:GetChildren()) do
		child:Destroy()
	end

	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.new(1, 0, 1, 0)
	bg.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	bg.BackgroundTransparency = 0.6
	bg.Parent = screenGui

	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.new(0, 300, 0, 400)
	container.Position = UDim2.new(0.5, -150, 0.5, -200)
	container.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
	container.BorderSizePixel = 0
	container.Parent = screenGui

	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 40)
	title.BackgroundTransparency = 1
	title.Text = "WORLDS"
	title.TextColor3 = Color3.fromRGB(255, 255, 255)
	title.TextSize = 24
	title.Font = Enum.Font.SourceSansBold
	title.Parent = container

	local worldList = Instance.new("UIListLayout")
	worldList.Padding = UDim.new(0, 5)
	worldList.Parent = container

	-- Main world button
	local mainWorld = Instance.new("TextButton")
	mainWorld.Name = "main"
	mainWorld.Size = UDim2.new(1, -20, 0, 40)
	mainWorld.Position = UDim2.new(0, 10, 0, 50)
	mainWorld.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
	mainWorld.Text = "🌍 Main World"
	mainWorld.TextColor3 = Color3.fromRGB(255, 255, 255)
	mainWorld.TextSize = 16
	mainWorld.Font = Enum.Font.SourceSans
	mainWorld.Parent = container

	-- Shop world button
	local shopWorld = Instance.new("TextButton")
	shopWorld.Name = "shop"
	shopWorld.Size = UDim2.new(1, -20, 0, 40)
	shopWorld.Position = UDim2.new(0, 10, 0, 100)
	shopWorld.BackgroundColor3 = Color3.fromRGB(60, 60, 70)
	shopWorld.Text = "🛒 BUY+ Shop"
	shopWorld.TextColor3 = Color3.fromRGB(198, 165, 50)
	shopWorld.TextSize = 16
	shopWorld.Font = Enum.Font.SourceSans
	shopWorld.Parent = container

	mainWorld.MouseButton1Click:Connect(function()
		Remotes.Events.PlayerJoined:Fire("main")
		WorldList.Toggle()
	end)

	shopWorld.MouseButton1Click:Connect(function()
		print("[WorldList] Shop world selected")
		WorldList.Toggle()
	end)
end

--[[
	Check if world list is open
]]
function WorldList.IsOpen(): boolean
	return isOpen
end

return WorldList
