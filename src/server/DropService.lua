--!strict
-- DropService.lua
-- Server-side authoritative drop system.
-- Drops are stored in worldData.drops[] (source of truth).
-- Workspace Drops_{WORLDNAME} folders are visual representations only.
-- Uses remotes: DropSpawned, DropDestroyed, WorldDropsLoaded, RequestPickupDrop

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local PhysicsService = game:GetService("PhysicsService")

local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)
local PlayerManager = require(script.Parent.PlayerManager)
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)
local ItemDatabase = require(ReplicatedStorage.Shared.ItemDatabase)

local DropService = {}

local DROPS_FOLDER_PREFIX = "Drops_"
local PICKUP_RADIUS = 12

-- Unique global counter — never resets within server session
local dropIdCounter = 0

--[[
	Get or create the world-scoped drop folder.
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
	Create a visual Part for a drop. Always uses worldName; never hardcodes "MAIN".
]]
local function createDropPart(entry: table): Part
	local TILE_SIZE = WorldConfig.TILE_SIZE_STUDS
	if not TILE_SIZE then
		warn("[DropService] WorldConfig.TILE_SIZE_STUDS is nil — falling back to 4")
		TILE_SIZE = 4
	end
	local worldName = string.upper(entry.worldName or "UNKNOWN")
	local xOffset = entry.xOffset or 0
	local tileX = entry.tileX or 0
	local tileY = entry.tileY or 0

	local restingPosition = Vector3.new(
		tileX * TILE_SIZE + xOffset,
		-tileY * TILE_SIZE,
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
	billboard.Size = UDim2.new(0, 28, 0, 28)
	billboard.StudsOffset = Vector3.new(0, 1.2, 0)
	billboard.AlwaysOnTop = true
	billboard.Parent = part

	local image = Instance.new("ImageLabel")
	image.Name = "ItemIcon"
	image.Size = UDim2.new(1, 0, 1, 0)
	image.ResampleMode = Enum.ResamplerMode.Pixelated
	image.Image = ""

	local itemDef = ItemDatabase.GetItem(entry.itemId) or ItemDatabase.GetSeed(entry.itemId)
	if itemDef then
		image.BackgroundColor3 = itemDef.color
		image.BackgroundTransparency = 0
	else
		image.BackgroundTransparency = 1
	end

	image.Parent = billboard
	part.Parent = getWorldDropFolder(worldName)
	return part
end

--[[
	Spawn a drop in the world.
	- Adds entry to worldData.drops[]
	- Creates visual Part in Workspace.Drops_{WORLDNAME}
	- Fires DropSpawned to ALL players in that world
]]
function DropService.SpawnDrop(itemId: number, count: number, worldData: table, tileX: number, tileY: number)
	local tileSize = WorldConfig.TILE_SIZE_STUDS
	if not tileSize then
		warn("[DropService] WorldConfig.TILE_SIZE_STUDS is nil — falling back to 4")
		tileSize = 4
	end
	local worldName = string.upper(worldData.name or "MAIN")
	print(`[DropService] SpawnDrop tileSize={tileSize} itemId={itemId}`)
	print(`[DropService] SpawnDrop: itemId={itemId}x{count} at ({tileX},{tileY}) world="{worldName}"`)

	worldData.drops = worldData.drops or {}

	dropIdCounter += 1
	local xOffset = math.random(-8, 8) / 10

	local dropEntry = {
		id = dropIdCounter,
		itemId = itemId,
		count = count,
		worldName = worldName,
		tileX = tileX,
		tileY = tileY,
		xOffset = xOffset,
	}

	table.insert(worldData.drops, dropEntry)

	-- Create visual Part
	createDropPart(dropEntry)

	-- Broadcast to all players in the world
	PlayerManager.BroadcastToWorld(worldName, "DropSpawned", dropEntry)

	print(`[DropService] Drop #{dropEntry.id} spawned — worldData.drops now has {#worldData.drops} entries`)
end

--[[
	Load saved drops from worldData.drops on world load.
	Creates Parts for all persisted drops.
]]
function DropService.LoadSavedDrops(worldName: string, worldData: table)
	local tileSize = WorldConfig.TILE_SIZE_STUDS
	if not tileSize then
		warn("[DropService] WorldConfig.TILE_SIZE_STUDS is nil — falling back to 4")
		tileSize = 4
	end
	if not worldData.drops or #worldData.drops == 0 then
		return
	end

	for _, entry in ipairs(worldData.drops) do
		entry.worldName = entry.worldName or string.upper(worldName)
		createDropPart(entry)
	end

	print(`[DropService] Respawned {#worldData.drops} saved drops for "{worldName}"`)
end

--[[
	Handle pickup request. Client sends dropId (number), NOT a Part reference.
]]
local function onRequestPickupDrop(player: Player, dropId: number)
	print(`[DropService] Pickup request: {player.Name} wants dropId={dropId}`)

	-- Validate player
	if not player or not player.UserId then
		print("[DropService] Pickup REJECTED: invalid player")
		return
	end

	-- Validate dropId
	if type(dropId) ~= "number" or dropId <= 0 then
		print(`[DropService] Pickup REJECTED: invalid dropId={dropId}`)
		return
	end

	-- Find the drop in worldData.drops
	local playerWorld = PlayerManager.GetPlayerWorld(player)
	if not playerWorld then
		print("[DropService] Pickup REJECTED: player not in any world")
		return
	end
	playerWorld = string.upper(playerWorld)

	-- Find the drop entry
	local WorldService = require(script.Parent.WorldService)
	local worldData = WorldService.GetCachedWorld(playerWorld)
	if not worldData or not worldData.drops then
		print(`[DropService] Pickup REJECTED: no drops data for world "{playerWorld}"`)
		return
	end

	local dropEntry = nil
	local dropIndex = nil
	for i, entry in ipairs(worldData.drops) do
		if entry.id == dropId then
			dropEntry = entry
			dropIndex = i
			break
		end
	end

	if not dropEntry then
		print(`[DropService] Pickup REJECTED: dropId={dropId} not found in world "{playerWorld}" (may be from a different world)`)
		return
	end

	-- Nil guard: drop entry must have valid position data
	if not dropEntry.tileX or not dropEntry.tileY then
		print(`[DropService] Pickup REJECTED: drop #{dropId} missing position data (tileX={dropEntry.tileX}, tileY={dropEntry.tileY})`)
		return
	end

	-- Validate world match
	if string.upper(dropEntry.worldName or "") ~= playerWorld then
		print(`[DropService] Pickup REJECTED: drop world "{dropEntry.worldName}" != player world "{playerWorld}"`)
		return
	end

	-- Validate distance (best-effort)
	local character = player.Character
	if character then
		local hrp = character:FindFirstChild("HumanoidRootPart")
		if hrp then
			local tileSize = WorldConfig.TILE_SIZE_STUDS
			if not tileSize then
				warn("[DropService] WorldConfig.TILE_SIZE_STUDS is nil — falling back to 4")
				tileSize = 4
			end
			local dropPosX = dropEntry.tileX * tileSize + (dropEntry.xOffset or 0)
			local dropPosY = -dropEntry.tileY * tileSize
			local distance = math.sqrt((hrp.Position.X - dropPosX)^2 + (hrp.Position.Y - dropPosY)^2)
			print(`[DropService] Distance check: {math.floor(distance)} studs (threshold {PICKUP_RADIUS})`)
			if distance > PICKUP_RADIUS then
				print(`[DropService] Pickup REJECTED: too far ({math.floor(distance)} > {PICKUP_RADIUS})`)
				return
			end
		end
	end

	-- Remove from source of truth
	table.remove(worldData.drops, dropIndex)
	worldData.updatedAt = os.time()
	print(`[DropService] Removed drop #{dropEntry.id} from worldData.drops`)

	-- Destroy visual Part
	local folderName = "Drops_" .. playerWorld
	local folder = Workspace:FindFirstChild(folderName)
	if folder then
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("BasePart") then
				local idValue = child:FindFirstChild("DropId")
				if idValue and idValue:IsA("IntValue") and idValue.Value == dropId then
					child:Destroy()
					print(`[DropService] Destroyed visual Part for drop #{dropId}`)
					break
				end
			end
		end
	end

	-- Broadcast destruction to all players in world
	PlayerManager.BroadcastToWorld(playerWorld, "DropDestroyed", dropId)

	-- Add items to player inventory
	local success = PlayerManager.AddItem(player, dropEntry.itemId, dropEntry.count)
	if success then
		print(`[DropService] Added {dropEntry.itemId}x{dropEntry.count} to {player.Name}`)
	else
		print(`[DropService] Inventory full — {player.Name} could not take {dropEntry.itemId}x{dropEntry.count}`)
	end

	-- Send updated inventory
	local InventoryService = require(script.Parent.InventoryService)
	PlayerManager.FireToPlayer(player, "InventoryUpdated", InventoryService.GetInventory(player))
end

--[[
	Clear all drops for a world (server-side + visual Parts).
	Called when the world is fully unloaded.
]]
function DropService.ClearWorldDrops(worldName: string)
	local upperName = string.upper(worldName)
	print(`[DropService] Clearing all drops for world "{upperName}"`)

	local folderName = "Drops_" .. upperName
	local folder = Workspace:FindFirstChild(folderName)
	if folder then
		local count = 0
		for _, child in ipairs(folder:GetChildren()) do
			if child:IsA("BasePart") then
				child:Destroy()
				count += 1
			end
		end
		folder:Destroy()
		print(`[DropService] Destroyed {count} visual drop Parts for "{upperName}"`)
	end

	-- Also clear from worldData.drops
	local WorldService = require(script.Parent.WorldService)
	local worldData = WorldService.GetCachedWorld(upperName)
	if worldData and worldData.drops then
		local count = #worldData.drops
		worldData.drops = {}
		print(`[DropService] Cleared {count} entries from worldData.drops[{upperName}]`)
	end
end

--[[
	Initialize DropService.
]]
function DropService.Init()
	-- Client → Server: pickup by dropId number
	RemoteEvents.RequestPickupDrop.OnServerEvent:Connect(onRequestPickupDrop)
	print("[DropService] Initialized (dropId-based pickup)")
end

return DropService
