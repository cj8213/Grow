--!strict
-- LockService.lua
-- Server-side world lock and small lock management
-- Validates player permissions for block modification

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)

local LockService = {}

--[[
	Small lock region definition:
	{
		x = number,       -- top-left corner X
		y = number,       -- top-left corner Y
		width = number,   -- width in tiles (default 10)
		height = number,  -- height in tiles (default 10)
		owner = userId,   -- player who placed it
		admins = { userId... },  -- players with access
	}
]]

local SMALL_LOCK_SIZE = 10 -- default width/height of a small lock region

-- Permanent admin user IDs — these players can modify any tile in any world
local PERMANENT_ADMINS: { [number]: boolean } = {
	[1424887141] = true, -- User's Roblox ID
}

--[[
	Check if a player can modify a specific tile in a world.
	Returns true if the player is:
	- A permanent admin (bypasses all lock checks)
	- The world lock owner
	- An admin of the world lock
	- Not in a locked region at all
	- An admin of the small lock covering this tile
	- The owner of the small lock covering this tile

	@param player: Player — the player attempting the action
	@param worldData: table — the world data containing lock info
	@param tileX: number — tile X coordinate
	@param tileY: number — tile Y coordinate
	@return boolean — true if the player can modify the tile
]]
function LockService.CanModify(player: Player, worldData: table, tileX: number, tileY: number): boolean
	-- Input validation: bounds check the tile coordinates
	if not WorldConfig.IsValidPosition(tileX, tileY) then
		return false
	end

	-- Validate player
	if not player or not player.UserId then
		return false
	end

	-- Permanent admin bypass: these players can modify any tile in any world
	if PERMANENT_ADMINS[player.UserId] then
		return true
	end

	-- Check if the world is locked at all
	local isWorldLocked, lockOwner = LockService.IsWorldLocked(worldData)
	if not isWorldLocked then
		-- World is public — check small locks only
		return LockService._canModifySmallLock(player, worldData, tileX, tileY)
	end

	-- World is locked
	-- Check if this player is the owner
	if lockOwner == player.UserId then
		return true
	end

	-- Check if this player is a world admin
	if LockService._isWorldAdmin(player, worldData) then
		return true
	end

	-- Check small locks (owner/admins of small locks can modify their area even in locked worlds)
	return LockService._canModifySmallLock(player, worldData, tileX, tileY)
end

--[[
	Check if a player can modify a tile based on small locks only.
]]
function LockService._canModifySmallLock(player: Player, worldData: table, tileX: number, tileY: number): boolean
	local smallLocks = worldData.smallLocks
	if not smallLocks or #smallLocks == 0 then
		return true -- No small locks, no restrictions
	end

	for _, sl in ipairs(smallLocks) do
		-- Check if the tile falls within this small lock's region
		if tileX >= sl.x and tileX < sl.x + sl.width
			and tileY >= sl.y and tileY < sl.y + sl.height then
			-- Tile is inside a small lock
			if sl.owner == player.UserId then
				return true
			end
			if sl.admins and LockService._isInTable(sl.admins, player.UserId) then
				return true
			end
			return false -- Tile is locked by a small lock and player has no access
		end
	end

	return true -- Tile is not inside any small lock
end

--[[
	Check if a player is a world admin.
]]
function LockService._isWorldAdmin(player: Player, worldData: table): boolean
	if not worldData.admins or not player then
		return false
	end
	return LockService._isInTable(worldData.admins, player.UserId)
end

--[[
	Helper: check if a value exists in a table (array).
]]
function LockService._isInTable(t: { number }, value: number): boolean
	for _, v in ipairs(t) do
		if v == value then
			return true
		end
	end
	return false
end

--[[
	Place a world lock. Sets the world's lockOwner to the placing player.
	If the world is already locked, returns false with a message.

	@param player: Player — the player placing the lock
	@param worldData: table — the world data
	@return boolean, string — success status and message
]]
function LockService.PlaceWorldLock(player: Player, worldData: table): (boolean, string)
	if not player then
		return false, "Invalid player"
	end

	if LockService.IsWorldLocked(worldData) then
		return false, "This world is already locked!"
	end

	worldData.lockOwner = player.UserId
	worldData.admins = worldData.admins or {}
	worldData.updatedAt = os.time()

	print(`[LockService] World "{worldData.name}" locked by {player.Name} (userId={player.UserId})`)
	return true, "World locked!"
end

--[[
	Remove a world lock. Only the owner can remove it.

	@param player: Player — the player attempting removal
	@param worldData: table — the world data
	@return boolean, string — success status and message
]]
function LockService.RemoveWorldLock(player: Player, worldData: table): (boolean, string)
	if not player then
		return false, "Invalid player"
	end

	if not LockService.IsWorldLocked(worldData) then
		return false, "This world is not locked!"
	end

	if worldData.lockOwner ~= player.UserId then
		return false, "Only the world owner can remove the lock!"
	end

	-- Check for untradeable items that prevent lock removal
	if LockService._hasUntradeableItems(worldData) then
		return false, "Cannot remove lock while untradeable items exist in the world!"
	end

	worldData.lockOwner = nil
	worldData.admins = {}
	worldData.updatedAt = os.time()

	print(`[LockService] World "{worldData.name}" unlocked by {player.Name} (userId={player.UserId})`)
	return true, "World unlocked!"
end

--[[
	Check if the world contains any untradeable items.
	Currently checks for the presence of locked doors or other special items.
	TODO: Expand this to check all tiles for untradeable items.
]]
function LockService._hasUntradeableItems(worldData: table): boolean
	-- For now, always return false to allow lock removal
	-- In a full implementation, scan all tiles for untradeable items
	return false
end

--[[
	Add a player as an admin of the world.
	Only the world owner can add admins.

	@param ownerPlayer: Player — the world owner
	@param targetUserId: number — the user to add as admin
	@param worldData: table — the world data
	@return boolean — true if successful
]]
function LockService.AddAdmin(ownerPlayer: Player, targetUserId: number, worldData: table): boolean
	if not ownerPlayer or not targetUserId then
		return false
	end

	if not LockService.IsWorldLocked(worldData) then
		warn(`[LockService] Cannot add admin: world "{worldData.name}" is not locked`)
		return false
	end

	if worldData.lockOwner ~= ownerPlayer.UserId then
		warn(`[LockService] Cannot add admin: {ownerPlayer.Name} is not the world owner`)
		return false
	end

	-- Initialize admins table if needed
	worldData.admins = worldData.admins or {}

	-- Don't add duplicates
	if LockService._isInTable(worldData.admins, targetUserId) then
		return true -- Already an admin, no error
	end

	table.insert(worldData.admins, targetUserId)
	worldData.updatedAt = os.time()

	print(`[LockService] Added userId={targetUserId} as admin of world "{worldData.name}"`)
	return true
end

--[[
	Remove a player from the world's admin list.
	Only the world owner can remove admins.

	@param ownerPlayer: Player — the world owner
	@param targetUserId: number — the user to remove as admin
	@param worldData: table — the world data
	@return boolean — true if successful
]]
function LockService.RemoveAdmin(ownerPlayer: Player, targetUserId: number, worldData: table): boolean
	if not ownerPlayer or not targetUserId then
		return false
	end

	if not LockService.IsWorldLocked(worldData) then
		return false
	end

	if worldData.lockOwner ~= ownerPlayer.UserId then
		warn(`[LockService] Cannot remove admin: {ownerPlayer.Name} is not the world owner`)
		return false
	end

	worldData.admins = worldData.admins or {}

	for i, uid in ipairs(worldData.admins) do
		if uid == targetUserId then
			table.remove(worldData.admins, i)
			worldData.updatedAt = os.time()
			print(`[LockService] Removed userId={targetUserId} as admin of world "{worldData.name}"`)
			return true
		end
	end

	return false -- User was not an admin
end

--[[
	Check if a world is locked.

	@param worldData: table — the world data
	@return boolean, number? — locked status and lock owner userId (nil if not locked)
]]
function LockService.IsWorldLocked(worldData: table): (boolean, number?)
	if not worldData then
		return false, nil
	end
	return worldData.lockOwner ~= nil, worldData.lockOwner
end

--[[
	Get the lock owner of a world.

	@param worldData: table — the world data
	@return number? — the lock owner's userId, or nil if not locked
]]
function LockService.GetLockOwner(worldData: table): number?
	if not worldData then
		return nil
	end
	return worldData.lockOwner
end

--[[
	Place a small lock in the world.
	Small locks can be placed by any player and lock a 10x10 area.

	@param player: Player — the player placing the lock
	@param worldData: table — the world data
	@param tileX: number — center X of the lock region
	@param tileY: number — center Y of the lock region
	@return boolean, string — success status and message
]]
function LockService.PlaceSmallLock(player: Player, worldData: table, tileX: number, tileY: number): (boolean, string)
	if not player then
		return false, "Invalid player"
	end

	if not WorldConfig.IsValidPosition(tileX, tileY) then
		return false, "Invalid position"
	end

	-- Initialize smallLocks table if needed
	worldData.smallLocks = worldData.smallLocks or {}

	-- Don't allow overlapping small locks owned by different players
	for _, sl in ipairs(worldData.smallLocks) do
		if sl.owner == player.UserId then
			-- Same owner can place multiple, but not too close
			local dx = math.abs(sl.x - tileX)
			local dy = math.abs(sl.y - tileY)
			if dx < SMALL_LOCK_SIZE and dy < SMALL_LOCK_SIZE then
				return false, "You already have a lock nearby!"
			end
		else
			-- Different owner: check if overlapping
			local dx = math.abs(sl.x - tileX)
			local dy = math.abs(sl.y - tileY)
			if dx < SMALL_LOCK_SIZE and dy < SMALL_LOCK_SIZE then
				return false, "Another player's lock is nearby!"
			end
		end
	end

	local newLock = {
		x = tileX - math.floor(SMALL_LOCK_SIZE / 2),
		y = tileY - math.floor(SMALL_LOCK_SIZE / 2),
		width = SMALL_LOCK_SIZE,
		height = SMALL_LOCK_SIZE,
		owner = player.UserId,
		admins = {},
	}

	-- Clamp to world bounds
	newLock.x = math.max(0, newLock.x)
	newLock.y = math.max(0, newLock.y)
	newLock.width = math.min(SMALL_LOCK_SIZE, WorldConfig.WORLD_WIDTH - newLock.x)
	newLock.height = math.min(SMALL_LOCK_SIZE, WorldConfig.WORLD_HEIGHT - newLock.y)

	table.insert(worldData.smallLocks, newLock)
	worldData.updatedAt = os.time()

	print(`[LockService] Small lock placed by {player.Name} at ({tileX}, {tileY}) in world "{worldData.name}"`)
	return true, "Small lock placed!"
end

--[[
	Initialize LockService.
]]
function LockService.Init()
	print("[LockService] Initialized")
end

return LockService
