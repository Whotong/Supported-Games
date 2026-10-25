--!strict
-- Grow a Plant: live Home dashboard and opt-in Farm/Shops/NPC deals. GameId 10768292556.
-- Root PlaceId 74641726785011; current live-test account recorded in game notes.
return function(Window: any, _Tabs: any)
	local Players = game:GetService("Players")
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Workspace = game:GetService("Workspace")
	local RunService = game:GetService("RunService")
	local player = Players.LocalPlayer
	local modules = ReplicatedStorage:FindFirstChild("Modules")
	local plants = ReplicatedStorage:FindFirstChild("Plants")
	local packs = ReplicatedStorage:FindFirstChild("SeedPacks")
	local alive, queued, growing = true, false, false
	local shopsChanged: (() -> ())?
	local farmChanged: (() -> ())?
	local dealsChanged: (() -> ())?
	local eventsChanged: (() -> ())?
	local connections: {[any]: boolean} = {}
	local dirty: {[string]: () -> ()} = {}
	local function listen(signal: any, callback: any, group: any?): any
		local connection = signal:Connect(callback)
		connections[connection] = true
		if group then table.insert(group, connection) end
		return connection
	end
	local function disconnect(group: any)
		for _, connection in ipairs(group) do connection:Disconnect() connections[connection] = nil end
		table.clear(group)
	end
	Window:OnClose(function()
		alive = false
		table.clear(dirty)
		for connection in pairs(connections) do connection:Disconnect() end
		table.clear(connections)
	end)
	-- One render per affected panel per event batch; deferred work belongs to
	-- the window and is cancelled by Unload.
	local function queue(key: string, callback: () -> ())
		if not alive then return end
		dirty[key] = callback
		if queued then return end
		queued = true
		Window:_later(0, function()
			queued = false
			local batch = dirty dirty = {}
			for name, render in pairs(batch) do
				local ok, err = pcall(render)
				if not ok then Window:ReportError(name, err) end
			end
		end)
	end
	local function dataModule(folder: string, name: string): any
		local group = modules and modules:FindFirstChild(folder)
		local module = group and group:FindFirstChild(name)
		if not module or not module:IsA("ModuleScript") then return nil end
		local ok, result = pcall(require, module)
		if ok and type(result) == "table" then return result end
		Window:ReportError(name, ok and "Expected a data table" or result)
		return nil
	end
	local mutations = dataModule("Plants", "Mutations")
	local upgrades = dataModule("Core", "UpgradeConfig")
	local petPowers = dataModule("Pets", "PetPowers")
	local function amount(value: any): string
		local n = tonumber(value)
		if not n or n ~= n then return "Unknown" end
		local text = string.format("%.2f", n):gsub("0+$", ""):gsub("%.$", "")
		local integer, fraction = text:match("^(%-?%d+)(.*)$")
		return (integer:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")) .. fraction
	end
	local function moneyValue(): any
		local stats = player:FindFirstChild("leaderstats")
		return stats and stats:FindFirstChild("Money")
	end
	local function definition(name: string): any
		if not plants then return nil end
		for _, rarity in ipairs(plants:GetChildren()) do
			if rarity:IsA("Folder") then
				local found = rarity:FindFirstChild(name)
				if found then return found end
			end
		end
		return nil
	end
	local home = Window:MakeTab("Home")
	local function panel(title: string, order: number, description: string): any
		local section = home:Section({Title = title})
		section.Frame.LayoutOrder = order
		return section:Paragraph({Title = "", Content = description})
	end
	local summary = panel("Economy", 5, "Waiting for your game data…")
	local gardenReport = panel("My garden", 6, "Waiting for your garden…")
	local stockReport = panel("Seed shop", 7, "Waiting for shop stock…")
	local upgradeReport = panel("Next upgrades", 8, "Waiting for upgrade data…")
	local function refreshEconomy()
		local value = moneyValue()
		summary:Set({Content = "Balance  $" .. amount(value and value.Value)
			.. "\nIncome  $" .. amount(player:GetAttribute("IncomeRate")) .. "/s"
			.. "\nGarden  " .. amount(player:GetAttribute("PlantCount")) .. " / " .. amount(player:GetAttribute("MaxPlants"))
			.. "\nInventory  " .. amount(player:GetAttribute("InvCount")) .. " / " .. amount(packs and packs:GetAttribute("MaxInventory"))
			.. "\nWatering speed  ×" .. amount(player:GetAttribute("WaterBoost"))
			.. "    Money multiplier  ×" .. amount(player:GetAttribute("MoneyMulti"))})
	end
	local plantedRoot: any
	local function refreshGarden()
		local now, entries = Workspace:GetServerTimeNow(), {}
		growing = false
		for _, spot in ipairs(plantedRoot and plantedRoot:GetChildren() or {}) do
			if not spot:IsA("BasePart") or spot:GetAttribute("Owner") ~= player.UserId then continue end
			local def = definition(spot:GetAttribute("PlantName") or spot.Name)
			if not def then continue end
			local total = (spot:GetAttribute("SproutDelay") or def:GetAttribute("SproutDelay") or 0)
				+ (spot:GetAttribute("GrowTime") or def:GetAttribute("GrowTime") or 0)
			local born = spot:GetAttribute("PlantedAt")
			local rate = tonumber(spot:GetAttribute("GrowRate")) or 1
			local elapsed = born and ((spot:GetAttribute("RateAt") or born) - born
				+ (now - (spot:GetAttribute("RateAt") or born)) * rate) or nil
			local progress = elapsed and (total > 0 and math.clamp(elapsed / total, 0, 1) or 1)
			growing = growing or (progress ~= nil and progress < 1 and rate > 0)
			local size, mutation = spot:GetAttribute("SizeMult") or 1, spot:GetAttribute("Mutation")
			local multiplier = not mutation and size or nil
			if mutations and type(mutations.Mult) == "function" then multiplier = mutations.Mult(size, mutation) end
			local ratio, baseIncome, moneyMulti = plants:GetAttribute("IncomeStartRatio"), def:GetAttribute("Income"), player:GetAttribute("MoneyMulti")
			local income = progress and multiplier and ratio and baseIncome and moneyMulti
				and baseIncome * multiplier * (ratio + (1 - ratio) * progress) * moneyMulti or nil
			local state = progress and (progress >= 1 and "Grown" or string.format("%.0f%% grown", progress * 100)) or "Growth unknown"
			if elapsed and progress and progress < 1 and rate > 0 then state ..= " · ~" .. amount(math.ceil((total - elapsed) / rate)) .. "s left" end
			table.insert(entries, {Income = income or -1, Text = (def:GetAttribute("DisplayName") or def.Name)
				.. "  ·  $" .. amount(income) .. "/s\n" .. state .. "  ·  size ×" .. amount(size)
				.. (mutation and "  ·  " .. tostring(mutation) or "")})
		end
		table.sort(entries, function(a, b) return a.Income > b.Income end)
		local lines = {}
		for _, entry in ipairs(entries) do table.insert(lines, entry.Text) end
		gardenReport:Set({Content = #lines > 0 and table.concat(lines, "\n\n") or "No owned plants are currently replicated."})
	end
	local stockMap: any
	local restockAt: number?
	local function nativeShop(): any
		local gui = player:FindFirstChildOfClass("PlayerGui")
		local shop = gui and gui:FindFirstChild("SeedShopGui")
		return shop and shop:FindFirstChild("MainFrame")
	end
	local function syncTimer()
		local main = nativeShop()
		local header = main and main:FindFirstChild("Header")
		local timer = header and header:FindFirstChild("TimerTxt")
		local minutes, seconds
		if timer then minutes, seconds = timer.Text:match("^New seeds in (%d+):(%d+)") end
		if minutes and seconds and not stockMap then
			restockAt = Workspace:GetServerTimeNow() + tonumber(minutes) * 60 + tonumber(seconds)
		end
	end
	local function refreshStock()
		local main = nativeShop()
		local body = main and main:FindFirstChild("Body")
		local seedList = body and body:FindFirstChild("SeedList")
		local entries = {}
		if packs then for _, pack in ipairs(packs:GetChildren()) do
			local basePrice = pack:GetAttribute("Price")
			if not basePrice then continue end
			local currency = pack:GetAttribute("Currency") or "Money"
			-- Only list packs in this shop, not Halloween/Candy-only catalog items.
			local card = seedList and seedList:FindFirstChild(pack:GetAttribute("Card") or pack.Name)
			local count = stockMap and stockMap[pack:GetAttribute("PackId") or pack.Name]
			if not card and count == nil then continue end
			local tag = card and card:FindFirstChild("StockTag")
			local stock = tag and tag:FindFirstChild("StockTxt")
			local nativePrice = card and card:FindFirstChild("PriceTxt")
			local price = basePrice
			if currency == "Money" and pack:GetAttribute("NoPetBonus") ~= true then
				if petPowers and type(petPowers.Price) == "function" then price = petPowers.Price(player, price)
				else price = nil end
			end
			local priceText = price and ((currency == "Money" and "$" or "") .. amount(price)
				.. (currency ~= "Money" and " " .. currency or "")) or (nativePrice and nativePrice.Text or "Price unknown")
			local stockText = type(count) == "number" and (count > 0 and ("x" .. count .. " Stock") or "NO STOCK")
				or (stock and stock.Text or "Stock unknown")
			table.insert(entries, {Order = pack:GetAttribute("Order") or 999, Text = pack.Name .. "  ·  " .. priceText .. "  ·  " .. stockText})
		end end
		table.sort(entries, function(a, b) return a.Order < b.Order end)
		local remaining = restockAt and math.max(0, math.ceil(restockAt - Workspace:GetServerTimeNow()))
		local lines = {remaining and string.format("Restock in %d:%02d", remaining // 60, remaining % 60) or "Waiting for the seed restock timer…"}
		for _, entry in ipairs(entries) do table.insert(lines, entry.Text) end
		stockReport:Set({Content = #entries > 0 and table.concat(lines, "\n") or "Seed shop stock is not loaded yet."})
	end
	local function refreshUpgrades()
		if not upgrades or type(upgrades.Price) ~= "function" or type(upgrades.Describe) ~= "function" then
			upgradeReport:Set({Content = "Upgrade data is unavailable."}) return
		end
		local lines = {}
		local balance = moneyValue()
		for _, key in ipairs({"Base", "WateringCan", "MoneyMulti"}) do
			local def, level = upgrades.List and upgrades.List[key], player:GetAttribute("Upg" .. key)
			if def and type(level) == "number" then
				if level >= def.Max then table.insert(lines, def.Name .. " · Maximum level")
				else
					local price = upgrades.Price(key, level + 1)
					local afford = price and balance and (balance.Value >= price and " · Affordable" or " · Need $" .. amount(price - balance.Value)) or ""
					table.insert(lines, def.Name .. " → " .. upgrades.Describe(key, level + 1) .. "  ·  $" .. amount(price) .. afford)
				end
			end
		end
		upgradeReport:Set({Content = #lines > 0 and table.concat(lines, "\n") or "Your upgrade levels have not loaded yet."})
	end
	local function economyChanged()
		queue("Economy", refreshEconomy) queue("Upgrades", refreshUpgrades)
		if shopsChanged then shopsChanged() end
	end
	local function gardenChanged() queue("Garden", refreshGarden) if farmChanged then farmChanged() end if dealsChanged then dealsChanged() end end
	local function stockChanged() queue("Seed stock", refreshStock) if shopsChanged then shopsChanged() end end
	local moneyGroup = {}
	local function watchMoney()
		disconnect(moneyGroup)
		local stats, value = player:FindFirstChild("leaderstats"), moneyValue()
		if stats then listen(stats.ChildAdded, watchMoney, moneyGroup) listen(stats.ChildRemoved, watchMoney, moneyGroup) end
		if value then listen(value:GetPropertyChangedSignal("Value"), economyChanged, moneyGroup) end
		economyChanged()
	end
	for _, attribute in ipairs({"IncomeRate", "PlantCount", "MaxPlants", "InvCount", "WaterBoost", "MoneyMulti", "DataLoaded", "UpgBase", "UpgWateringCan", "UpgMoneyMulti"}) do
		listen(player:GetAttributeChangedSignal(attribute), function()
			economyChanged()
			if attribute == "MoneyMulti" or attribute == "DataLoaded" then gardenChanged() end
			if farmChanged and (attribute == "PlantCount" or attribute == "MaxPlants" or attribute == "DataLoaded") then farmChanged() end
		end)
	end
	-- Track each spot separately so removal releases its listeners immediately.
	local spotGroups: {[any]: any} = {}
	local plantedGroup, worldGroup = {}, {}
	local function watchSpot(spot: any)
		if spotGroups[spot] then disconnect(spotGroups[spot]) end
		local group = {} spotGroups[spot] = group
		if not spot:IsA("BasePart") then return end
		listen(spot:GetAttributeChangedSignal("Owner"), function() watchSpot(spot) gardenChanged() end, group)
		if spot:GetAttribute("Owner") == player.UserId then
			for _, key in ipairs({"PlantName", "PlantedAt", "RateAt", "GrowRate", "GrowTime", "SproutDelay", "SizeMult", "Mutation", "Favorite"}) do
				listen(spot:GetAttributeChangedSignal(key), gardenChanged, group)
			end
		end
	end
	local function bindPlanted(root: any)
		disconnect(plantedGroup)
		for spot, group in pairs(spotGroups) do disconnect(group) spotGroups[spot] = nil end
		plantedRoot = root
		if root then
			for _, spot in ipairs(root:GetChildren()) do watchSpot(spot) end
			listen(root.ChildAdded, function(spot: any) watchSpot(spot) gardenChanged() end, plantedGroup)
			listen(root.ChildRemoved, function(spot: any)
				if spotGroups[spot] then disconnect(spotGroups[spot]) spotGroups[spot] = nil end
				gardenChanged()
			end, plantedGroup)
		end
		gardenChanged()
	end
	local function bindWorld(world: any)
		disconnect(worldGroup)
		bindPlanted(world and world:FindFirstChild("Planted"))
		if world then
			listen(world.ChildAdded, function(child: any) if child.Name == "Planted" then bindPlanted(child) end end, worldGroup)
			listen(world.ChildRemoved, function(child: any) if child == plantedRoot then bindPlanted(nil) end end, worldGroup)
		end
	end
	listen(Workspace.ChildAdded, function(child: any) if child.Name == "Plants" then bindWorld(child) end end)
	listen(Workspace.ChildRemoved, function(child: any) if child.Name == "Plants" then bindWorld(nil) end end)
	bindWorld(Workspace:FindFirstChild("Plants"))
	-- Observe native text and replicated definitions, including late/rebuilt UI.
	local function watchTree(root: any, choose: any, changed: any, relevant: any?): () -> ()
		local group, items = {}, {}
		local function add(inst: any)
			if items[inst] then disconnect(items[inst]) end
			local itemGroup = {} items[inst] = itemGroup
			choose(inst, itemGroup)
		end
		for _, inst in ipairs(root:GetDescendants()) do add(inst) end
		listen(root.DescendantAdded, function(inst: any) add(inst) if not relevant or relevant(inst) then changed() end end, group)
		listen(root.DescendantRemoving, function(inst: any)
			if items[inst] then disconnect(items[inst]) items[inst] = nil end
			if not relevant or relevant(inst) then changed() end
		end, group)
		return function()
			disconnect(group)
			for inst, itemGroup in pairs(items) do disconnect(itemGroup) items[inst] = nil end
		end
	end
	local stopShop: any
	local function bindShop()
		if stopShop then stopShop() stopShop = nil end
		local main = nativeShop()
		if main then
			stopShop = watchTree(main, function(inst: any, group: any)
				if (inst:IsA("TextLabel") or inst:IsA("TextButton"))
					and (inst.Name == "StockTxt" or inst.Name == "PriceTxt" or inst.Name == "TimerTxt") then
					listen(inst:GetPropertyChangedSignal("Text"), function() syncTimer() stockChanged() end, group)
				end
			end, function() syncTimer() stockChanged() end)
		end
		syncTimer() stockChanged()
	end
	local gui = player:FindFirstChildOfClass("PlayerGui")
	if gui then
		listen(gui.ChildAdded, function(child: any) if child.Name == "SeedShopGui" then bindShop() end end)
		listen(gui.ChildRemoved, function(child: any) if child.Name == "SeedShopGui" then bindShop() end end)
		listen(gui.DescendantAdded, function(child: any)
			if child.Name == "MainFrame" and child.Parent and child.Parent.Name == "SeedShopGui" then bindShop() end
		end)
		listen(gui.DescendantRemoving, function(child: any)
			if child.Name == "MainFrame" and child.Parent and child.Parent.Name == "SeedShopGui" then queue("Shop binding", bindShop) end
		end)
	end
	listen(player.ChildAdded, function(child: any) if child.Name == "leaderstats" then watchMoney() end end)
	listen(player.ChildRemoved, function(child: any) if child.Name == "leaderstats" then watchMoney() end end)
	if plants then
		listen(plants:GetAttributeChangedSignal("IncomeStartRatio"), gardenChanged)
		watchTree(plants, function(inst: any, group: any)
			if inst.Parent and inst.Parent.Parent == plants then
				for _, key in ipairs({"Income", "DisplayName", "GrowTime", "SproutDelay", "Rarity"}) do listen(inst:GetAttributeChangedSignal(key), gardenChanged, group) end
			elseif inst.Parent == plants then
				listen(inst:GetAttributeChangedSignal("Order"), gardenChanged, group)
			end
		end, gardenChanged)
	end
	if packs then
		listen(packs:GetAttributeChangedSignal("MaxInventory"), economyChanged)
		watchTree(packs, function(inst: any, group: any)
			if inst.Parent == packs then
				for _, key in ipairs({"Price", "Currency", "NoPetBonus", "Card", "PackId", "Order"}) do listen(inst:GetAttributeChangedSignal(key), stockChanged, group) end
			end
		end, stockChanged)
	end
	local remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local seedShop = remotes and remotes:FindFirstChild("SeedShop")
	if seedShop and seedShop:IsA("RemoteEvent") then
		listen(seedShop.OnClientEvent, function(kind: any, map: any, at: any)
			if kind == "Stock" and type(map) == "table" then
				stockMap = table.clone(map)
				if type(at) == "number" then restockAt = at end
				stockChanged()
			end
		end)
	end
	-- Elapsed time has no change signal. Only countdowns/growing plants need
	-- this clock; no remote requests or gameplay work are performed.
	local seconds = 0
	listen(RunService.Heartbeat, function(delta: number)
		seconds += delta
		if seconds < 1 then return end
		seconds %= 1
		if growing then gardenChanged() end
		if restockAt then stockChanged() end
	end)
	watchMoney()
	bindShop()
	refreshEconomy() refreshGarden() refreshStock() refreshUpgrades()

	-- Shops are opt-in. Merely loading, navigating, or configuring does no
	-- buying/listing/selling. Only these four owning toggles can start work.
	local shops = Window:MakeTab("Shops")
	local eggs, pets = ReplicatedStorage:FindFirstChild("Eggs"), ReplicatedStorage:FindFirstChild("Pets")
	local eggRemote = remotes and remotes:FindFirstChild("EggShop")
	local sellRemote = remotes and remotes:FindFirstChild("SellItems")
	local teleportRemote = remotes and remotes:FindFirstChild("Teleport")
	local config = {Seeds = {}, Eggs = {}, PlantRarities = {}, PetRarities = {}, SeedRarities = {}, UseIncome = false, IncomeCap = 0, Reserve = 0, SeedLimit = 0, EggLimit = 0, OpenLimit = 0}
	local handles, actions, enabled, versions, confirmed = {}, {}, {}, {}, {}
	local buyIds = {"AutoBuySeedPacks", "AutoBuyEggs"}
	local plantId, petId = "AutoSellPlants", "AutoSellPets"
	local farmSeedId, farmBestId = "FarmAutoSeeds", "FarmBestPlants"
	local farmState: any = {Busy = false, Retained = {}}
	local dealState: any = {Busy = false}
	local eventState: any = {Busy = false}
	local supply: any = {On = false, Reserved = {}, Info = "Off", Bought = 0, Opened = 0, Activation = 0}
	local prepId, openId = "EventPreparePlant", "AutoOpenSeedPacks"
	local openRemote = remotes and remotes:FindFirstChild("OpenPack")
	local inventoryVersion, scannedVersion = 0, -1
	local eggStock: any
	local pending: any
	local travel: any
	local travelTimeout: any
	local acknowledged = {Plants = {}, Pets = {}}
	local finishTravel: any
	local worker: any
	local timer: any
	local workingId: string?
	local requests: {[any]: boolean} = {}
	local lastRequest = -math.huge
	local again = false
	local wake: any
	local configured: any
	local function anyEnabled(): boolean
		for _, value in pairs(enabled) do if value then return true end end
		return false
	end
	local function valid(id: string, version: number): boolean
		return alive and enabled[id] == true and versions[id] == version
	end
	local function tripIds(trip: any): {string}
		return trip.Destination == "Buy" and {buyIds[1], buyIds[2], prepId} or {plantId, petId}
	end
	local function status(id: string, text: string)
		local action = actions[id]
		if action and action.Status ~= text then action:SetStatus(text) end
	end
	local function stop(id: string, text: string?)
		enabled[id] = false versions[id] = (versions[id] or 0) + 1
		if id == prepId then supply.On = false supply.Info = text or "Off" end
		if actions[id] then actions[id]:Sync(false, text or "Off") end
	end
	local function cancelTravelTimer()
		if travelTimeout then
			local ok, err = pcall(task.cancel, travelTimeout)
			if not ok then Window:ReportError("Shops cleanup", err) end
			Window._tasks[travelTimeout] = nil
			travelTimeout = nil
		end
	end
	local function clearTravel()
		travel = nil
		cancelTravelTimer()
	end
	local function cancelWorker()
		if worker and worker ~= coroutine.running() then
			local ok, err = pcall(task.cancel, worker)
			if not ok then Window:ReportError("Shops cleanup", err) end
			Window._tasks[worker] = nil
		end
		worker = nil
		for thread in pairs(requests) do
			local ok, err = pcall(task.cancel, thread)
			if not ok then Window:ReportError("Shops request cleanup", err) end
			requests[thread] = nil
		end
	end
	local function changed()
		inventoryVersion += 1
		if supply.Refresh then supply.Refresh() end
		if configured then
			for id, action in pairs(actions) do
				local available, reason = configured(id)
				if available then reason = nil end
				if action.Available ~= available or action.Reason ~= reason then action:SetAvailable(available, reason) end
			end
		end
		if wake then wake() end
		if farmChanged then farmChanged() end
		if dealsChanged then dealsChanged() end
		if eventsChanged then eventsChanged() end
	end
	configured = function(id: string): (boolean, string?)
		if pending and pending.Uncertain then return false, "Previous pack opening is unconfirmed · reload after inspecting inventory" end
		if player:GetAttribute("DataLoaded") == false then return false, "Waiting for game data" end
		if id == prepId then
			local take = remotes and remotes:FindFirstChild("BasePlants")
			return take ~= nil and take:IsA("RemoteFunction") and eventState.Available ~= nil and eventState.Available(), "Event preparation unavailable"
		end
		if id == openId then
			return openRemote ~= nil and openRemote:IsA("RemoteEvent") and (#config.Seeds > 0 or supply.On), "Select seed packs or enable Prepare requested plant"
		end
		if id == farmSeedId or id == farmBestId then
			local place = remotes and remotes:FindFirstChild(id == farmSeedId and "PlantSeed" or "PlacePlant")
			if not place or not place:IsA("RemoteEvent") then return false, "Planting unavailable" end
			if id == farmSeedId then return #config.SeedRarities > 0, "Select at least one seed rarity" end
			local take = remotes and remotes:FindFirstChild("BasePlants")
			return take ~= nil and take:IsA("RemoteFunction"), "Plant pickup unavailable"
		end
		if id == buyIds[1] then
			if not seedShop or not seedShop:IsA("RemoteEvent") then return false, "Seed shop unavailable" end
			return #config.Seeds > 0 or supply.On, "Select at least one seed pack"
		elseif id == buyIds[2] then
			if not eggRemote or not eggRemote:IsA("RemoteEvent") then return false, "Egg shop unavailable" end
			return #config.Eggs > 0, "Select at least one egg"
		end
		if not sellRemote or not sellRemote:IsA("RemoteFunction") then return false, "Sell menu unavailable" end
		if id == plantId then return #config.PlantRarities > 0 or config.UseIncome, "Select rarities or enable an income limit" end
		return #config.PetRarities > 0, "Select at least one pet rarity"
	end
	local function makeToggle(section: any, id: string, title: string, description: string)
		actions[id] = section:Toggle({Id = id, Title = title, Content = description, Default = false,
			CanActivate = function() return configured(id) end,
			Callback = function(on: boolean)
				versions[id] = (versions[id] or 0) + 1
				enabled[id] = on
				if id == prepId then
					supply.On = on supply.Info = on and "Checking event supplies" or "Off"
					if on then
						eventState.NeedsTalk = true supply.Bought = 0 supply.Opened = 0 supply.Activation += 1
					end
					eventState.Version = (eventState.Version or 0) + 1
					if supply.Refresh then supply.Refresh() end
					if eventsChanged then eventsChanged() end
				end
				if on then confirmed[id] = 0 inventoryVersion += 1 status(id, "Waiting for matching items")
				else
					if workingId == id then cancelWorker() workingId = nil end
					if travel then
						local running = false for _, owner in ipairs(tripIds(travel)) do if enabled[owner] then running = true end end
						if not running then finishTravel() end
					end
					status(id, "Off")
				end
				if wake then wake() end
				if id == farmSeedId or id == farmBestId or id == prepId then if farmChanged then farmChanged() end end
			end})
	end
	local function numberInput(section: any, key: string, title: string, description: string)
		handles[key] = section:TextInput({Title = title, Content = description, Default = "0", Callback = function(text: string)
			local value = tonumber((text:gsub(",", "")))
			assert(value and value == value and value >= 0 and value < math.huge, "Enter a non-negative number")
			config[key] = key:find("Limit") and math.floor(value) or value
			changed()
		end})
	end
	local function rarityOptions(root: any): {string}
		local list = {}
		for _, item in ipairs(root and root:GetChildren() or {}) do
			if item:IsA("Folder") and type(item:GetAttribute("Order")) == "number" then table.insert(list, item) end
		end
		table.sort(list, function(a, b) return a:GetAttribute("Order") < b:GetAttribute("Order") end)
		local result = {} for _, item in ipairs(list) do table.insert(result, item.Name) end return result
	end
	local function catalog(isEgg: boolean): {any}
		local result = {}
		for _, item in ipairs(isEgg and (eggs and eggs:GetDescendants() or {}) or (packs and packs:GetChildren() or {})) do
			if type(item:GetAttribute("Price")) == "number" and (not isEgg or item:IsA("Model"))
				and (item:GetAttribute("Currency") or "Money") == "Money" and item:GetAttribute("Shop") ~= "Halloween" then
				table.insert(result, item)
			end
		end
		table.sort(result, function(a, b) return (a:GetAttribute("Order") or 999) < (b:GetAttribute("Order") or 999) end)
		return result
	end
	local function names(list: {any}): {string}
		local result = {} for _, item in ipairs(list) do table.insert(result, item.Name) end return result
	end
	local function selection(section: any, key: string, title: string, options: {string})
		handles[key] = section:Dropdown({Title = title, Multi = true, Options = options, Default = {}, Callback = function(values: {string})
			config[key] = table.clone(values)
			-- Recheck a changed filter after an outstanding read completes.
			for id in pairs(versions) do versions[id] += 1 end
			changed()
		end})
	end
	local limits = shops:Section({Title = "Purchase limits", Expanded = true})
	numberInput(limits, "Reserve", "Keep at least ($)", "Both buyers respect this shared balance reserve. 0 keeps no reserve.")
	local seedsSection = shops:Section({Title = "Seed packs", Expanded = true})
	makeToggle(seedsSection, buyIds[1], "Auto buy selected seed packs", "Teleport to Buy for affordable in-stock selections, confirm each purchase, then return to your saved position.")
	selection(seedsSection, "Seeds", "Selected seed packs", names(catalog(false)))
	numberInput(seedsSection, "SeedLimit", "Seed packs per activation", "0 keeps buying while enabled. A positive limit stops after confirmed purchases.")
	makeToggle(seedsSection, openId, "Auto open selected seed packs", "Open selected owned packs for ordinary farming. Events preparation buys and opens its own missing supplies, even when these Shops toggles are off.")
	numberInput(seedsSection, "OpenLimit", "Packs opened per activation", "0 continues while enabled. Waits for pack consumption, seed receipt and the native opening duration.")
	local plantsSection = shops:Section({Title = "Sell plants", Expanded = true})
	makeToggle(plantsSection, plantId, "Auto sell matching plants", "Teleport to Sell, clear inventory matching rarity OR enabled income limit, then return to your saved position. Favorites are kept.")
	selection(plantsSection, "PlantRarities", "Plant rarities to sell", rarityOptions(plants))
	handles.UseIncome = plantsSection:Toggle({Title = "Use income limit", Setting = true, Default = false, Callback = function(value: boolean)
		config.UseIncome = value versions[plantId] = (versions[plantId] or 0) + 1 changed()
	end})
	numberInput(plantsSection, "IncomeCap", "Sell at or below ($/s)", "Estimated planted income, including growth, size, mutation, and your money multiplier.")
	local eggsSection = shops:Section({Title = "Eggs", Expanded = true})
	makeToggle(eggsSection, buyIds[2], "Auto buy selected eggs", "Teleport to Buy for selected in-stock eggs, confirm each purchase, then return to your saved position. Eggs remain unhatched.")
	selection(eggsSection, "Eggs", "Selected eggs", names(catalog(true)))
	numberInput(eggsSection, "EggLimit", "Eggs per activation", "0 keeps buying while enabled. A positive limit stops after confirmed purchases.")
	local petsSection = shops:Section({Title = "Sell pets", Expanded = true})
	makeToggle(petsSection, petId, "Auto sell selected pet rarities", "Teleport to Sell, clear matching inventory pets, then return to your saved position. Favorites and equipped pets are kept.")
	selection(petsSection, "PetRarities", "Pet rarities to sell", rarityOptions(pets))
	petsSection:Toggle({Id = "AutoSellEggs", Title = "Auto sell unhatched eggs", Available = false,
		UnavailableReason = "No egg-selling action is exposed by the native sell system", Default = false})

	local function heldCount(isEgg: boolean, name: string): number
		local count = 0
		for _, root in ipairs({player:FindFirstChildOfClass("Backpack"), player.Character}) do
			if root then for _, tool in ipairs(root:GetChildren()) do
				if tool:IsA("Tool") and (isEgg and tool:GetAttribute("ToolType") == "Egg" and tool:GetAttribute("EggName") == name
					or not isEgg and tool:GetAttribute("PackId") == name) then count += tonumber(tool:GetAttribute("Count")) or 1 end
			end end
		end
		return count
	end
	local function currentStock(item: any, isEgg: boolean): number?
		local map = isEgg and eggStock or stockMap
		local value = map and map[isEgg and item.Name or (item:GetAttribute("PackId") or item.Name)]
		if type(value) == "number" then return value end
		local main = nativeShop()
		local body = main and main:FindFirstChild(isEgg and "EggBody" or "Body")
		local list = body and body:FindFirstChild(isEgg and "EggList" or "SeedList")
		local card = list and list:FindFirstChild(item:GetAttribute("Card") or item.Name)
		local tag = card and card:FindFirstChild("StockTag")
		local text = tag and tag:FindFirstChild("StockTxt")
		if not text then return nil end
		if text.Text == "NO STOCK" then return 0 end
		return tonumber(text.Text:match("^x(%d+) Stock$"))
	end
	local function waitGap(id: string, version: number): boolean
		local gap = 0.5 - (Workspace:GetServerTimeNow() - lastRequest)
		if gap > 0 then task.wait(gap) end
		return valid(id, version)
	end
	local function invokeRemote(remote: any, id: string, version: number, ...: any): any
		if not waitGap(id, version) then return nil end
		lastRequest = Workspace:GetServerTimeNow()
		local args, done, success, result = table.pack(...), false, false, nil
		local thread = task.defer(function()
			success, result = pcall(remote.InvokeServer, remote, table.unpack(args, 1, args.n))
			done = true
		end)
		requests[thread] = true
		local started = Workspace:GetServerTimeNow()
		while not done and valid(id, version) and Workspace:GetServerTimeNow() - started < 8 do task.wait(0.05) end
		requests[thread] = nil
		if not done then
			local cancelled, err = pcall(task.cancel, thread)
			if not cancelled then error(err) end
			if not valid(id, version) then return nil end
			error("Shop request timed out; automation paused")
		end
		if not success then error(result) end
		if not valid(id, version) then return nil end
		return result
	end
	local function invoke(id: string, version: number, ...: any): any return invokeRemote(sellRemote, id, version, ...) end
	local function protected(entry: any, category: string): boolean
		if category == "Plants" and (farmState.Retained[entry.id] or supply.Reserved[entry.id]) then return true end
		if entry.fav == true or entry.eq == true then return true end
		for _, root in ipairs({player:FindFirstChildOfClass("Backpack"), player.Character}) do
			if root then for _, tool in ipairs(root:GetChildren()) do
				if tool:IsA("Tool") and tool:GetAttribute(category == "Plants" and "ItemId" or "PetId") == entry.id then
					if tool:GetAttribute("Favorite") == true or category == "Pets" and tool.Parent == player.Character then return true end
				end
			end end
		end
		return false
	end
	local function plantIncome(entry: any): number?
		local def = type(entry.plant) == "string" and definition(entry.plant)
		if not def or type(entry.elapsed) ~= "number" or type(entry.size) ~= "number" then return nil end
		local base, ratio, multi = def:GetAttribute("Income"), plants:GetAttribute("IncomeStartRatio"), player:GetAttribute("MoneyMulti")
		if type(base) ~= "number" or type(ratio) ~= "number" or type(multi) ~= "number" then return nil end
		local total = (def:GetAttribute("SproutDelay") or 0) + (def:GetAttribute("GrowTime") or 0)
		local size = not entry.mut and entry.size or nil
		if mutations and type(mutations.Mult) == "function" then size = mutations.Mult(entry.size, entry.mut) end
		if not size then return nil end
		return base * size * (ratio + (1 - ratio) * (total > 0 and math.clamp(entry.elapsed / total, 0, 1) or 1)) * multi
	end
	local function saleFailure(result: any, category: string, count: number): string
		local detail = {category .. " sale declined by server", tostring(count) .. " item(s) requested"}
		if type(result) == "table" then
			table.insert(detail, "ok=" .. tostring(result.ok))
			for _, key in ipairs({"message", "error", "reason", "code"}) do
				local value = result[key]
				if type(value) == "string" or type(value) == "number" then table.insert(detail, key .. "=" .. tostring(value):sub(1, 200)) end
			end
		else table.insert(detail, "response=" .. tostring(result):sub(1, 200)) end
		return table.concat(detail, "; ") .. ". Selling paused; no automatic retry."
	end
	local function shopAccess(destination: string): (boolean, string, boolean)
		local lobby = Workspace:FindFirstChild("LobbyFolder")
		local shop = lobby and lobby:FindFirstChild(destination == "Buy" and "ShopBuy" or "ShopSell")
		local part = shop and shop:FindFirstChild("ProximityPromptPart")
		local prompt = part and part:FindFirstChildOfClass("ProximityPrompt")
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if not root then return false, "Waiting for character", false end
		if not part or not part:IsA("BasePart") or not prompt then return false, "Waiting for " .. destination .. " shop", false end
		local distance = (root.Position - part.Position).Magnitude
		return distance <= prompt.MaxActivationDistance, "Move near " .. destination .. " shop · " .. tostring(math.ceil(distance)) .. " studs", true
	end
	local function pauseTrip(trip: any, reason: string)
		for _, id in ipairs(tripIds(trip)) do stop(id, reason) end
	end
	finishTravel = function(force: boolean?)
		local trip = travel
		if not trip then return end
		if trip.Returning then if force then clearTravel() end return end
		trip.Cancelled = true
		-- An already-sent native teleport can still arrive after Stop All. Keep
		-- only its bounded return cleanup alive; never sell after cancellation.
		if not trip.Arrived and not force then return end
		trip.Returning = true
		cancelTravelTimer()
		if player.Character ~= trip.Character or not trip.Character.Parent then
			clearTravel()
			pauseTrip(trip, "Paused · character changed")
			return
		end
		for _, id in ipairs(tripIds(trip)) do if enabled[id] then status(id, "Returning to saved position") end end
		local ok, err = pcall(trip.Character.PivotTo, trip.Character, trip.Origin)
		if not ok or not alive then
			clearTravel()
			if not ok then
				pauseTrip(trip, "Paused · return failed")
				Window:ReportError("Shops", "Could not return to the saved " .. trip.Destination .. " trip position: " .. tostring(err))
			end
			return
		end
		-- One delayed observation checks the return after replication settles.
		-- Never repeatedly snap the character if the position is rejected.
		travelTimeout = Window:_later(0.75, function()
			travelTimeout = nil
			if travel ~= trip then return end
			local sameCharacter = player.Character == trip.Character and trip.Character.Parent ~= nil
			local read, pivot = false, nil
			if sameCharacter then read, pivot = pcall(trip.Character.GetPivot, trip.Character) end
			local returned = read and (pivot.Position - trip.Origin.Position).Magnitude <= 3
			clearTravel()
			if not returned then
				pauseTrip(trip, "Paused · return unconfirmed")
				Window:ReportError("Shops", "Return to the saved position was not confirmed. Sellers paused without retrying movement.")
			else
				for _, id in ipairs(tripIds(trip)) do if enabled[id] then status(id, trip.Destination == "Buy" and "Waiting for purchase conditions" or "Waiting for matching inventory") end end
			end
			if wake then wake() end
		end)
	end
	local function shopPositionChanged()
		local trip = travel
		if not trip then if enabled[buyIds[1]] or enabled[buyIds[2]] or supply.On then wake() end return end
		if trip.Returning then return end
		if player.Character ~= trip.Character then
			clearTravel()
			pauseTrip(trip, "Paused · character changed")
			return
		end
		if shopAccess(trip.Destination) and not trip.Arrived then
			trip.Arrived = true cancelTravelTimer()
			if trip.Cancelled then finishTravel() return end
			inventoryVersion += 1 wake()
		end
	end
	local function ensureShopAccess(id: string, version: number, destination: string): boolean
		local near, reason, canTravel = shopAccess(destination)
		if travel then
			if travel.Destination ~= destination then return false end
			if travel.Returning or travel.Cancelled or not travel.Arrived then return false end
			assert(near, "Left the " .. destination .. " shop during its trip; automation paused")
			return true
		end
		if near then return true end
		if not canTravel then status(id, reason) return false end
		if not teleportRemote or not teleportRemote:IsA("RemoteEvent") then status(id, destination .. " teleport unavailable · move to the shop") return false end
		if not waitGap(id, version) then return false end
		-- Save the origin at departure, after the shared request gap.
		if shopAccess(destination) then return true end
		local character = player.Character
		if not character or not character:FindFirstChild("HumanoidRootPart") then return false end
		local read, origin = pcall(character.GetPivot, character)
		assert(read, "Could not save the position before selling")
		local order = {Character = character, Origin = origin, Arrived = false, Destination = destination}
		travel = order lastRequest = Workspace:GetServerTimeNow()
		status(id, "Travelling to " .. destination .. " shop")
		travelTimeout = Window:_later(8, function()
			travelTimeout = nil
			if travel ~= order then return end
			if shopAccess(destination) then shopPositionChanged() return end
			pauseTrip(order, "Paused · " .. destination .. " teleport unconfirmed")
			finishTravel(true)
			Window:ReportError("Shops", destination .. " teleport did not arrive. " .. (destination == "Buy" and "Buyers" or "Sellers") .. " paused without retrying it.")
		end)
		teleportRemote:FireServer(destination)
		return false
	end
	local function sellMatching(id: string, category: string, key: string, revision: number): string
		if not enabled[id] then return "idle" end
		workingId = id
		local version = versions[id]
		local result = invoke(id, version, "List")
		if not valid(id, version) then again = true return "busy" end
		assert(type(result) == "table" and type(result[key]) == "table", "Unexpected sell inventory response")
		if inventoryVersion ~= revision then again = true return "busy" end
		local present = {}
		for _, entry in ipairs(result[key]) do if type(entry) == "table" and type(entry.id) == "string" then present[entry.id] = true end end
		for itemId in pairs(acknowledged[category]) do if not present[itemId] then acknowledged[category][itemId] = nil end end
		local ids = {}
		for _, entry in ipairs(result[key]) do
			if type(entry) == "table" and type(entry.id) == "string" and not protected(entry, category) then
				local def = category == "Plants" and type(entry.plant) == "string" and definition(entry.plant) or nil
				local rarity = category == "Plants" and def and def:GetAttribute("Rarity") or category == "Pets" and entry.rarity
				local picked = table.find(category == "Plants" and config.PlantRarities or config.PetRarities, rarity) ~= nil
				local income = category == "Plants" and config.UseIncome and plantIncome(entry) or nil
				if picked or income and income <= config.IncomeCap then table.insert(ids, entry.id) end
			end
		end
		if #ids == 0 then status(id, "Waiting for matching inventory") return "idle" end
		for _, itemId in ipairs(ids) do assert(not acknowledged[category][itemId], "A confirmed sale still appears in inventory; selling paused without resubmitting it") end
		if not ensureShopAccess(id, version, "Sell") then return "busy" end
		-- Filters/inventory may change while the global request gap elapses.
		if not waitGap(id, version) then again = true return "busy" end
		if inventoryVersion ~= revision then again = true return "busy" end
		if not shopAccess("Sell") then again = true return "busy" end
		local sold = invoke(id, version, "Sell", category, ids)
		if not valid(id, version) then again = true return "busy" end
		if type(sold) ~= "table" or sold.ok ~= true then error(saleFailure(sold, category, #ids), 0) end
		local progress = 0
		for _, itemId in ipairs(type(sold.sold) == "table" and sold.sold or {}) do
			if table.find(ids, itemId) then acknowledged[category][itemId] = true progress += 1 end
		end
		assert(progress > 0, "Sale returned no confirmed item IDs; sellers paused without retrying it")
		status(id, "Sale confirmed · $" .. amount(sold.total))
		return "sold"
	end
	local buyTurn = 1
	local function effectivePrice(item: any, isEgg: boolean): number?
		local price = item:GetAttribute("Price")
		if isEgg or item:GetAttribute("NoPetBonus") ~= true then
			if not petPowers or type(petPowers.Price) ~= "function" then return nil end
			price = petPowers.Price(player, price)
		end
		return type(price) == "number" and price > 0 and price < math.huge and price or nil
	end
	local function tryBuy(id: string, isEgg: boolean): boolean
		local event = not isEgg and supply.On
		if event then id = prepId end
		if not enabled[id] then return false end
		if event then
			if supply.Refresh then supply.Refresh() end
			if not supply.WantPack then return false end
		end
		if event and (not seedShop or not seedShop:IsA("RemoteEvent")) then status(id, "Event seed shop unavailable") return false end
		local limit = isEgg and config.EggLimit or config.SeedLimit
		if limit > 0 and (event and supply.Bought or confirmed[id] or 0) >= limit then
			if event then status(id, "Event pack purchase limit reached · increase Seed packs per activation in Shops") else stop(id, "Purchase limit reached") end
			return false
		end
		local count, cap = player:GetAttribute(isEgg and "PetInvCount" or "InvCount"), packs and packs:GetAttribute(isEgg and "MaxPetInventory" or "MaxInventory")
		if type(count) ~= "number" or type(cap) ~= "number" then status(id, "Waiting for inventory data") return false end
		if count >= cap then status(id, "Inventory full · waiting for space") return false end
		local choices, foundStock, affordable = isEgg and config.Eggs or config.Seeds, false, false
		if not isEgg and supply.On then
			if supply.Refresh then supply.Refresh() end
			choices = supply.WantPack and supply.PackChoices or {}
			if #choices == 0 then status(id, "Prepare · " .. supply.Info) return false end
		end
		for _, item in ipairs(catalog(isEgg)) do
			if table.find(choices, item.Name) then
				local stock = currentStock(item, isEgg)
				if stock and stock > 0 then
					foundStock = true
					local price = effectivePrice(item, isEgg)
					local balance = moneyValue()
					if balance and type(price) == "number" and price > 0 and balance.Value - price >= config.Reserve then
						affordable = true workingId = id
						local version = versions[id]
						if not ensureShopAccess(id, version, "Buy") then return travel ~= nil end
						if not waitGap(id, version) then return false end
						-- Recheck every precondition at the actual send boundary.
						balance = moneyValue() stock = currentStock(item, isEgg)
						price = effectivePrice(item, isEgg)
						count = player:GetAttribute(isEgg and "PetInvCount" or "InvCount")
						cap = packs:GetAttribute(isEgg and "MaxPetInventory" or "MaxInventory")
						limit = isEgg and config.EggLimit or config.SeedLimit
						if not price or not balance or balance.Value - price < config.Reserve or not stock or stock <= 0 or type(count) ~= "number" or type(cap) ~= "number" or count >= cap
							or not table.find(not isEgg and supply.On and (supply.WantPack and supply.PackChoices or {}) or isEgg and config.Eggs or config.Seeds, item.Name) or limit > 0 and (event and supply.Bought or confirmed[id] or 0) >= limit then return false end
						if not shopAccess("Buy") then again = true return false end
						local name = isEgg and item.Name or (item:GetAttribute("PackId") or item.Name)
						pending = {Id = id, Event = event, Activation = supply.Activation, IsEgg = isEgg, Name = name, Before = heldCount(isEgg, name), At = Workspace:GetServerTimeNow()}
						local remote = isEgg and eggRemote or seedShop
						lastRequest = pending.At
						local ok, err = pcall(remote.FireServer, remote, "Buy", name)
						if not ok then pending = nil error(err) end
						status(id, "Purchase requested · waiting for inventory")
						return true
					end
				end
			end
		end
		status(id, not foundStock and "Waiting for selected stock" or not affordable and "Waiting for money above reserve" or "Waiting")
		return false
	end
	local function buySelected(): boolean
		for offset = 0, 1 do
			local index = (buyTurn + offset - 1) % 2 + 1
			if tryBuy(buyIds[index], index == 2) then buyTurn = index % 2 + 1 return true end
		end
		return false
	end
	local function inventoryTools(): {any}
		local out = {}
		for _, root in pairs({player:FindFirstChildOfClass("Backpack"), player.Character}) do
			if root then for _, tool in ipairs(root:GetChildren()) do if tool:IsA("Tool") then table.insert(out, tool) end end end
		end
		return out
	end
	local function seedCounts(): any
		local out = {}
		for _, tool in ipairs(inventoryTools()) do if tool:GetAttribute("ToolType") == "Seed" then
			local name = tool:GetAttribute("PlantName") if type(name) == "string" then out[name] = (out[name] or 0) + (tool:GetAttribute("Count") or 1) end
		end end
		return out
	end
	local function restoreOpen(order: any)
		if order.Timer then
			local thread = order.Timer order.Timer = nil
			if thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
				local ok, err = pcall(task.cancel, thread) if not ok then Window:ReportError("Pack cleanup", err) end
			end
			Window._tasks[thread] = nil
		end
		if player.Character ~= order.Character then return end
		local hum = order.Character:FindFirstChildOfClass("Humanoid") local held = order.Character:FindFirstChildOfClass("Tool")
		if hum and (held == nil or held == order.Tool) then
			local prior = order.Equipment
			local ok, err = pcall(function()
				if prior and (prior.Parent == player.Character or prior.Parent == player:FindFirstChildOfClass("Backpack")) then hum:EquipTool(prior) else hum:UnequipTools() end
			end)
			if not ok then Window:ReportError("Pack equipment", err) end
		end
	end
	local function tryOpen(): boolean
		local event = supply.On
		local id = event and prepId or openId
		if not enabled[id] then return false end
		if event then
			if supply.Refresh then supply.Refresh() end
			if not supply.WantOpen then return false end
		end
		if event and (not openRemote or not openRemote:IsA("RemoteEvent")) then status(id, "Event pack opening unavailable") return false end
		if config.OpenLimit > 0 and (event and supply.Opened or confirmed[openId] or 0) >= config.OpenLimit then
			if event then status(id, "Event pack opening limit reached · increase Packs opened per activation in Shops") else stop(openId, "Opening limit reached") end
			return false
		end
		if player:GetAttribute("InCinematic") or player:GetAttribute("UiLocked") then status(id, "Finish the current dialogue or animation") return false end
		if supply.Refresh then supply.Refresh() end
		local choices = supply.On and (supply.WantOpen and supply.PackChoices or {}) or config.Seeds
		local tool
		for _, item in ipairs(inventoryTools()) do if item:GetAttribute("Favorite") ~= true and table.find(choices, item:GetAttribute("PackId")) then tool = item break end end
		if not tool then status(id, supply.On and ("Prepare · " .. supply.Info) or "Waiting for selected owned packs") return false end
		local inv, cap = player:GetAttribute("InvCount"), packs and packs:GetAttribute("MaxInventory")
		-- Leave one slot for a possible DoubleSeed bonus. Never assume a full
		-- inventory can accept the result merely because a pack is consumed.
		if type(inv) ~= "number" or type(cap) ~= "number" or inv + 1 > cap then status(id, "Free one inventory slot before opening") return false end
		local version = versions[id]
		if not waitGap(id, version) then return false end
		if supply.Refresh then supply.Refresh() end
		choices = supply.On and (supply.WantOpen and supply.PackChoices or {}) or config.Seeds
		if not table.find(choices, tool:GetAttribute("PackId")) or tool:GetAttribute("Favorite") == true then return false end
		local char = player.Character local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not hum or not tool.Parent or player:GetAttribute("InvCount") + 1 > packs:GetAttribute("MaxInventory") then return false end
		local previous = char:FindFirstChildOfClass("Tool")
		pending = {Kind = "Open", Id = id, Event = event, Activation = supply.Activation, Tool = tool, Name = tool:GetAttribute("PackId"), Before = heldCount(false, tool:GetAttribute("PackId")), Seeds = seedCounts(), At = Workspace:GetServerTimeNow(), Character = char, Equipment = previous or false}
		local opening = pending
		opening.Timer = Window:_later(8, function() opening.Timer = nil if pending == opening then wake() end end)
		hum:EquipTool(tool)
		if tool.Parent ~= char then local order = pending pending = nil restoreOpen(order) error("Could not equip the seed pack") end
		lastRequest = Workspace:GetServerTimeNow()
		local ok, err = pcall(openRemote.FireServer, openRemote)
		if not ok then local order = pending pending = nil restoreOpen(order) error(err) end
		status(id, "Opening pack · waiting for seed receipt")
		return true
	end
	if openRemote and openRemote:IsA("RemoteEvent") then listen(openRemote.OnClientEvent, function(owner: any, payload: any)
		local order = pending
		if owner ~= player or not order or order.Kind ~= "Open" or order.Duration then return end
		if type(payload) ~= "table" or type(payload.dur) ~= "number" or payload.dur <= 0 or payload.dur > 120 or type(payload.rolls) ~= "table" or type(payload.rolls[#payload.rolls]) ~= "string" then return end
		order.Duration = payload.dur order.Result = payload.rolls[#payload.rolls]
		order.EndAt = Workspace:GetServerTimeNow() + payload.dur
		if order.Timer then
			local thread = order.Timer local ok, err = pcall(task.cancel, thread)
			if not ok then Window:ReportError("Pack cleanup", err) end Window._tasks[thread] = nil
		end
		order.Timer = Window:_later(payload.dur, function()
			order.Timer = nil
			if pending ~= order then return end
			order.Timer = Window:_later(8, function() order.Timer = nil if pending == order then wake() end end)
			wake()
		end)
		wake()
	end) end
	local function process()
		if farmState.Busy or dealState.Busy or eventState.Busy then return end
		if farmState.PlantPending or farmState.Take and not farmState.Take.Confirmed then return end
		if pending then
			local order = pending
			if order.Uncertain then return end
			if order.Kind == "Open" then
				local seeds = seedCounts()
				local received = order.Result and (seeds[order.Result] or 0) > (order.Seeds[order.Result] or 0)
				if order.EndAt and Workspace:GetServerTimeNow() >= order.EndAt and received and heldCount(false, order.Name) < order.Before then
					pending = nil restoreOpen(order)
					if order.Event then
						if order.Activation == supply.Activation then supply.Opened += 1 end
						if supply.On then status(prepId, "Event seed received · " .. order.Result) end
					else
						confirmed[openId] = (confirmed[openId] or 0) + 1
						if config.OpenLimit > 0 and confirmed[openId] >= config.OpenLimit then stop(openId, "Opening limit reached") else status(openId, "Seed received · " .. order.Result) end
					end
					if supply.Refresh then supply.Refresh() end
				elseif Workspace:GetServerTimeNow() >= (order.EndAt or order.At) + 8 then
					-- The outcome is unknown. Hold the lease until Unload; starting
					-- another gameplay worker could consume a late opening receipt.
					Window:StopAll() stop(order.Id, "Paused · pack opening unconfirmed")
					order.Uncertain = true Window:ReportError("Shops", "Pack consumption, seed receipt or opening duration was not confirmed; no retry was sent")
					return
				else return end
			elseif heldCount(order.IsEgg, order.Name) > order.Before then
				if order.Event then
					if order.Activation == supply.Activation then supply.Bought += 1 end
					if supply.On then status(prepId, "Event pack purchase confirmed") end
				else
					confirmed[order.Id] = (confirmed[order.Id] or 0) + 1
					status(order.Id, "Confirmed purchases: " .. confirmed[order.Id])
				end
				pending = nil
				local limit = order.IsEgg and config.EggLimit or config.SeedLimit
				if not order.Event and enabled[order.Id] and limit > 0 and confirmed[order.Id] >= limit then stop(order.Id, "Purchase limit reached") end
			elseif Workspace:GetServerTimeNow() - order.At >= 8 then
				pending = nil
				stop(buyIds[1], "Paused · purchase unconfirmed") stop(buyIds[2], "Paused · purchase unconfirmed")
				if order.Event then stop(prepId, "Paused · event purchase unconfirmed") end
				Window:ReportError("Shops", "No inventory confirmation for the purchase. Buyers paused without retrying it.")
			else return end
		end
		if not pending and not travel and farmState.Dirty and farmState.HasJob and farmState.HasJob() then farmState.Wake() return end
		if travel and (not travel.Arrived or travel.Returning or travel.Cancelled) then return end
		if travel and travel.Destination == "Buy" then
			if not buySelected() then finishTravel() end
			return
		end
		if inventoryVersion ~= scannedVersion then
			local revision = inventoryVersion
			local plantResult = sellMatching(plantId, "Plants", "plants", revision)
			if travel and not travel.Arrived then return end
			local petResult = sellMatching(petId, "Pets", "pets", revision)
			if plantResult == "sold" or petResult == "sold" then
				-- Drain partial batches and arrivals during the trip even when the
				-- server's inventory event has not reached this client yet.
				inventoryVersion += 1 again = true return
			end
			if revision == inventoryVersion and plantResult == "idle" and petResult == "idle" then
				scannedVersion = revision
				if travel then finishTravel() return end
			end
		end
		if travel then return end
		if not tryOpen() then buySelected() end
	end
	wake = function(delay: number?)
		if dealsChanged then dealsChanged() end
		if eventState.Wake then eventState.Wake() end
		if not alive or (not anyEnabled() and not pending and not travel) or farmState.Busy or dealState.Busy or eventState.Busy then return end
		if worker then again = true return end
		if timer then return end
		timer = Window:_later(math.max(delay or 0.2, 0.5 - (Workspace:GetServerTimeNow() - lastRequest)), function()
			timer = nil
			if not anyEnabled() and not pending and not travel then return end
			worker = coroutine.running() again = false
			local current = worker
			local ok, err = pcall(process)
			if worker == current then worker = nil end
			if not ok then
				if travel then
					pauseTrip(travel, "Paused · see Diagnostics")
					finishTravel(true)
				elseif workingId then stop(workingId, "Paused · see Diagnostics") end
				Window:ReportError("Shops", err)
			end
			workingId = nil
			if pending and pending.Kind ~= "Open" and not pending.Uncertain or again then wake(pending and 0.25 or 0.5) end
			if farmState.Wake then farmState.Wake() end
			if eventState.Wake then eventState.Wake() end
		end)
	end
	shopsChanged = function() wake() end
	listen(player:GetAttributeChangedSignal("PetInvCount"), changed)
	listen(player:GetAttributeChangedSignal("InvCount"), changed)
	listen(player:GetAttributeChangedSignal("MoneyMulti"), changed)
	local roots: {[string]: any} = {}
	local function bindInventory(key: string, root: any)
		if roots[key] then roots[key]() roots[key] = nil end
		local function relevant(inst: any): boolean return inst:IsA("Tool") or key == "Pets" and inst.Parent == root or key == "Character" and inst.Name == "HumanoidRootPart" end
		if root then roots[key] = watchTree(root, function(inst: any, group: any)
			if key == "Character" and inst.Name == "HumanoidRootPart" then listen(inst:GetPropertyChangedSignal("CFrame"), function() shopPositionChanged() if farmState.Moved then farmState.Moved() end if eventState.Moved then eventState.Moved() end end, group) end
			if relevant(inst) then
				for _, attribute in ipairs({"Favorite", "Equipped", "Count", "ItemId", "PetId", "ToolType", "PlantName", "Mutation", "SizeMult", "Elapsed"}) do listen(inst:GetAttributeChangedSignal(attribute), changed, group) end
			end
		end, changed, relevant) end
		changed()
	end
	listen(player.ChildAdded, function(child: any)
		if child:IsA("Backpack") then bindInventory("Backpack", child) elseif child.Name == "PetsOwned" then bindInventory("Pets", child) end
	end)
	listen(player.ChildRemoved, function(child: any)
		if child:IsA("Backpack") then bindInventory("Backpack", nil) elseif child.Name == "PetsOwned" then bindInventory("Pets", nil) end
	end)
	listen(player.CharacterAdded, function(character: any) shopPositionChanged() bindInventory("Character", character) end)
	if teleportRemote and teleportRemote:IsA("RemoteEvent") then listen(teleportRemote.OnClientEvent, function(kind: any) if kind == "Done" then shopPositionChanged() end end) end
	if seedShop then listen(seedShop.OnClientEvent, function() wake() end) end
	if eggRemote then listen(eggRemote.OnClientEvent, function(kind: any, map: any)
		if kind == "Stock" and type(map) == "table" then eggStock = table.clone(map) wake() end
	end) end
	local balance = moneyValue()
	if balance then listen(balance:GetPropertyChangedSignal("Value"), function() wake() end) end
	bindInventory("Backpack", player:FindFirstChildOfClass("Backpack"))
	bindInventory("Character", player.Character)
	bindInventory("Pets", player:FindFirstChild("PetsOwned"))
	Window:OnClose(function()
		for id in pairs(enabled) do enabled[id] = false end
		cancelWorker()
		finishTravel(true)
		if pending and pending.Kind == "Open" then restoreOpen(pending) end
		pending = nil
	end)
	handles.Actions = actions
	-- Farm uses the same request gap and an exclusive work lease. Shops never
	-- sells or moves the character while a planting/replacement is in progress.
	do
		local F = farmState
		local farm = Window:MakeTab("Farm")
		local seeds = farm:Section({Title = "Plant seeds", Expanded = true})
		makeToggle(seeds, farmSeedId, "Auto plant selected seed rarities", "Fill free slots with selected seed rarities. Existing-plant replacement is handled by Best plants. Favorites stay untouched.")
		selection(seeds, "SeedRarities", "Seed rarities to plant", rarityOptions(plants))
		local best = farm:Section({Title = "Best plants", Expanded = true})
		makeToggle(best, farmBestId, "Auto equip / plant best plants", "Equip inventory plants, ranked by fully grown $/s including size and mutations. Pick up weaker planted items and keep them out of auto-sell for this session.")
		local activity = farm:Section({Title = "Farm activity"}) activity.Frame.LayoutOrder = 4
		activity:Paragraph({Title = "Automatic care", Content = "Best inventory plants get free slots first, then selected seeds. Uses your Base teleport when needed and returns afterward. No packs are opened and no plants are sold here."})
		F.Handles = {SeedRarities = handles.SeedRarities, Actions = {[farmSeedId] = actions[farmSeedId], [farmBestId] = actions[farmBestId]}}
		F.Signal = Instance.new("BindableEvent")
		F.Dirty = false
		local function cancel(thread: any)
			if not thread then return end
			if coroutine.status(thread) ~= "dead" then
				local ok, err = pcall(task.cancel, thread)
				if not ok then Window:ReportError("Farm cleanup", err) end
			end
			Window._tasks[thread] = nil
		end
		local plantSeed = remotes and remotes:FindFirstChild("PlantSeed")
		local placePlant = remotes and remotes:FindFirstChild("PlacePlant")
		local basePlants = remotes and remotes:FindFirstChild("BasePlants")
		local grid = dataModule("Plants", "PlantGrid")
		local function active(): boolean return enabled[farmSeedId] == true or enabled[farmBestId] == true or supply.On end
		local function tools(): {any}
			local out = {}
			local function collect(root: any) if root then for _, tool in ipairs(root:GetChildren()) do if tool:IsA("Tool") then table.insert(out, tool) end end end end
			collect(player:FindFirstChildOfClass("Backpack")) collect(player.Character)
			return out
		end
		local function ownTool(tool: any): boolean return tool and (tool.Parent == player.Character or tool.Parent == player:FindFirstChildOfClass("Backpack")) end
		local function count(tool: any): number return ownTool(tool) and (tonumber(tool:GetAttribute("Count")) or 1) or 0 end
		local function owned(): {any}
			local out = {}
			for _, spot in ipairs(plantedRoot and plantedRoot:GetChildren() or {}) do if spot:IsA("BasePart") and spot:GetAttribute("Owner") == player.UserId then table.insert(out, spot) end end
			return out
		end
		local function potential(item: any): number?
			local def = definition(item:GetAttribute("PlantName") or item.Name)
			local size, mut = item:GetAttribute("SizeMult"), item:GetAttribute("Mutation")
			local base = def and def:GetAttribute("Income")
			if type(size) ~= "number" or type(base) ~= "number" then return nil end
			local mult = not mut and size or nil
			if mutations and type(mutations.Mult) == "function" then mult = mutations.Mult(size, mut) end
			local score = mult and base * mult
			return score and score == score and score > 0 and score < math.huge and score or nil
		end
		local function base(): any
			local bases = Workspace:FindFirstChild("Bases")
			for _, plot in ipairs(bases and bases:GetChildren() or {}) do if plot:GetAttribute("OwnerId") == player.UserId then return plot end end
			return nil
		end
		local function ground(part: any, plot: any): boolean
			if not part or not plot or part:GetAttribute("BuildTok") and not part:GetAttribute("BuildKeep") then return false end
			local root = plot:FindFirstChild("Ground")
			if root and part:IsDescendantOf(root) then return true end
			local deco = plot:FindFirstChild("LevelDeco")
			local parent = part.Parent
			while deco and parent and parent ~= plot do
				if parent.Name == "Ground" and parent.Parent and parent.Parent.Parent == deco then return true end
				parent = parent.Parent
			end
			return false
		end
		local function hitPosition(position: any, ignore: any?): any
			local plot, spacing = base(), plants and plants:GetAttribute("MinSpacing")
			if not plot or type(spacing) ~= "number" or spacing <= 0 then return nil end
			local params = RaycastParams.new() params.FilterType = Enum.RaycastFilterType.Exclude
			local excludes = {plantedRoot, Workspace.CurrentCamera}
			if player.Character then table.insert(excludes, player.Character) end
			local visuals = Workspace:FindFirstChild("PlantVisuals") if visuals then table.insert(excludes, visuals) end
			params.FilterDescendantsInstances = excludes
			local hit = Workspace:Raycast(position + Vector3.new(0, 8, 0), Vector3.new(0, -16, 0), params)
			if not hit or hit.Normal.Y < 0.7 or not ground(hit.Instance, plot) then return nil end
			local point = hit.Position
			if player:GetAttribute("ShowGrid") == true then
				assert(grid and type(grid.Snap) == "function", "Plant grid data unavailable")
				point = grid.Snap(hit.Instance, point, hit.Normal)
			end
			for _, spot in ipairs(plantedRoot and plantedRoot:GetChildren() or {}) do
				if spot ~= ignore and spot:IsA("BasePart") and (spot.Position - point).Magnitude < spacing - 0.01 then return nil end
			end
			return point
		end
		local function inRange(position: any): boolean
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			local range, height = plants and plants:GetAttribute("MaxRange"), plants and plants:GetAttribute("MaxHeight")
			return root ~= nil and type(range) == "number" and type(height) == "number"
				and Vector3.new(position.X - root.Position.X, 0, position.Z - root.Position.Z).Magnitude <= range and math.abs(position.Y - root.Position.Y) <= height
		end
		local function position(preferred: any?, ignore: any?): any
			if preferred then local point = hitPosition(preferred, ignore) if point then return point end end
			local plot, spacing = base(), plants and plants:GetAttribute("MinSpacing")
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if not plot or not root or type(spacing) ~= "number" or spacing <= 0 then return nil end
			local points = {}
			for _, part in ipairs(plot:GetDescendants()) do
				if part:IsA("BasePart") and ground(part, plot) and part.CFrame.UpVector.Y >= 0.7 then
					local nx, nz = math.floor(part.Size.X / spacing), math.floor(part.Size.Z / spacing)
					for x = 0, nx - 1 do for z = 0, nz - 1 do
						if #points >= 4096 then break end
						table.insert(points, part.CFrame:PointToWorldSpace(Vector3.new(-nx * spacing / 2 + (x + 0.5) * spacing, part.Size.Y / 2, -nz * spacing / 2 + (z + 0.5) * spacing)))
					end end
				end
			end
			table.sort(points, function(a, b) return (a - root.Position).Magnitude < (b - root.Position).Magnitude end)
			for _, point in ipairs(points) do local hit = hitPosition(point, ignore) if hit then return hit end end
			return nil
		end
		local function retainTaken(): any
			local take = F.Take
			if not take then return nil end
			if take.Tool then return take.Tool end
			for _, tool in ipairs(tools()) do
				local id = tool:GetAttribute("ItemId")
				if type(id) == "string" and not take.Before[id] and tool:GetAttribute("ToolType") == "PlantItem"
					and tool:GetAttribute("PlantName") == take.Name and tool:GetAttribute("SizeMult") == take.Size and tool:GetAttribute("Mutation") == take.Mutation then
					if take.Role == "Pickup" then supply.Reserved[id] = true supply.Fresh = tool supply.RestorePending = true
					elseif take.Role == "ClearSlot" then F.Retained[id] = true supply.Backup = tool supply.BackupPoint = take.Spot.Position supply.RestorePending = false
					else F.Retained[id] = true end
					if not take.Spot:IsDescendantOf(plantedRoot) then take.Confirmed = true take.Tool = tool end
					return tool
				end
			end
			return nil
		end
		farmChanged = function()
			if not alive then return end
			retainTaken() F.Dirty = true
			if supply.Refresh then supply.Refresh() end
			if F.PlantPending and F.PlantPending.Check() then
				F.PlantPending = nil
				if F.PlantTimer then cancel(F.PlantTimer) F.PlantTimer = nil end
			end
			F.Signal:Fire()
			if F.Wake then F.Wake() end
		end
		F.Moved = function() if F.Signal then F.Signal:Fire() end if F.WaitingRange and not F.Busy and farmChanged then farmChanged() end end
		local function await(test: any, id: string, version: number, message: string, cleanup: boolean?): boolean
			local expired, done = false, false
			local deadline = Window:_later(8, function() expired = true F.Signal:Fire() end)
			while alive and not expired and (cleanup or valid(id, version)) do
				if test() then done = true break end
				F.Signal.Event:Wait()
			end
			cancel(deadline)
			if not alive or not cleanup and not valid(id, version) then return false end
			assert(done, message)
			return true
		end
		local function mature(spot: any): boolean
			local def = definition(spot:GetAttribute("PlantName") or "") if not def then return false end
			local total = (spot:GetAttribute("SproutDelay") or def:GetAttribute("SproutDelay") or 0) + (spot:GetAttribute("GrowTime") or def:GetAttribute("GrowTime") or 0)
			local born, rateAt = spot:GetAttribute("PlantedAt"), spot:GetAttribute("RateAt")
			if type(born) ~= "number" then return false end
			rateAt = rateAt or born
			return rateAt - born + (Workspace:GetServerTimeNow() - rateAt) * (spot:GetAttribute("GrowRate") or 1) >= total
		end
		local function supplyPlan(): any
			local P, E = supply, eventState
			P.WantPack = false P.WantOpen = false P.PackChoices = {} P.Spot = nil P.Seed = nil
			if not P.On then return nil end
			local function idle(text: string): any P.Info = text status(prepId, text) return nil end
			if player:GetAttribute("DataLoaded") ~= true then return idle("Waiting for game data") end
			if player:GetAttribute("InCinematic") or player:GetAttribute("UiLocked") then return idle("Finish the current dialogue or animation") end
			if E.NeedsTalk or not E.Request then return idle("Checking the event request") end
			if not table.find(E.Allowed, E.Request) then return idle("Requested " .. E.Request .. " is disabled") end
			local request = E.Request
			if P.Request ~= request then
				-- A completed submission can change tiers while inventory removal
				-- is replicating. Unused event candidates stay available for later
				-- requests; only actual Farm displacement belongs in Retained.
				P.Reserved = {} P.Fresh = nil P.Request = request
			end
			local garden, cap = owned(), player:GetAttribute("MaxPlants")
			local inv, maxInv = player:GetAttribute("InvCount"), packs and packs:GetAttribute("MaxInventory")
			if type(cap) ~= "number" or type(inv) ~= "number" or type(maxInv) ~= "number" then return idle("Waiting for garden and inventory capacity data") end
			local ready = E.Candidate and E.Candidate(request)
			if P.Backup and ownTool(P.Backup) and P.RestorePending then
				if P.Backup:GetAttribute("Favorite") == true then return idle("Displaced plant is now a favorite · kept in inventory") end
				if #garden < cap and (player:GetAttribute("PlantCount") or cap) < cap then return {Id = prepId, Tool = P.Backup, Point = position(P.BackupPoint), Role = "Restore", Request = request} end
				return idle("Garden changed · kept the displaced plant in inventory")
			end
			if ready then P.Reserved[ready:GetAttribute("ItemId")] = true return idle(E.Qualified and E.Qualified.Tool == ready and "Plant ready · waiting for Auto submit" or "Checking the grown plant with Pumpkin Man") end
			if P.Fresh and ownTool(P.Fresh) then
				if E.Rejected[P.Fresh] then return idle("Server says " .. tostring(E.Rejected[P.Fresh].Status) .. " · keeping the plant; waiting for a growth or inventory update") end
				return idle("Waiting for the picked-up plant's growth attributes and event check")
			end
			local spot, value
			for _, item in ipairs(garden) do
				local def = definition(item:GetAttribute("PlantName") or "") local score = potential(item)
				if item:GetAttribute("Favorite") ~= true and type(item:GetAttribute("SpotId")) == "string" and def and def:GetAttribute("Rarity") == request and score and (not value or score < value) then spot, value = item, score end
			end
			if spot then
				P.Spot = spot
				if not mature(spot) then return idle("Growing requested " .. request .. " plant") end
				if inv >= maxInv then return idle("Inventory full · free space for event pickup; Auto sell uses your filters") end
				return {Id = prepId, Tool = spot, Take = spot, Point = spot.Position, Role = "Pickup", Request = request}
			end
			local tool, score
			for _, item in ipairs(tools()) do
				local kind, def = item:GetAttribute("ToolType"), definition(item:GetAttribute("PlantName") or "")
				local id = item:GetAttribute("ItemId")
				if (kind == "Seed" or kind == "PlantItem") and item:GetAttribute("Favorite") ~= true and count(item) > 0 and not F.Retained[id] and def and def:GetAttribute("Rarity") == request then
					local value = kind == "Seed" and 0 or potential(item)
					if value and (not score or value < score) then tool, score = item, value end
				end
			end
			if tool then
				P.Seed = tool local id = tool:GetAttribute("ItemId") if id then P.Reserved[id] = true end
				if inv >= maxInv then return idle("Free one inventory slot for the grown plant before preparing") end
				if #garden >= cap or (player:GetAttribute("PlantCount") or cap) >= cap then
					if P.Backup and ownTool(P.Backup) then return idle("Garden full · displaced plant is already kept in inventory") end
					local low
					for _, item in ipairs(garden) do local v = potential(item)
						if item:GetAttribute("Favorite") ~= true and type(item:GetAttribute("SpotId")) == "string" and v and (not low or v < low) then spot, low = item, v end
					end
					if not spot then return idle("Garden full · favorites and unknown plants are protected") end
					if inv + 1 >= maxInv then return idle("Free two inventory slots before temporarily clearing a garden slot") end
					P.Spot = spot return {Id = prepId, Tool = tool, Take = spot, Point = position(spot.Position, spot), Role = "ClearSlot", Request = request}
				end
				return {Id = prepId, Tool = tool, Point = position(), Role = "Plant", Request = request}
			end
			if cap <= 0 then return idle("Waiting for an unlocked garden slot before buying supplies") end
			if #garden >= cap or (player:GetAttribute("PlantCount") or cap) >= cap then
				local replaceable = false
				for _, item in ipairs(garden) do
					if item:GetAttribute("Favorite") ~= true and type(item:GetAttribute("SpotId")) == "string" and potential(item) then replaceable = true break end
				end
				if not replaceable then return idle("Garden full · favorites and unknown plants are protected; no packs bought") end
				if P.Backup and ownTool(P.Backup) then return idle("Garden full · displaced plant is already kept in inventory; no packs bought") end
				if inv + 2 >= maxInv then return idle("Free three inventory slots before buying supplies and temporarily clearing a garden slot") end
			end
			for _, item in ipairs(catalog(false)) do if item:GetAttribute("SeedRarity") == request then table.insert(P.PackChoices, item.Name) end end
			if #P.PackChoices == 0 then return idle("No verified Money seed pack supplies " .. request) end
			for _, item in ipairs(tools()) do if item:GetAttribute("Favorite") ~= true and table.find(P.PackChoices, item:GetAttribute("PackId")) then
				if inv + 1 > maxInv then return idle("Free one inventory slot before opening the event pack") end
				if not openRemote or not openRemote:IsA("RemoteEvent") then return idle("Event pack opening unavailable") end
				if config.OpenLimit > 0 and P.Opened >= config.OpenLimit then return idle("Event pack opening limit reached · increase Packs opened per activation in Shops") end
				P.WantOpen = true return idle("Opening the matching event seed pack")
			end end
			if inv + 1 >= maxInv then return idle("Free two inventory slots before buying and opening a pack") end
			if not seedShop or not seedShop:IsA("RemoteEvent") then return idle("Event seed shop unavailable") end
			if not openRemote or not openRemote:IsA("RemoteEvent") then return idle("Event pack opening unavailable") end
			if config.OpenLimit > 0 and P.Opened >= config.OpenLimit then return idle("Event pack opening limit reached · increase Packs opened per activation in Shops") end
			if config.SeedLimit > 0 and P.Bought >= config.SeedLimit then return idle("Event pack purchase limit reached · increase Seed packs per activation in Shops") end
			P.WantPack = true
			return idle("Buying missing event seed pack · waiting for matching stock or money above reserve")
		end
		supply.Refresh = function() if supply.On and not F.Busy and not eventState.Busy then supplyPlan() end end
		local function prepValid(job: any): boolean
			if not supply.On or eventState.NeedsTalk or eventState.Request ~= job.Request or not table.find(eventState.Allowed, job.Request) then return false end
			if job.Role == "Restore" then return job.Tool == supply.Backup end
			local def = definition(job.Tool:GetAttribute("PlantName") or "")
			if not def or def:GetAttribute("Rarity") ~= job.Request then return false end
			if job.Role == "Pickup" then return job.Take == supply.Spot and mature(job.Take) end
			local kind = job.Tool:GetAttribute("ToolType")
			return job.Tool == supply.Seed and (kind == "Seed" or kind == "PlantItem") and ownTool(job.Tool)
		end
		local function plan(): any
			F.Idle = {}
			if F.Take and not F.Take.Confirmed or F.PlantPending then
				F.Idle[farmSeedId] = "Waiting for the previous Farm request to be confirmed"
				F.Idle[farmBestId] = F.Idle[farmSeedId]
				return nil
			end
			if supply.On then return supplyPlan() end
			local garden, cap = owned(), player:GetAttribute("MaxPlants")
			if not plantedRoot or not base() or type(cap) ~= "number" then return nil end
			local candidates = tools()
			local bestTool, score
			if enabled[farmBestId] then
				for _, tool in ipairs(candidates) do if tool:GetAttribute("ToolType") == "PlantItem" and tool:GetAttribute("Favorite") ~= true and not supply.Reserved[tool:GetAttribute("ItemId")] and type(tool:GetAttribute("ItemId")) == "string" then
					local value = potential(tool)
					if value and (not score or value > score) then bestTool, score = tool, value end
				end end
			end
			if bestTool then
				if #garden < cap then
					if (player:GetAttribute("PlantCount") or cap) < cap then return {Id = farmBestId, Tool = bestTool, Point = position(F.Slot)} end
					F.Idle[farmBestId] = "Waiting for the garden capacity update"
					return nil
				end
				local weakest, low
				for _, spot in ipairs(garden) do if spot:GetAttribute("Favorite") ~= true and spot ~= supply.Spot and type(spot:GetAttribute("SpotId")) == "string" then
					local value = potential(spot)
					if value and (not low or value < low) then weakest, low = spot, value end
				end end
				local inv, maxInv = player:GetAttribute("InvCount"), packs and packs:GetAttribute("MaxInventory")
				if weakest and score > low + math.max(1e-6, low * 1e-6) then
					if type(inv) == "number" and type(maxInv) == "number" then
						if inv < maxInv then return {Id = farmBestId, Tool = bestTool, Take = weakest, Point = position(weakest.Position, weakest)} end
						F.Idle[farmBestId] = "Inventory full · free space before picking up a weaker plant"
					else F.Idle[farmBestId] = "Waiting for inventory capacity data" end
				elseif weakest then F.Idle[farmBestId] = "No stronger inventory plant available"
				else F.Idle[farmBestId] = "No replaceable planted item · favorites and unknown plants are kept" end
			elseif enabled[farmBestId] then
				F.Idle[farmBestId] = "Waiting for plants in your inventory · seeds use the seed planter"
			end
			if enabled[farmSeedId] then
				if #garden >= cap or (player:GetAttribute("PlantCount") or cap) >= cap then
					F.Idle[farmSeedId] = enabled[farmBestId] and "Garden full · waiting for a free slot" or "Garden full · enable Best plants to replace weaker plants"
				else F.Idle[farmSeedId] = "Waiting for selected seed rarities" end
			end
			if enabled[farmSeedId] and #garden < cap and (player:GetAttribute("PlantCount") or cap) < cap then
				for _, tool in ipairs(candidates) do
					local def = definition(tool:GetAttribute("PlantName") or "")
					if tool:GetAttribute("ToolType") == "Seed" and tool ~= supply.Seed and tool:GetAttribute("Favorite") ~= true and count(tool) > 0 and def and table.find(config.SeedRarities, def:GetAttribute("Rarity")) then
						return {Id = farmSeedId, Tool = tool, Point = position(F.Slot)}
				end
				end
			end
			return nil
		end
		local function run()
			while alive and active() do
				F.Dirty = false F.WaitingRange = false
				local job = plan()
				if not job then for _, id in ipairs({farmSeedId, farmBestId}) do if enabled[id] then status(id, supply.On and "Prepare requested plant has priority" or F.Idle[id] or "Waiting for owned plot and capacity data") end end break end
				local id, tool = job.Id, job.Tool
				F.Active = id local version = versions[id]
				if not job.Point then status(id, "Waiting for clear owned ground") F.WaitingRange = true break end
				if not inRange(job.Point) then
					if F.Origin then status(id, "Move closer to available ground") F.WaitingRange = true break end
					assert(teleportRemote and teleportRemote:IsA("RemoteEvent"), "Base teleport unavailable")
					if not waitGap(id, version) then break end
					F.Character = player.Character F.Origin = F.Character:GetPivot()
					status(id, "Travelling to your base") lastRequest = Workspace:GetServerTimeNow()
					teleportRemote:FireServer("Base")
					-- Return cleanup must still be possible if switched off in flight.
					if not await(function() return player.Character == F.Character and inRange(job.Point) end, id, version, "Base teleport did not arrive; Farm paused", true) then break end
					continue
				end
				if not waitGap(id, version) then break end
				if player.Character ~= F.RunCharacter then error("Character changed; Farm paused") end
				if id == prepId and not prepValid(job) then continue end
				if (not job.Take or id ~= prepId) and not ownTool(tool) or tool:GetAttribute("Favorite") == true then continue end
				if job.Take then
					local spot = job.Take
					if not spot.Parent or spot:GetAttribute("Owner") ~= player.UserId or spot:GetAttribute("Favorite") == true then continue end
					local current, replacement = potential(spot), potential(tool)
					if id ~= prepId and (not current or not replacement or replacement <= current) then continue end
					local inv, maxInv = player:GetAttribute("InvCount"), packs and packs:GetAttribute("MaxInventory")
					if type(inv) ~= "number" or type(maxInv) ~= "number" or inv >= maxInv then status(id, "Waiting for inventory space before pickup") break end
					local before = {} for _, item in ipairs(tools()) do local key = item:GetAttribute("ItemId") if key then before[key] = true end end
					F.Take = {Role = job.Role, Before = before, Spot = spot, Name = spot:GetAttribute("PlantName"), Size = spot:GetAttribute("SizeMult"), Mutation = spot:GetAttribute("Mutation")}
					cancel(F.KeepTimer)
					F.KeepTimer = Window:_later(16, function()
						retainTaken()
						if F.Take and not F.Take.Confirmed and active() then
							stop(prepId, "Paused · Farm interrupted") stop(farmSeedId, "Paused · pickup unconfirmed") stop(farmBestId, "Paused · pickup unconfirmed")
							Window:ReportError("Farm", "Plant pickup was not confirmed; Farm paused without resubmitting it.")
						end
						F.Take = nil F.KeepTimer = nil
					end)
					F.Slot = job.Point status(id, job.Role == "Pickup" and "Picking up requested grown plant" or "Keeping displaced plant in inventory")
					local result = invokeRemote(basePlants, id, version, "Take", spot:GetAttribute("SpotId"))
					if not valid(id, version) then break end
					assert(result == true, "Plant pickup declined; Farm paused without retrying it")
					if not await(function() return retainTaken() ~= nil and not spot:IsDescendantOf(plantedRoot) end, id, version, "Plant pickup was not confirmed; Farm paused") then break end
				else
					local char = player.Character local humanoid = char and char:FindFirstChildOfClass("Humanoid")
					assert(humanoid, "Character unavailable for equipping")
					if not F.Equipment then
						local previous for _, item in ipairs(char:GetChildren()) do if item:IsA("Tool") then previous = item break end end
						F.Equipment = {Character = char, Previous = previous}
					end
					F.Equipment.Last = tool
					if tool.Parent ~= char then humanoid:EquipTool(tool) if not await(function() return tool.Parent == char end, id, version, "Could not equip planting tool") then break end end
					if not valid(id, version) then break end
					local point = hitPosition(job.Point)
					if not point or not inRange(point) then status(id, "Waiting for clear ground in range") F.WaitingRange = true break end
					if tool:GetAttribute("Favorite") == true then continue end
					local cap = player:GetAttribute("MaxPlants")
					if type(cap) ~= "number" or #owned() >= cap or (player:GetAttribute("PlantCount") or cap) >= cap then continue end
					local def = definition(tool:GetAttribute("PlantName") or "")
					if id == farmSeedId and (tool:GetAttribute("ToolType") ~= "Seed" or not def or not table.find(config.SeedRarities, def:GetAttribute("Rarity"))) then continue end
					if id == farmBestId and (tool:GetAttribute("ToolType") ~= "PlantItem" or type(tool:GetAttribute("ItemId")) ~= "string") then continue end
					if id == prepId and not prepValid(job) then continue end
					local before = {} for _, spot in ipairs(owned()) do before[spot] = true end
					local beforeCount, name, mutation = count(tool), tool:GetAttribute("PlantName"), tool:GetAttribute("Mutation")
					local function confirmed(): boolean
						if count(tool) >= beforeCount then return false end
						for _, spot in ipairs(owned()) do if not before[spot] and spot:GetAttribute("PlantName") == name and spot:GetAttribute("Mutation") == mutation and (spot.Position - point).Magnitude < 1 then return true end end
						return false
					end
					F.PlantPending = {Check = confirmed}
					F.PlantTimer = Window:_later(8, function()
						F.PlantTimer = nil F.PlantPending = nil
						if active() then
							stop(prepId, "Paused · Farm interrupted") stop(farmSeedId, "Paused · planting unconfirmed") stop(farmBestId, "Paused · planting unconfirmed")
							Window:ReportError("Farm", "Planting was not confirmed; Farm paused without retrying it.")
						end
						F.Signal:Fire()
					end)
					lastRequest = Workspace:GetServerTimeNow() status(id, "Planting · waiting for confirmation")
					if tool:GetAttribute("ToolType") == "Seed" then plantSeed:FireServer(point, 0, player:GetAttribute("ShowGrid") == true)
					else placePlant:FireServer(tool:GetAttribute("ItemId"), point, tool:GetAttribute("Yaw") or 0, player:GetAttribute("ShowGrid") == true) end
					if not await(confirmed, id, version, "Planting was not confirmed; Farm paused without retrying it") then break end
					F.Slot = nil status(id, "Plant confirmed")
					if job.Role == "Restore" then supply.Backup = nil supply.BackupPoint = nil supply.RestorePending = false end
				end
			end
		end
		local function release()
			local equipment = F.Equipment F.Equipment = nil
			if equipment and player.Character == equipment.Character then
				local humanoid = equipment.Character:FindFirstChildOfClass("Humanoid")
				local held for _, tool in ipairs(equipment.Character:GetChildren()) do if tool:IsA("Tool") then held = tool break end end
				if humanoid and (held == nil or held == equipment.Last) then
					if ownTool(equipment.Previous) then pcall(humanoid.EquipTool, humanoid, equipment.Previous) else pcall(humanoid.UnequipTools, humanoid) end
				end
			end
			F.Slot = nil
			local character, origin = F.Character, F.Origin F.Character, F.Origin = nil, nil
			if character and player.Character == character and character.Parent then
				local ok, err = pcall(character.PivotTo, character, origin)
				if not ok then Window:ReportError("Farm return", err) end
				if ok and alive then
					F.Returning = true
					Window:_later(0.75, function()
						F.Returning = false F.Busy = false F.Thread = nil
						local read, pivot = false, nil
						if player.Character == character then read, pivot = pcall(character.GetPivot, character) end
						if not read or (pivot.Position - origin.Position).Magnitude > 3 then
							stop(prepId, "Paused · Farm interrupted") stop(farmSeedId, "Paused · return unconfirmed") stop(farmBestId, "Paused · return unconfirmed")
							Window:ReportError("Farm", "Return position was not confirmed; Farm paused without retrying movement.")
						end
						if wake then wake() end if F.Dirty and F.Wake then F.Wake() end
					end)
					return
				end
			end
			F.Busy = false F.Thread = nil
			if wake then wake() end
			if F.Dirty and F.Wake then F.Wake() end
		end
		F.HasJob = function() return active() and plan() ~= nil end
		F.Wake = function()
			if not alive or not active() or not F.Dirty or F.Busy or F.Timer or dealState.Busy or eventState.Busy then return end
			F.Timer = Window:_later(0.2, function()
				F.Timer = nil
				if not active() or worker or travel or pending or dealState.Busy or eventState.Busy then return end
				F.Busy = true F.RunCharacter = player.Character
				F.Thread = Window:_later(0, function()
					local ok, err = pcall(run)
					if not ok then stop(prepId, "Paused · Farm interrupted") stop(farmSeedId, "Paused · see Diagnostics") stop(farmBestId, "Paused · see Diagnostics") Window:ReportError("Farm", err) end
					release()
				end)
			end)
		end
		local bases = Workspace:FindFirstChild("Bases")
		if bases then watchTree(bases, function(inst: any, group: any)
			for _, key in ipairs({"OwnerId", "Level", "BuildTok", "BuildKeep"}) do listen(inst:GetAttributeChangedSignal(key), farmChanged, group) end
		end, farmChanged) end
		Window:OnClose(function()
			cancel(F.Thread)
			release()
			F.Signal:Destroy() F.Signal = nil
		end)
	end
	-- Native NPC answers are opt-in. Upgrades compare rarity, same-plant size
	-- and mature income per occupied slot; reward count may never expand slots.
	local dealHandles: any = {}
	do
		local visitRemote = remotes and remotes:FindFirstChild("NpcVisit")
		local answerRemote = remotes and remotes:FindFirstChild("NpcAnswer")
		local section = Window:MakeTab("Farm"):Section({Title = "NPC deals", Expanded = true})
		section.Frame.LayoutOrder = 3
		local report = section:Paragraph({Title = "Live offer", Content = "Watching for NPC offers. Enable auto manage to check the current visitor."})
		local D: any = {Mode = "Accept upgrades", Answers = {}, Order = {}}
		local action: any
		local function finite(n: any): boolean return type(n) == "number" and n == n and math.abs(n) < math.huge end
		local function available(): (boolean, string?)
			return visitRemote ~= nil and visitRemote:IsA("RemoteEvent") and answerRemote ~= nil and answerRemote:IsA("RemoteEvent"), "NPC deals unavailable"
		end
		local function cancel(key: string)
			local thread = D[key] D[key] = nil
			if thread then
				local ok, err = pcall(task.cancel, thread)
				if not ok then Window:ReportError("NPC deals cleanup", err) end
				Window._tasks[thread] = nil
			end
		end
		local function score(def: any, size: any, mutation: any): number?
			local income = def and def:GetAttribute("Income")
			if not finite(income) or not finite(size) or size <= 0 or not mutations or type(mutations.Mult) ~= "function" then return nil end
			local ok, mult = pcall(mutations.Mult, size, mutation)
			if not ok or not finite(mult) or mult <= 0 then return nil end
			local result = income * mult
			return finite(result) and result > 0 and result or nil
		end
		local function inspect(offer: any): any
			local result = {Keep = false, Reason = "Unknown offer · decline", Cost = "Unknown request", Reward = "Unknown reward", Odds = "No success odds stated"}
			if type(offer) ~= "table" then return result end
			local want = offer.want or {type = "Plant", spots = {offer.spot}}
			local give = offer.give or {type = "Money", amount = offer.price}
			if type(want) ~= "table" or type(give) ~= "table" then return result end
			result.Cost, result.Reward = tostring(want.type or "Unknown request"), tostring(give.type or "Unknown reward")
			local rewardDef = type(give.plant) == "string" and definition(give.plant)
			local count = give.n == nil and 1 or give.n
			if rewardDef then
				result.Reward = tostring(count) .. "× " .. (rewardDef:GetAttribute("DisplayName") or rewardDef.Name)
					.. " · " .. tostring(rewardDef:GetAttribute("Rarity") or "Unknown rarity")
					.. (give.type == "Seed" and " seed" or give.type == "Plant" and (" · grown size ×" .. amount(give.size)) or "")
			end
			if give.chance ~= nil then
				if not finite(give.chance) or give.chance < 0 or give.chance > 1 then result.Reason = "Invalid success odds · decline" return result end
				result.Odds = amount(give.chance * 100) .. "% advertised success"
				if give.chance < 1 then result.Reason = "Risk of losing the deal · decline" return result end
			end
			if type(give.label) == "string" and (give.label:find("%%") or give.label:find("50/50", 1, true))
				and (give.chance ~= 1 or tonumber(give.label:match("(%d+%.?%d*)%%")) ~= 100) then
				result.Reason = "Unverified odds in reward text · decline" return result
			end
			if give.type == "Gamble" or give.type == "Mystery" then result.Reason = "Gamble or hidden reward · decline" return result end
			local kind = type(offer.kind) == "string" and offer.kind:lower() or ""
			if kind:find("scam", 1, true) or kind:find("gambl", 1, true) or kind:find("mystery", 1, true) then result.Reason = "Risky offer type · decline" return result end
			if give.type ~= "Seed" and give.type ~= "Plant" then result.Reason = "Outside plant upgrade rules · decline" return result end
			if not rewardDef or not finite(count) or count < 1 or count % 1 ~= 0 then result.Reason = "Reward details unknown · decline" return result end
			if want.type ~= "Plant" and want.type ~= "Plants" then result.Reason = "Cash, random or mixed cost · decline" return result end
			if want.amount ~= nil or want.pct ~= nil or want.n ~= nil or want.rarity ~= nil or want.need ~= nil or want.from ~= nil then result.Reason = "Additional or uncertain cost · decline" return result end
			local spots = want.spots or (want.type == "Plant" and {offer.spot})
			if type(spots) ~= "table" or #spots == 0 or (want.type == "Plant" and #spots ~= 1) then result.Reason = "Requested plants unknown · decline" return result end
			local cost, highestOrder, names, seen = 0, -math.huge, {}, {}
			for _, spot in ipairs(spots) do
				if typeof(spot) ~= "Instance" or not spot:IsA("BasePart") or spot.Parent ~= plantedRoot or spot:GetAttribute("Owner") ~= player.UserId or seen[spot] then result.Reason = "Requested plants changed or unknown · decline" return result end
				seen[spot] = true
				if spot:GetAttribute("Favorite") == true then result.Reason = "Requested plant is a favorite · decline" return result end
				local def = definition(spot:GetAttribute("PlantName") or "")
				local value = score(def, spot:GetAttribute("SizeMult"), spot:GetAttribute("Mutation"))
				local order = def and def.Parent:GetAttribute("Order")
				if not value or not finite(order) then result.Reason = "Requested plant value unknown · decline" return result end
				cost += value highestOrder = math.max(highestOrder, order)
				table.insert(names, (def:GetAttribute("DisplayName") or def.Name) .. " ×" .. amount(spot:GetAttribute("SizeMult"))
					.. (spot:GetAttribute("Mutation") and (" · " .. tostring(spot:GetAttribute("Mutation"))) or ""))
			end
			result.Cost = table.concat(names, ", ")
			result.Slots = #spots .. " → " .. count .. " plant slots"
			result.Spots, result.Give = spots, give
			if count > #spots then result.Reason = "Requires more plant slots · decline" return result end
			local rewardOrder = rewardDef.Parent:GetAttribute("Order")
			if not finite(rewardOrder) then result.Reason = "Reward rarity unknown · decline" return result end
			if give.type == "Seed" then
				if rewardOrder > highestOrder then
					result.Keep = true result.Reason = "Rarity upgrade · seed size and income unknown"
				else result.Reason = "Seed value cannot establish an upgrade · decline" end
				return result
			end
			local value = score(rewardDef, give.size, nil)
			if not value then result.Reason = "Reward size or income unknown · decline" return result end
			local perSlot = cost / #spots
			local sameLarger = #spots == 1 and give.plant == spots[1]:GetAttribute("PlantName")
				and give.size > spots[1]:GetAttribute("SizeMult") and value >= cost
			if rewardOrder > highestOrder then result.Keep = true result.Reason = "Rarity upgrade"
			elseif sameLarger then result.Keep = true result.Reason = "Larger size of the same plant"
			elseif value > perSlot then result.Keep = true result.Reason = "Better mature income per slot"
			else result.Reason = "No rarity, size or income per slot upgrade · decline" return result end
			result.Reason ..= " · " .. amount(value / perSlot) .. "× mature income per slot"
			return result
		end
		local function tools(): {any}
			local result = {}
			for _, root in ipairs({player:FindFirstChildOfClass("Backpack"), player.Character}) do
				if root then for _, tool in ipairs(root:GetChildren()) do if tool:IsA("Tool") then table.insert(result, tool) end end end
			end
			return result
		end
		local function rewardMatches(item: any, give: any, planted: boolean): boolean
			if item:GetAttribute("PlantName") ~= give.plant then return false end
			if planted then
				if give.type ~= "Plant" or item:GetAttribute("Owner") ~= player.UserId then return false end
			elseif item:GetAttribute("ToolType") ~= (give.type == "Seed" and "Seed" or "PlantItem") then return false end
			return give.type == "Seed" or item:GetAttribute("SizeMult") == give.size and item:GetAttribute("Mutation") == nil
		end
		local function clearPending()
			cancel("AnswerTimer") D.Pending = nil D.PendingId = nil dealState.Busy = false
			if wake then wake() end if farmState.Wake then farmState.Wake() end
		end
		local function confirmAccepted(order: any): boolean
			local received = 0
			for _, tool in ipairs(tools()) do
				if rewardMatches(tool, order.Check.Give, false) then
					local increase = math.max(0, (tonumber(tool:GetAttribute("Count")) or 1) - (order.Tools[tool] or 0))
					received += increase
					local id = tool:GetAttribute("ItemId")
					if increase > 0 and type(id) == "string" and order.Check.Give.type == "Plant" then farmState.Retained[id] = true end
				end
			end
			for _, spot in ipairs(plantedRoot and plantedRoot:GetChildren() or {}) do
				if not order.Spots[spot] and rewardMatches(spot, order.Check.Give, true) then received += 1 end
			end
			if not order.Accepted or received < (order.Check.Give.n or 1) then return false end
			for _, spot in ipairs(order.Check.Spots) do if spot.Parent == plantedRoot then return false end end
			return true
		end
		local function refresh()
			cancel("Timer")
			local order = D.Pending
			if order and order.Accept then
				if confirmAccepted(order) then
					D.Last = "Upgrade confirmed · " .. order.Check.Slots clearPending()
					Window:Notify({Title = "NPC upgrade accepted", Content = order.Check.Reward .. ". " .. order.Check.Reason})
				else
					if action.Enabled then action:SetStatus("Accept sent · waiting for trade confirmation") end
					report:Set({Content = "Give up: " .. order.Check.Cost .. "\nReceive: " .. order.Check.Reward .. "\n" .. order.Check.Reason
						.. "\n" .. order.Check.Slots .. "\n" .. (order.TimedOut and "Trade unconfirmed · automation paused" or "Waiting for the requested plants to leave and the reward to arrive.")})
					return
				end
			end
			local current = D.Current
			if not current then
				if action.Enabled then action:SetStatus(D.Last or "Waiting for NPC offers") end
				report:Set({Content = (D.Last or "Watching for NPC offers.") .. "\nUpgrades use no more plant slots. Hidden scams cannot be verified."})
				return
			end
			local now = Workspace:GetServerTimeNow()
			if now >= current.expireAt and current.pausedRemaining == nil then
				D.Current = nil D.Last = "Offer expired" dealsChanged() return
			end
			local check = inspect(current.offer)
			local decision = D.Mode == "Decline every deal" and "Decline every deal" or check.Reason
			local answered = D.Answers[current.id] ~= nil
			local accepting = D.Mode == "Accept upgrades" and check.Keep
			local sent = D.Answers[current.id] == "Accept" and "Accept sent · awaiting confirmation" or "Decline sent · awaiting closure"
			local paused = current.pausedRemaining ~= nil or current.visitOnly == true
			report:Set({Content = tostring(current.npc or "NPC") .. "\nGive up: " .. check.Cost .. "\nReceive: " .. check.Reward
				.. "\n" .. check.Odds .. "\n" .. decision .. (check.Slots and ("\n" .. check.Slots) or "")
				.. (answered and ("\n" .. sent) or paused and "\nVisitor paused or not offering a deal" or now < current.offerAt and "\nWaiting for the NPC to offer" or accepting and "\nAuto accepts this upgrade when enabled." or "\nReview on the native board.")
				.. "\nHidden scams cannot be verified."})
			if check.Keep and D.Mode == "Keep possible upgrades" and not paused and not answered and not current.Notified then
				current.Notified = true Window:Notify({Title = "Possible NPC upgrade", Content = check.Reward .. ". " .. check.Odds .. ". Review the native deal before accepting."})
			end
			if action.Enabled then action:SetStatus(answered and sent or paused and "Waiting for an active offer" or now < current.offerAt and "Waiting for the NPC to offer" or accepting and "Accepting upgrade" or D.Mode ~= "Decline every deal" and check.Keep and "Possible upgrade · review manually" or "Declining offer") end
			if action.Enabled and not answered and not paused and (D.Mode == "Accept upgrades" or D.Mode == "Decline every deal" or not check.Keep) then
				local due = math.max(current.offerAt, (D.LastAnswer or -math.huge) + 0.5, lastRequest + 0.5)
				if now >= due then
					if player:GetAttribute("DataLoaded") == false then action:SetStatus("Waiting for game data") return end
					if D.Pending then action:SetStatus("Waiting for the previous NPC answer") return end
					if accepting then
						if worker or travel or pending or farmState.Busy or eventState.Busy or farmState.PlantPending or farmState.Take and not farmState.Take.Confirmed then action:SetStatus("Waiting for Farm, Shops or Events") return end
						local cap, count = packs and packs:GetAttribute("MaxInventory"), player:GetAttribute("InvCount")
						if not finite(cap) or not finite(count) then action:SetStatus("Waiting for inventory capacity") return end
						if count + (check.Give.n or 1) > cap then action:SetStatus("Waiting for inventory space") return end
					end
					D.Answers[current.id] = accepting and "Accept" or "Decline" table.insert(D.Order, current.id)
					if #D.Order > 64 then D.Answers[table.remove(D.Order, 1)] = nil end
					D.LastAnswer = now lastRequest = now
					local request: any = {Id = current.id, Accept = accepting, Check = check, Tools = {}, Spots = {}}
					if accepting then
						for _, tool in ipairs(tools()) do request.Tools[tool] = tonumber(tool:GetAttribute("Count")) or 1 end
						for _, spot in ipairs(plantedRoot and plantedRoot:GetChildren() or {}) do request.Spots[spot] = true end
						dealState.Busy = true
					end
					D.Pending, D.PendingId = request, current.id
					local ok, err = pcall(answerRemote.FireServer, answerRemote, current.id, accepting)
					if not ok then
						if accepting then request.TimedOut = true Window:StopAll() else clearPending() action:Sync(false, "Paused · decline failed") end
						Window:ReportError("NPC deals", err) return
					end
					cancel("AnswerTimer")
					D.AnswerTimer = Window:_later(8, function()
						D.AnswerTimer = nil
						if D.Pending ~= request then return end
						if accepting then
							request.TimedOut = true Window:StopAll() action:Sync(false, "Paused · trade unconfirmed")
							Window:ReportError("NPC deals", "Trade outcome was not confirmed; all automation paused without retrying the acceptance.")
						else
							clearPending()
							if action.Enabled then action:Sync(false, "Paused · decline unconfirmed") Window:ReportError("NPC deals", "Decline was not confirmed by the native visit stream; paused without retrying.") end
						end
						dealsChanged()
					end)
					dealsChanged() return
				end
				if due < current.expireAt then D.Timer = Window:_later(due - now, function() D.Timer = nil dealsChanged() end) return end
			end
			if current.pausedRemaining == nil then D.Timer = Window:_later(math.max(0, current.expireAt - now), function() D.Timer = nil dealsChanged() end) end
		end
		dealsChanged = function()
			queue("NPC deals", function()
				local ok, err = pcall(refresh)
				if not ok then action:Sync(false, "Paused · see Diagnostics") Window:ReportError("NPC deals", err) end
			end)
		end
		dealHandles.Mode = section:Dropdown({Title = "Deal rule", Options = {"Accept upgrades", "Keep possible upgrades", "Decline every deal"}, Default = D.Mode,
			Content = "Accept upgrades automatically, review them manually, or decline every deal. Trades never require more plant slots.", Callback = function(value: string)
				assert(value == "Accept upgrades" or value == "Keep possible upgrades" or value == "Decline every deal", "Choose a deal rule")
				D.Mode = value dealsChanged()
			end})
		action = section:Toggle({Id = "AutoDeclineNpcDeals", Title = "Auto manage NPC deals", Default = false,
			Content = "Accept higher rarity, larger same-plant size, or better mature income per slot. Decline unwanted deals and all advertised odds below 100%.", CanActivate = available,
			Callback = function(on: boolean)
				cancel("Timer")
				if on then
					local ok, err = pcall(visitRemote.FireServer, visitRemote, "Sync")
					if not ok then action:Sync(false, "Paused · visit sync failed") Window:ReportError("NPC deals", err) end
				end
				dealsChanged()
			end})
		dealHandles.Action = action
		local ready, reason = available() action:SetAvailable(ready, ready and nil or reason)
		if visitRemote and visitRemote:IsA("RemoteEvent") then
			listen(visitRemote.OnClientEvent, function(payload: any)
				if type(payload) ~= "table" or tonumber(payload.ownerId) ~= player.UserId then return end
				local current = D.Current
				if payload.kind == "Start" then
					if (not finite(payload.id) and type(payload.id) ~= "string") or type(payload.offer) ~= "table" or not finite(payload.offerAt) or not finite(payload.expireAt) or payload.expireAt <= payload.offerAt then return end
					D.Current = table.clone(payload)
					if current and current.id == payload.id then D.Current.Notified = current.Notified end
				elseif payload.kind == "Update" then
					if not current or payload.id ~= current.id then return end
					if finite(payload.expireAt) then current.expireAt = payload.expireAt end
					current.pausedRemaining = payload.pausedRemaining
					if type(payload.offer) == "table" then current.offer = payload.offer current.Notified = nil end
				elseif payload.kind == "Leave" or payload.kind == "End" then
					if payload.id ~= nil and (not current or payload.id ~= current.id) and payload.id ~= D.PendingId then return end
					if D.PendingId and (payload.id == nil or payload.id == D.PendingId) then
						local order = D.Pending
						if order and order.Accept then
							if payload.kind == "Leave" then
								if payload.reason == "Accepted" and payload.win ~= false then order.Accepted = true
								else Window:StopAll() clearPending() action:Sync(false, "Paused · trade rejected") Window:ReportError("NPC deals", "NPC acceptance failed: " .. tostring(payload.reason) .. ", win=" .. tostring(payload.win) .. ". No retry was sent.") end
							end
						else clearPending() D.Last = "Decline confirmed · visitor left" end
					elseif current or payload.kind ~= "End" then D.Last = "Visitor left" .. (type(payload.reason) == "string" and (" · " .. payload.reason) or "") end
					if payload.id == nil or (current and payload.id == current.id) then D.Current = nil end
				else return end
				dealsChanged()
			end)
		end
		listen(player:GetAttributeChangedSignal("DataLoaded"), dealsChanged)
		Window:OnClose(function() cancel("Timer") cancel("AnswerTimer") D.Current = nil D.Pending = nil dealState.Busy = false dealsChanged = nil end)
	end
	local eventHandles: any = {}
	do
		local E = eventState
		local remote = remotes and remotes:FindFirstChild("PumpkinSacrifice")
		local data = dataModule("Events", "PumpkinSacrificeData")
		local tiers = {}
		for _, row in ipairs(data and data.Rarities or {}) do if type(row.Name) == "string" then table.insert(tiers, row.Name) end end
		E.Allowed = table.clone(tiers) E.Limit = 0 E.Completed = 0 E.Version = 0 E.Rejected = {} E.NeedsTalk = true E.Info = "Off"
		E.Signal = Instance.new("BindableEvent")
		local section = Window:MakeTab("Events"):Section({Title = "Pumpkin Man", Expanded = true})
		local report = section:Paragraph({Title = "Current request", Content = "Enable auto submit to check the event request."})
		local action: any
		local function finite(n: any): boolean return type(n) == "number" and n == n and math.abs(n) < math.huge end
		local function cancel(thread: any)
			if not thread then return end
			if thread ~= coroutine.running() and coroutine.status(thread) ~= "dead" then
				local ok, err = pcall(task.cancel, thread) if not ok then Window:ReportError("Events cleanup", err) end
			end
			Window._tasks[thread] = nil
		end
		local function locate(): (any, any, any)
			local lobby = Workspace:FindFirstChild("LobbyFolder") local assets = lobby and lobby:FindFirstChild("EventAssets")
			local npc = assets and assets:FindFirstChild("PumpkinManPodium") local podium = npc and npc:FindFirstChild("Podium")
			local point = podium and podium:FindFirstChild("TalkPoint")
			return npc, point, point and point:FindFirstChild("TalkPrompt")
		end
		local function available(): (boolean, string?)
			if E.Uncertain then return false, "Previous submission is unconfirmed · inspect inventory" end
			if not remote or not remote:IsA("RemoteFunction") or not data or not finite(data.Range) or #tiers == 0 then return false, "Pumpkin event unavailable" end
			local _, point, prompt = locate()
			if not point or not point:IsA("Attachment") or not prompt or not prompt:IsA("ProximityPrompt") then return false, "Pumpkin Man unavailable" end
			return #E.Allowed > 0, "Select at least one allowed tier"
		end
		local function active(): boolean return E.On == true or supply.On end
		local function valid(version: number): boolean return alive and active() and E.Version == version end
		E.Available = available
		local function owned(tool: any): boolean
			local bag = player:FindFirstChildOfClass("Backpack")
			return tool ~= nil and tool.Parent ~= nil and (tool.Parent == bag or tool.Parent == player.Character)
		end
		local function stamp(tool: any): string
			local result = {} for _, key in ipairs({"ItemId", "PlantName", "Elapsed", "StageIndex", "SizeMult", "Mutation", "Favorite"}) do table.insert(result, tostring(tool:GetAttribute(key))) end
			return table.concat(result, "|")
		end
		local function usable(tool: any, request: string?): number?
			if not owned(tool) or not tool:IsA("Tool") or tool:GetAttribute("ToolType") ~= "PlantItem" or tool:GetAttribute("Favorite") == true then return nil end
			local id = tool:GetAttribute("ItemId") if type(id) ~= "string" or farmState.Retained[id] then return nil end
			local def = definition(tool:GetAttribute("PlantName") or "") local rarity = def and def:GetAttribute("Rarity")
			if not def or not table.find(E.Allowed, rarity) or request and rarity ~= request then return nil end
			local elapsed, grow, sprout = tool:GetAttribute("Elapsed"), def:GetAttribute("GrowTime"), def:GetAttribute("SproutDelay")
			local income, size = def:GetAttribute("Income"), tool:GetAttribute("SizeMult")
			if not finite(elapsed) or not finite(grow) or not finite(sprout) or elapsed < grow + sprout or not finite(income) or not finite(size) then return nil end
			if not mutations or type(mutations.Mult) ~= "function" then return nil end
			local ok, mult = pcall(mutations.Mult, size, tool:GetAttribute("Mutation"))
			if not ok or not finite(mult) or mult <= 0 or income <= 0 then return nil end
			local rejected = E.Rejected[tool]
			if rejected and rejected.Stamp == stamp(tool) and rejected.Request == request then return nil end
			local value = income * mult return finite(value) and value or nil
		end
		local function candidate(request: string?): any
			local best, value
			for _, root in pairs({player:FindFirstChildOfClass("Backpack"), player.Character}) do
				if root then for _, tool in ipairs(root:GetChildren()) do
					local score = usable(tool, request)
					if score and (not value or score < value) then best, value = tool, score end
				end end
			end
			return best
		end
		E.Candidate = candidate
		local function inRange(): boolean
			local _, point, prompt = locate() local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			return root ~= nil and point ~= nil and prompt ~= nil and (root.Position - point.WorldPosition).Magnitude <= math.min(data.Range, prompt.MaxActivationDistance)
		end
		local function pause(text: string)
			E.On = false E.Version += 1 E.Info = text action:Sync(false, text) E.Signal:Fire()
		end
		local function receipt(): boolean
			local order = E.Pending
			return order ~= nil and not owned(order.Tool) and finite(player:GetAttribute("PumpkinTokens"))
				and player:GetAttribute("PumpkinTokens") >= order.Tokens + order.Reward
		end
		local function refresh()
			report:Set({Content = "Requested tier  " .. (E.Request or "Unknown · enable auto submit to check")
				.. "\nPumpkin tokens  " .. amount(player:GetAttribute("PumpkinTokens")) .. "    Golden tokens  " .. amount(player:GetAttribute("GoldenPumpkinTokens"))
				.. "\nConfirmed submissions  " .. E.Completed .. "\n" .. E.Info .. (supply.On and ("\nPrepare  " .. supply.Info) or "")})
			if E.On then action:SetStatus(E.Info) end
			local ready, reason = available() action:SetAvailable(ready, ready and nil or reason)
		end
		local function waitFor(test: any, version: number, cleanup: boolean?): boolean
			local expired = false local deadline = Window:_later(8, function() expired = true E.Signal:Fire() end)
			while alive and (cleanup or valid(version)) and not test() and not expired do E.Signal.Event:Wait() end
			cancel(deadline)
			return alive and (cleanup or valid(version)) and test()
		end
		local function rpc(verb: string, id: string?, version: number, preflight: any?): any
			local gap = 0.5 - (Workspace:GetServerTimeNow() - lastRequest) if gap > 0 then task.wait(gap) end
			if not valid(version) then return nil end
			local done, success, result = false, false, nil
			E.RPC = Window:_later(0, function()
				if not valid(version) then success, done = true, true E.Signal:Fire() return end
				if preflight then
					local ok, ready = pcall(preflight)
					if not ok or not ready then success, result, done = ok, ok and nil or ready, true E.Signal:Fire() return end
				end
				lastRequest = Workspace:GetServerTimeNow()
				if verb == "Give" then E.Pending.Sent = true end
				if id then success, result = pcall(remote.InvokeServer, remote, verb, id) else success, result = pcall(remote.InvokeServer, remote, verb) end
				done = true if E.Signal then E.Signal:Fire() end
			end)
			local completed = waitFor(function() return done end, version, verb == "Give")
			cancel(E.RPC) E.RPC = nil
			if not completed then if valid(version) or verb == "Give" then error("Event " .. verb .. " request was not confirmed; no retry was sent") end return nil end
			if not success then error(tostring(result)) end
			return result
		end
		local function setRequest(request: any)
			assert(type(request) == "string" and table.find(tiers, request), "Event returned an unknown requested tier")
			if E.Request ~= request then E.LastRejection = nil end E.Request = request
		end
		local function read(verb: string, version: number, preflight: any?): any
			local result = rpc(verb, nil, version, preflight)
			-- Nil is the native client's normal no-access/no-session response.
			-- Retry one read after travel/replication settles, never a Give.
			if result == nil and valid(version) and (not preflight or preflight()) then
				task.wait(0.75)
				if valid(version) and (not preflight or preflight()) then result = rpc(verb, nil, version, preflight) end
			end
			return result
		end
		local function run(version: number)
			E.Dirty = false
			if player:GetAttribute("DataLoaded") ~= true then E.Info = "Waiting for game data" return end
			if player:GetAttribute("InCinematic") or player:GetAttribute("UiLocked") then E.Info = "Finish the current dialogue or animation" return end
			local filter = E.Request if E.NeedsTalk then filter = nil end
			if not (supply.On and E.NeedsTalk) and not candidate(filter) then E.Info = E.LastRejection and ("Server says " .. E.LastRejection .. " · waiting for inventory changes") or "Waiting for a fully grown, unprotected inventory plant" return end
			if not E.On and not E.NeedsTalk and E.Qualified and owned(E.Qualified.Tool) and E.Qualified.Request == E.Request and stamp(E.Qualified.Tool) == E.Qualified.Stamp then E.Info = "Plant eligible · enable Auto submit requested plant" return end
			local character = player.Character local root = character and character:FindFirstChild("HumanoidRootPart")
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not root or not humanoid or root.Anchored == true then E.Info = "Waiting for a movable character" return end
			E.Equipment = {Character = character, Previous = character:FindFirstChildOfClass("Tool")}
			if not inRange() then
				local npc, point = locate() E.Character, E.Origin = character, character:GetPivot()
				local pos, look = point.WorldPosition, npc:GetPivot().Position
				character:PivotTo(CFrame.lookAt(Vector3.new(pos.X, root.Position.Y, pos.Z), Vector3.new(look.X, root.Position.Y, look.Z)))
				task.wait(0.5)
			end
			if not valid(version) then return end
			assert(inRange(), "Pumpkin Man arrival was not confirmed")
			if E.NeedsTalk then
				E.Info = "Checking the requested tier" queue("Events", refresh)
				local talk = read("Talk", version, inRange)
				if not valid(version) then return end
				if talk == nil then E.Info = "Waiting for Pumpkin Man access · move closer or wait for inventory to update" return end
				assert(type(talk) == "table", "Pumpkin Man did not return the current request")
				setRequest(talk.request) E.NeedsTalk = false
			end
			while valid(version) do
				E.Dirty = false
				if not table.find(E.Allowed, E.Request) then E.Info = "Requested " .. E.Request .. " is disabled" break end
				local tool = candidate(E.Request)
				if not tool then E.Info = E.LastRejection and ("Server says " .. E.LastRejection .. " · waiting for inventory changes") or ("Waiting for a fully grown " .. E.Request .. " inventory plant") break end
				if player.Character ~= character or not inRange() or player:GetAttribute("InCinematic") or player:GetAttribute("UiLocked") then E.Info = "Waiting for event access" break end
				local beforeStamp, request = stamp(tool), E.Request
				humanoid:EquipTool(tool) E.Equipment.Last = tool
				-- EquipTool predicts the character parent locally before the server
				-- sees the held item. A parent check alone is not a server receipt.
				task.wait(0.75)
				if not valid(version) then break end
				if not waitFor(function() return tool.Parent == character end, version) then error("Could not equip the requested event plant") end
				local function sameHeld(): boolean
					return valid(version) and owned(tool) and tool.Parent == character and stamp(tool) == beforeStamp and E.Request == request
						and table.find(E.Allowed, request) ~= nil and usable(tool, request) ~= nil and inRange()
						and not player:GetAttribute("InCinematic") and not player:GetAttribute("UiLocked")
				end
				if not sameHeld() then break end
				-- The native dialogue starts while its plant is already held.
				-- Reopen that read session after selecting a different tool so the
				-- server checks the current held item, not the earlier Talk state.
				local heldTalk = read("Talk", version, sameHeld)
				if not valid(version) then break end
				if heldTalk == nil and not sameHeld() then break end
				if heldTalk == nil then E.NeedsTalk = true E.Qualified = nil E.Info = "Waiting for Pumpkin Man to confirm the held plant · move closer or wait for an inventory update" break end
				assert(type(heldTalk) == "table", "Pumpkin Man did not confirm the held plant session")
				setRequest(heldTalk.request) E.NeedsTalk = false
				if E.Request ~= request then continue end
				if not sameHeld() then break end
				local checked = read("Check", version, sameHeld)
				if not valid(version) then break end
				if checked == nil and not sameHeld() then break end
				if checked == nil then E.NeedsTalk = true E.Qualified = nil E.Info = "Waiting for event eligibility · move closer or wait for an inventory update" break end
				assert(type(checked) == "table", "Event eligibility check returned no data")
				if checked.status == "NotGrown" and checked.request == request and sameHeld() then
					E.Info = "Waiting for the server to see the equipped plant" queue("Events", refresh)
					-- One bounded read of the unchanged held item handles replication
					-- delay. Never repeat Give or cycle through tools during this wait.
					task.wait(1.25)
					if not sameHeld() then break end
					checked = read("Check", version, sameHeld)
					if not valid(version) then break end
					if checked == nil and not sameHeld() then break end
					if checked == nil then E.NeedsTalk = true E.Qualified = nil E.Info = "Waiting for event eligibility · move closer or wait for an inventory update" break end
					assert(type(checked) == "table", "Event eligibility recheck returned no data")
				end
				setRequest(checked.request)
				if checked.status ~= "Eligible" then
					assert(checked.status == "NotGrown" or checked.status == "WrongRarity" or checked.status == "Favorite", "Unknown event eligibility status: " .. tostring(checked.status))
					E.Rejected[tool] = {Stamp = beforeStamp, Request = request, Status = checked.status} E.LastRejection = checked.status
					continue
				end
				assert(checked.id == tool:GetAttribute("ItemId") and checked.request == request and finite(checked.size)
					and math.abs(checked.size - tool:GetAttribute("SizeMult")) < 0.0001 and checked.mut == tool:GetAttribute("Mutation"), "Server checked a different plant; submission cancelled")
				assert(finite(checked.tokens) and checked.tokens > 0 and finite(player:GetAttribute("PumpkinTokens")), "Event reward data is unavailable")
				E.Qualified = {Tool = tool, Stamp = beforeStamp, Request = request}
				if supply.On then supply.Reserved[checked.id] = true end
				if not E.On then E.Info = "Plant eligible · enable Auto submit requested plant" break end
				E.Pending = {Tool = tool, Tokens = player:GetAttribute("PumpkinTokens"), Reward = checked.tokens}
				E.Info = "Submitting " .. (checked.name or tool.Name) queue("Events", refresh)
				local result = rpc("Give", checked.id, version, function()
					return E.On == true and usable(tool, request) ~= nil and stamp(tool) == beforeStamp and tool.Parent == character and E.Request == request
						and table.find(E.Allowed, request) ~= nil and inRange() and not player:GetAttribute("InCinematic") and not player:GetAttribute("UiLocked")
				end)
				if not E.Pending.Sent then E.Pending = nil break end
				assert(type(result) == "table" and result.ok == true, "Event submission was declined; no retry was sent")
				assert(finite(result.tokens) and result.tokens > 0, "Event submission reward was not confirmed")
				E.Pending.Reward = result.tokens
				assert(waitFor(receipt, version, true), "Event plant removal and token receipt were not confirmed")
				supply.Reserved[checked.id] = nil supply.Fresh = nil E.Qualified = nil
				E.Pending = nil E.Completed += 1 setRequest(result.request) E.NeedsTalk = false
				E.Info = "Submission confirmed · " .. E.Request .. " requested next" queue("Events", refresh)
				if E.Limit > 0 and E.Completed >= E.Limit then pause("Submission limit reached") break end
			end
		end
		local function release()
			local equipment = E.Equipment E.Equipment = nil
			if equipment and player.Character == equipment.Character then
				local hum = equipment.Character:FindFirstChildOfClass("Humanoid") local held = equipment.Character:FindFirstChildOfClass("Tool")
				if hum and (held == nil or held == equipment.Last) then
					local ok, err = pcall(function() if owned(equipment.Previous) then hum:EquipTool(equipment.Previous) else hum:UnequipTools() end end)
					if not ok then Window:ReportError("Events equipment", err) end
				end
			end
			local character, origin = E.Character, E.Origin E.Character, E.Origin = nil, nil
			local function done()
				E.Returning = false E.Thread = nil E.Busy = E.Uncertain == true
				if alive then if supply.Refresh then supply.Refresh() end if farmChanged then farmChanged() end queue("Events", refresh) if wake then wake() end if farmState.Wake then farmState.Wake() end end
			end
			if character and player.Character == character and character.Parent then
				local ok, err = pcall(character.PivotTo, character, origin)
				if not ok then Window:ReportError("Events return", err) end
				if ok and alive then
					E.Returning = true E.ReturnTimer = Window:_later(0.75, function()
						E.ReturnTimer = nil
						local ok, pivot = pcall(character.GetPivot, character)
						if player.Character ~= character or not ok or (pivot.Position - origin.Position).Magnitude > 3 then pause("Paused · return unconfirmed") Window:ReportError("Events", "Event return was not confirmed; movement was not retried") end
						done()
					end)
					return
				end
			end
			done()
		end
		E.Wake = function()
			if not alive or not active() or not E.Dirty or E.Busy or E.Timer then return end
			E.Timer = Window:_later(0.2, function()
				E.Timer = nil
				if not active() or E.Busy or worker or travel or pending or farmState.Busy or dealState.Busy or farmState.PlantPending or farmState.Take and not farmState.Take.Confirmed then return end
				E.Busy = true local version = E.Version
				E.Thread = Window:_later(0, function()
					local ok, err = pcall(run, version)
					if not ok then
						if E.Pending and E.Pending.Sent and not receipt() then E.Uncertain = true Window:StopAll() end
						stop(prepId, "Paused · event request failed")
						pause(E.Uncertain and "Paused · submission unconfirmed" or "Paused · see Diagnostics") Window:ReportError("Events", err)
					end
					release()
				end)
			end)
		end
		eventsChanged = function()
			if not alive then return end
			if E.Uncertain and receipt() then
				E.Uncertain = false E.Pending = nil E.Completed += 1 E.NeedsTalk = true E.Info = "Late submission confirmed · automation remains off" action:Sync(false, E.Info)
				if not E.Thread and not E.Returning then E.Busy = false end
			end
			E.Dirty = true E.Signal:Fire() queue("Events", refresh) E.Wake()
		end
		E.Moved = function() if active() and not E.Busy then eventsChanged() end end
		eventHandles.Tiers = section:Dropdown({Title = "Allowed sacrifice tiers", Options = tiers, Multi = true, Default = E.Allowed,
			Content = "Permanently consumes the weakest fully grown matching inventory plant. Favorites and plants retained by Farm are protected.", Callback = function(value: {string})
				for _, tier in ipairs(value) do assert(table.find(tiers, tier), "Unknown event tier") end E.Allowed = table.clone(value) E.Version += 1 eventsChanged()
			end})
		eventHandles.Limit = section:TextInput({Title = "Submissions per activation", Default = "0", Content = "0 keeps submitting while enabled. A positive number stops after confirmed submissions.", Callback = function(text: string)
			local n = tonumber(text) assert(finite(n) and n >= 0 and n % 1 == 0, "Enter a non-negative whole number") E.Limit = n E.Version += 1 eventsChanged()
		end})
		action = section:Toggle({Id = "EventAutoSubmitPlant", Title = "Auto submit requested plant", Default = false,
			Content = "Travel to Pumpkin Man, equip the weakest eligible inventory plant, submit the requested tier, then return. Uses direct event requests without launching dialogue or the local eating animation.", CanActivate = available,
			Callback = function(on: boolean)
				E.On = on E.Version += 1
				if on then E.Completed = 0 E.NeedsTalk = true E.Info = "Waiting for event access" else E.Info = "Off" end
				eventsChanged()
			end})
		eventHandles.Action = action
		local preparation = Window:MakeTab("Events"):Section({Title = "Prepare event supplies", Expanded = true})
		makeToggle(preparation, prepId, "Prepare requested plant", "Reuse a matching plant or seed; otherwise buy and open the matching seed pack automatically. Grow the plant, then pick it up. Temporarily keeps and restores one displaced plant. Auto submit is separate.")
		eventHandles.Prepare = actions[prepId]
		preparation:Paragraph({Title = "Automatic event supplies", Content = "Prepare includes missing-pack buying and opening; the Shops toggles can stay off. It respects Keep at least, Seed packs per activation and Packs opened per activation in Shops, counted separately for each Prepare activation. Auto submit remains separate. Full inventory waits for space; Auto sell uses your filters only when enabled."})
		for _, key in ipairs({"DataLoaded", "InCinematic", "UiLocked", "GoldenPumpkinTokens"}) do listen(player:GetAttributeChangedSignal(key), eventsChanged) end
		listen(player:GetAttributeChangedSignal("PumpkinTokens"), function() if not E.Pending then E.NeedsTalk = true end eventsChanged() end)
		Window:OnClose(function()
			supply.On = false E.On = false E.Version += 1 cancel(E.RPC) cancel(E.Thread) cancel(E.Timer) cancel(E.ReturnTimer)
			E.Uncertain = false release() E.Signal:Destroy() E.Signal = nil eventsChanged = nil E.Moved = nil
		end)
		refresh()
	end
	Window:SetReady("Garden dashboard, Farm, Shops and Events ready")
	return {Shops = handles, Farm = farmState.Handles, Deals = dealHandles, Events = eventHandles}
end
