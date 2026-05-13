-- init.luau
-- Shared module root - exports all shared modules
-- This file is at src/shared/init.luau -> ReplicatedStorage.Shared

local Shared = {}

Shared.Enums = require(script.Enums)
Shared.Types = require(script.Types)
Shared.Remotes = require(script.Remotes)

-- New modules for the 2D tile-based system
Shared.WorldConfig = require(script.WorldConfig)
Shared.ItemDatabase = require(script.ItemDatabase)
Shared.SpliceRecipes = require(script.SpliceRecipes)

-- Task #5 RemoteEvents module (flat API with Throttle helper)
-- Uses separate "GrowRemotes" folder to avoid conflict with legacy Remotes module
Shared.RemoteEvents = require(script.RemoteEvents)

-- Gem compression utility (shared between server and client)
Shared.GemUtils = require(script.GemUtils)

return Shared
