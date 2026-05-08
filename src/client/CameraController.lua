-- CameraController.lua (client)
-- Side-scrolling fixed-angle camera for GrowRoblox
-- Follows the character's X and Y position, locked to a 2D plane view

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local CameraController = {}

--[[
    ===== CONSTANTS =====
]]


local WORLD_WIDTH = 100            -- Matches WorldConfig
local WORLD_HEIGHT = 60            -- Matches WorldConfig
local TILE_SIZE = 4                -- Matches WorldConfig
local WORLD_WIDTH_STUDS = WORLD_WIDTH * TILE_SIZE
local WORLD_HEIGHT_STUDS = WORLD_HEIGHT * TILE_SIZE

local DEFAULT_ZOOM = 28        -- default Z distance
local MIN_ZOOM = 20            -- closest zoom (no first person)
local MAX_ZOOM = 50            -- farthest zoom
local ZOOM_STEP = 3            -- scroll wheel zoom increment
local LERP_FACTOR = 0.15       -- camera smoothing (0.01 = very slow, 1 = instant snap)
local SNAP_DISTANCE = 50       -- if camera is this far from target, snap instantly instead of lerping
local FIELD_OF_VIEW = 60
local CAMERA_Y_OFFSET = 0      -- How many studs above the root part the camera should aim
--[[
    ===== STATE =====
]]

local localPlayer = Players.LocalPlayer
local camera = Workspace.CurrentCamera

-- Current zoom level (Z distance from world plane)
local currentZoom = DEFAULT_ZOOM

-- Touch pinch tracking
local pinchStartZoom = DEFAULT_ZOOM

--[[
    ===== PUBLIC API =====
]]

function CameraController.Init()
	if not camera then
		camera = Workspace.CurrentCamera
	end

	-- RenderStepped: update camera position every frame
	RunService.RenderStepped:Connect(function()
		CameraController.UpdateCamera()
	end)

	-- Scroll wheel zoom (desktop)
	UserInputService.InputChanged:Connect(function(inputObject: InputObject)
		if inputObject.UserInputType == Enum.UserInputType.MouseWheel then
			local scrollDelta = inputObject.Position.Z
			if scrollDelta > 0 then
				currentZoom = math.max(MIN_ZOOM, currentZoom - ZOOM_STEP)
			elseif scrollDelta < 0 then
				currentZoom = math.min(MAX_ZOOM, currentZoom + ZOOM_STEP)
			end
		end
	end)

	-- Track pinch gesture start to lock the base zoom
	UserInputService.TouchStarted:Connect(function(inputObject: InputObject, isProcessed: boolean)
		if isProcessed then return end
		pinchStartZoom = currentZoom
	end)

	-- Pinch zoom (mobile touch)
	UserInputService.TouchPinch:Connect(function(touchPositions: { Vector3 }, scale: number)
		-- Calculate the new target zoom based on the starting zoom of the gesture
		local targetZoom = pinchStartZoom * (1 / scale)
		currentZoom = math.clamp(targetZoom, MIN_ZOOM, MAX_ZOOM)
	end)

	print("[CameraController] Initialized with zoom range", MIN_ZOOM, "-", MAX_ZOOM)
end

function CameraController.UpdateCamera()
	if not camera then
		camera = Workspace.CurrentCamera
		if not camera then return end
	end

	local character = localPlayer.Character
	if not character then return end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
		or character:FindFirstChild("Torso")
		or character:FindFirstChild("UpperTorso")
	if not rootPart then return end

	if camera.CameraType ~= Enum.CameraType.Scriptable then
		camera.CameraType = Enum.CameraType.Scriptable
	end

	-- 1. Calculate how much of the world the camera can currently see
	local viewportSize = camera.ViewportSize
	local aspectRatio = viewportSize.X / viewportSize.Y

	-- Trigonometry to find the visible height and width at the current Z-depth
	local halfFOV = math.rad(FIELD_OF_VIEW) / 2
	local visibleHeight = 2 * math.tan(halfFOV) * currentZoom
	local visibleWidth = visibleHeight * aspectRatio

	local halfWidth = visibleWidth / 2
	local halfHeight = visibleHeight / 2

	-- 2. Calculate the safe boundaries (pushing the edges inward by half the screen size)
	local minX = halfWidth
	local maxX = WORLD_WIDTH_STUDS - halfWidth

	-- Note: Your Y coordinates go into the negatives (0 is top, -240 is bottom)
	-- math.clamp requires the first bound to be the smaller number
	local minY = -WORLD_HEIGHT_STUDS + halfHeight
	local maxY = 0 - halfHeight

	-- 3. Clamp the player's position to these safe boundaries
    local targetX = rootPart.Position.X
    local targetY = rootPart.Position.Y + CAMERA_Y_OFFSET

    -- Safety check: If the user zooms out so far that the screen is bigger than the whole map,
    -- center the camera instead of letting the clamp error out.
    if minX > maxX then
        targetX = WORLD_WIDTH_STUDS / 2
    else
        targetX = math.clamp(targetX, minX, maxX)
    end

    if minY > maxY then
        targetY = -WORLD_HEIGHT_STUDS / 2
    else
        targetY = math.clamp(targetY, minY, maxY)
    end

	-- 4. Apply the clamped position
	local targetCamPos = Vector3.new(targetX, targetY, currentZoom)
	local targetLookPos = Vector3.new(targetX, targetY, 0)
	local targetCFrame = CFrame.new(targetCamPos, targetLookPos)

	if (camera.CFrame.Position - targetCamPos).Magnitude > SNAP_DISTANCE then
		camera.CFrame = targetCFrame
	else
		camera.CFrame = camera.CFrame:Lerp(targetCFrame, LERP_FACTOR)
	end

	camera.FieldOfView = FIELD_OF_VIEW
end

function CameraController.GetZoom(): number
	return currentZoom
end

function CameraController.SetZoom(zoom: number)
	currentZoom = math.clamp(zoom, MIN_ZOOM, MAX_ZOOM)
end

function CameraController.Destroy()
	print("[CameraController] Destroyed")
end

return CameraController