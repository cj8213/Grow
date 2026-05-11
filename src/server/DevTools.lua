--!strict
-- DevTools.lua (server)
-- Studio-only smoke test utilities for admin-level testing.
-- All commands are guarded by RunService:IsStudio() — they only work
-- when the game is running in Roblox Studio.
--
-- Commands (handled via NetworkHandler integration):
--   /godmode      — Toggle godmode (invulnerability tracking)
--   /printworld   — Print current world info to server console
--   /tp <x> <y>   — Teleport to tile coordinates
--
-- Unit tests (run on Init() in Studio):
--   DevTools.TestCanModify() — runs LockService.CanModify four-case test

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local LockService = require(script.Parent.LockService)
local PlayerManager = require(script.Parent.PlayerManager)
local WorldService = require(script.Parent.WorldService)

local DevTools = {}

-- Internal: active godmode per player
local godmodePlayers: { [number]: boolean } = {}

--[[
	Check if dev tools are enabled (Studio only).
	@return boolean
]]
function DevTools.IsEnabled(): boolean
	return RunService:IsStudio()
end

--[[
	Check if a player has godmode enabled.
	@param player: Player
	@return boolean
]]
function DevTools.IsGodmode(player: Player): boolean
	return godmodePlayers[player.UserId] == true
end

--[[
	Handle a slash command from a player.
	Called by NetworkHandler.onRequestChatMessage for all slash commands.
	
	@param player: Player — the player who typed the command
	@param cmd: string — the command name (lowercase, e.g. "godmode")
	@param args: { string } — full split of the message (args[1] is the command)
	@return boolean — true if the command was handled by DevTools
]]
function DevTools.HandleCommand(player: Player, cmd: string, args: { string }): boolean
	if not RunService:IsStudio() then
		return false
	end

	if cmd == "godmode" then
		local userId = player.UserId
		godmodePlayers[userId] = not godmodePlayers[userId]
		local status = godmodePlayers[userId] and "ENABLED" or "DISABLED"
		PlayerManager.FireToPlayer(player, "ChatMessage", "DevTools",
			`Godmode {status}`, Color3.fromRGB(255, 200, 50))
		print(`[DevTools] Godmode {status} for {player.Name}`)
		return true

	elseif cmd == "printworld" then
		local worldName = PlayerManager.GetPlayerWorld(player)
		if not worldName then
			PlayerManager.FireToPlayer(player, "ChatMessage", "DevTools",
				"Not in any world!", Color3.fromRGB(255, 200, 50))
			return true
		end

		local allWorlds = WorldService.GetAllWorlds()
		local wd = allWorlds and allWorlds[worldName]
		if wd then
			print("========== WORLD INFO ==========")
			print(`Name:          {worldName}`)
			print(`Seed:          {wd.seed}`)
			print(`Lock Owner:    {wd.lockOwner or "None (unlocked)"}`)
			print(`Admins:        {if wd.admins then #wd.admins else 0}`)
			print(`Updated At:    {os.date("%c", wd.updatedAt or 0)}`)
			print(`Is Special:    {WorldService.IsSpecialWorld(worldName)}`)
			-- Count non-empty foreground tiles
			local tileCount = 0
			local treeCount = 0
			for _, tile in ipairs(wd.tiles) do
				if tile.fg ~= 0 then
					tileCount = tileCount + 1
					if tile.treeData then
						treeCount = treeCount + 1
					end
				end
			end
			print(`Non-empty fg:  {tileCount} / {#wd.tiles}`)
			print(`Trees growing: {treeCount}`)
			print("================================")
			PlayerManager.FireToPlayer(player, "ChatMessage", "DevTools",
				`World info printed to server console`, Color3.fromRGB(200, 255, 200))
		else
			PlayerManager.FireToPlayer(player, "ChatMessage", "DevTools",
				`World "{worldName}" not found in cache`, Color3.fromRGB(255, 200, 50))
		end
		return true

	elseif cmd == "tp" then
		local x = tonumber(args[2])
		local y = tonumber(args[3])
		if x and y then
			local Shared = require(game:GetService("ReplicatedStorage").Shared)
			local WorldConfig = Shared.WorldConfig
			if WorldConfig.IsValidPosition(x, y) then
				-- Fire PlayerSpawned to teleport the player
				local worldName = PlayerManager.GetPlayerWorld(player) or "START"
				PlayerManager.FireToPlayer(player, "PlayerSpawned", x, y, worldName)
				PlayerManager.FireToPlayer(player, "ChatMessage", "DevTools",
					`Teleported to ({x}, {y}) in "{worldName}"`, Color3.fromRGB(200, 255, 200))
				print(`[DevTools] Teleported {player.Name} to ({x}, {y}) in "{worldName}"`)
			else
				PlayerManager.FireToPlayer(player, "ChatMessage", "DevTools",
					`Invalid position ({x}, {y}) — world bounds are 0..{WorldConfig.WORLD_WIDTH-1} x 0..{WorldConfig.WORLD_HEIGHT-1}`,
					Color3.fromRGB(255, 200, 50))
			end
		else
			PlayerManager.FireToPlayer(player, "ChatMessage", "DevTools",
				"Usage: /tp <x> <y>", Color3.fromRGB(255, 200, 50))
		end
		return true

	elseif cmd == "showlocks" then
		local worldName = PlayerManager.GetPlayerWorld(player)
		if not worldName then
			PlayerManager.FireToPlayer(player, "ChatMessage", "DevTools",
				"Not in any world!", Color3.fromRGB(255, 200, 50))
			return true
		end

		local allWorlds = WorldService.GetAllWorlds()
		local wd = allWorlds and allWorlds[worldName]
		if not wd then
			PlayerManager.FireToPlayer(player, "ChatMessage", "DevTools",
				"World not found", Color3.fromRGB(255, 200, 50))
			return true
		end

		-- Send lock zone data to client using new dynamic lock system
		local lockData = LockService.BuildLockZonesData(wd)
		PlayerManager.FireToPlayer(player, "LockZonesUpdated", lockData)
		PlayerManager.FireToPlayer(player, "ChatMessage", "DevTools",
			`Showing {#lockData.smallLocks} small lock zone(s)`, Color3.fromRGB(200, 255, 200))
		print(`[DevTools] Sent {#lockData.smallLocks} small lock zones to {player.Name} in "{worldName}"`)
		return true
	elseif cmd == "cleardrops" then
		local WorldService = require(script.Parent.WorldService)
		local allWorlds = WorldService.GetAllWorlds()
		local total = 0
		for worldName, worldData in pairs(allWorlds) do
			if worldData.drops then
				total = total + #worldData.drops
				worldData.drops = {}
				print(`[DevTools] Cleared drops for world "{worldName}"`)
				-- Tell all players in this world to destroy visual drop Parts
				PlayerManager.BroadcastToWorld(worldName, "ClearAllDrops", worldName)
			end
		end
		-- Force save all worlds immediately
		local DataService = require(script.Parent.DataService)
		for worldName, worldData in pairs(allWorlds) do
			DataService.SaveWorldData(worldName, worldData)
		end
		PlayerManager.FireToPlayer(player, "ChatMessage", "System",
			`Cleared {total} corrupted drops`, Color3.fromRGB(200, 255, 200))
		print(`[DevTools] Cleared {total} corrupted drops total`)
		return true
	end

	return false -- Not a DevTools command
end

--[[
	Run the LockService.CanModify four-case unit test.
	
	Cases tested:
	1. World owner can modify locked world (even inside a small lock) → true
	2. World admin can modify locked world (even inside a small lock) → true
	3. Non-owner, non-admin cannot modify inside a small lock in locked world → false
	4. Non-owner can modify unlocked world with no small locks → true
	
	Prints PASS/FAIL for each case to the server console.
]]
function DevTools.TestCanModify()
	if not RunService:IsStudio() then
		print("[DevTools] CanModify test skipped — not running in Studio")
		return
	end

	print("===== LockService.CanModify Unit Test =====")

	-- Create mock player objects (only UserId matters for CanModify)
	local mockOwner = { UserId = 1001, Name = "Owner" } :: Player
	local mockAdmin = { UserId = 1002, Name = "Admin" } :: Player
	local mockOther = { UserId = 1003, Name = "Other" } :: Player

	-- Locked world with a small lock covering the test tile (new dynamic system)
	local lockedWorld = {
		lockOwner = 1001,
		admins = { 1002 },
		lockClaims = {},
		lockRegistry = {},
		nextLockId = 1,
	}

	-- Place a small lock centered at (5,5) with radius 5 → covers tiles 0..10, 0..10
	local lockId = "SL_test_1"
	lockedWorld.lockRegistry[lockId] = {
		owner = 1001,
		admins = {},
		centerX = 5,
		centerY = 5,
		radius = 5,
	}
	for dx = -5, 5 do
		for dy = -5, 5 do
			local tx = 5 + dx
			local ty = 5 + dy
			local index = tx + ty * 100
			lockedWorld.lockClaims[index] = lockId
		end
	end

	-- Unlocked world with no small locks
	local unlockedWorld = {
		lockOwner = nil,
		admins = {},
		lockClaims = {},
		lockRegistry = {},
		nextLockId = 1,
	}

	-- Test 1: World owner can modify locked world
	local ok1 = pcall(function()
		local result = LockService.CanModify(mockOwner, lockedWorld, 5, 5)
		assert(result == true, "Expected true for world owner in locked world")
	end)
	print(` Test 1 (world owner in locked world):       {ok1 and "PASS" or "FAIL"}`)

	-- Test 2: World admin can modify locked world
	local ok2 = pcall(function()
		local result = LockService.CanModify(mockAdmin, lockedWorld, 5, 5)
		assert(result == true, "Expected true for world admin in locked world")
	end)
	print(` Test 2 (world admin in locked world):       {ok2 and "PASS" or "FAIL"}`)

	-- Test 3: Non-owner cannot modify inside a small lock in locked world
	local ok3 = pcall(function()
		local result = LockService.CanModify(mockOther, lockedWorld, 5, 5)
		assert(result == false, "Expected false for non-owner inside small lock")
	end)
	print(` Test 3 (non-owner in locked + small lock):  {ok3 and "PASS" or "FAIL"}`)

	-- Test 4: Non-owner can modify unlocked world (no locks)
	local ok4 = pcall(function()
		local result = LockService.CanModify(mockOther, unlockedWorld, 5, 5)
		assert(result == true, "Expected true for non-owner in unlocked world")
	end)
	print(` Test 4 (non-owner in unlocked world):       {ok4 and "PASS" or "FAIL"}`)

	-- Summary
	local passed = (ok1 and 1 or 0) + (ok2 and 1 or 0) + (ok3 and 1 or 0) + (ok4 and 1 or 0)
	print(`============================================`)
	print(`[DevTools] CanModify test: {passed}/4 passed`)
	if passed < 4 then
		warn("[DevTools] Some CanModify tests FAILED — review LockService.lua")
	end
end

--[[
	Initialize DevTools.
	Runs LockService.CanModify unit test on boot in Studio.
]]
function DevTools.Init()
	if RunService:IsStudio() then
		print("[DevTools] Initialized — Studio mode active, dev commands enabled")
		DevTools.TestCanModify()
	else
		print("[DevTools] Running in production — dev commands disabled")
	end
end

return DevTools
