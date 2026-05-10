-- InputController.lua (client)
-- Handles player input for GrowRoblox with Parts-based world.
--
-- Architecture:
--   - Keyboard input for hotbar (1-9), wrench (E), toggle inventory (Tab)
--   - Mouse click → Raycast from camera to detect which tile Part was hit
--   - Parse tileX, tileY from "Tile_{x}_{y}" Part name
--   - Reach check: distance from player to tile ≤ 4 tiles
--   - Tile highlight: semi-transparent Part on hovered tile
--   - Auto-break on left mouse hold for non-seed items
--   - Movement keys (A/D/Space) are handled by Roblox default character scripts
--   - Arm stretch: visual Part extends from character right hand toward targeted tile
--   - Hotbar keys: handled even when UI consumes the event (isProcessed=true)

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage.Shared)
local WorldConfig = Shared.WorldConfig
local ItemDatabase = Shared.ItemDatabase
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)

local InputController = {}

--[[
	===== CONSTANTS =====
]]

local SERVER_REACH = WorldConfig.PLAYER_REACH or 4      -- tiles
local BREAK_COOLDOWN = 0.3                                -- seconds between auto-break fires
local DEBOUNCE_TIME = 0.1                                 -- minimum between any remote fire
local TILE_SIZE = 4                                        -- studs per tile (matching WorldRenderer)

--[[
	===== STATE =====
]]

local localPlayer = Players.LocalPlayer

-- Equipped item tracking
local equippedItemId = 0      -- 0 = fist / no item
local equippedSlot = 1

-- Mouse state
local mouseDown = false
local leftMouseHeld = false
local rightMousePressed = false
local lastBreakFireTime = 0
local lastClickTime = 0

-- Debounce table: remoteName → lastFireTime
local debounceTable: { [string]: number } = {}

-- Mouse position (updated every frame)
local mouseX = 0
local mouseY = 0

-- Tile highlight Part (in Workspace)
local highlightPart: Part? = nil

-- Inventory cache (local mirror of equipped item)
local inventoryCache = {}      -- { [slotIndex] = { itemId, count } }

-- Door travel cooldown
local DOOR_TRAVEL_COOLDOWN = 2.0
local lastDoorTravelTime = 0

-- Module references
local worldRenderer = nil
local cameraController = nil

-- Player character reference
local character: Model? = nil
local humanoidRootPart: BasePart? = nil

-- Pending spawn position (applied when character loads)
local pendingSpawnPos: Vector3? = nil

-- Last known spawn position (persists across respawns)
local lastSpawnPos: Vector3? = nil

-- Arm stretch Part (visual extension from right hand toward targeted tile)
local armStretchPart: Part? = nil

-- Drop pickup state (instant proximity — no magnet)
local PICKUP_DISTANCE = 6         -- studs — must be this close to pick up
local pendingPickups: { [number]: boolean } = {}  -- debounce by dropId (number), not Part reference

-- Current world name (updated from PlayerSpawned) — only scan Drops_ folder matching this world
local currentWorldName: string = "START"

--[[
	===== HELPERS =====
]]

-- Debounce: don't fire the same remote within DEBOUNCE_TIME seconds
local function canFire(name: string): boolean
	local now = os.clock()
	local last = debounceTable[name]
	if last and (now - last) < DEBOUNCE_TIME then
		return false
	end
	debounceTable[name] = now
	return true
end

-- Get the player's current tile position from their character position
local function getPlayerTilePosition(): (number, number)
	if humanoidRootPart then
		local pos = humanoidRootPart.Position
		local tx = math.floor((pos.X + TILE_SIZE / 2) / TILE_SIZE)
		local ty = math.floor((-pos.Y + TILE_SIZE / 2) / TILE_SIZE)
		return tx, ty
	end
	if worldRenderer then
		return worldRenderer.GetPlayerTile()
	end
	return -1, -1
end

-- Get distance in tiles between player and a target tile
local function getTileDistance(tileX: number, tileY: number): number
	local px, py = getPlayerTilePosition()
	if px < 0 or py < 0 then return 999 end
	local dx = px - tileX
	local dy = py - tileY
	return math.sqrt(dx * dx + dy * dy)
end

-- Get the character's current world space position for spawn logic
local function getCharacterPosition(): Vector3?
	if humanoidRootPart then
		return humanoidRootPart.Position
	end
	return nil
end

--[[
	Determine the action to take based on equipped item type.
	Returns the remote event to fire and the arguments.
]]
local function getActionForEquippedItem(tileX: number, tileY: number): (RemoteEvent?, any)
	-- Fist (ID 1000) or empty slot -> BreakBlock
	if not equippedItemId or equippedItemId == 0 then
		return RemoteEvents.RequestBreakBlock, { tileX, tileY }
	end

	local item = ItemDatabase.GetItem(equippedItemId)
	if not item then
		-- Item not found in database -> do nothing
		return nil, nil
	end

	-- Other tools (Axe 1001, Wrench 1002, Scissors 1003, Shovel 1004) have type=FIST
	-- but should NOT break blocks. Only the Fist (1000) can break blocks.
	if item.type == WorldConfig.ItemTypes.FIST and equippedItemId ~= 1000 then
		-- Equipped a non-Fist tool -> do nothing on click
		return nil, nil
	end

	if item.type == WorldConfig.ItemTypes.SEED or ItemDatabase.IsSeed(equippedItemId) then
		-- Always fire RequestPlantSeed — the server handles the logic:
		--   - Empty tile → fresh plant
		--   - Tile with DIFFERENT seed → splice (via SeedService → SpliceService)
		--   - Tile with SAME seed → rejected "Already planted"
		return RemoteEvents.RequestPlantSeed, { tileX, tileY, equippedItemId }

	elseif item.type == WorldConfig.ItemTypes.FIST then
		-- Fist (ID 1000) = break block
		return RemoteEvents.RequestBreakBlock, { tileX, tileY }

	elseif item.type == WorldConfig.ItemTypes.WRENCH then
		return RemoteEvents.RequestWrenchTile, { tileX, tileY }

	elseif item.type == WorldConfig.ItemTypes.BACKGROUND or
	       item.type == WorldConfig.ItemTypes.SOLID or
	       item.type == WorldConfig.ItemTypes.PLATFORM or
	       item.type == WorldConfig.ItemTypes.DOOR or
	       item.type == WorldConfig.ItemTypes.LOCK or
	       item.type == WorldConfig.ItemTypes.SIGN or
	       item.type == WorldConfig.ItemTypes.BOOMBOX or
	       item.type == WorldConfig.ItemTypes.PORTAL or
	       item.type == WorldConfig.ItemTypes.ICE then
		return RemoteEvents.RequestPlaceBlock, { tileX, tileY, equippedItemId }

	else
		-- Unknown item type -> do nothing
		return nil, nil
	end
end

-- Parse tile coordinates from a Part name like "Tile_12_5"
local function parseTileName(name: string): (number, number, boolean)
	local prefix = "Tile_"
	if string.sub(name, 1, #prefix) ~= prefix then
		return -1, -1, false
	end
	local rest = string.sub(name, #prefix + 1)
	local underscorePos = string.find(rest, "_")
	if not underscorePos then return -1, -1, false end

	local xStr = string.sub(rest, 1, underscorePos - 1)
	local yStr = string.sub(rest, underscorePos + 1)
	local x = tonumber(xStr)
	local y = tonumber(yStr)
	if x and y then
		return x, y, true
	end
	return -1, -1, false
end

-- Raycast from mouse position to find which tile was clicked
local function raycastTile(mX: number, mY: number): (number, number, boolean)
	local camera = Workspace.CurrentCamera
	if not camera then
		return -1, -1, false
	end

	local ray = camera:ScreenPointToRay(mX, mY, 0)
	local fgParams = worldRenderer and worldRenderer.GetFgRaycastParams()
	if not fgParams then
		return -1, -1, false
	end

	local result = Workspace:Raycast(ray.Origin, ray.Direction * 500, fgParams)
	if result and result.Instance then
		local inst = result.Instance

		-- Skip barrier parts (defense-in-depth: CanQuery=false should prevent hits, but doesn't always work)
		local parentFolder = inst.Parent
		if parentFolder and parentFolder.Name == "WorldBarriers" then
			return -1, -1, false
		end

		-- Skip TempFloor (destroyed after world loads, but may still be present briefly)
		if inst.Name == "TempFloor" then
			return -1, -1, false
		end

		local tx, ty, ok = parseTileName(inst.Name)
		if ok then
			return tx, ty, true
		end
	end

	return -1, -1, false
end

-- Fire the appropriate remote for a click on (tileX, tileY)
local function handleClick(tileX: number, tileY: number)
	if tileX < 0 or tileY < 0 then
		print(`[DEBUG Click] Invalid tile ({tileX}, {tileY})`)
		return
	end

	-- Client-side reach check
	local dist = getTileDistance(tileX, tileY)
	if dist > SERVER_REACH + 2 then
		print(`[DEBUG Click] Out of reach: dist={dist} max={SERVER_REACH + 2}`)
		return
	end

	print(`[DEBUG Click] equippedItemId={equippedItemId} equippedSlot={equippedSlot} at ({tileX}, {tileY})`)
	local remote, args = getActionForEquippedItem(tileX, tileY)
	if not remote then
		print(`[DEBUG Click] No remote returned for item {equippedItemId}`)
		return
	end

	local eventKey = tostring(remote)
	print(`[DEBUG Click] Firing {eventKey} with args={args}`)

	if not canFire(eventKey) then
		print(`[DEBUG Click] Debounce blocked {eventKey}`)
		return
	end

	remote:FireServer(unpack(args))
	lastClickTime = os.clock()
	print(`[DEBUG Click] Fired successfully`)
end

-- Auto-break: if left mouse is held on a non-seed item, fire break repeatedly
local function tryAutoBreak()
	if not leftMouseHeld then return end
	if not equippedItemId or equippedItemId == 0 then
		-- Fist → auto break
	else
		local item = ItemDatabase.GetItem(equippedItemId)
		if not item then
			return
		end
		local itemType = item.type
		-- Don't auto-break when holding a placeable item (block, lock, seed)
		if itemType == WorldConfig.ItemTypes.SEED
			or itemType == WorldConfig.ItemTypes.LOCK
			or itemType == WorldConfig.ItemTypes.BACKGROUND
			or itemType == WorldConfig.ItemTypes.SOLID
			or itemType == WorldConfig.ItemTypes.PLATFORM
			or itemType == WorldConfig.ItemTypes.DOOR
			or itemType == WorldConfig.ItemTypes.SIGN
			or ItemDatabase.IsSeed(equippedItemId) then
			return
		end
	end

	local now = os.clock()
	if (now - lastBreakFireTime) < BREAK_COOLDOWN then return end

	local tileX, tileY, hit = raycastTile(mouseX, mouseY)
	if not hit or tileX < 0 or tileY < 0 then return end

	local dist = getTileDistance(tileX, tileY)
	if dist > SERVER_REACH + 2 then return end

	if not canFire("RequestBreakBlock") then return end

	RemoteEvents.RequestBreakBlock:FireServer(tileX, tileY)
	lastBreakFireTime = now
end

-- Check if the player is standing on a door tile and trigger world travel
local function checkDoorCollision()
	if not humanoidRootPart or not worldRenderer then return end

	local px, py = getPlayerTilePosition()
	if px < 0 or py < 0 then return end

	-- Check tile at player's feet position
	local tile = worldRenderer.GetTileAt(px, py)
	if not tile then
		-- Also check the tile below
		tile = worldRenderer.GetTileAt(px, py + 1)
	end
	if not tile then return end

	local fgId = tile.fg
	if not fgId or fgId <= 0 then return end

	local fgItem = ItemDatabase.GetItem(fgId)
	if not fgItem then return end

	local itemType = fgItem.type
	if itemType ~= WorldConfig.ItemTypes.DOOR and itemType ~= WorldConfig.ItemTypes.PORTAL then
		return
	end

	local now = os.clock()
	if (now - lastDoorTravelTime) < DOOR_TRAVEL_COOLDOWN then return end

	local destination = "START"
	if fgId == 6 then
		destination = "START"
	elseif tile.fgExtra and tile.fgExtra.doorDestination then
		destination = tile.fgExtra.doorDestination
	end

	lastDoorTravelTime = now
	RemoteEvents.RequestTravelWorld:FireServer(destination)
	print(`[InputController] Door travel → "{destination}"`)
end

--[[
	Update the tile highlight Part.
	Red if out of reach, white if reachable, invisible if no tile hit.
]]
local function updateTileHighlight()
	if not highlightPart or not worldRenderer then return end

	local tileX, tileY, hit = raycastTile(mouseX, mouseY)

	if not hit or tileX < 0 or tileY < 0 then
		highlightPart.Transparency = 1
		return
	end

	local dist = getTileDistance(tileX, tileY)
	local reachable = dist <= SERVER_REACH + 2

	-- Position highlight over the tile
	highlightPart.Position = Vector3.new(tileX * TILE_SIZE, -tileY * TILE_SIZE, -0.5)
	highlightPart.Transparency = 0.7

	if reachable then
		highlightPart.BrickColor = BrickColor.White()
		highlightPart.Transparency = 0.7
	else
		highlightPart.BrickColor = BrickColor.Red()
		highlightPart.Transparency = 0.6
	end
end

--[[
	Update the arm stretch Part to visually extend from the character's
	right hand toward the targeted tile.
	Creates a thin colored beam from the character's RightHand (or Right Arm)
	to the tile under the cursor.
]]
local function updateArmStretch()
	if not armStretchPart then return end

	-- Get the targeted tile position from raycast
	local tileX, tileY, hit = raycastTile(mouseX, mouseY)
	if not hit or tileX < 0 or tileY < 0 then
		armStretchPart.Transparency = 1
		return
	end

	-- Get character's right hand position
	if not character then
		armStretchPart.Transparency = 1
		return
	end

	-- Find the right hand or right arm attachment
	local rightHand = character:FindFirstChild("RightHand")
		or character:FindFirstChild("Right Arm")
		or character:FindFirstChild("RightLowerArm")
		or character:FindFirstChild("RightUpperArm")

	if not rightHand then
		-- Fallback: use humanoidRootPart position offset to the right
		if humanoidRootPart then
			local handPos = humanoidRootPart.Position + Vector3.new(2, -1, 0)
			local targetPos = Vector3.new(tileX * TILE_SIZE, -tileY * TILE_SIZE, 0)
			local midPoint = (handPos + targetPos) / 2
			local distance = (targetPos - handPos).Magnitude

			armStretchPart.Size = Vector3.new(0.3, 0.3, distance)
			armStretchPart.CFrame = CFrame.new(midPoint, targetPos)
			armStretchPart.Transparency = 0.3
		else
			armStretchPart.Transparency = 1
		end
		return
	end

	-- Use the right hand's world position
	local handPos = rightHand.Position
	local targetPos = Vector3.new(tileX * TILE_SIZE, -tileY * TILE_SIZE, 0)

	-- Calculate midpoint and distance
	local midPoint = (handPos + targetPos) / 2
	local distance = (targetPos - handPos).Magnitude

	-- Clamp minimum distance to avoid zero-size Part
	if distance < 0.5 then
		armStretchPart.Transparency = 1
		return
	end

	-- Position the arm stretch Part between hand and target
	armStretchPart.Size = Vector3.new(0.3, 0.3, distance)
	armStretchPart.CFrame = CFrame.new(midPoint, targetPos)
	armStretchPart.Transparency = 0.3
	armStretchPart.BrickColor = BrickColor.new(Color3.fromRGB(255, 200, 150))  -- Skin color
end

--[[
	Update locally cached equipped item ID from hotbar state.
]]
local function updateEquippedItem()
	local slotData = inventoryCache[equippedSlot]
	if slotData then
		equippedItemId = slotData.itemId
	else
		equippedItemId = 0
	end
end

--[[
	Update inventory cache from server event.
]]
local function onInventoryUpdated(inventoryTable: { { itemId: number, count: number }? })
	inventoryCache = {}
	for i, slot in ipairs(inventoryTable) do
		if slot then
			inventoryCache[i] = { itemId = slot.itemId, count = slot.count }
		else
			inventoryCache[i] = nil
		end
	end
	-- Sync equipped slot from Hotbar UI (clicking hotbar slots doesn't update InputController's slot)
	local Hotbar = require(script.Parent.UI.Hotbar)
	local hotbarSlot = Hotbar.GetSelectedSlot()
	if hotbarSlot and hotbarSlot ~= equippedSlot then
		equippedSlot = hotbarSlot
	end
	updateEquippedItem()
end

-- Handle character changes (respawn, world travel)
local function onCharacterAdded(newCharacter: Model)
	character = newCharacter
	humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
		or character:FindFirstChild("Torso")
		or character:FindFirstChild("UpperTorso")

	print(`[InputController] onCharacterAdded — humanoidRootPart = {humanoidRootPart}`)

	-- Update raycast filter to exclude new character
	if worldRenderer then
		worldRenderer.UpdateRaycastFilter(character)
	end

	-- If we have a pending spawn position, apply it now
	if pendingSpawnPos and humanoidRootPart then
		print(`[InputController] Applying pending spawn pos {pendingSpawnPos}`)
		humanoidRootPart.CFrame = CFrame.new(pendingSpawnPos)
		pendingSpawnPos = nil
	end

	-- Also reapply last known spawn position on every respawn (Bug 4)
	if lastSpawnPos and humanoidRootPart then
		task.wait(0.1)  -- brief wait for physics to settle
		-- Re-acquire humanoidRootPart after the wait (character may have changed)
		local hrp = newCharacter:FindFirstChild("HumanoidRootPart")
			or newCharacter:FindFirstChild("Torso")
			or newCharacter:FindFirstChild("UpperTorso")
		if hrp then
			print(`[InputController] Reapplying lastSpawnPos {lastSpawnPos} after respawn`)
			hrp.CFrame = CFrame.new(lastSpawnPos)
			humanoidRootPart = hrp
		end
	end
end

--[[
	===== INPUT EVENT HANDLERS =====
]]

local function onKeyInput(inputObject: InputObject, isProcessed: boolean): boolean
	-- NOTE: We do NOT return early on isProcessed=true for hotbar keys,
	-- because the UI (e.g., chat, inventory) may consume the event but
	-- we still want hotbar selection to work.

	local keyCode = inputObject.KeyCode
	local isDown = inputObject.UserInputState == Enum.UserInputState.Begin

	if not isDown then return false end  -- Only handle key-down actions below

	-- Hotbar slots (1-9) — handled even if UI consumed the event
	-- Compare EnumItem.Value (number) since Roblox Luau doesn't support >=/<= on EnumItems
	local kv = keyCode.Value
	if kv >= Enum.KeyCode.One.Value and kv <= Enum.KeyCode.Nine.Value then
		local slotIndex = kv - Enum.KeyCode.One.Value + 1
		equippedSlot = slotIndex
		updateEquippedItem()

		-- Update the hotbar visual highlight to match
		local Hotbar = require(script.Parent.UI.Hotbar)
		Hotbar.SetSelectedSlot(slotIndex)

		if canFire("RequestSetEquippedSlot") then
			RemoteEvents.RequestSetEquippedSlot:FireServer(slotIndex)
		end
		return true
	end

	-- If UI processed the event, don't handle non-hotbar keys
	if isProcessed then return false end

	-- Tab: toggle expandable inventory (hotbar backpack slide-up)
	if keyCode == Enum.KeyCode.Tab then
		local Hotbar = require(script.Parent.UI.Hotbar)
		Hotbar.ToggleExpand()
		return true
	end

	-- E: Wrench action on tile under cursor
	if keyCode == Enum.KeyCode.E then
		local tileX, tileY, hit = raycastTile(mouseX, mouseY)
		if hit and tileX >= 0 and tileY >= 0 then
			local dist = getTileDistance(tileX, tileY)
			if dist <= SERVER_REACH + 2 then
				if canFire("RequestWrenchTile") then
					RemoteEvents.RequestWrenchTile:FireServer(tileX, tileY)
				end
			end
		end
		return true
	end

	return false
end

local function onMouseInput(inputObject: InputObject, isProcessed: boolean): boolean
	if isProcessed then
		return false
	end

	local isDown = inputObject.UserInputState == Enum.UserInputState.Begin
	local button = inputObject.UserInputType

	-- Left click
	if button == Enum.UserInputType.MouseButton1 then
		leftMouseHeld = isDown
		if isDown then
			local tileX, tileY, hit = raycastTile(mouseX, mouseY)
			if hit then
				handleClick(tileX, tileY)
			end
		end
		return true
	end

	-- Right click → always break
	if button == Enum.UserInputType.MouseButton2 then
		if isDown then
			local tileX, tileY, hit = raycastTile(mouseX, mouseY)
			if hit and tileX >= 0 and tileY >= 0 then
				local dist = getTileDistance(tileX, tileY)
				if dist <= SERVER_REACH + 2 then
					if canFire("RequestBreakBlock") then
						RemoteEvents.RequestBreakBlock:FireServer(tileX, tileY)
					end
				end
			end
		end
		return true
	end

	return false
end

local function onTouchInput(inputObject: InputObject, isProcessed: boolean): boolean
	if isProcessed then return false end

	local touchPos = inputObject.Position
	local isDown = inputObject.UserInputState == Enum.UserInputState.Begin

	mouseX = touchPos.X
	mouseY = touchPos.Y

	if isDown then
		leftMouseHeld = true
		local tileX, tileY, hit = raycastTile(touchPos.X, touchPos.Y)
		if hit then
			handleClick(tileX, tileY)
		end
	else
		leftMouseHeld = false
	end

	return true
end

--[[
	===== PUBLIC API =====
]]

--[[
	Initialize InputController:
	- Connect keyboard/mouse/touch input events
	- Create the tile highlight Part
	- Connect to inventory updates from server
	- Watch for character changes
]]
function InputController.Init()
	worldRenderer = require(script.Parent.WorldRenderer)
	cameraController = require(script.Parent.CameraController)

	-- Get current character (may be nil if not loaded yet)
	character = localPlayer.Character
	if character then
		onCharacterAdded(character)
	else
		print("[InputController] Character not available yet, will poll in RenderStepped")
	end

	-- Watch for character changes (respawn, world travel)
	localPlayer.CharacterAdded:Connect(onCharacterAdded)

	-- Create tile highlight Part (a semi-transparent box in the workspace)
	highlightPart = Instance.new("Part")
	highlightPart.Name = "TileHighlight"
	highlightPart.Size = Vector3.new(TILE_SIZE + 0.1, TILE_SIZE + 0.1, 0.5)
	highlightPart.Anchored = true
	highlightPart.CanCollide = false
	highlightPart.CanQuery = false
	highlightPart.CastShadow = false
	highlightPart.Material = Enum.Material.SmoothPlastic
	highlightPart.Transparency = 1
	highlightPart.BrickColor = BrickColor.White()
	highlightPart.Parent = Workspace

	-- Create arm stretch Part (visual beam from right hand to targeted tile)
	armStretchPart = Instance.new("Part")
	armStretchPart.Name = "ArmStretch"
	armStretchPart.Size = Vector3.new(0.3, 0.3, 1)
	armStretchPart.Anchored = true
	armStretchPart.CanCollide = false
	armStretchPart.CanQuery = false
	armStretchPart.CastShadow = false
	armStretchPart.Material = Enum.Material.SmoothPlastic
	armStretchPart.Transparency = 1
	armStretchPart.BrickColor = BrickColor.new(Color3.fromRGB(255, 200, 150))  -- Skin color
	armStretchPart.Parent = Workspace

	-- Keyboard input
	UserInputService.InputBegan:Connect(function(inputObject: InputObject, isProcessed: boolean)
		if inputObject.UserInputType == Enum.UserInputType.Keyboard then
			onKeyInput(inputObject, isProcessed)
		elseif inputObject.UserInputType == Enum.UserInputType.MouseButton1
			or inputObject.UserInputType == Enum.UserInputType.MouseButton2 then
			onMouseInput(inputObject, isProcessed)
		elseif inputObject.UserInputType == Enum.UserInputType.Touch then
			onTouchInput(inputObject, isProcessed)
		end
	end)

	UserInputService.InputEnded:Connect(function(inputObject: InputObject, isProcessed: boolean)
		if inputObject.UserInputType == Enum.UserInputType.MouseButton1 then
			leftMouseHeld = false
		elseif inputObject.UserInputType == Enum.UserInputType.Touch then
			leftMouseHeld = false
		end
	end)

	-- Mouse movement (update cursor position)
	UserInputService.InputChanged:Connect(function(inputObject: InputObject)
		if inputObject.UserInputType == Enum.UserInputType.MouseMovement then
			mouseX = inputObject.Position.X
			mouseY = inputObject.Position.Y
		elseif inputObject.UserInputType == Enum.UserInputType.Touch then
			mouseX = inputObject.Position.X
			mouseY = inputObject.Position.Y
		end
	end)
-- Listen for inventory updates from server
RemoteEvents.InventoryUpdated.OnClientEvent:Connect(onInventoryUpdated)

-- Listen for WorldLoaded — clear pendingPickups so drops in the new world can be picked up
RemoteEvents.WorldLoaded.OnClientEvent:Connect(function(worldName: string)
	pendingPickups = {}
	print(`[InputController] Cleared pendingPickups for world change to "{worldName}"`)
end)

-- Listen for PlayerSpawned (server tells us where to spawn the character)
RemoteEvents.PlayerSpawned.OnClientEvent:Connect(function(tileX: number, tileY: number, worldName: string)
	print(`[InputController] PlayerSpawned at tile ({tileX}, {tileY}) in "{worldName}"`)
	currentWorldName = worldName

	-- Absolute spawn math:
	-- Tile (tileX, tileY) center = (tileX * TILE_SIZE, -tileY * TILE_SIZE, 0)
	-- For surface tile (50, 5): center = (200, -20, 0)
	-- Top of tile = center.Y + TILE_SIZE/2 = -20 + 2 = -18
	-- HumanoidRootPart should be ~2 studs above tile top = -18 + 2 = -16
	-- Formula: -tileY * TILE_SIZE + TILE_SIZE = -20 + 4 = -16 ✓
	local spawnPos = Vector3.new(tileX * TILE_SIZE, -tileY * TILE_SIZE + TILE_SIZE, 0)

	-- ALWAYS store the spawn position (Bug 2 + Bug 4)
	pendingSpawnPos = spawnPos
	lastSpawnPos = spawnPos

	-- If character already exists, apply immediately
	if humanoidRootPart and humanoidRootPart.Parent then
		print(`[InputController] Applying spawn pos immediately {spawnPos}`)
		humanoidRootPart.CFrame = CFrame.new(spawnPos)
		pendingSpawnPos = nil
	else
		print(`[InputController] Character not loaded, storing pending spawn pos {spawnPos}`)
	end

	-- Update WorldRenderer's player tile tracking
	if worldRenderer then
		worldRenderer.SetPlayerTile(tileX, tileY)
	end
end)

-- Update loop for auto-break, tile highlight, door collision, arm stretch, camera culling,
-- and drop pickup

	RunService.RenderStepped:Connect(function()
		tryAutoBreak()
		updateTileHighlight()
		updateArmStretch()
		checkDoorCollision()

		-- Instant pickup: only scan the Drops_ folder matching the player's current world.
		if humanoidRootPart and humanoidRootPart.Parent then
			local expectedFolderName = "Drops_" .. currentWorldName
			local folder = Workspace:FindFirstChild(expectedFolderName)
			if folder and folder:IsA("Folder") then
				for _, dropPart in ipairs(folder:GetChildren()) do
					if not dropPart:IsA("BasePart") then
						continue
					end

					-- Read dropId from IntValue
					local idValue = dropPart:FindFirstChild("DropId")
					if not idValue or not idValue:IsA("IntValue") then
						continue
					end
					local dropId = idValue.Value

					-- Debounce by dropId
					if pendingPickups[dropId] then
						continue
					end

					local distance = (humanoidRootPart.Position - dropPart.Position).Magnitude
					if distance <= PICKUP_DISTANCE then
						pendingPickups[dropId] = true
						RemoteEvents.RequestPickupDrop:FireServer(dropId)
						print(`[InputController] Pickup: dropId={dropId} ({math.floor(distance * 10) / 10} studs) world="{currentWorldName}"`)
					end
				end
			end
		end

		-- Clean up stale pendingPickups entries (drops destroyed after pickup — DropDestroyed fires from server)

		-- Ensure we have a valid humanoidRootPart reference
		-- (character may have loaded after Init, or been re-created after falling)
		if not humanoidRootPart or not humanoidRootPart.Parent then
			local currentChar = localPlayer.Character
			if currentChar then
				character = currentChar
				humanoidRootPart = currentChar:FindFirstChild("HumanoidRootPart")
					or currentChar:FindFirstChild("Torso")
					or currentChar:FindFirstChild("UpperTorso")
				if humanoidRootPart then
					print(`[InputController] Acquired humanoidRootPart via RenderStepped poll`)
					-- Update raycast filter for new character
					if worldRenderer then
						worldRenderer.UpdateRaycastFilter(currentChar)
					end
				end
			end
		end

		-- If we have a pending spawn position, apply it as soon as we have a valid root part
		if pendingSpawnPos and humanoidRootPart and humanoidRootPart.Parent then
			print(`[InputController] Applying pending spawn pos {pendingSpawnPos} via RenderStepped`)
			humanoidRootPart.CFrame = CFrame.new(pendingSpawnPos)
			pendingSpawnPos = nil
		end

		-- Notify WorldRenderer of camera center for viewport culling
		local px, py = getPlayerTilePosition()
		if px >= 0 and py >= 0 and worldRenderer then
			worldRenderer.SetCameraCenter(px, py)
		end
	end)

	-- Apply pending world travel from cross-server teleport
	if _G.pendingWorldTravel then
		local targetWorld = _G.pendingWorldTravel
		print(`[InputController] Applying pending world travel: {targetWorld}`)
		task.wait(2)
		RemoteEvents.RequestTravelWorld:FireServer(targetWorld)
		_G.pendingWorldTravel = nil
	end

	print("[InputController] Initialized — raycast-based input")
end

--[[
	Get the currently equipped item ID (0 = fist/none).
]]
function InputController.GetEquippedItemId(): number
	return equippedItemId
end

--[[
	Set the equipped item ID externally (e.g., from HotbarUI).
]]
function InputController.SetEquippedItemId(itemId: number)
	equippedItemId = itemId
end

--[[
	Set the equipped slot index externally.
]]
function InputController.SetEquippedSlot(slotIndex: number)
	equippedSlot = math.clamp(slotIndex, 1, 9)
	updateEquippedItem()
end

--[[
	Update the inventory cache with latest data from server/UI.
]]
function InputController.SetInventorySlot(slotIndex: number, itemId: number, count: number)
	inventoryCache[slotIndex] = { itemId = itemId, count = count }
	if slotIndex == equippedSlot then
		updateEquippedItem()
	end
end

--[[
	Clean up resources.
]]
function InputController.Destroy()
	if highlightPart then
		highlightPart:Destroy()
		highlightPart = nil
	end
	if armStretchPart then
		armStretchPart:Destroy()
		armStretchPart = nil
	end
	print("[InputController] Destroyed")
end

return InputController
