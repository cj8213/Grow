-- WorldRenderer.lua (client)
-- Parts-based 2D tile world renderer for GrowRoblox
-- Includes static tile rendering, collision barriers, and 2.5D parallax clouds

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = require(ReplicatedStorage.Shared)
local WorldConfig = Shared.WorldConfig
local ItemDatabase = Shared.ItemDatabase
local RemoteEvents = require(ReplicatedStorage.Shared.RemoteEvents)

local WorldRenderer = {}

--[[
    ===== CONSTANTS =====
]]

local WORLD_WIDTH = WorldConfig.WORLD_WIDTH          -- 100
local WORLD_HEIGHT = WorldConfig.WORLD_HEIGHT        -- 60
local TILE_SIZE = 4                                  -- studs per tile
local RENDER_DISTANCE = 20                           -- tiles in each direction from camera

-- Layer constants
local LAYER_SURFACE_Y = 5
local LAYER_BEDROCK_START = 54
local BG_Z_OFFSET = TILE_SIZE / 2 + 0.5

-- Background Constants
local CLOUD_Z_DEPTH = -60   -- Deep background plane

-- NEW CLOUD CONFIGURATION:
local CLOUD_COUNT = 12          -- How many clouds to spawn
local CLOUD_BASE_Y = 5.8     -- The average Y height of the clouds
local CLOUD_Y_VARIANCE = 15     -- How far up/down clouds can randomly spawn from the base Y
local CLOUD_LEAN_ANGLE = 15     -- Degrees to tilt the cloud back on the X-axis
local CLOUD_MIN_SPEED = 1.5     -- Slowest cloud speed
local CLOUD_MAX_SPEED = 3.5     -- Fastest cloud speed

--[[
    ===== STATE =====
]]

local localPlayer = Players.LocalPlayer

-- Environment Folders
local worldTilesFolder: Folder? = nil
local worldBarriersFolder: Folder? = nil
local backgroundFolder: Folder? = nil

-- Memory Management: Track all event connections to prevent leaks
local connections: { RBXScriptConnection } = {}

-- Grid and Render Tracking
local tileGrid: { { table } } = {}
local renderedTiles: { [number]: { fgPart: Part?, bgPart: Part? } } = {}
local activeClouds: { MeshPart } = {}

-- Camera & Player Tracking
local lastCameraCenterX = -999
local lastCameraCenterY = -999
local playerTileX = math.floor(WORLD_WIDTH / 2)
local playerTileY = LAYER_SURFACE_Y

local colorCache: { [number]: Color3 } = {}
local fgRaycastParams: RaycastParams? = nil

-- Reference to the Assets folder in ReplicatedStorage containing Decal textures
-- The user should have Decal objects named "Dirt" and "Grass" in ReplicatedStorage.Assets
local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")


--[[
    ===== DEFAULT TERRAIN GENERATOR =====
]]
local function getDefaultTile(x: number, y: number)
    if y >= 54 and y <= 59 then
        return { fg = 5, bg = 0, hp = 99999, owner = nil, treeData = nil, fgExtra = nil }
    elseif y >= 50 and y <= 53 then
        local pattern = (x * 7 + y * 13) % 10
        if pattern < 5 then
            return { fg = 2, bg = 4, hp = 10, owner = nil, treeData = nil, fgExtra = nil }
        else
            return { fg = 1, bg = 4, hp = 6, owner = nil, treeData = nil, fgExtra = nil }
        end
    elseif y >= 35 and y <= 49 then
        return { fg = 2, bg = 3, hp = 10, owner = nil, treeData = nil, fgExtra = nil }
    elseif y >= 6 and y <= 34 then
        local isRock = ((x * 17 + y * 31) % 100) < 8
        local fgId = isRock and 2 or 1
        local hp = isRock and 10 or 6
        return { fg = fgId, bg = 3, hp = hp, owner = nil, treeData = nil, fgExtra = nil }
    elseif y == LAYER_SURFACE_Y then
        return { fg = 1, bg = 0, hp = 6, owner = nil, treeData = nil, fgExtra = nil }
    elseif y < LAYER_SURFACE_Y then
        return { fg = 0, bg = 0, hp = 0, owner = nil, treeData = nil, fgExtra = nil }
    end
    return { fg = 0, bg = 0, hp = 0, owner = nil, treeData = nil, fgExtra = nil }
end

local function rebuildGrid(sparseData: { table }?)
    tileGrid = {}
    for y = 0, WORLD_HEIGHT - 1 do
        tileGrid[y + 1] = {}
        for x = 0, WORLD_WIDTH - 1 do
            tileGrid[y + 1][x + 1] = getDefaultTile(x, y)
        end
    end

    local doorX = math.floor(WORLD_WIDTH / 2)
    local doorY = LAYER_SURFACE_Y
    tileGrid[doorY + 1][doorX + 1] = { fg = 6, bg = 0, hp = 99999, owner = nil, treeData = nil, fgExtra = nil }
    if doorY + 1 < WORLD_HEIGHT then
        tileGrid[doorY + 2][doorX + 1] = { fg = 5, bg = 0, hp = 99999, owner = nil, treeData = nil, fgExtra = nil }
    end

    if sparseData and #sparseData > 0 then
        for _, entry in ipairs(sparseData) do
            local i = entry.i
            if i and i >= 1 and i <= WORLD_WIDTH * WORLD_HEIGHT then
                local ty = math.floor((i - 1) / WORLD_WIDTH)
                local tx = (i - 1) % WORLD_WIDTH
                local tile = tileGrid[ty + 1][tx + 1]
                if entry.fg ~= nil then tile.fg = entry.fg end
                if entry.bg ~= nil then tile.bg = entry.bg end
                if entry.hp ~= nil then tile.hp = entry.hp end
                if entry.treeData ~= nil then tile.treeData = entry.treeData end
                if entry.fgExtra ~= nil then tile.fgExtra = entry.fgExtra end
            end
        end
    end
end

--[[
    ===== COLOR CACHE HELPERS =====
]]
local function getItemColor(itemId: number): Color3
    if itemId == 0 then return Color3.fromRGB(0, 0, 0) end
    if colorCache[itemId] then return colorCache[itemId] end

    local item = ItemDatabase.GetItem(itemId)
    if item and item.color then
        colorCache[itemId] = item.color
        return item.color
    end

    local fallback = Color3.fromRGB(150, 150, 150)
    colorCache[itemId] = fallback
    return fallback
end

--[[
    ===== PART CREATION =====
]]
local function tileIndex(x: number, y: number): number
    return x + y * WORLD_WIDTH
end

local function tileToWorld(x: number, y: number): Vector3
    return Vector3.new(x * TILE_SIZE, -y * TILE_SIZE, 0)
end

local function getTexturesForBlock(fgId, x, y)
    -- Returns (topFaceTextureId, sideFaceTextureId, frontBackTextureId) or nil,nil,nil if no texture
    -- frontBackTextureId defaults to sideFaceTextureId if nil
    
    if not assetsFolder then
        return nil, nil, nil
    end
    
    if fgId == 1 then
        -- Dirt block: check the tile ABOVE (y-1) to determine if this is the top-most exposed block.
        -- A block is "top-most" if there is NO block above it (sky/air above).
        -- If there IS a block above, this block is buried and should show Dirt on all faces.
        local aboveRow = tileGrid[y]  -- tileGrid is 1-indexed, y is 0-based, so tileGrid[y] = row at Y = y-1
        local aboveTile = aboveRow and aboveRow[x + 1]
        local aboveFg = aboveTile and aboveTile.fg or 0
        
        local dirtDecal = assetsFolder:FindFirstChild("Dirt")
        local grassDecal = assetsFolder:FindFirstChild("Grass")
        local topGrassDecal = assetsFolder:FindFirstChild("TopGrass")
        local dirtTex = dirtDecal and dirtDecal.Texture
        local grassTex = grassDecal and grassDecal.Texture
        local topGrassTex = topGrassDecal and topGrassDecal.Texture
        
        -- Surface blocks (LAYER_SURFACE_Y) always show Grass on top, Grass on front/back/left/right, Dirt on sides (bottom)
        -- This matches the user's requirement: "the most top dirt block should have the grass texture always"
        if y == LAYER_SURFACE_Y then
            return topGrassTex or grassTex, dirtTex, grassTex
        end
        
        if aboveFg == 0 or aboveFg == nil then
            -- Top-most exposed Dirt (no block above): Grass/TopGrass on top, Grass on front/back/left/right, Dirt on bottom
            return topGrassTex or grassTex, dirtTex, grassTex
        else
            -- Buried Dirt (block above): Dirt on all faces
            return dirtTex, dirtTex, dirtTex
        end
    elseif fgId == 7 then
        -- Grass block: TopGrass on top, Grass on sides and front/back
        local grassDecal = assetsFolder:FindFirstChild("Grass")
        local topGrassDecal = assetsFolder:FindFirstChild("TopGrass")
        local grassTex = grassDecal and grassDecal.Texture
        local topGrassTex = topGrassDecal and topGrassDecal.Texture
        return topGrassTex or grassTex, grassTex, grassTex
    end
    
    return nil, nil, nil
end

local function applyBlockTextures(fgPart: Part, fgId: number, x: number, y: number)
    -- Determine which textures to use for this block
    local topTex, sideTex, frontBackTex = getTexturesForBlock(fgId, x, y)
    if not topTex and not sideTex and not frontBackTex then return end

    -- Use frontBackTex for front/back/left/right faces, falling back to sideTex
    local actualFrontBackTex = frontBackTex or sideTex
    local actualTopTex = topTex or sideTex

    -- Helper function to generate a SurfaceGui instead of a Decal
    local function applyFace(face: Enum.NormalId, textureString: string)
        if not textureString then return end
        
        local surfaceGui = Instance.new("SurfaceGui")
        surfaceGui.Name = face.Name
        surfaceGui.Face = face
        surfaceGui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
        surfaceGui.CanvasSize = Vector2.new(100, 100)
        surfaceGui.LightInfluence = 1 -- Ensures the texture reacts to world lighting/shadows
        surfaceGui.Parent = fgPart

        local imageLabel = Instance.new("ImageLabel")
        imageLabel.Size = UDim2.new(1, 0, 1, 0)
        imageLabel.BackgroundTransparency = 1
        imageLabel.Image = textureString
        
        -- THE MAGIC BULLET: This completely disables the blurry edge filtering
        imageLabel.ResampleMode = Enum.ResamplerMode.Pixelated 
        
        imageLabel.Parent = surfaceGui
    end

    -- Apply the textures to all sides using SurfaceGuis
    applyFace(Enum.NormalId.Front, actualFrontBackTex)
    applyFace(Enum.NormalId.Back, actualFrontBackTex)
    applyFace(Enum.NormalId.Top, actualTopTex)
    applyFace(Enum.NormalId.Bottom, sideTex)
    applyFace(Enum.NormalId.Left, actualFrontBackTex)
    applyFace(Enum.NormalId.Right, actualFrontBackTex)
end

local function createTileParts(x: number, y: number)
    local key = tileIndex(x, y)
    local tile = tileGrid[y + 1] and tileGrid[y + 1][x + 1]
    if not tile then return end

    local fgId = tile.fg or 0

    local existing = renderedTiles[key]
    if existing then
    	if existing.fgPart then existing.fgPart:Destroy() end
    	if existing.bgPart then existing.bgPart:Destroy() end
    	renderedTiles[key] = nil
    end

    if not worldTilesFolder then return end
    local worldPos = tileToWorld(x, y)
    local fgPart: Part? = nil

    if fgId > 0 then
        -- Check if this is a tall door — spans 2 tiles vertically
        local itemDef = ItemDatabase.GetItem(fgId)
        local isTallDoor = itemDef and itemDef.isTallDoor == true

        if isTallDoor then
            -- Tall door: create a Part that spans 2 tiles vertically
            fgPart = Instance.new("Part")
            fgPart.Name = `Tile_{x}_{y}`
            fgPart.Size = Vector3.new(TILE_SIZE, TILE_SIZE * 2, TILE_SIZE)
            -- Offset up by half a tile so it spans current tile and tile above
            fgPart.Position = Vector3.new(x * TILE_SIZE, -y * TILE_SIZE + TILE_SIZE / 2, 0)
            fgPart.Anchored = true
            fgPart.CanCollide = true
            fgPart.CastShadow = false
            fgPart.Material = Enum.Material.SmoothPlastic
            fgPart.BrickColor = BrickColor.new(getItemColor(fgId))
            fgPart.Parent = worldTilesFolder
        else
            -- Standard block: 1 tile
            fgPart = Instance.new("Part")
            fgPart.Name = `Tile_{x}_{y}`
            fgPart.Size = Vector3.new(TILE_SIZE, TILE_SIZE, TILE_SIZE)
            fgPart.Position = worldPos
            fgPart.Anchored = true
            fgPart.CanCollide = true
            fgPart.CastShadow = false
            fgPart.Material = Enum.Material.SmoothPlastic
            fgPart.BrickColor = BrickColor.new(getItemColor(fgId))
            fgPart.Parent = worldTilesFolder
        end

        -- Apply textures to block faces
        applyBlockTextures(fgPart, fgId, x, y)
    else
        -- Invisible clickable part for empty tiles (air/sky/broken)
        -- Allows raycast to detect clicks on empty spaces for block placement
        fgPart = Instance.new("Part")
        fgPart.Name = `Tile_{x}_{y}`
        fgPart.Size = Vector3.new(TILE_SIZE, TILE_SIZE, TILE_SIZE)
        fgPart.Position = worldPos
        fgPart.Anchored = true
        fgPart.CanCollide = false       -- Players walk through
        fgPart.CanQuery = true          -- Raycast can hit it (default)
        fgPart.Transparency = 1         -- Invisible
        fgPart.CastShadow = false
        fgPart.Material = Enum.Material.SmoothPlastic
        fgPart.Parent = worldTilesFolder
    end

    -- Store the fgPart for this tile
    renderedTiles[key] = { fgPart = fgPart, bgPart = nil }

    -- If this tile has treeData (a seed/tree is planted), add a small sprout indicator Part on top
    if fgPart and fgId > 0 and tile.treeData and tile.treeData.seedId then
        local seedDef = ItemDatabase.GetSeed(tile.treeData.seedId)
        local sproutColor = seedDef and seedDef.color or Color3.fromRGB(100, 255, 100)
        local sprout = Instance.new("Part")
        sprout.Name = `Sprout_{x}_{y}`
        sprout.Size = Vector3.new(2, 1.5, 2)
        -- Position sprout on TOP of the tile: tile center + half tile up + half sprout up
        sprout.Position = Vector3.new(x * TILE_SIZE, -y * TILE_SIZE + TILE_SIZE / 2 + 1, 0)
        sprout.Anchored = true
        sprout.CanCollide = false
        sprout.CanQuery = false
        sprout.CastShadow = false
        sprout.BrickColor = BrickColor.new(sproutColor)
        sprout.Material = Enum.Material.ForceField
        sprout.Transparency = 0.3
        sprout.Parent = worldTilesFolder
        
        -- Store reference to sprout so it gets cleaned up with the tile
        renderedTiles[key].bgPart = sprout
    end
end

local function destroyOutOfRangeTiles(centerX: number, centerY: number)
    local keysToRemove: { number } = {}
    for key, parts in pairs(renderedTiles) do
        local tx = key % WORLD_WIDTH
        local ty = math.floor(key / WORLD_WIDTH)
        local dx = math.abs(tx - centerX)
        local dy = math.abs(ty - centerY)
        if dx > RENDER_DISTANCE or dy > RENDER_DISTANCE then
            table.insert(keysToRemove, key)
        end
    end

    for _, key in ipairs(keysToRemove) do
        local parts = renderedTiles[key]
        if parts then
            if parts.fgPart then parts.fgPart:Destroy() end
            if parts.bgPart then parts.bgPart:Destroy() end
            renderedTiles[key] = nil
        end
    end
end

local function renderViewport(centerX: number, centerY: number)
    if not worldTilesFolder then return end
    destroyOutOfRangeTiles(centerX, centerY)

    local startX = math.max(0, centerX - RENDER_DISTANCE)
    local endX = math.min(WORLD_WIDTH - 1, centerX + RENDER_DISTANCE)
    local startY = math.max(0, centerY - RENDER_DISTANCE)
    local endY = math.min(WORLD_HEIGHT - 1, centerY + RENDER_DISTANCE)

    for y = startY, endY do
        for x = startX, endX do
            local key = tileIndex(x, y)
            if not renderedTiles[key] then
                createTileParts(x, y)
            end
        end
    end
end

local function clearAllTiles()
	for key, parts in pairs(renderedTiles) do
		if parts.fgPart then parts.fgPart:Destroy() end
		if parts.bgPart then parts.bgPart:Destroy() end
	end
	renderedTiles = {}
end

--[[
    ===== ENVIRONMENT SETUP (BARRIERS & BACKGROUND) =====
]]
local function createBarriers()
    if not worldTilesFolder then return end

    worldBarriersFolder = Instance.new("Folder")
    worldBarriersFolder.Name = "WorldBarriers"
    worldBarriersFolder.Parent = Workspace

    local worldWidthStuds = WORLD_WIDTH * TILE_SIZE
    local worldHeightStuds = WORLD_HEIGHT * TILE_SIZE
    local barrierThickness = TILE_SIZE
    local barrierCenterY = -worldHeightStuds / 2
    local barrierHeight = worldHeightStuds + TILE_SIZE * 2

    local function makeBarrier(name: string, size: Vector3, pos: Vector3)
        local p = Instance.new("Part")
        p.Name = name
        p.Size = size
        p.Position = pos
        p.Anchored = true
        p.CanCollide = true
        p.CanQuery = false
        p.Transparency = 1
        p.Material = Enum.Material.SmoothPlastic
        p.Parent = worldBarriersFolder
        return p
    end

    makeBarrier("Barrier_Left", Vector3.new(barrierThickness, barrierHeight, TILE_SIZE * 3), Vector3.new(-TILE_SIZE, barrierCenterY, 0))
    makeBarrier("Barrier_Right", Vector3.new(barrierThickness, barrierHeight, TILE_SIZE * 3), Vector3.new(worldWidthStuds, barrierCenterY, 0))
    makeBarrier("Barrier_Back", Vector3.new(worldWidthStuds + TILE_SIZE * 2, barrierHeight, barrierThickness), Vector3.new(worldWidthStuds / 2 - TILE_SIZE / 2, barrierCenterY, -TILE_SIZE))
    makeBarrier("Barrier_Front", Vector3.new(worldWidthStuds + TILE_SIZE * 2, barrierHeight, barrierThickness), Vector3.new(worldWidthStuds / 2 - TILE_SIZE / 2, barrierCenterY, TILE_SIZE))
    -- Bottom floor barrier: prevents items and players from falling into the void
    -- Placed directly below the maximum WORLD_HEIGHT
    makeBarrier("Barrier_Bottom", Vector3.new(worldWidthStuds + TILE_SIZE * 2, barrierThickness, TILE_SIZE * 3), Vector3.new(worldWidthStuds / 2 - TILE_SIZE / 2, -worldHeightStuds - TILE_SIZE / 2, 0))
end

local function setupBackground()
    backgroundFolder = Instance.new("Folder")
    backgroundFolder.Name = "BackgroundDecorations"
    backgroundFolder.Parent = Workspace

    local assetsFolder = ReplicatedStorage:FindFirstChild("Assets")
    local cloudTemplate = assetsFolder and assetsFolder:FindFirstChild("Clouds")

    if cloudTemplate then
        for i = 1, CLOUD_COUNT do
            local cloud = cloudTemplate:Clone()

            -- 1. Randomized Size (Scale between 0.7x and 1.5x of the original)
            local scale = math.random(70, 150) / 100
            cloud.Size = Vector3.new(25.773 * scale, 13.327 * scale, 25.434 * scale)

            cloud.Transparency = 0.2
            cloud.Anchored = true
            cloud.CanCollide = false
            cloud.CastShadow = false

            -- 2. Randomized Positions
            -- Spread randomly across the world width
            local startX = math.random(-100, (WORLD_WIDTH * TILE_SIZE) + 100)

            -- Vary the Y position around the base height
            local startY = CLOUD_BASE_Y + (math.random(-CLOUD_Y_VARIANCE * 10, CLOUD_Y_VARIANCE * 10) / 10)

            -- Stagger the Z depth slightly so overlapping clouds don't clip/flicker (Z-fighting)
            local zOffset = math.random(-30, 30) / 10 
            cloud.Position = Vector3.new(startX, startY, CLOUD_Z_DEPTH + zOffset)

            -- 3. Lean Back (Rotate on the X axis)
            cloud.Orientation = Vector3.new(CLOUD_LEAN_ANGLE, 0, 0)

            -- 4. Assign a unique speed so they can pass each other
            local randomSpeed = math.random(CLOUD_MIN_SPEED * 10, CLOUD_MAX_SPEED * 10) / 10
            cloud:SetAttribute("Speed", randomSpeed)

            cloud.Parent = backgroundFolder
            table.insert(activeClouds, cloud)
        end
    else
        warn("[WorldRenderer] Cloud mesh not found in ReplicatedStorage.assets")
    end

    -- Continuous cloud movement loop
    local cloudConn = RunService.RenderStepped:Connect(function(dt)
        for _, cloud in ipairs(activeClouds) do
            -- Fetch this specific cloud's speed
            local speed = cloud:GetAttribute("Speed") or 2
            local newX = cloud.Position.X + (speed * dt)

            -- Wrap around when it goes far off-screen
            if newX > (WORLD_WIDTH * TILE_SIZE) + 100 then
                newX = -100
                -- Optional: Give it a new random Y height and Speed when it wraps!
                local newY = CLOUD_BASE_Y + (math.random(-CLOUD_Y_VARIANCE * 10, CLOUD_Y_VARIANCE * 10) / 10)
                cloud.Position = Vector3.new(newX, newY, cloud.Position.Z)
                cloud:SetAttribute("Speed", math.random(CLOUD_MIN_SPEED * 10, CLOUD_MAX_SPEED * 10) / 10)
            else
                cloud.Position = Vector3.new(newX, cloud.Position.Y, cloud.Position.Z)
            end
        end
    end)
    table.insert(connections, cloudConn)
end

--[[
    ===== PUBLIC API =====
]]
function WorldRenderer.Init()
    worldTilesFolder = Instance.new("Folder")
    worldTilesFolder.Name = "WorldTiles"
    worldTilesFolder.Parent = Workspace

    createBarriers()
    setupBackground()

    fgRaycastParams = RaycastParams.new()
    fgRaycastParams.FilterType = Enum.RaycastFilterType.Exclude

    -- Store RemoteEvent connections to prevent leaks
    local loadConn = RemoteEvents.WorldLoaded.OnClientEvent:Connect(function(worldName: string, sparseData: { table }, worldWidth: number, worldHeight: number)
        clearAllTiles()
        rebuildGrid(sparseData)

        local spawnX = math.floor(WORLD_WIDTH / 2)
        local spawnY = LAYER_SURFACE_Y
        playerTileX = spawnX
        playerTileY = spawnY
        lastCameraCenterX = -999
        lastCameraCenterY = -999

        renderViewport(spawnX, spawnY)
        print(`[WorldRenderer] Loaded world "{worldName}"`)
    end)
    table.insert(connections, loadConn)

    local updateConn = RemoteEvents.TileUpdated.OnClientEvent:Connect(function(worldName: string, tileX: number, tileY: number, tileData: table)
        if tileGrid[tileY + 1] and tileGrid[tileY + 1][tileX + 1] then
            local tile = tileGrid[tileY + 1][tileX + 1]
            if tileData.fg ~= nil then tile.fg = tileData.fg end
            if tileData.bg ~= nil then tile.bg = tileData.bg end
            if tileData.hp ~= nil then tile.hp = tileData.hp end
            if tileData.treeData ~= nil then tile.treeData = tileData.treeData end
            if tileData.fgExtra ~= nil then tile.fgExtra = tileData.fgExtra end
        end
        -- Re-render the updated tile
        createTileParts(tileX, tileY)
        -- Re-render the tile ABOVE (tileY-1), because its texture depends on
        -- whether there is a block above it (e.g., Dirt block with Grass-on-top vs Dirt-on-all-faces).
        -- When a block is placed at (tileX, tileY), the tile at (tileX, tileY-1) may need
        -- to change from "Grass on top" to "Dirt on all faces" (or vice versa when broken).
        if tileY - 1 >= 0 then
            createTileParts(tileX, tileY - 1)
        end
        -- Also re-render the tile BELOW (tileY+1), because when a block is broken,
        -- the block below becomes the new top-most exposed block and needs to update
        -- from "Dirt on all faces" to "Grass on top" (with Grass/TopGrass textures).
        if tileY + 1 < WORLD_HEIGHT then
            createTileParts(tileX, tileY + 1)
        end
    end)
    table.insert(connections, updateConn)

    local growthConn = RemoteEvents.GrowthUpdate.OnClientEvent:Connect(function(worldName: string, changedTiles: { { x: number, y: number, growthPercent: number } })
        -- Future enhancement
    end)
    table.insert(connections, growthConn)

    -- Lock zone visualization: ALWAYS rendered from LockZonesUpdated data
    -- Shows per-tile claimed areas as semi-transparent overlays.
    -- No dev tools needed — this fires automatically on world enter and lock changes.
    local lockZoneFolder: Folder? = nil

    local function renderLockZones(lockData: table)
        if lockZoneFolder then
            lockZoneFolder:Destroy()
            lockZoneFolder = nil
        end

        local TILE_SIZE = 4

        lockZoneFolder = Instance.new("Folder")
        lockZoneFolder.Name = "LockZoneOverlays"
        lockZoneFolder.Parent = workspace

        -- World lock indicator
        if lockData.worldLocked then
            local worldLockPart = Instance.new("Part")
            worldLockPart.Name = "WorldLockIndicator"
            worldLockPart.Size = Vector3.new(WORLD_WIDTH * TILE_SIZE, 1, TILE_SIZE * 3)
            worldLockPart.Position = Vector3.new((WORLD_WIDTH * TILE_SIZE) / 2 - TILE_SIZE / 2, TILE_SIZE, 0)
            worldLockPart.Anchored = true
            worldLockPart.CanCollide = false
            worldLockPart.CanQuery = false
            worldLockPart.CastShadow = false
            worldLockPart.BrickColor = BrickColor.new(Color3.fromRGB(255, 215, 0))
            worldLockPart.Material = Enum.Material.ForceField
            worldLockPart.Transparency = 0.5
            worldLockPart.Parent = lockZoneFolder
        end

        -- Draw each small lock zone as an outline only (edge tiles of the bounding box)
        if lockData.smallLocks then
            for _, zone in ipairs(lockData.smallLocks) do
                -- Color: bright vivid colors
                local outlineColor = Color3.fromRGB(50, 130, 255)   -- bright blue
                if zone.owner and zone.owner == localPlayer.UserId then
                    outlineColor = Color3.fromRGB(50, 255, 80)       -- bright green
                end

                if zone.claimedTiles and #zone.claimedTiles > 0 then
                    -- Build a set of claimed tile indices for O(1) edge detection
                    local claimSet: { [number]: boolean } = {}
                    local minX, maxX, minY, maxY = 9999, -1, 9999, -1
                    for _, idx in ipairs(zone.claimedTiles) do
                        claimSet[idx] = true
                        local tx = idx % WORLD_WIDTH
                        local ty = math.floor(idx / WORLD_WIDTH)
                        if tx < minX then minX = tx end
                        if tx > maxX then maxX = tx end
                        if ty < minY then minY = ty end
                        if ty > maxY then maxY = ty end
                    end

                    -- Only render tiles that are on the outermost edge of the claimed area.
                    -- A tile is an "edge" if any of its 4 neighbors is NOT in the claim set
                    -- (or is outside world bounds).
                    local neighborChecks = { {0, 1}, {0, -1}, {1, 0}, {-1, 0} }
                    for _, idx in ipairs(zone.claimedTiles) do
                        local tx = idx % WORLD_WIDTH
                        local ty = math.floor(idx / WORLD_WIDTH)

                        -- Check if this tile is on the edge
                        local isEdge = false
                        for _, check in ipairs(neighborChecks) do
                            local nx = tx + check[1]
                            local ny = ty + check[2]
                            if nx < 0 or nx >= WORLD_WIDTH or ny < 0 or ny >= WORLD_HEIGHT then
                                isEdge = true  -- edge of world = edge of zone
                            else
                                local nidx = nx + ny * WORLD_WIDTH
                                if not claimSet[nidx] then
                                    isEdge = true  -- unclaimed neighbor = edge of zone
                                end
                            end
                            if isEdge then break end
                        end

                        if isEdge then
                            local tilePos = Vector3.new(tx * TILE_SIZE, -ty * TILE_SIZE, 0)

                            -- Outline Part: thin strip on this edge tile
                            local outline = Instance.new("Part")
                            outline.Name = `LockOutline_{zone.lockId}_{tx}_{ty}`
                            outline.Size = Vector3.new(TILE_SIZE - 0.1, TILE_SIZE - 0.1, 1)
                            outline.Position = tilePos
                            outline.Anchored = true
                            outline.CanCollide = false
                            outline.CanQuery = false
                            outline.CastShadow = false
                            outline.BrickColor = BrickColor.new(outlineColor)
                            outline.Material = Enum.Material.SmoothPlastic
                            outline.Transparency = 0.3
                            outline.Parent = lockZoneFolder
                        end
                    end
                end
            end
        end
    end

    -- Listen for LockZonesUpdated (fires on world enter + lock place/break)
    local lockZonesConn = RemoteEvents.LockZonesUpdated.OnClientEvent:Connect(function(lockData: table)
        renderLockZones(lockData)
    end)
    table.insert(connections, lockZonesConn)

    -- Backward compat with old ShowLockZones (dev tools)
    local lockConn = RemoteEvents.ShowLockZones.OnClientEvent:Connect(function()
        -- Deprecated
    end)
    table.insert(connections, lockConn)

    print("[WorldRenderer] Initialized — Parts-based renderer")
end

function WorldRenderer.SetCameraCenter(tileX: number, tileY: number)
    local intX = math.floor(tileX)
    local intY = math.floor(tileY)

    if intX == lastCameraCenterX and intY == lastCameraCenterY then return end
    lastCameraCenterX = intX
    lastCameraCenterY = intY

    renderViewport(intX, intY)
end

function WorldRenderer.SetPlayerTile(tileX: number, tileY: number)
    playerTileX = tileX
    playerTileY = tileY
end

function WorldRenderer.GetPlayerTile(): (number, number)
    return playerTileX, playerTileY
end

function WorldRenderer.GetTileAt(tileX: number, tileY: number): table?
    if tileGrid[tileY + 1] then
        return tileGrid[tileY + 1][tileX + 1]
    end
    return nil
end

function WorldRenderer.GetTileGrid(): { { table } }
    return tileGrid
end

function WorldRenderer.GetWorldSize(): (number, number)
    return WORLD_WIDTH, WORLD_HEIGHT
end

function WorldRenderer.GetTileSize(): number
    return TILE_SIZE
end

function WorldRenderer.GetFgRaycastParams(): RaycastParams?
    return fgRaycastParams
end

function WorldRenderer.UpdateRaycastFilter(character: Model?)
    if not fgRaycastParams then return end

    local filterList: { Instance } = {}
    if character then
        for _, descendant in ipairs(character:GetDescendants()) do
            if descendant:IsA("BasePart") then
                table.insert(filterList, descendant)
            end
        end
    end

    -- Also exclude world barrier parts so raycasts pass through to tiles
    if worldBarriersFolder then
        for _, barrierPart in ipairs(worldBarriersFolder:GetChildren()) do
            if barrierPart:IsA("BasePart") then
                table.insert(filterList, barrierPart)
            end
        end
    end

    fgRaycastParams.FilterDescendantsInstances = filterList
end

function WorldRenderer.WorldToTile(worldPos: Vector3): (number, number)
    local tx = math.floor((worldPos.X + TILE_SIZE / 2) / TILE_SIZE)
    local ty = math.floor((-worldPos.Y + TILE_SIZE / 2) / TILE_SIZE)
    return tx, ty
end

function WorldRenderer.Destroy()
    -- 1. Disconnect all events to prevent memory leaks
    for _, conn in ipairs(connections) do
        if conn.Connected then
            conn:Disconnect()
        end
    end
    connections = {} -- Clear the table

    -- 2. Clear visual objects
    clearAllTiles()

    if worldTilesFolder then
        worldTilesFolder:Destroy()
        worldTilesFolder = nil
    end

    if worldBarriersFolder then
        worldBarriersFolder:Destroy()
        worldBarriersFolder = nil
    end

    if backgroundFolder then
        backgroundFolder:Destroy()
        backgroundFolder = nil
    end

    -- 3. Clear data structures
    tileGrid = {}
    activeClouds = {}
    fgRaycastParams = nil

    print("[WorldRenderer] Destroyed safely with no memory leaks")
end

return WorldRenderer