-- HUD.lua (client)
-- Heads-up display: world name (top-left), gem count (top-right), lock indicator (top-center),
-- notification toast system, chat display with input, player name.
-- Separate ScreenGui (HUDGUI) for ZIndex isolation.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage.Shared)
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)

local HUD = {}

--[[
	===== CONSTANTS =====
]]
local NOTIFICATION_DURATION = 2.5       -- seconds toast stays visible
local CHAT_FADE_TIME = 8                -- seconds before chat line fades
local MAX_CHAT_LINES = 6

local GEM_COLOR = Color3.fromRGB(255, 215, 0)
local PADLOCK_GREEN = Color3.fromRGB(50, 200, 50)
local PADLOCK_YELLOW = Color3.fromRGB(200, 200, 50)
local PADLOCK_GRAY = Color3.fromRGB(120, 120, 120)
local CHAT_BG_COLOR = Color3.fromRGB(20, 20, 20)

--[[
	===== STATE =====
]]
local screenGui: ScreenGui? = nil
local worldNameLabel: TextLabel? = nil
local gemLabel: TextLabel? = nil
local lockIndicator: Frame? = nil
local playerNameLabel: TextLabel? = nil

-- Notification system
local notifContainer: Frame? = nil
local notifQueue: { { text: string, color: Color3 } } = {}
local currentNotifText: TextLabel? = nil
local currentNotifFrame: Frame? = nil
local notifActive = false

-- Chat system
local chatContainer: Frame? = nil
local chatLines: { TextLabel } = {}            -- Pool of 6 labels
local chatInputBox: TextBox? = nil
local chatInputActive = false
local chatLineTimers: { number } = {}          -- os.clock() time for each line

-- Remote connections
local remoteConnections: { RBXScriptConnection } = {}
local inputConnections: { RBXScriptConnection } = {}

--[[
	===== CREATE NOTIFICATION UI =====
]]
local function createNotificationFrame(): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Notification"
	frame.Size = UDim2.new(0, 280, 0, 32)
	frame.Position = UDim2.new(0.5, -140, 0, 60)  -- top-center, below lock indicator
	frame.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	frame.BackgroundTransparency = 0.3
	frame.BorderSizePixel = 0
	frame.ZIndex = 20
	frame.Visible = false
	frame.Parent = screenGui

	local label = Instance.new("TextLabel")
	label.Name = "Text"
	label.Size = UDim2.new(1, -16, 1, 0)
	label.Position = UDim2.new(0, 8, 0, 0)
	label.BackgroundTransparency = 1
	label.Text = ""
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.TextSize = 15
	label.Font = Enum.Font.SourceSansBold
	label.TextXAlignment = Enum.TextXAlignment.Center
	label.TextYAlignment = Enum.TextYAlignment.Center
	label.Parent = frame

	return frame
end

--[[
	===== NOTIFICATION SYSTEM =====
]]
local function showNextNotification()
	if #notifQueue == 0 then
		notifActive = false
		if currentNotifFrame then
			currentNotifFrame.Visible = false
		end
		return
	end

	notifActive = true
	local notif = table.remove(notifQueue, 1)

	if not currentNotifFrame or not currentNotifText then
		notifActive = false
		return
	end

	currentNotifText.Text = notif.text
	currentNotifText.TextColor3 = notif.color
	currentNotifFrame.Size = UDim2.new(0, math.clamp(#notif.text * 9 + 40, 120, 400), 0, 32)
	currentNotifFrame.Position = UDim2.new(0.5, -currentNotifFrame.Size.X.Offset / 2, 0, 60)
	currentNotifFrame.Visible = true

	-- Slide in from top
	currentNotifFrame.Position = UDim2.new(0.5, -currentNotifFrame.Size.X.Offset / 2, 0, -10)
	local tween = TweenService:Create(
		currentNotifFrame,
		TweenInfo.new(0.2, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = UDim2.new(0.5, -currentNotifFrame.Size.X.Offset / 2, 0, 60) }
	)
	tween:Play()

	-- Fade out after duration
	task.delay(NOTIFICATION_DURATION, function()
		if not currentNotifFrame then return end
		local fadeOut = TweenService:Create(
			currentNotifFrame,
			TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ BackgroundTransparency = 1 }
		)
		fadeOut:Play()
		fadeOut.Completed:Once(function()
			if currentNotifFrame then
				currentNotifFrame.Visible = false
				currentNotifFrame.BackgroundTransparency = 0.3
			end
			notifActive = false
			showNextNotification()
		end)
	end)
end

--[[
	===== CHAT SYSTEM =====
]]
-- Forward declaration for repositionChatLines (assigned below, called from addChatLine's task.delay closure)
local repositionChatLines: () -> ()

local function addChatLine(senderName: string, message: string, textColor: Color3)
	-- Shift lines up (remove oldest)
	if #chatLines >= MAX_CHAT_LINES then
		local oldest = table.remove(chatLines, 1)
		oldest.Text = ""
		oldest.Visible = false
		table.insert(chatLines, oldest)
		table.remove(chatLineTimers, 1)
	end

	-- Find first empty or invisible label to reuse
	local label: TextLabel? = nil
	for _, line in ipairs(chatLines) do
		if line.Text == "" or not line.Visible then
			label = line
			break
		end
	end

	-- If no reusable label, create new one
	if not label then
		label = Instance.new("TextLabel")
		label.Name = "ChatLine"
		label.Size = UDim2.new(0, 400, 0, 18)
		label.BackgroundTransparency = 1
		label.Text = ""
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 14
		label.Font = Enum.Font.SourceSans
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Bottom
		label.RichText = true
		label.ZIndex = 5
		label.Parent = chatContainer
		table.insert(chatLines, label)
	end

	-- Set text with sender name colored
	label.Text = `<font color="#{textColor:ToHex()}">{senderName}:</font> {message}`
	label.TextColor3 = Color3.fromRGB(255, 255, 255)
	label.Visible = true
	label.TextTransparency = 0

	-- Position: last line at bottom, others above
	local yOffset = -(#chatLines) * 18
	for i, line in ipairs(chatLines) do
		line.Position = UDim2.new(0, 10, 1, yOffset + (i - 1) * 18)
	end

	-- Fade timer
	local startTime = os.clock()
	table.insert(chatLineTimers, startTime)

	-- After CHAT_FADE_TIME, start fading
	task.delay(CHAT_FADE_TIME - 2, function()
		if not label or label.Text == "" then return end
		local fadeOut = TweenService:Create(
			label,
			TweenInfo.new(2, Enum.EasingStyle.Linear),
			{ TextTransparency = 1 }
		)
		fadeOut:Play()
		fadeOut.Completed:Once(function()
			if label then
				label.Text = ""
				label.Visible = false
				-- Recalculate positions after removal
				repositionChatLines()
			end
		end)
	end)
end

repositionChatLines = function()
	local visibleCount = 0
	for _, line in ipairs(chatLines) do
		if line.Visible then
			visibleCount += 1
		end
	end

	local index = 0
	for _, line in ipairs(chatLines) do
		if line.Visible then
			line.Position = UDim2.new(0, 10, 1, -(visibleCount - index) * 18)
			index += 1
		end
	end
end

local function openChatInput()
	if chatInputActive then return end
	if not chatInputBox then return end

	chatInputActive = true
	chatInputBox.Visible = true
	chatInputBox:CaptureFocus()
	chatInputBox.Text = ""
end

local function closeChatInput()
	if not chatInputActive then return end
	chatInputActive = false
	if chatInputBox then
		chatInputBox.Visible = false
		UserInputService:SetCursorIcon("Arrow")
	end
end

local function sendChatMessage()
	if not chatInputBox then return end

	local message = chatInputBox.Text:match("^%s*(.-)%s*$")  -- trim
	if message and #message > 0 then
		-- Prepend ";" as the command prefix
		-- When the user presses / to open chat, the / is consumed,
		-- so the text box only has "command". We add the prefix here.
		RemoteEvents.RequestChatMessage:FireServer(";" .. message)
	end

	closeChatInput()
end

--[[
	===== REMOTE EVENT HANDLERS =====
]]
local function onSpliceResult(tileX: number, tileY: number, success: boolean, resultItemName: string?)
	if success and resultItemName then
		HUD.Notify(`Spliced! Created: {resultItemName}`, Color3.fromRGB(0, 255, 100))
	elseif not success then
		HUD.Notify("Splice failed! Seeds rejected.", Color3.fromRGB(255, 100, 100))
	end
end

local function onWorldLoaded(worldName: string, tileData: any, worldWidth: number, worldHeight: number)
	if worldNameLabel then
		worldNameLabel.Text = worldName:upper()
	end

	-- Reset lock indicator to gray (unlocked) until we hear otherwise
	if lockIndicator then
		lockIndicator.BackgroundColor3 = PADLOCK_GRAY
	end
end

local function onGemsUpdated(gemCount: number)
	if gemLabel then
		gemLabel.Text = `◆ {gemCount}`
	end
end

local function onWorldLockStatus(isLocked: boolean, ownerName: string?)
	if not lockIndicator then return end

	if not isLocked then
		-- Unlocked: gray
		lockIndicator.BackgroundColor3 = PADLOCK_GRAY
	elseif ownerName == Players.LocalPlayer.Name then
		-- Owned by local player: green
		lockIndicator.BackgroundColor3 = PADLOCK_GREEN
	else
		-- Locked by someone else: yellow
		lockIndicator.BackgroundColor3 = PADLOCK_YELLOW
	end
end

local function onChatMessage(senderName: string, message: string, textColor: Color3)
	addChatLine(senderName, message, textColor or Color3.fromRGB(255, 255, 255))
end

--[[
	===== INPUT HANDLING =====
]]
local function onInputBegan(input: InputObject, isProcessed: boolean)
	if isProcessed then return end

	-- If chat input active, handle Enter/Return
	if chatInputActive then
		if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter then
			sendChatMessage()
			return true
		elseif input.KeyCode == Enum.KeyCode.Escape then
			closeChatInput()
			return true
		end
		return false
	end

	-- '/' or ';' opens chat input (commands use ; prefix)
	if input.KeyCode == Enum.KeyCode.Slash then
		openChatInput()
		return true
	end

	-- Enter also opens chat
	if input.KeyCode == Enum.KeyCode.Return or input.KeyCode == Enum.KeyCode.KeypadEnter then
		openChatInput()
		return true
	end

	return false
end

--[[
	===== PUBLIC API =====
]]

--[[
	Initialize HUD: create all labels, indicators, chat system, and connect remotes.
]]
function HUD.Init()
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "HUDGUI"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	--[[ TOP-LEFT: World Name ]]
	worldNameLabel = Instance.new("TextLabel")
	worldNameLabel.Name = "WorldName"
	worldNameLabel.Size = UDim2.new(0, 200, 0, 22)
	worldNameLabel.Position = UDim2.new(0, 10, 0, 8)
	worldNameLabel.BackgroundTransparency = 0.4
	worldNameLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	worldNameLabel.Text = "START"
	worldNameLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
	worldNameLabel.TextSize = 16
	worldNameLabel.Font = Enum.Font.SourceSansBold
	worldNameLabel.TextXAlignment = Enum.TextXAlignment.Left
	worldNameLabel.ZIndex = 2
	worldNameLabel.Parent = screenGui

	--[[ TOP-CENTER: Lock Indicator ]]
	lockIndicator = Instance.new("Frame")
	lockIndicator.Name = "LockIndicator"
	lockIndicator.Size = UDim2.new(0, 14, 0, 18)
	lockIndicator.Position = UDim2.new(0.5, -7, 0, 8)
	lockIndicator.BackgroundColor3 = PADLOCK_GRAY
	lockIndicator.BackgroundTransparency = 0
	lockIndicator.BorderSizePixel = 0
	lockIndicator.ZIndex = 2
	lockIndicator.Parent = screenGui

	-- Small lock icon text
	local lockLabel = Instance.new("TextLabel")
	lockLabel.Name = "LockIcon"
	lockLabel.Size = UDim2.new(1, 0, 1, 0)
	lockLabel.BackgroundTransparency = 1
	lockLabel.Text = "🔒"
	lockLabel.TextSize = 12
	lockLabel.Font = Enum.Font.SourceSansBold
	lockLabel.TextXAlignment = Enum.TextXAlignment.Center
	lockLabel.TextYAlignment = Enum.TextYAlignment.Center
	lockLabel.Parent = lockIndicator

	--[[ TOP-RIGHT: Gem Counter ]]
	gemLabel = Instance.new("TextLabel")
	gemLabel.Name = "GemCounter"
	gemLabel.Size = UDim2.new(0, 110, 0, 24)
	gemLabel.Position = UDim2.new(1, -120, 0, 8)
	gemLabel.BackgroundTransparency = 0.4
	gemLabel.BackgroundColor3 = Color3.fromRGB(0, 0, 0)
	gemLabel.Text = "◆ 0"
	gemLabel.TextColor3 = GEM_COLOR
	gemLabel.TextSize = 16
	gemLabel.Font = Enum.Font.SourceSansBold
	gemLabel.TextXAlignment = Enum.TextXAlignment.Right
	gemLabel.ZIndex = 2
	gemLabel.Parent = screenGui

	--[[ NOTIFICATION SYSTEM ]]
	notifContainer = Instance.new("Frame")
	notifContainer.Name = "NotificationContainer"
	notifContainer.Size = UDim2.new(0, 400, 0, 100)
	notifContainer.Position = UDim2.new(0.5, -200, 0, 50)
	notifContainer.BackgroundTransparency = 1
	notifContainer.BorderSizePixel = 0
	notifContainer.ZIndex = 20
	notifContainer.Parent = screenGui

	-- Create the notification frame (reused)
	currentNotifFrame = createNotificationFrame()
	currentNotifText = currentNotifFrame:FindFirstChild("Text") :: TextLabel

	--[[ CHAT SYSTEM ]]
	chatContainer = Instance.new("Frame")
	chatContainer.Name = "ChatContainer"
	chatContainer.Size = UDim2.new(0, 420, 0, MAX_CHAT_LINES * 18 + 8)
	chatContainer.Position = UDim2.new(0, 10, 1, -(MAX_CHAT_LINES * 18) - 20 - 70)  -- Above hotbar
	chatContainer.BackgroundTransparency = 0.3
	chatContainer.BackgroundColor3 = CHAT_BG_COLOR
	chatContainer.BorderSizePixel = 0
	chatContainer.ZIndex = 4
	chatContainer.Parent = screenGui

	-- Create pooled chat labels (pre-create MAX_CHAT_LINES)
	for i = 1, MAX_CHAT_LINES do
		local label = Instance.new("TextLabel")
		label.Name = "ChatLine" .. i
		label.Size = UDim2.new(0, 400, 0, 18)
		label.Position = UDim2.new(0, 10, 1, -(i * 18))
		label.BackgroundTransparency = 1
		label.Text = ""
		label.TextColor3 = Color3.fromRGB(255, 255, 255)
		label.TextSize = 14
		label.Font = Enum.Font.SourceSans
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.TextYAlignment = Enum.TextYAlignment.Bottom
		label.RichText = true
		label.ZIndex = 5
		label.Visible = false
		label.Parent = chatContainer
		table.insert(chatLines, label)
	end

	-- Chat input box (hidden until activated)
	chatInputBox = Instance.new("TextBox")
	chatInputBox.Name = "ChatInput"
	chatInputBox.Size = UDim2.new(0, 400, 0, 26)
	chatInputBox.Position = UDim2.new(0, 10, 1, -(MAX_CHAT_LINES * 18) - 20 - 70 - 30)  -- Below chat
	chatInputBox.BackgroundColor3 = Color3.fromRGB(30, 30, 30)
	chatInputBox.BackgroundTransparency = 0.2
	chatInputBox.BorderSizePixel = 1
	chatInputBox.BorderColor3 = Color3.fromRGB(80, 80, 80)
	chatInputBox.Text = ""
	chatInputBox.TextColor3 = Color3.fromRGB(255, 255, 255)
	chatInputBox.TextSize = 15
	chatInputBox.Font = Enum.Font.SourceSans
	chatInputBox.PlaceholderText = "Type a message..."
	chatInputBox.ClearTextOnFocus = false
	chatInputBox.ZIndex = 6
	chatInputBox.Visible = false
	chatInputBox.Parent = screenGui

	-- Handle Enter in input box to send
	chatInputBox.FocusLost:Connect(function(enterPressed: boolean)
		if enterPressed then
			sendChatMessage()
		else
			closeChatInput()
		end
	end)

	--[[ REMOTE EVENT CONNECTIONS ]]
	local conn1 = RemoteEvents.SpliceResult.OnClientEvent:Connect(onSpliceResult)
	table.insert(remoteConnections, conn1)

	local conn2 = RemoteEvents.WorldLoaded.OnClientEvent:Connect(onWorldLoaded)
	table.insert(remoteConnections, conn2)

	local conn3 = RemoteEvents.GemsUpdated.OnClientEvent:Connect(onGemsUpdated)
	table.insert(remoteConnections, conn3)

	local conn4 = RemoteEvents.WorldLockStatus.OnClientEvent:Connect(onWorldLockStatus)
	table.insert(remoteConnections, conn4)

	local conn5 = RemoteEvents.ChatMessage.OnClientEvent:Connect(onChatMessage)
	table.insert(remoteConnections, conn5)

	--[[ INPUT CONNECTIONS ]]
	local conn6 = UserInputService.InputBegan:Connect(onInputBegan)
	table.insert(inputConnections, conn6)

	print("[HUD] Initialized")
end

--[[
	Show a notification toast.
	Queues if one is already active.
	@param message: string — text to display
	@param color: Color3 — text color
]]
function HUD.Notify(message: string, color: Color3?)
	color = color or Color3.fromRGB(255, 255, 255)
	table.insert(notifQueue, { text = message, color = color })

	if not notifActive then
		showNextNotification()
	end
end

--[[
	Set gem count display.
	@param count: number
]]
function HUD.SetGems(count: number)
	if gemLabel then
		gemLabel.Text = `◆ {count}`
	end
end

--[[
	Set world name display.
	@param name: string
]]
function HUD.SetWorldName(name: string)
	if worldNameLabel then
		worldNameLabel.Text = name:upper()
	end
end

--[[
	Clean up all GUI and connections.
]]
function HUD.Destroy()
	for _, conn in ipairs(remoteConnections) do
		conn:Disconnect()
	end
	for _, conn in ipairs(inputConnections) do
		conn:Disconnect()
	end
	if screenGui then
		screenGui:Destroy()
		screenGui = nil
	end
	chatLines = {}
	notifQueue = {}
	print("[HUD] Destroyed")
end

return HUD
