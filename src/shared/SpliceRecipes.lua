-- SpliceRecipes.lua
-- All splice recipe pairs for GrowRoblox
-- Recipe key: "minId_maxId" -> resultId
-- All recipes are symmetric (A+B = B+A)

local SpliceRecipes = {}

-- Internal recipe lookup table
local recipes = {}

-- Helper: register a recipe
local function recipe(seedA: number, seedB: number, result: number)
	local key
	if seedA < seedB then
		key = seedA .. "_" .. seedB
	else
		key = seedB .. "_" .. seedA
	end
	recipes[key] = result
end

--[[
	=== TIER 2 RECIPES ===
	From base world items (Dirt=1, Rock=2, CaveBg=3, Lava=4)
]]

-- Dirt + Cave Background = Door (ID 8)
recipe(1, 3, 8)

-- Dirt + Rock = Grass (ID 7)
recipe(1, 2, 7)

-- Dirt + Lava = Wood Block (ID 9)
recipe(1, 4, 9)

-- Rock + Lava = Glass Pane (ID 10)
recipe(2, 4, 10)

-- Cave Background + Rock = Sign (ID 11)
recipe(2, 3, 11)

-- Lava + Cave Background = Lava Rock (ID 12)
recipe(3, 4, 12)

--[[
	=== TIER 3 RECIPES ===
	From Tier 2 items
]]

-- Grass(7) + Door(8) = Wooden Background(13)
recipe(7, 8, 13)

-- Door(8) + Sign(11) = Pointy Sign(14)
recipe(8, 11, 14)

-- Door(8) + Dirt(1) = Crappy Sign(15)
recipe(1, 8, 15)

-- Grass(7) + Dirt(1) = Daisy(16)
recipe(1, 7, 16)

-- Wood Block(9) + Grass(7) = Wooden Platform(17)
recipe(7, 9, 17)

-- Rock(2) + Door(8) = Rock Background(18)
recipe(2, 8, 18)

-- Rock(2) + Grass(7) = Bricks(19)
recipe(2, 7, 19)

-- Grass(7) + Lava(4) = Rose(20)
recipe(4, 7, 20)

-- Cave Background(3) + Grass(7) = Mushroom(22)
recipe(3, 7, 22)

-- Dirt(1) + Wood Block(9) = Cargo Shorts(25)
recipe(1, 9, 25)

-- Dirt(1) + Glass Pane(10) = Amber Glass(23)
recipe(1, 10, 23)

-- Sign(11) + Lava(4) = Torch(21)
recipe(4, 11, 21)

-- Dirt(1) + Sign(11) = Super Crate Box(24)
recipe(1, 11, 24)

--[[
	=== TIER 4 RECIPES (Sugar Cane + Window) ===
]]

-- Sugar Cane(29) + Window(30) = Sugar Window (future)
-- Add more as new items are introduced

--[[
	=== TIER 2 NEW RECIPES (IDs 31-36) ===
]]

-- Dirt + Cave BG = Timber
recipe(1, 3, 31)
-- Rock + Cave BG = Fire Brick
recipe(2, 3, 32)
-- Dirt + Rock = Mud Slab
recipe(1, 2, 33)
-- Timber + Rock = Scaffold
recipe(31, 2, 34)
-- Mud Slab + Cave BG = Stone Gate
recipe(33, 3, 35)
-- Fire Brick + Cave BG = Wall Torch
recipe(32, 3, 36)

--[[
	=== TIER 3 RECIPES (IDs 37-43) ===
]]

-- Timber + Dirt = Wood Panel
recipe(31, 1, 37)
-- Fire Brick + Rock = Cut Stone
recipe(32, 2, 38)
-- Mud Slab + Dirt = Red Floor Tile
recipe(33, 1, 39)
-- Scaffold + Timber = Bridge Plank
recipe(34, 31, 40)
-- Stone Gate + Fire Brick = Heavy Gate
recipe(35, 32, 41)
-- Wall Torch + Wood Panel = Lamp Post
recipe(36, 37, 42)
-- Red Floor Tile + Cave BG = Burnt Shard
recipe(39, 3, 43)

--[[
	=== TIER 4 RECIPES (IDs 44-49) ===
]]

-- Cut Stone + Burnt Shard = Black Glass Tile
recipe(38, 43, 44)
-- Wood Panel + Burnt Shard = Charwood Beam
recipe(37, 43, 45)
-- Bridge Plank + Cut Stone = Stone Arch
recipe(40, 38, 46)
-- Heavy Gate + Charwood Beam = Wood Iron Door
recipe(41, 45, 47)
-- Lamp Post + Black Glass Tile = Blue Crystal Lamp
recipe(42, 44, 48)
-- Burnt Shard + Burnt Shard = Sparkle Dust
recipe(43, 43, 49)

--[[
	=== TIER 5 RECIPES (IDs 50-53) ===
]]

-- Black Glass Tile + Sparkle Dust = Shadow Tile
recipe(44, 49, 50)
-- Charwood Beam + Sparkle Dust = Lava Wood
recipe(45, 49, 51)
-- Blue Crystal Lamp + Sparkle Dust = Rainbow Beacon
recipe(48, 49, 52)
-- Stone Arch + Sparkle Dust = Golden Arch
recipe(46, 49, 53)

--[[
	=== TIER 6 FARMABLE SEED RECIPES (IDs 54-56) ===
]]

-- Shadow Tile + Lava Wood = Ashveil Seed
recipe(50, 51, 54)
-- Golden Arch + Rainbow Beacon = Duskbloom Seed
recipe(53, 52, 55)
-- Ashveil Seed + Duskbloom Seed = Sunstone Seed
recipe(54, 55, 56)

--[[
	=== PUBLIC API ===
]]

function SpliceRecipes.GetResult(seedA: number, seedB: number): number?
	local key
	if seedA < seedB then
		key = seedA .. "_" .. seedB
	else
		key = seedB .. "_" .. seedA
	end
	return recipes[key]
end

function SpliceRecipes.CanSplice(seedA: number, seedB: number): boolean
	return SpliceRecipes.GetResult(seedA, seedB) ~= nil
end

function SpliceRecipes.GetAllRecipes(): { { seedA: number, seedB: number, result: number } }
	local list = {}
	for key, result in pairs(recipes) do
		local a, b = string.match(key, "(%d+)_(%d+)")
		table.insert(list, {
			seedA = tonumber(a),
			seedB = tonumber(b),
			result = result,
		})
	end
	return list
end

-- Register tier 1 seeds for backwards compatibility
-- Dirt Seed(101), Rock Seed(102), CaveBg Seed(103), Lava Seed(104)

local recipeCount = 0
for _ in pairs(recipes) do recipeCount += 1 end
print(`[SpliceRecipes] Loaded {recipeCount} recipes`)

return SpliceRecipes
