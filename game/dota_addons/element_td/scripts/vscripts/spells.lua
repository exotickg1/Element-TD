-- spells.lua
-- handles player spell upgrading

local towersKV = LoadKeyValues("scripts/kv/towers.kv")

function UpdatePlayerSpells(playerID)
	local playerData = GetPlayerData(playerID)
	local hero = PlayerResource:GetSelectedHeroEntity(playerID)
	if hero then
		for i=0,15 do
			local ability = hero:GetAbilityByIndex(i)
			if ability then
				ability:SetActivated(MeetsAbilityElementRequirements(ability:GetAbilityName(), playerID))
			end
		end

		for i=0,5 do
			local item = hero:GetItemInSlot(i)
			if item then
				local itemName = item:GetAbilityName()
				if itemName == "item_build_periodic_tower_disabled" and MeetsItemElementRequirements(item, playerID) then
					item:RemoveSelf()
					hero:AddItem(CreateItem("item_build_periodic_tower", hero, hero))
				end
			end
		end

		-- In Random mode, essence purchasing is disabled
		if IsPlayerUsingRandomMode( playerID ) then
			local buy_essence = GetItemByName(playerData.summoner, "item_buy_pure_essence")
			if buy_essence then
				buy_essence:RemoveSelf()
			end
		end
	end
end

--called when a Sell Tower ability is cast
function SellTowerCast(keys)
	local tower = keys.caster

	if tower:GetHealth() == tower:GetMaxHealth() then -- only allow selling if the tower is fully built
		local hero = tower:GetOwner()
		local playerID = hero:GetPlayerID()
		local playerData = GetPlayerData(playerID)
		local sellPercentage = tonumber(keys.SellAmount)

		local refundAmount = math.ceil(GetUnitKeyValue(tower.class, "TotalCost") * sellPercentage)
		if sellPercentage > 0  then
			Sounds:EmitSoundOnClient(playerID, "General.Coins")	
			PopupAlchemistGold(tower, refundAmount)

		    local coins = ParticleManager:CreateParticle("particles/econ/items/alchemist/alchemist_midas_knuckles/alch_knuckles_lasthit_coins.vpcf", PATTACH_CUSTOMORIGIN, tower)
		    ParticleManager:SetParticleControl(coins, 1, tower:GetAbsOrigin())

			-- Add gold
			hero:ModifyGold(refundAmount, true, 0)

			-- If a tower costs a Pure Essence (Pure, Periodic), then that essence is refunded upon selling the tower.
			local essenceCost = GetUnitKeyValue(tower.class, "EssenceCost")
			if essenceCost > 0 then
				ModifyPureEssence(playerID, essenceCost)
			end
		end

		if tower.isClone then
			RemoveClone(tower)
		else
			-- we must delete a random clone of this type
			if playerData.clones[tower.class] and tower:HasModifier("modifier_conjure_prevent_cloning") then
				RemoveRandomClone(playerData, tower.class)
			end
		end

		--[[for towerID,_ in pairs(playerData.towers) do
			UpdateUpgrades(EntIndexToHScript(towerID))
		end]]

		tower.sold = true
		if tower.scriptObject["OnDestroyed"] then
			tower.scriptObject:OnDestroyed()
		end

		-- Kills and hide the tower, so that its running timers can still execute until it gets removed by the engine
		tower:AddEffects(EF_NODRAW)
		tower:ForceKill(true)
		playerData.towers[tower:entindex()] = nil -- remove this tower index from the player's tower list

		UpdateScoreboard(hero:GetPlayerID())
		Log:debug(playerData.name .. " has sold a tower")
		UpdatePlayerSpells(hero:GetPlayerID())
	end
end

function MeetsAbilityElementRequirements(name, playerID)
	local req = GetAbilityKeyValue(name, "Requirements")

	if req then
		local playerData = GetPlayerData(playerID)
		for e, l in pairs(req) do
			if tonumber(l) > playerData.elements[e] then
				return false
			end
		end
	end
	return true
end

function MeetsItemElementRequirements(upgrade_item, playerID)
	local name = upgrade_item:GetAbilityName()
	local req = GetItemKeyValue(name, "Requirements")

	if req then
		local playerData = GetPlayerData(playerID)
		for e, l in pairs(req) do
			if tonumber(l) > playerData.elements[e] then
				return false
			end
		end
	end
	return true
end

function UpgradeTower(keys)
	local tower = keys.caster
	local hero = tower:GetOwner()
	local newClass = keys.tower -- the class of the tower to upgrade to
	local cost = GetUnitKeyValue(newClass, "Cost") -- Old GetCostForTower(newClass)
	local playerID = hero:GetPlayerID()
	local playerData = GetPlayerData(playerID)
	local essenceCost = GetUnitKeyValue(newClass, "EssenceCost") or 0
	local playerEssence = GetPlayerData(playerID).pureEssence
	
	if not MeetsItemElementRequirements(keys.ability, playerID) then
		ShowWarnMessage(playerID, "Incomplete Element Requirements!")
	elseif essenceCost > playerEssence then
		ShowWarnMessage(playerID, "You need 1 Essence! Buy it at the Elemental Summoner")
	elseif cost > hero:GetGold() then
		ShowWarnMessage(playerID, "Not Enough Gold!")
	elseif tower:GetHealth() == tower:GetMaxHealth() then
		hero:SpendGold(cost, DOTA_ModifyGold_PurchaseItem)
		ModifyPureEssence(playerID, -essenceCost)
		GetPlayerData(playerID).towers[tower:entindex()] = nil --and remove it from the player's tower list

		-- Replace the tower by a new one
		local newTower = BuildingHelper:UpgradeBuilding(tower, newClass)

		-- set some basic values to this tower from its KeyValues
		newTower.class = newClass
		newTower.element = GetUnitKeyValue(newClass, "Element")
		newTower.damageType = GetUnitKeyValue(newClass, "DamageType")

		-- New pedestal if one wasn't created already
		if not newTower.prop then
			local basicName = newTower.damageType.."_tower"
			local pedestalName = GetUnitKeyValue(basicName, "PedestalModel")
			local prop = BuildingHelper:CreatePedestalForBuilding(newTower, basicName, GetGroundPosition(newTower:GetAbsOrigin(), nil), pedestalName)
		end

		GetPlayerData(playerID).towers[newTower:entindex()] = newClass --add this tower to the player's tower list
		UpdateUpgrades(newTower) --update this tower's upgrades
		UpdatePlayerSpells(playerID) --update the player's spells

		local upgradeData = {}
		if tower.scriptObject and tower.scriptObject["GetUpgradeData"] then
			upgradeData = tower.scriptObject:GetUpgradeData()
		end

		-- create a script object for this tower
        local scriptClassName = GetUnitKeyValue(newClass, "ScriptClass")
        if not scriptClassName then scriptClassName = "BasicTower" end
        if TOWER_CLASSES[scriptClassName] then
	        local scriptObject = TOWER_CLASSES[scriptClassName](newTower, newClass)
	        newTower.scriptClass = scriptClassName
	        newTower.scriptObject = scriptObject
	        newTower.scriptObject:OnCreated()
	        if newTower.scriptObject["ApplyUpgradeData"] then
	        	newTower.scriptObject:ApplyUpgradeData(upgradeData)
	        end
        else
	    	Log:error("Unknown script class, " .. scriptClassName .. " for tower " .. newTower.class)
    	end

    	if IsSupportTower(newTower) then
        	newTower:AddNewModifier(newTower, nil, "modifier_support_tower", {})
        end

		if string.find(GameSettings.elementsOrderName, "Random") ~= nil then
			AddAbility(newTower, "sell_tower_100")
		elseif string.find(newTower.class, "arrow_tower") ~= nil or string.find(newTower.class, "cannon_tower") ~= nil then
			AddAbility(newTower, "sell_tower_95")
		else
			AddAbility(newTower, "sell_tower_75")
		end

		AddAbility(newTower, newTower.damageType .. "_passive")
		if GetUnitKeyValue(newClass, "AOE_Full") and GetUnitKeyValue(newClass, "AOE_Half") then
			AddAbility(newTower, "splash_damage_orb")
		end

		if tower.scriptObject["OnDestroyed"] then
			tower.scriptObject:OnDestroyed()
		end

		-- When you sell/upgrade a tower that has been cloned in the last 60 seconds, you lose a random clone of that tower type (this is to prevent abuse with 100% sell).
		-- we must delete a random clone of this type
		if playerData.clones[tower.class] and tower:HasModifier("modifier_conjure_prevent_cloning") then
			RemoveRandomClone(playerData, tower.class)
		end

		local modelScale = tower:GetModelScale()
		tower.deleted = true --mark the old tower for deletion
		BuildTower(newTower, modelScale) --start the tower building animation

		if GetUnitKeyValue(newClass, "DisableTurning") then
        	newTower:AddNewModifier(newTower, nil, "modifier_disable_turning", {})
        end

		Timers:CreateTimer(function()
			RemoveUnitFromSelection( tower )
			AddUnitToSelection(newTower)
		end)
	end
end

function RemoveRandomClone( playerData, name )
	local clones = {}
	local i = 0
	for entindex,_ in pairs(playerData.clones[name]) do
		local clone = EntIndexToHScript(entindex)
		if IsValidEntity(clone) and clone:GetClassname() == "npc_dota_creature" and clone:IsAlive() then
			i = i + 1
			clones[i] = clone
		else
			playerData.clones[name][entindex] = nil
		end
	end

	if #clones > 0 then
		local ranIndex = RandomInt(1,i)
		local clone = clones[ranIndex]
		RemoveClone(clone)
	end
end

function UpdateUpgrades(tower)
	local class = tower.class
	local playerID = tower:GetPlayerOwnerID()
	local data = GetPlayerData(playerID)
	local upgrades = NPC_UNITS_CUSTOM[class].Upgrades

	-- delete all items first
	for i = 0, 5, 1 do
		local item = tower:GetItemInSlot(i)
		if item then
			UTIL_Remove(item)
		end
	end

	-- now add them again
	if upgrades.Count then
		local count = tonumber(upgrades.Count)
		for i = 1, count, 1 do
			local upgrade = upgrades[tostring(i)]
			local cost = tonumber(towersKV[upgrade].Cost)
			local suffix = ""

			--[[if cost > PlayerResource:GetGold(playerID) then
				suffix = "_disabled"
			end]]
			-- Put a _disabled item if the requirement isn't met yet
			if towersKV[upgrade].Requirements then
				for element, level in pairs(towersKV[upgrade].Requirements) do
					if level > data.elements[element] then
						suffix = "_disabled"
					end
				end
			end

			local item = CreateItem("item_upgrade_to_" .. upgrade .. suffix, nil, nil)
			tower:AddItem(item)
		end
	end
end

-- starts the tower building animation
function BuildTower(tower, baseScale)
	tower:RemoveModifierByName("modifier_invulnerable")
	tower:RemoveModifierByName("modifier_tower_truesight_aura")
	tower:AddNewModifier(nil, nil, "modifier_disarmed", {}) --towers are disarmed until they finish building
	tower:AddNewModifier(nil, nil, "modifier_silence", {}) --towers are silenced until they finish building

	local buildTime = GetUnitKeyValue(tower.class, "BuildTime")
	if not buildTime then
		print(tower.class .. " does not have a build time!")
		buildTime = 1
	else
		buildTime = tonumber(buildTime)
	end

	local scale = tower:GetModelScale()
	local scaleIncrement = (scale - baseScale) / (buildTime * 20)

	tower:SetModelScale(baseScale)
	tower:SetHealth(1)
	tower:SetMaxHealth(buildTime * 20)
	tower:SetBaseMaxHealth(buildTime * 20)

	-- create a timer to build up the tower slowly
	Timers:CreateTimer("BuildTower"..tower:entindex(), {
		endTime = 0.05,
		callback = function()
			tower:SetHealth(tower:GetHealth() + 1)
	        tower:SetModelScale(tower:GetModelScale() + scaleIncrement)

			if tower:GetHealth() == tower:GetMaxHealth() then
	        	tower:RemoveModifierByName("modifier_disarmed")
	        	tower:RemoveModifierByName("modifier_silence")
	        	tower:AddNewModifier(nil, nil, "modifier_invulnerable", {})
	        	tower:NoHealthBar()

				tower:SetMaxHealth(GetUnitKeyValue(tower.class, "TotalCost"))
				tower:SetBaseMaxHealth(GetUnitKeyValue(tower.class, "TotalCost"))

	        	tower:SetHealth(tower:GetMaxHealth())
	        	tower.scriptObject:OnBuildingFinished()
	        	return nil
	        end
	        return 0.05
		end
	})
end