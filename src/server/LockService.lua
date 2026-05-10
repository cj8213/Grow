--!strict
-- LockService.lua
-- Server-side world lock and small lock management
-- Dynamic tile-claim system: each lock claims individual tiles in a radius.
-- Multiple locks can coexist — overlapping tiles stay with the first claimer.
-- Permission check: O(1) dictionary lookup per tile.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local WorldConfig = require(ReplicatedStorage.Shared.WorldConfig)

local LockService = {}

--[[
	Data structures (stored on worldData):
	
	worldData.lockClaims = { [tileIndex]: lockId }
		- Maps each claimed tile to a lock ID (string like "SL_1")
		- nil means unclaimed
		- lockId format: "SL_{number}" for Small Locks, "WL" for World Lock
	
	worldData.lockRegistry = { [lockId]: LockData }
		- Maps lock ID to its metadata:
		{
			owner: number,        -- userId who placed it
			admins: { number },   -- additional users with access
			centerX: number,      -- tile X where placed
			centerY: number,      -- tile Y where placed
			radius: number,       -- claim radius (5 for small lock)
		}
	
	worldData.nextLockId = 1
		- Auto-incrementing counter for lock IDs
]]

-- Claim radius of a small lock (half of the 10x10 area)
local SMALL_LOCK_RADIUS = 2

-- Permanent admin user IDs — these players can modify any tile in any world
local PERMANENT_ADMINS: { [number]: boolean } = {
	[1424887141] = true, -- User's Roblox ID
}

--[[
	Initialize lock data structures on a world if not present.
	Also migrates old-format locks (worldData.smallLocks) to the new
	dynamic tile-claim format (lockClaims/lockRegistry) on first load.
	Safe to call multiple times.
]]
function LockService.EnsureLockData(worldData: table)
	local needsInit = false
	if not worldData.lockClaims then
		worldData.lockClaims = {}
		needsInit = true
	end
	if not worldData.lockRegistry then
		worldData.lockRegistry = {}
		needsInit = true
	end
	if not worldData.nextLockId then
		worldData.nextLockId = 1
		needsInit = true
	end

	-- MIGRATE old-format smallLocks (rectangles) to new dynamic tile-claim format
	if needsInit and worldData.smallLocks and #worldData.smallLocks > 0 then
		print(`[LockService] Migrating {#worldData.smallLocks} old-format small locks to dynamic tile-claim system`)
		for i, sl in ipairs(worldData.smallLocks) do
			local lockId = "SL_migrated_" .. i
			local centerX = sl.x + math.floor(sl.width / 2)
			local centerY = sl.y + math.floor(sl.height / 2)
			worldData.lockRegistry[lockId] = {
				owner = sl.owner,
				admins = sl.admins or {},
				centerX = centerX,
				centerY = centerY,
				radius = math.floor(sl.width / 2),
			}
			-- Claim all tiles in the old rectangle
			for dx = 0, sl.width - 1 do
				for dy = 0, sl.height - 1 do
					local tx = sl.x + dx
					local ty = sl.y + dy
					if WorldConfig.IsValidPosition(tx, ty) then
						local index = tx + ty * WorldConfig.WORLD_WIDTH
						worldData.lockClaims[index] = lockId
					end
				end
			end
			print(`[LockService]   Migrated lock #{i}: owner={sl.owner}, center=({centerX},{centerY}), {sl.width}x{sl.height}`)
		end
		worldData.smallLocks = nil
		worldData.updatedAt = os.time()
		-- Count migrated locks
		local migratedCount = 0
		for _ in pairs(worldData.lockRegistry) do
			migratedCount += 1
		end
		print(`[LockService] Migration complete — converted to {migratedCount} dynamic locks`)
	end
end

--[[
	Get the next lock ID and increment counter.
]]
function LockService._nextLockId(worldData: table): string
	LockService.EnsureLockData(worldData)
	local id = "SL_" .. worldData.nextLockId
	worldData.nextLockId += 1
	return id
end

--[[
	Check if a player can modify a specific tile in a world.
	Returns true if the player is:
	- A permanent admin (bypasses all lock checks)
	- The world lock owner
	- An admin of the world lock
	- Not in a claimed region at all
	- An admin of the lock covering this tile
	- The owner of the lock covering this tile
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

	-- Permanent admin bypass
	if PERMANENT_ADMINS[player.UserId] then
		return true
	end

	-- Check if the world is locked at all
	local isWorldLocked, lockOwner = LockService.IsWorldLocked(worldData)
	if not isWorldLocked then
		-- World is public — check small lock claims only
		return LockService._canModifySmallLock(player, worldData, tileX, tileY)
	end

	-- World is locked
	if lockOwner == player.UserId then
		return true
	end

	-- Check if this player is a world admin
	if LockService._isWorldAdmin(player, worldData) then
		return true
	end

	-- Check small locks (owner/admins can modify even in locked worlds)
	return LockService._canModifySmallLock(player, worldData, tileX, tileY)
end

--[[
	Check if a player can modify a tile based on small lock claims only.
	O(1) lookup: checks lockClaims[tileIndex].
]]
function LockService._canModifySmallLock(player: Player, worldData: table, tileX: number, tileY: number): boolean
	LockService.EnsureLockData(worldData)

	local tileIndex = tileX + tileY * WorldConfig.WORLD_WIDTH
	local lockId = worldData.lockClaims[tileIndex]

	if lockId == nil then
		return true -- Unclaimed — free to modify
	end

	local lockData = worldData.lockRegistry[lockId]
	if not lockData then
		return true -- Orphaned claim — treat as unclaimed (shouldn't happen)
	end

	if lockData.owner == player.UserId then
		return true
	end

	if lockData.admins and LockService._isInTable(lockData.admins, player.UserId) then
		return true
	end

	return false -- Tile is locked by someone else
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
	Get the lock metadata for a tile.
	@return (string?, table?) — lockId and lockData, or nil, nil if unclaimed
]]
function LockService.GetLockAt(worldData: table, tileX: number, tileY: number): (string?, table?)
	LockService.EnsureLockData(worldData)
	local tileIndex = tileX + tileY * WorldConfig.WORLD_WIDTH
	local lockId = worldData.lockClaims[tileIndex]
	if not lockId then
		return nil, nil
	end
	return lockId, worldData.lockRegistry[lockId]
end

--[[
	Place a world lock. Sets the world's lockOwner to the placing player.
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

	worldData.lockOwner = nil
	worldData.admins = {}
	worldData.updatedAt = os.time()

	print(`[LockService] World "{worldData.name}" unlocked by {player.Name} (userId={player.UserId})`)
	return true, "World unlocked!"
end

--[[
	Add a player as an admin of the world.
	Only the world owner can add admins.
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

	worldData.admins = worldData.admins or {}

	if LockService._isInTable(worldData.admins, targetUserId) then
		return true
	end

	table.insert(worldData.admins, targetUserId)
	worldData.updatedAt = os.time()

	print(`[LockService] Added userId={targetUserId} as admin of world "{worldData.name}"`)
	return true
end

--[[
	Remove a player from the world's admin list.
	Only the world owner can remove admins.
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

	return false
end

--[[
	Check if a world is locked.
]]
function LockService.IsWorldLocked(worldData: table): (boolean, number?)
	if not worldData then
		return false, nil
	end
	return worldData.lockOwner ~= nil, worldData.lockOwner
end

--[[
	Get the lock owner of a world.
]]
function LockService.GetLockOwner(worldData: table): number?
	if not worldData then
		return nil
	end
	return worldData.lockOwner
end

--[[
	Place a small lock in the world.
	Claims unoccupied tiles in a SMALL_LOCK_RADIUS area around (tileX, tileY).
	Tiles already claimed by another lock are skipped.
	Only the tiles actually claimed get lock protection.
	
	@param player: Player — the player placing the lock
	@param worldData: table — the world data
	@param tileX: number — center X
	@param tileY: number — center Y
	@return boolean, string, number? — success, message, tiles claimed count
]]
function LockService.PlaceSmallLock(player: Player, worldData: table, tileX: number, tileY: number): (boolean, string, number?)
	if not player then
		return false, "Invalid player", nil
	end

	if not WorldConfig.IsValidPosition(tileX, tileY) then
		return false, "Invalid position", nil
	end

	LockService.EnsureLockData(worldData)

	-- Generate lock ID
	local lockId = LockService._nextLockId(worldData)

	-- Claim unoccupied tiles in a single pass.
	-- If no tiles are claimed, reject because the area is fully claimed.
	local claimedCount = 0
	for dx = -SMALL_LOCK_RADIUS, SMALL_LOCK_RADIUS do
		for dy = -SMALL_LOCK_RADIUS, SMALL_LOCK_RADIUS do
			local tx = tileX + dx
			local ty = tileY + dy
			if WorldConfig.IsValidPosition(tx, ty) then
				local index = tx + ty * WorldConfig.WORLD_WIDTH
				if not worldData.lockClaims[index] then
					worldData.lockClaims[index] = lockId
					claimedCount += 1
				end
			end
		end
	end

	-- If no tiles could be claimed, reject
	if claimedCount == 0 then
		-- Remove the unused lockId from registry (clean up)
		worldData.lockRegistry[lockId] = nil
		return false, "All tiles in this area are already claimed!", nil
	end

	-- Register lock metadata
	worldData.lockRegistry[lockId] = {
		owner = player.UserId,
		admins = {},
		centerX = tileX,
		centerY = tileY,
		radius = SMALL_LOCK_RADIUS,
	}

	worldData.updatedAt = os.time()

	print(`[LockService] Small lock "{lockId}" placed by {player.Name} at ({tileX},{tileY}) — claimed {claimedCount}/{SMALL_LOCK_RADIUS*2+1}^2 tiles`)
	return true, `Small lock placed! Claimed {claimedCount} tiles.`, claimedCount
end

--[[
	Remove a small lock and release all its claimed tiles.
	Only the lock owner can remove it.
	
	@param player: Player — the player breaking the lock
	@param worldData: table — the world data
	@param lockId: string — the lock ID to remove
	@return boolean, string — success, message
]]
function LockService.RemoveSmallLock(player: Player, worldData: table, lockId: string): (boolean, string)
	if not player then
		return false, "Invalid player"
	end

	LockService.EnsureLockData(worldData)

	local lockData = worldData.lockRegistry[lockId]
	if not lockData then
		return false, "Lock not found"
	end

	if lockData.owner ~= player.UserId then
		return false, "Only the lock owner can remove this lock!"
	end

	-- Unclaim all tiles belonging to this lock
	local unclaimed = 0
	for tileIndex, claimLockId in pairs(worldData.lockClaims) do
		if claimLockId == lockId then
			worldData.lockClaims[tileIndex] = nil
			unclaimed += 1
		end
	end

	-- Remove from registry
	worldData.lockRegistry[lockId] = nil
	worldData.updatedAt = os.time()

	print(`[LockService] Small lock "{lockId}" removed by {player.Name} — unclaimed {unclaimed} tiles`)
	return true, `Lock removed!`
end

--[[
	Remove all small locks owned by a specific player.
	Used by admin removelocks.
	
	@param player: Player
	@param worldData: table
	@return number — count of locks removed
]]
function LockService.RemoveAllSmallLocks(player: Player, worldData: table): number
	LockService.EnsureLockData(worldData)

	local removed = 0

	-- Collect all lock IDs owned by this player (or all locks if player is permanent admin)
	local isAdmin = PERMANENT_ADMINS[player.UserId]
	local lockIdsToRemove: { string } = {}
	for lockId, lockData in pairs(worldData.lockRegistry) do
		if lockId:sub(1, 3) == "SL_" then
			if isAdmin or lockData.owner == player.UserId then
				table.insert(lockIdsToRemove, lockId)
			end
		end
	end

	-- Remove each lock
	for _, lockId in ipairs(lockIdsToRemove) do
		-- Unclaim tiles
		for tileIndex, claimLockId in pairs(worldData.lockClaims) do
			if claimLockId == lockId then
				worldData.lockClaims[tileIndex] = nil
			end
		end
		-- Remove from registry
		worldData.lockRegistry[lockId] = nil
		removed += 1
	end

	if removed > 0 then
		worldData.updatedAt = os.time()
	end

	return removed
end

--[[
	Remove ALL small locks in a world (bypasses ownership check).
	Returns count of locks removed + lock items to return.
	
	@param worldData: table
	@return number, number — locks removed, lock items returned
]]
function LockService.RemoveAllLocks(worldData: table): (number, number)
	LockService.EnsureLockData(worldData)

	local locksRemoved = 0
	local lockItems = 0

	-- Collect all SL_ lock IDs
	local lockIds: { string } = {}
	for lockId in pairs(worldData.lockRegistry) do
		if lockId:sub(1, 3) == "SL_" then
			table.insert(lockIds, lockId)
		end
	end

	-- Remove each lock
	for _, lockId in ipairs(lockIds) do
		for tileIndex, claimLockId in pairs(worldData.lockClaims) do
			if claimLockId == lockId then
				worldData.lockClaims[tileIndex] = nil
			end
		end
		worldData.lockRegistry[lockId] = nil
		locksRemoved += 1
		lockItems += 1
	end

	if locksRemoved > 0 then
		worldData.updatedAt = os.time()
	end

	return locksRemoved, lockItems
end

--[[
	Build lock zones data for broadcasting to clients.
	Returns a table suitable for LockZonesUpdated RemoteEvent:
	{
		worldLocked: boolean,
		lockOwner: number?,
		admins: { number }?,
		smallLocks: [{
			lockId: string,
			owner: number,
			admins: { number },
			centerX: number,
			centerY: number,
			radius: number,
			claimedCount: number,
			claimedTiles: [number],  -- actual tile indices for per-tile rendering
		}]
	}
]]
function LockService.BuildLockZonesData(worldData: table): table
	LockService.EnsureLockData(worldData)

	local smallLockData: { table } = {}
	for lockId, lockData in pairs(worldData.lockRegistry) do
		if lockId:sub(1, 3) == "SL_" then
			-- Collect all claimed tile indices for this lock
			local claimedTiles: { number } = {}
			for tileIndexStr, claimLockId in pairs(worldData.lockClaims) do
				if claimLockId == lockId then
					table.insert(claimedTiles, tonumber(tileIndexStr))
				end
			end

			table.insert(smallLockData, {
				lockId = lockId,
				owner = lockData.owner,
				admins = lockData.admins or {},
				centerX = lockData.centerX,
				centerY = lockData.centerY,
				radius = lockData.radius,
				claimedCount = #claimedTiles,
				claimedTiles = claimedTiles,
			})
		end
	end

	return {
		worldLocked = worldData.lockOwner ~= nil,
		lockOwner = worldData.lockOwner,
		admins = worldData.admins or {},
		smallLocks = smallLockData,
	}
end

--[[
	Check if a world has any small locks placed.
]]
function LockService.HasSmallLocks(worldData: table): boolean
	LockService.EnsureLockData(worldData)
	for lockId in pairs(worldData.lockRegistry) do
		if lockId:sub(1, 3) == "SL_" then
			return true
		end
	end
	return false
end

--[[
	Initialize LockService.
]]
function LockService.Init()
	print("[LockService] Initialized — dynamic tile-claim system")
end

return LockService
