--!strict
-- WorldRegistry.lua
-- Global DataStore-backed registry for tracking which worlds are active on which server.
-- Enables cross-server world travel: if a world is already loaded on another server,
-- the player gets teleported there instead of loading a conflicting copy locally.
--
-- Uses a completely separate DataStore (WorldRegistry_v1) from player/world data.
-- All DataStore calls wrapped in pcall — registry failure must never block gameplay.

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local WorldRegistry = {}

local REGISTRY_DATASTORE_NAME = "WorldRegistry_v1"

-- Stale threshold: entries older than 60s without heartbeat are treated as dead
local STALE_THRESHOLD = 60

-- How often to refresh heartbeat (seconds)
local HEARTBEAT_INTERVAL = 30

-- Worlds currently active on THIS server (worldName -> true)
local localWorlds: { [string]: boolean } = {}

--[[
	Get a stable server ID:
	- In production: game.JobId (unique per server instance)
	- In Studio: "STUDIO_XXXX" since JobId is empty string
]]
local function getServerId(): string
	if game.JobId ~= "" then
		return game.JobId
	end
	return "STUDIO_" .. tostring(math.random(1000, 9999))
end

--[[
	Get or create the registry DataStore.
]]
local function getRegistryStore(): DataStore?
	local success, result = pcall(function()
		return DataStoreService:GetDataStore(REGISTRY_DATASTORE_NAME)
	end)
	if success then
		return result
	else
		warn(`[WorldRegistry] Failed to get registry DataStore: {result}`)
		return nil
	end
end

--[[
	Read a registry entry from DataStore.
	@param worldName: string — normalized world name
	@return table? — entry or nil if not found
]]
local function readEntry(worldName: string): table?
	local store = getRegistryStore()
	if not store then return nil end

	local key = "world_" .. worldName
	local success, result = pcall(function()
		return store:GetAsync(key)
	end)

	if success and result ~= nil then
		return result
	end
	return nil
end

--[[
	Write a registry entry to DataStore.
	@param worldName: string — normalized world name
	@param entry: table — registry entry data
	@return boolean — true if written successfully
]]
local function writeEntry(worldName: string, entry: table): boolean
	local store = getRegistryStore()
	if not store then return false end

	local key = "world_" .. worldName
	local success, err = pcall(function()
		store:SetAsync(key, entry)
	end)

	if success then
		return true
	else
		warn(`[WorldRegistry] Failed to write entry for "{worldName}": {err}`)
		return false
	end
end

--[[
	Remove a registry entry from DataStore.
	@param worldName: string — normalized world name
]]
local function removeEntry(worldName: string)
	local store = getRegistryStore()
	if not store then return end

	local key = "world_" .. worldName
	pcall(function()
		store:RemoveAsync(key)
	end)
end

--[[
	Register a world as active on this server.
	Called when a world is loaded.
	
	@param worldName: string — normalized world name
	@return boolean — true if registered successfully
]]
function WorldRegistry.Register(worldName: string): boolean
	local normalized = string.upper(string.gsub(worldName, "[^%w_]", ""))

	-- Never register START (always generated fresh per server)
	if normalized == "START" then
		return true
	end

	local entry = {
		serverId = getServerId(),
		placeId = game.PlaceId,
		playerCount = 0,
		lastActive = os.time(),
		isActive = true,
	}

	local success = writeEntry(normalized, entry)
	if success then
		localWorlds[normalized] = true
		print(`[WorldRegistry] Registered world "{normalized}" on server {getServerId()}`)
	else
		warn(`[WorldRegistry] Failed to register world "{normalized}"`)
	end

	return success
end

--[[
	Deregister a world from this server.
	Called when a world is unloaded.
	
	@param worldName: string — normalized world name
	@return boolean — true if deregistered successfully
]]
function WorldRegistry.Deregister(worldName: string): boolean
	local normalized = string.upper(string.gsub(worldName, "[^%w_]", ""))

	if normalized == "START" then
		return true
	end

	removeEntry(normalized)
	localWorlds[normalized] = nil
	print(`[WorldRegistry] Deregistered world "{normalized}"`)
	return true
end

--[[
	Find which server hosts a world.
	Returns nil if the world is not active on any server,
	or if the entry is stale (no heartbeat for >60s).
	
	@param worldName: string — normalized world name
	@return { serverId: string, placeId: number, playerCount: number }? — server info or nil
]]
function WorldRegistry.Find(worldName: string): { serverId: string, placeId: number, playerCount: number }?
	local normalized = string.upper(string.gsub(worldName, "[^%w_]", ""))

	if normalized == "START" then
		return nil -- START is always local
	end

	local entry = readEntry(normalized)
	if not entry then
		print(`[WorldRegistry] "{normalized}" not active on any server`)
		return nil
	end

	-- Check if entry is stale (server probably crashed)
	if os.time() - entry.lastActive > STALE_THRESHOLD then
		print(`[WorldRegistry] "{normalized}" entry is stale ({os.time() - entry.lastActive}s old), treating as inactive`)
		-- Clean up stale entry
		removeEntry(normalized)
		return nil
	end

	print(`[WorldRegistry] Found "{normalized}" on server {entry.serverId}`)
	return {
		serverId = entry.serverId,
		placeId = entry.placeId,
		playerCount = entry.playerCount or 0,
	}
end

--[[
	Update the player count for a world on this server.
	Called by PlayerManager when a player enters or leaves a world.
	
	@param worldName: string — normalized world name
	@param count: number — current player count
	@return boolean — true if updated successfully
]]
function WorldRegistry.UpdatePlayerCount(worldName: string, count: number): boolean
	local normalized = string.upper(string.gsub(worldName, "[^%w_]", ""))

	if normalized == "START" then
		return true
	end

	-- Read current entry, update playerCount, write back
	local entry = readEntry(normalized)
	if not entry then
		return false
	end

	entry.playerCount = count
	entry.lastActive = os.time()

	return writeEntry(normalized, entry)
end

--[[
	Start the heartbeat loop.
	Every 30 seconds, updates lastActive for all worlds on this server,
	so other servers know this server is still alive.
]]
function WorldRegistry.StartHeartbeat()
	task.spawn(function()
		while true do
			task.wait(HEARTBEAT_INTERVAL)

			local count = 0
			for worldName in pairs(localWorlds) do
				local entry = readEntry(worldName)
				if entry then
					entry.lastActive = os.time()
					writeEntry(worldName, entry)
					count += 1
				end
			end

			if count > 0 then
				print(`[WorldRegistry] Heartbeat updated {count} worlds`)
			end
		end
	end)

	print(`[WorldRegistry] Heartbeat started ({HEARTBEAT_INTERVAL}s interval)`)
end

--[[
	Clean up ALL worlds registered to this server.
	Called on server shutdown via game:BindToClose().
	Prevents stale entries after server shutdown.
]]
function WorldRegistry.CleanupServer()
	local count = 0
	for worldName in pairs(localWorlds) do
		removeEntry(worldName)
		localWorlds[worldName] = nil
		count += 1
	end
	print(`[WorldRegistry] Server shutting down, deregistered {count} worlds`)
end

--[[
	Initialize WorldRegistry.
]]
function WorldRegistry.Init()
	WorldRegistry.StartHeartbeat()

	print(`[WorldRegistry] Initialized — serverId={getServerId()}, placeId={game.PlaceId}`)
end

return WorldRegistry
