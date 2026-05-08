--!strict
-- WrenchUI.lua (client)
-- Opens when player presses E on a tile (server sends WrenchData)
// Displays tile info (fg, bg, tree data, lock info)
// If tile is a door: shows text input to set destination world
// If tile is a lock and player is owner: shows admin management
// Auto-closes when player moves more than 3 tiles from wrenched tile

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Shared = require(ReplicatedStorage.Shared)
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
local WorldConfig = Shared.WorldConfig
local ItemDatabase = Shared.ItemDatabase

local WrenchUI = {}

// === CONSTANTS ===

local POPUP_WIDTH = 220
local POPUP_HEIGHT = 180
local CLOSE_DISTANCE = 3 // tiles, auto-close when player moves further
local TILE_SIZE = 40

// === STATE ===

local localPlayer = Players.LocalPlayer
local screenGui: ScreenGui? = nil
local popup: Frame? = nil
local isOpen = false
local wrenchedTileX = -1
local wrenchedTileY = -1
local lastWrenchCheckTime = 0

// WorldRenderer reference for getting player position
local worldRenderer = nil
local playerController = nil

// === UI CREATION ===

local function createPopup(data: {
    tileX: number,
    tileY: number,
    fg: { itemId: number, name: string, hp: number, type: number }?,
    bg: { itemId: number, name: string }?,
    treeData: { seedId: number, growthPercent: number }?,
    lockInfo: { isLocked: boolean, ownerName: string?, isAdmin: boolean }?,
    isDoor: boolean,
    doorDestination: string?,
})
    if not screenGui then return end

    -- Close any existing popup
    if popup then
        popup:Destroy()
        popup = nil
    end

    wrenchedTileX = data.tileX
    wrenchedTileY = data.tileY

    -- Main popup frame (positioned near the tile)
    popup = Instance.new("Frame")
    popup.Name = "WrenchPopup"
    popup.Size = UDim2.new(0, POPUP_WIDTH, 0, POPUP_HEIGHT)
    popup.BackgroundColor3 = Color3.fromRGB(25, 25, 35)
    popup.BackgroundTransparency = 0.15
    popup.BorderSizePixel = 0
    popup.ZIndex = 80
    popup.Parent = screenGui

    // Position popup near the tile on screen
    local camOffX, camOffY = worldRenderer and worldRenderer.GetCameraOffset() or { 0, 0 }
    local canvas = worldRenderer and worldRenderer.GetCanvas()
    local canvasPos = canvas and canvas.AbsolutePosition or Vector2.new(0, 0)
    local screenX = canvasPos.X + data.tileX * TILE_SIZE - camOffX
    local screenY = canvasPos.Y + data.tileY * TILE_SIZE - camOffY - POPUP_HEIGHT - 10

    popup.Position = UDim2.new(0, screenX, 0, screenY)

    // Title bar
    local titleBar = Instance.new("Frame")
    titleBar.Name = "TitleBar"
    titleBar.Size = UDim2.new(1, 0, 0, 24)
    titleBar.BackgroundColor3 = Color3.fromRGB(40, 40, 55)
    titleBar.BorderSizePixel = 0
    titleBar.ZIndex = 81
    titleBar.Parent = popup

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name = "Title"
    titleLabel.Size = UDim2.new(1, -10, 1, 0)
    titleLabel.Position = UDim2.new(0, 5, 0, 0)
    titleLabel.BackgroundTransparency = 1
    titleLabel.Text = "🔧 Tile Info"
    titleLabel.TextColor3 = Color3.fromRGB(255, 255, 200)
    titleLabel.TextSize = 14
    titleLabel.Font = Enum.Font.SourceSansBold
    titleLabel.TextXAlignment = Enum.TextXAlignment.Left
    titleLabel.TextYAlignment = Enum.TextYAlignment.Center
    titleLabel.ZIndex = 82
    titleLabel.Parent = titleBar

    // Content area (scrollable in case of lots of info)
    local content = Instance.new("Frame")
    content.Name = "Content"
    content.Size = UDim2.new(1, -10, 1, -30)
    content.Position = UDim2.new(0, 5, 0, 26)
    content.BackgroundTransparency = 1
    content.ZIndex = 81
    content.Parent = popup

    local currentY = 0

    // Foreground info
    if data.fg then
        local fgLabel = Instance.new("TextLabel")
        fgLabel.Size = UDim2.new(1, 0, 0, 18)
        fgLabel.Position = UDim2.new(0, 0, 0, currentY)
        fgLabel.BackgroundTransparency = 1
        fgLabel.Text = `■ {data.fg.name} (HP: {data.fg.hp})`
        fgLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        fgLabel.TextSize = 13
        fgLabel.Font = Enum.Font.SourceSans
        fgLabel.TextXAlignment = Enum.TextXAlignment.Left
        fgLabel.ZIndex = 82
        fgLabel.Parent = content
        currentY += 20
    end

    // Background info
    if data.bg then
        local bgLabel = Instance.new("TextLabel")
        bgLabel.Size = UDim2.new(1, 0, 0, 18)
        bgLabel.Position = UDim2.new(0, 0, 0, currentY)
        bgLabel.BackgroundTransparency = 1
        bgLabel.Text = `◻ BG: {data.bg.name}`
        bgLabel.TextColor3 = Color3.fromRGB(180, 180, 200)
        bgLabel.TextSize = 12
        bgLabel.Font = Enum.Font.SourceSans
        bgLabel.TextXAlignment = Enum.TextXAlignment.Left
        bgLabel.ZIndex = 82
        bgLabel.Parent = content
        currentY += 18
    end

    // Tree data
    if data.treeData then
        local treeLabel = Instance.new("TextLabel")
        treeLabel.Size = UDim2.new(1, 0, 0, 18)
        treeLabel.Position = UDim2.new(0, 0, 0, currentY)
        treeLabel.BackgroundTransparency = 1
        treeLabel.Text = `🌱 Growth: {math.floor(data.treeData.growthPercent * 100)}%`
        treeLabel.TextColor3 = Color3.fromRGB(100, 255, 100)
        treeLabel.TextSize = 12
        treeLabel.Font = Enum.Font.SourceSans
        treeLabel.TextXAlignment = Enum.TextXAlignment.Left
        treeLabel.ZIndex = 82
        treeLabel.Parent = content
        currentY += 18

        local seedLabel = Instance.new("TextLabel")
        seedLabel.Size = UDim2.new(1, 0, 0, 18)
        seedLabel.Position = UDim2.new(0, 0, 0, currentY)
        seedLabel.BackgroundTransparency = 1
        seedLabel.Text = `Seed ID: {data.treeData.seedId}`
        seedLabel.TextColor3 = Color3.fromRGB(150, 200, 150)
        seedLabel.TextSize = 11
        seedLabel.Font = Enum.Font.SourceSans
        seedLabel.TextXAlignment = Enum.TextXAlignment.Left
        seedLabel.ZIndex = 82
        seedLabel.Parent = content
        currentY += 18
    end

    // Lock info
    if data.lockInfo then
        if data.lockInfo.isLocked then
            local lockLabel = Instance.new("TextLabel")
            lockLabel.Size = UDim2.new(1, 0, 0, 18)
            lockLabel.Position = UDim2.new(0, 0, 0, currentY)
            lockLabel.BackgroundTransparency = 1
            lockLabel.Text = `🔒 Locked by: {data.lockInfo.ownerName or "Unknown"}`
            lockLabel.TextColor3 = data.lockInfo.isAdmin and Color3.fromRGB(150, 255, 150) or Color3.fromRGB(255, 200, 100)
            lockLabel.TextSize = 11
            lockLabel.Font = Enum.Font.SourceSans
            lockLabel.TextXAlignment = Enum.TextXAlignment.Left
            lockLabel.ZIndex = 82
            lockLabel.Parent = content
            currentY += 18

            if data.lockInfo.isAdmin then
                local adminLabel = Instance.new("TextLabel")
                adminLabel.Size = UDim2.new(1, 0, 0, 18)
                adminLabel.Position = UDim2.new(0, 0, 0, currentY)
                adminLabel.BackgroundTransparency = 1
                adminLabel.Text = "You are an admin here"
                adminLabel.TextColor3 = Color3.fromRGB(150, 255, 150)
                adminLabel.TextSize = 11
                adminLabel.Font = Enum.Font.SourceSans
                adminLabel.TextXAlignment = Enum.TextXAlignment.Left
                adminLabel.ZIndex = 82
                adminLabel.Parent = content
                currentY += 18
            end
        else
            local unlockLabel = Instance.new("TextLabel")
            unlockLabel.Size = UDim2.new(1, 0, 0, 18)
            unlockLabel.Position = UDim2.new(0, 0, 0, currentY)
            unlockLabel.BackgroundTransparency = 1
            unlockLabel.Text = "🔓 Unlocked"
            unlockLabel.TextColor3 = Color3.fromRGB(150, 150, 150)
            unlockLabel.TextSize = 11
            unlockLabel.Font = Enum.Font.SourceSans
            unlockLabel.TextXAlignment = Enum.TextXAlignment.Left
            unlockLabel.ZIndex = 82
            unlockLabel.Parent = content
            currentY += 18
        end
    end

    // Door destination controls
    if data.isDoor then
        local isMainDoor = data.fg and data.fg.itemId == 6

        local doorLabel = Instance.new("TextLabel")
        doorLabel.Size = UDim2.new(1, 0, 0, 18)
        doorLabel.Position = UDim2.new(0, 0, 0, currentY)
        doorLabel.BackgroundTransparency = 1
        doorLabel.Text = isMainDoor and "🚪 Main Door (to START)" or "🚪 Door"
        doorLabel.TextColor3 = Color3.fromRGB(200, 200, 255)
        doorLabel.TextSize = 12
        doorLabel.Font = Enum.Font.SourceSansBold
        doorLabel.TextXAlignment = Enum.TextXAlignment.Left
        doorLabel.ZIndex = 82
        doorLabel.Parent = content
        currentY += 20

        if not isMainDoor then
            -- Current destination display
            local destLabel = Instance.new("TextLabel")
            destLabel.Size = UDim2.new(1, 0, 0, 18)
            destLabel.Position = UDim2.new(0, 0, 0, currentY)
            destLabel.BackgroundTransparency = 1
            destLabel.Text = `Dest: {data.doorDestination or "(not set)"}`
            destLabel.TextColor3 = Color3.fromRGB(180, 200, 255)
            destLabel.TextSize = 11
            destLabel.Font = Enum.Font.SourceSans
            destLabel.TextXAlignment = Enum.TextXAlignment.Left
            destLabel.ZIndex = 82
            destLabel.Parent = content
            currentY += 18

            -- Text input for setting destination
            local inputBox = Instance.new("TextBox")
            inputBox.Name = "DoorInput"
            inputBox.Size = UDim2.new(1, 0, 0, 22)
            inputBox.Position = UDim2.new(0, 0, 0, currentY)
            inputBox.BackgroundColor3 = Color3.fromRGB(40, 40, 60)
            inputBox.BorderSizePixel = 0
            inputBox.Text = data.doorDestination or ""
            inputBox.TextColor3 = Color3.fromRGB(255, 255, 255)
            inputBox.TextSize = 12
            inputBox.Font = Enum.Font.SourceSans
            inputBox.PlaceholderText = "World name..."
            inputBox.ZIndex = 83
            inputBox.Parent = content
            currentY += 26

            -- Set destination button
            local setBtn = Instance.new("TextButton")
            setBtn.Name = "SetDoorBtn"
            setBtn.Size = UDim2.new(1, 0, 0, 22)
            setBtn.Position = UDim2.new(0, 0, 0, currentY)
            setBtn.BackgroundColor3 = Color3.fromRGB(40, 80, 120)
            setBtn.BorderSizePixel = 0
            setBtn.Text = "Set Destination"
            setBtn.TextColor3 = Color3.fromRGB(200, 220, 255)
            setBtn.TextSize = 12
            setBtn.Font = Enum.Font.SourceSansBold
            setBtn.ZIndex = 83
            setBtn.Parent = content
            setBtn.MouseButton1Click:Connect(function()
                local destName = inputBox.Text:match("^%s*(.-)%s*$") -- trim
                if destName and #destName > 0 then
                    RemoteEvents.RequestSetDoorDestination:FireServer(data.tileX, data.tileY, destName)
                    data.doorDestination = destName
                    destLabel.Text = `Dest: {destName}`
                    WrenchUI._flashFeedback("Destination set!", Color3.fromRGB(150, 255, 150))
                end
            end)
            currentY += 26
        end
    end

    // Admin management (if tile is a lock and player is owner)
    if data.lockInfo and data.lockInfo.isAdmin and data.lockInfo.isLocked then
        local adminHeader = Instance.new("TextLabel")
        adminHeader.Size = UDim2.new(1, 0, 0, 20)
        adminHeader.Position = UDim2.new(0, 0, 0, currentY)
        adminHeader.BackgroundTransparency = 1
        adminHeader.Text = "--- Admin Management ---"
        adminHeader.TextColor3 = Color3.fromRGB(200, 200, 255)
        adminHeader.TextSize = 11
        adminHeader.Font = Enum.Font.SourceSansBold
        adminHeader.TextXAlignment = Enum.TextXAlignment.Center
        adminHeader.ZIndex = 82
        adminHeader.Parent = content
        currentY += 22

        -- Add admin input
        local addAdminBox = Instance.new("TextBox")
        addAdminBox.Name = "AddAdminInput"
        addAdminBox.Size = UDim2.new(0.7, -4, 0, 22)
        addAdminBox.Position = UDim2.new(0, 0, 0, currentY)
        addAdminBox.BackgroundColor3 = Color3.fromRGB(40, 40, 60)
        addAdminBox.BorderSizePixel = 0
        addAdminBox.Text = ""
        addAdminBox.TextColor3 = Color3.fromRGB(255, 255, 255)
        addAdminBox.TextSize = 12
        addAdminBox.Font = Enum.Font.SourceSans
        addAdminBox.PlaceholderText = "UserID..."
        addAdminBox.ZIndex = 83
        addAdminBox.Parent = content

        local addAdminBtn = Instance.new("TextButton")
        addAdminBtn.Size = UDim2.new(0.3, -4, 0, 22)
        addAdminBtn.Position = UDim2.new(0.7, 4, 0, currentY)
        addAdminBtn.BackgroundColor3 = Color3.fromRGB(50, 100, 50)
        addAdminBtn.BorderSizePixel = 0
        addAdminBtn.Text = "+Add"
        addAdminBtn.TextColor3 = Color3.fromRGB(200, 255, 200)
        addAdminBtn.TextSize = 11
        addAdminBtn.Font = Enum.Font.SourceSansBold
        addAdminBtn.ZIndex = 83
        addAdminBtn.Parent = content
        addAdminBtn.MouseButton1Click:Connect(function()
            local userId = tonumber(addAdminBox.Text:match("^%s*(.-)%s*$"))
            if userId then
                RemoteEvents.RequestAddAdmin:FireServer(userId)
                addAdminBox.Text = ""
                WrenchUI._flashFeedback("Admin request sent!", Color3.fromRGB(150, 255, 150))
            end
        end)
        currentY += 26

        // Also allow removing admins - listen for WorldLockStatus updates
    end

    // Resize popup to fit content
    local finalHeight = math.max(POPUP_HEIGHT, currentY + 36)
    popup.Size = UDim2.new(0, POPUP_WIDTH, 0, finalHeight)

    // Make sure popup stays within screen bounds
    local viewportSize = workspace.CurrentCamera.ViewportSize
    if screenX + POPUP_WIDTH > viewportSize.X then
        popup.Position = UDim2.new(0, viewportSize.X - POPUP_WIDTH - 10, 0, screenY)
    end
    if screenY < 0 then
        popup.Position = UDim2.new(0, screenX, 0, 10)
    end
end

// [[
// Flash feedback label on the popup.
// ]]

function WrenchUI._flashFeedback(message: string, color: Color3)
    if not popup then return end

    local feedback = Instance.new("TextLabel")
    feedback.Name = "WrenchFeedback"
    feedback.Size = UDim2.new(1, -20, 0, 20)
    feedback.Position = UDim2.new(0, 10, 1, -24)
    feedback.BackgroundTransparency = 0.3
    feedback.BackgroundColor3 = Color3.fromRGB(0, 40, 0)
    feedback.BorderSizePixel = 0
    feedback.Text = message
    feedback.TextColor3 = color
    feedback.TextSize = 12
    feedback.Font = Enum.Font.SourceSansBold
    feedback.TextXAlignment = Enum.TextXAlignment.Center
    feedback.TextYAlignment = Enum.TextYAlignment.Center
    feedback.ZIndex = 90
    feedback.Parent = popup

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
end

// [[
// Close the wrench popup.
// ]]

local function closePopup()
    isOpen = false
    wrenchedTileX = -1
    wrenchedTileY = -1
    if popup then
        popup:Destroy()
        popup = nil
    end
end

// [[
// Check if the player has moved too far from the wrenched tile.
// Auto-close if > 3 tiles away.
// ]]

local function checkPlayerDistance()
    if not isOpen or wrenchedTileX < 0 then return end

    local now = os.clock()
    if now - lastWrenchCheckTime < 0.5 then return end
    lastWrenchCheckTime = now

    local px, py = playerController and playerController.GetTilePosition() or { -1, -1 }
    if px < 0 or py < 0 then return end

    local dx = math.abs(px - wrenchedTileX)
    local dy = math.abs(py - wrenchedTileY)

    if dx > CLOSE_DISTANCE or dy > CLOSE_DISTANCE then
        closePopup()
    end
end

// [[
// === REMOTE EVENT HANDLERS ===
// ]]

local function onWrenchData(data: {
    tileX: number,
    tileY: number,
    fg: { itemId: number, name: string, hp: number, type: number }?,
    bg: { itemId: number, name: string }?,
    treeData: { seedId: number, growthPercent: number }?,
    lockInfo: { isLocked: boolean, ownerName: string?, isAdmin: boolean }?,
    isDoor: boolean,
    doorDestination: string?,
})
    // Close any existing popup first
    if isOpen then
        closePopup()
        task.wait(0.1)
    end

    isOpen = true
    createPopup(data)
end

// [[
// === PUBLIC API ===
// ]]

// [[
// Initialize WrenchUI.
// ]]

function WrenchUI.Init()
    worldRenderer = require(script.Parent.WorldRenderer)
    playerController = require(script.Parent.PlayerController)

    -- Create ScreenGui
    screenGui = Instance.new("ScreenGui")
    screenGui.Name = "WrenchGUI"
    screenGui.ResetOnSpawn = false
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = localPlayer:WaitForChild("PlayerGui")

    -- Listen for WrenchData from server
    RemoteEvents.WrenchData.OnClientEvent:Connect(onWrenchData)

    -- Close popup when pressing E again or clicking elsewhere
    UserInputService.InputBegan:Connect(function(input: InputObject, isProcessed: boolean)
        if isProcessed then return end
        if isOpen and input.KeyCode == Enum.KeyCode.E then
            closePopup()
        end
        -- Close on any click outside the popup
        if isOpen and (input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch) then
            closePopup()
        end
    end)

    -- Check player distance every RenderStepped
    RunService.RenderStepped:Connect(function()
        checkPlayerDistance()
    end)

    print("[WrenchUI] Initialized")
end

// [[
// Clean up.
// ]]

function WrenchUI.Destroy()
    closePopup()
    if screenGui then
        screenGui:Destroy()
        screenGui = nil
    end
    print("[WrenchUI] Destroyed")
end

return WrenchUI
