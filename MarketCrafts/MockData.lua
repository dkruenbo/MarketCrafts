-- MockData.lua — Simulation / mock data for testing without a second account.
-- Usage: /mc debug  → toggle debug mode
--        /mc sim N  → inject N fake sellers into the browse cache
--        /mc sim clear → remove all simulated entries
-- Requires debug mode to be ON. Data flows through Cache:AddOrUpdate so all
-- rate-limiting, TTL, blocklist, and UI refresh paths are exercised.
local AddonName, NS = ...
local MC = NS.MC
MC.MockData = {}

---------------------------------------------------------------------------
-- Debug mode (same pattern as GuildCrafts)
---------------------------------------------------------------------------
MC.debugMode = false

function MC:Debug(...)
    if self.debugMode then
        self:Print("|cff999999[debug]|r", ...)
    end
end

---------------------------------------------------------------------------
-- Sample data pools — real TBC Classic item IDs and names
---------------------------------------------------------------------------
local PROF_NAMES = {
    "Alchemy", "Blacksmithing", "Enchanting",
    "Engineering", "Leatherworking", "Tailoring",
}

-- { itemID, itemName, profName }
local SAMPLE_RECIPES = {
    -- Alchemy
    { 22861, "Flask of Supreme Power",        "Alchemy" },
    { 22854, "Flask of Distilled Wisdom",     "Alchemy" },
    { 22866, "Flask of Pure Death",           "Alchemy" },
    { 22851, "Flask of Fortification",        "Alchemy" },
    { 33447, "Elixir of Major Agility",       "Alchemy" },
    { 22845, "Major Arcane Protection Potion", "Alchemy" },
    { 22839, "Destruction Potion",            "Alchemy" },
    { 22838, "Haste Potion",                  "Alchemy" },
    { 31679, "Fel Mana Potion",               "Alchemy" },
    { 22832, "Super Mana Potion",             "Alchemy" },
    -- Blacksmithing
    { 23541, "Lionheart Blade",               "Blacksmithing" },
    { 28421, "Bulwark of Kings",              "Blacksmithing" },
    { 28425, "Blazeguard",                    "Blacksmithing" },
    { 23540, "Felsteel Longblade",            "Blacksmithing" },
    { 23538, "Khorium Champion",              "Blacksmithing" },
    { 23529, "Adamantite Rapier",             "Blacksmithing" },
    -- Enchanting
    { 22560, "Formula: Enchant Weapon - Mongoose",       "Enchanting" },
    { 22561, "Formula: Enchant Weapon - Soulfrost",      "Enchanting" },
    { 22559, "Formula: Enchant Weapon - Sunfire",        "Enchanting" },
    { 28270, "Formula: Enchant Ring - Spellpower",       "Enchanting" },
    { 28271, "Formula: Enchant Ring - Healing Power",    "Enchanting" },
    { 22555, "Formula: Enchant Bracer - Spellpower",     "Enchanting" },
    -- Engineering
    { 23825, "Gnomish Power Goggles",         "Engineering" },
    { 23828, "Goblin Rocket Launcher",        "Engineering" },
    { 23763, "Felsteel Stabilizer",           "Engineering" },
    { 23746, "Elemental Seaforium Charge",    "Engineering" },
    -- Leatherworking
    { 29525, "Drums of Battle",               "Leatherworking" },
    { 29529, "Drums of Panic",                "Leatherworking" },
    { 25686, "Stylin' Purple Hat",            "Leatherworking" },
    { 25689, "Stylin' Crimson Hat",           "Leatherworking" },
    { 29502, "Netherscale Armor",             "Leatherworking" },
    -- Tailoring
    { 21874, "Primal Mooncloth Robe",         "Tailoring" },
    { 21875, "Primal Mooncloth Shoulders",    "Tailoring" },
    { 21871, "Frozen Shadoweave Boots",       "Tailoring" },
    { 21848, "Spellfire Robe",                "Tailoring" },
    { 24266, "Spellstrike Pants",             "Tailoring" },
    { 24262, "Battlecast Pants",              "Tailoring" },
}

local SELLER_NAMES = {
    "Aelindra", "Brakgor", "Crystalwind", "Durnholde", "Elyndra",
    "Frostweave", "Grimbolt", "Haldren", "Illyria", "Jaximus",
    "Kaelthar", "Luminos", "Mordreth", "Nightpaw", "Oakenshield",
    "Pyraxis", "Quilboar", "Ravencrest", "Shadowmend", "Thornblade",
    "Uldaman", "Vexoria", "Wyrmcrest", "Xalvador", "Zandalor",
}

---------------------------------------------------------------------------
-- Simulation commands
---------------------------------------------------------------------------
function MC.MockData:HandleSimCommand(arg)
    if not MC.debugMode then
        MC:Print("Simulation requires debug mode. Run /mc debug first.")
        return
    end

    MC:Debug("HandleSimCommand called with arg:", arg)

    if arg == "clear" then
        MC.MockData:SimClear()
    else
        local count = tonumber(arg)
        if count and count > 0 then
            MC:Debug("Generating", count, "simulated sellers")
            MC.MockData:SimGenerate(count)
        else
            MC:Print("Usage: /mc sim <N> | /mc sim clear")
        end
    end
end

--- Inject N fake sellers, each with 1-5 random listings.
--- Data flows through Cache:AddOrUpdate so all validation, rate-limiting,
--- icon resolution, and UI refresh paths are tested end-to-end.
function MC.MockData:SimGenerate(count)
    MC:Debug("SimGenerate starting, count =", count)
    local injected = 0
    local totalListings = 0

    for i = 1, count do
        local seller = SELLER_NAMES[((i - 1) % #SELLER_NAMES) + 1]
        -- Append a number suffix if we wrap around the name list
        if i > #SELLER_NAMES then
            seller = seller .. tostring(math.ceil(i / #SELLER_NAMES))
        end

        MC:Debug("Creating seller:", seller)

        -- Pick 1-5 random recipes for this seller
        local numListings = math.random(1, 5)
        local used = {}
        for _ = 1, numListings do
            local idx = math.random(#SAMPLE_RECIPES)
            -- Avoid duplicate recipes per seller
            local attempts = 0
            while used[idx] and attempts < 20 do
                idx = (idx % #SAMPLE_RECIPES) + 1
                attempts = attempts + 1
            end
            if not used[idx] then
                used[idx] = true
                local recipe = SAMPLE_RECIPES[idx]

                MC:Debug("  Adding listing:", recipe[2], "for", seller)

                -- Feed through the normal cache path
                MC.Cache:AddOrUpdate({
                    itemID   = recipe[1],
                    profName = recipe[3],
                    itemName = recipe[2],
                    seller   = seller,
                    _simulated = true,
                })
                totalListings = totalListings + 1
            end
        end
        injected = injected + 1
    end

    if MC.debugMode then
        MC:Printf("Simulated %d sellers with %d total listings.", injected, totalListings)
        MC:Debug("Mock data injected via Cache:AddOrUpdate — all validation ran.")
        MC:Debug("Current cache size:", MC.Cache:GetCacheSize())
    end
end

--- Remove all simulated entries from cache.
function MC.MockData:SimClear()
    local cleared = MC.Cache:ClearSimulated()
    MC:Printf("Cleared %d simulated listing(s).", cleared)
end
