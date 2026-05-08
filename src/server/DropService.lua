--!strict
-- DropService.lua
-- Server-side physical world drop system.
-- When a block is broken or a tree is harvested, items appear as 2D sprites
-- resting on the nearest solid tile below. No native physics — the server's
-- Workspace is empty (tiles are client-rendered), so we use math-based gravity.
-- Drops are scoped per-world (Workspace.Drops_{WorldName}) and persisted in
-- worldData.drops for cross-restart durability (enabling "Drop Rooms").
-- The client picks up via instant proximity (no magnet), then fires
-- RequestPickupDrop to claim them server-side.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local PhysicsService = game:GetService("PhysicsService")

local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
local PlayerManager = require(script.Parent.PlayerManager)
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local ItemDatabase = require(ReplicatedStorage.Shared.ItemDatabase)

local DropService = {}

-- Drop folder name prefix — each world gets Workspace.Drops_{worldName}
local DROPS_FOLDER_PREFIX = "Drops_"

-- Maximum distance (in studs) a player can be from a drop to pick it up.
-- Set to 12 to provide network tolerance padding: the client triggers at 6 studs,
-- but by the time the server receives the RemoteEvent, the player may have moved
-- or the server's authoritative position may lag behind due to ping.
local PICKUP_RADIUS = 12

-- Unique ID counter for drops within this server session
local dropIdCounter = 0

--[[
	Get (or create) the world-scoped drop folder for a given world name.
	e.g., Workspace.Drops_MAIN
]]
local function getWorldDropFolder(worldName: string): Folder
	local folderName = DROPS_FOLDER_PREFIX .. worldName
	local folder = Workspace:FindFirstChild(folderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = folderName
		folder.Parent = Workspace
	end
	return folder
end

--[[
	Find the Y-coordinate of the first solid tile below (tileX, startTileY).
	Searches downward through worldData.tiles. If no solid tile is found,
	returns startTileY (drop sits at the broken/harvested tile itself).

	A tile is considered "solid" if its foreground (fg) > 0.

	@param worldData: table — the world data containing the tile grid
	@param tileX: number — column to search
	@param startTileY: number — starting row (the broken/harvested tile)
	@return number — the tile Y of the surface to rest on
]]
local function findSurfaceY(worldData: table, tileX: number, startTileY: number): number
	if not worldData or not worldData.tiles then
		return startTileY
	end

	local width = WorldConfig.WORLD_WIDTH
	local height = WorldConfig.WORLD_HEIGHT

	-- Search downward from the tile below startTileY
	for y = startTileY + 1, height - 1 do
		local tileIndex = tileX + y * width + 1
		local tile = worldData.tiles[tileIndex]
		if tile and tile.fg and tile.fg > 0 then
			-- Found a solid tile — rest on top of it (tile y - 1)
			return y - 1
		end
	end

	-- No solid tile found below; rest at the bottom of the world
	return height - 1
end

--[[
	Spawn a 2D sprite drop Part in the world using math-based gravity.
	Persists the drop metadata into worldData.drops so it survives restarts.

	Since the server's Workspace has no physical tiles (they are rendered
	client-side by WorldRenderer.lua), we cannot rely on native Roblox gravity.
	Instead, we scan worldData.tiles downward from the broken tile to find
	the nearest solid surface, then place the drop anchored at that position.

	The Part is invisible (Transparency = 1) and carries a BillboardGui with
	an ImageLabel for the 2D sprite visual. The client sees this as a floating
	item icon above the tile.

	@param itemId: number — the item ID to drop
	@param count: number — how many of this item
	@param worldData: table — the world data (for surface-finding and persistence)
	@param tileX: number — the tile column where the block was broken
	@param tileY: number — the tile row where the block was broken
]]
function DropService.SpawnDrop(itemId: number, count: number, worldData: table, tileX: number, tileY: number)
	local worldName = worldData.name or "MAIN"
	local folder = getWorldDropFolder(worldName)

	-- Ensure the worldData.drops array exists
	worldData.drops = worldData.drops or {}

	-- Math-based gravity: find the surface tile below the break point
	local surfaceY = findSurfaceY(worldData, tileX, tileY)

	-- Calculate the resting position on top of the surface tile
	-- Tile center: X = tileX * TILE_SIZE_STUDS, Y = -surfaceY * TILE_SIZE_STUDS
	-- Add a small random X-offset so multiple drops don't stack perfectly
	local xOffset = math.random(-8, 8) / 10 -- -0.8 to 0.8 studs
	local restingPosition = Vector3.new(
		tileX * WorldConfig.TILE_SIZE_STUDS + xOffset,
		-surfaceY * WorldConfig.TILE_SIZE_STUDS,
		0
	)

	-- Generate a unique ID for this drop
	dropIdCounter += 1
	local dropId = dropIdCounter

	-- Create the invisible anchor Part
	local part = Instance.new("Part")
	part.Name = `Drop_{itemId}`
	part.Size = Vector3.new(1, 1, 0.2)
	part.CFrame = CFrame.new(restingPosition)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CanTouch = false
	part.Transparency = 1

	-- Assign to "Drops" collision group (still useful for query filtering)
	PhysicsService:SetPartCollisionGroup(part, "Drops")

	-- Store item data as IntValues
	local itemIdValue = Instance.new("IntValue")
	itemIdValue.Name = "DropItemId"
	itemIdValue.Value = itemId
	itemIdValue.Parent = part

	local countValue = Instance.new("IntValue")
	countValue.Name = "DropCount"
	countValue.Value = count
	countValue.Parent = part

	-- Store the unique drop ID for worldData.drops lookup
	local idValue = Instance.new("IntValue")
	idValue.Name = "DropId"
	idValue.Value = dropId
	idValue.Parent = part

	-- BillboardGui for the 2D sprite visual
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DropSprite"
	billboard.Size = UDim2.new(0, 28, 0, 28)     -- 28x28 pixels (small icon)
	billboard.StudsOffset = Vector3.new(0, 1.2, 0) -- float above the tile
	billboard.AlwaysOnTop = true
	billboard.Parent = part

	local image = Instance.new("ImageLabel")
	image.Name = "ItemIcon"
	image.Size = UDim2.new(1, 0, 1, 0)
	image.ResampleMode = Enum.ResamplerMode.Pixelated
	image.Image = "" -- Leave blank for now; map item textures later

	-- Use item color so the drop is visible even without a texture
	local itemDef = ItemDatabase.GetItem(itemId) or ItemDatabase.GetSeed(itemId)
	if itemDef then
		image.BackgroundColor3 = itemDef.color
		image.BackgroundTransparency = 0
	else
		image.BackgroundTransparency = 1
	end

	image.Parent = billboard

	part.Parent = folder

	-- Persist the drop metadata
	local dropEntry = {
		id = dropId,
		itemId = itemId,
		count = count,
		tileX = tileX,
		surfaceY = surfaceY,
		xOffset = xOffset,
	}
	table.insert(worldData.drops, dropEntry)
end

--[[
	Respawn physical drop Parts from saved worldData.drops data.
	Called when a world is loaded from DataStore (after a server restart).

	@param worldName: string — the world name
	@param worldData: table — the world data containing the drops array
]]
function DropService.LoadSavedDrops(worldName: string, worldData: table)
	if not worldData.drops or #worldData.drops == 0 then
		return
	end

	local folder = getWorldDropFolder(worldName)

	for _, entry in ipairs(worldData.drops) do
		local restingPosition = Vector3.new(
			entry.tileX * WorldConfig.TILE_SIZE_STUDS + (entry.xOffset or 0),
			-entry.surfaceY * WorldConfig.TILE_SIZE_STUDS,
			0
		)

		local part = Instance.new("Part")
		part.Name = `Drop_{entry.itemId}`
		part.Size = Vector3.new(1, 1, 0.2)
		part.CFrame = CFrame.new(restingPosition)
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = true
		part.CanTouch = false
		part.Transparency = 1

		PhysicsService:SetPartCollisionGroup(part, "Drops")

		local itemIdValue = Instance.new("IntValue")
		itemIdValue.Name = "DropItemId"
		itemIdValue.Value = entry.itemId
		itemIdValue.Parent = part

		local countValue = Instance.new("IntValue")
		countValue.Name = "DropCount"
		countValue.Value = entry.count
		countValue.Parent = part

		local idValue = Instance.new("IntValue")
		idValue.Name = "DropId"
		idValue.Value = entry.id
		idValue.Parent = part

		local billboard = Instance.new("BillboardGui")
		billboard.Name = "DropSprite"
		billboard.Size = UDim2.new(0, 28, 0, 28)     -- 28x28 pixels (small icon)
		billboard.StudsOffset = Vector3.new(0, 1.2, 0) -- float above the tile
		billboard.AlwaysOnTop = true
		billboard.Parent = part

		local image = Instance.new("ImageLabel")
		image.Name = "ItemIcon"
		image.Size = UDim2.new(1, 0, 1, 0)
		image.ResampleMode = Enum.ResamplerMode.Pixelated
		image.Image = ""

		-- Use item color so the drop is visible even without a texture
		local itemDef = ItemDatabase.GetItem(entry.itemId) or ItemDatabase.GetSeed(entry.itemId)
		if itemDef then
			image.BackgroundColor3 = itemDef.color
			image.BackgroundTransparency = 0
		else
			image.BackgroundTransparency = 1
		end

		image.Parent = billboard

		part.Parent = folder
	end

	print(`[DropService] Respawned {#worldData.drops} saved drops for "{worldName}"`)
end

--[[
	Handle a client's request to pick up a physical drop.

	Validates:
	1. The drop Part still exists and is a valid drop
	2. The player's character is within PICKUP_RADIUS studs of the drop
	3. The drop has valid itemId/count IntValues

	On success: destroys the Part, removes from worldData.drops by ID,
	adds items to player inventory, fires InventoryUpdated to the player.

	@param player: Player — the player requesting pickup
	@param dropPart: Instance — the drop Part to pick up
]]
local function onRequestPickupDrop(player: Player, dropPart: Instance)
	-- DEBUG: Trace entry
	print(`[DropService] onRequestPickupDrop called by {player.Name} for {dropPart}`)

	-- 1. Validate player
	if not player or not player.UserId then
		warn("[DropService] REJECTED: invalid player")
		return
	end
	print(`[DropService] DEBUG player={player.Name} userId={player.UserId}`)

	-- 2. Validate the drop Part still exists and is in a Drops_* folder
	if not dropPart or not dropPart.Parent then
		warn(`[DropService] REJECTED: dropPart already destroyed or has no parent`)
		return
	end

	local parentFolder = dropPart.Parent
	local folderName = parentFolder.Name
	print(`[DropService] DEBUG folderName="{folderName}"`)
	if not string.match(folderName, "^Drops_") then
		warn(`[DropService] REJECTED: not in a Drops_* folder (got "{folderName}")`)
		return
	end

	-- Parse world name from folder name ("Drops_MAIN" -> "MAIN")
	local worldName = string.sub(folderName, 7)
	print(`[DropService] DEBUG parsed worldName="{worldName}"`)

	-- 3. Read item data from IntValues
	local itemIdValue = dropPart:FindFirstChild("DropItemId")
	local countValue = dropPart:FindFirstChild("DropCount")
	local idValue = dropPart:FindFirstChild("DropId")
	if not itemIdValue or not countValue or not idValue then
		warn(`[DropService] REJECTED: Drop Part missing IntValues (itemId={itemIdValue}, count={countValue}, id={idValue})`)
		return
	end

	local itemId = itemIdValue.Value
	local count = countValue.Value
	local dropId = idValue.Value
	print(`[DropService] DEBUG itemId={itemId} count={count} dropId={dropId}`)
	if itemId <= 0 or count <= 0 then
		warn(`[DropService] REJECTED: invalid itemId={itemId} count={count}`)
		return
	end

	-- 4. Validate distance: player's character must be within PICKUP_RADIUS studs
	local character = player.Character
	if not character then
		warn(`[DropService] REJECTED: player has no character`)
		return
	end

	local humanoidRootPart = character:FindFirstChild("HumanoidRootPart")
	if not humanoidRootPart then
		warn(`[DropService] REJECTED: character has no HumanoidRootPart`)
		return
	end

	local distance = (humanoidRootPart.Position - dropPart.Position).Magnitude
	print(`[DropService] DEBUG distance={distance} (max {PICKUP_RADIUS})`)
	if distance > PICKUP_RADIUS then
		warn(`[DropService] REJECTED: {player.Name} too far ({distance} > {PICKUP_RADIUS})`)
		return
	end

	-- 5. Destroy the drop Part (prevent double-pickup)
	print(`[DropService] PICKUP SUCCESS — destroying drop {dropPart.Name} (dropId={dropId})`)
	dropPart:Destroy()

	-- 6. Remove the drop from worldData.drops (if the world is still loaded)
	local WorldService = require(script.Parent.WorldService)
	local worldData = WorldService.GetCachedWorld(worldName)
	if worldData and worldData.drops then
		for i, entry in ipairs(worldData.drops) do
			if entry.id == dropId then
				table.remove(worldData.drops, i)
				print(`[DropService] Removed dropId={dropId} from worldData.drops[{i}]`)
				break
			end
		end
	else
		warn(`[DropService] Could not find worldData for "{worldName}" to remove dropId={dropId}`)
	end

	-- 7. Add items to player inventory
	local success = PlayerManager.AddItem(player, itemId, count)
	if not success then
		warn(`[DropService] Failed to add item {itemId} x{count} to {player.Name}'s inventory (full?)`)
	else
		print(`[DropService] Added item {itemId} x{count} to {player.Name}`)
	end

	-- 8. Send updated inventory to the player
	local InventoryService = require(script.Parent.InventoryService)
	PlayerManager.FireToPlayer(player, "InventoryUpdated", InventoryService.GetInventory(player))
	print(`[DropService] Sent InventoryUpdated to {player.Name}`)
end

--[[
	Initialize DropService: wire up the RequestPickupDrop listener.
]]
function DropService.Init()
	RemoteEvents.RequestPickupDrop.OnServerEvent:Connect(onRequestPickupDrop)
	print("[DropService] Initialized")
end

return DropService
