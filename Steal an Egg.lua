--!strict
-- Re: Hub — Steal An Egg Feature Engine
-- Fills the standard Main/Automation/Misc pages. Contract: function(Window, Tabs)
--
-- Integration: uses the game's own client modules (EggCmds/Network/BaseUpgradeClient/
-- PlotCmds/Save) — identical call patterns to native client code. No hooks, no blind
-- remote fires, no CFrame teleports (server runs ReportAfkTeleport + CorrectionStarted).
-- All features default OFF. Humanized pacing everywhere.

local EGGS_DATA_URL = "https://raw.githubusercontent.com/Whotong/DataBase/main/GameData/Steal%20an%20Egg/Eggs.lua"

return function(Window: any, Tabs: any)
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local Players = game:GetService("Players")
	local RunService = game:GetService("RunService")
	local Workspace = game:GetService("Workspace")

	local LocalPlayer = Players.LocalPlayer

	-- ═══════════════════════════════════════════
	-- GAME MODULE REQUIRES (pcall-guarded)
	-- ═══════════════════════════════════════════
	local okLibs, Libs = pcall(function()
		local Library = (ReplicatedStorage :: any).Library
		return {
			EggCmds = require(Library.Client.EggCmds),
			Network = require(Library.Client.Network),
			Endpoints = require(Library.Globals.Constants).NETWORK_MAP,
			BaseUpgradeClient = require(Library.Client.BaseUpgradeClient),
			PlotCmds = require(Library.Client.PlotCmds),
			Save = require(Library.Client.Save),
			SlotIdentity = require(Library.Util.AreaEggSlotIdentity),
		}
	end)
	if not okLibs then
		Window:Notify({ Title = "Steal An Egg", Content = "Game modules not found — features unavailable", Delay = 8 })
		return
	end
	local EggCmds: any = Libs.EggCmds
	local Network: any = Libs.Network
	local Endpoints: any = Libs.Endpoints
	local BaseUpgradeClient: any = Libs.BaseUpgradeClient
	local PlotCmds: any = Libs.PlotCmds
	local Save: any = Libs.Save
	local SlotIdentity: any = Libs.SlotIdentity

	-- Rarity map from our GameData snapshot (optional — feature degrades gracefully)
	local EggsData: {[string]: any} = {}
	do
		local okData, dataSrc = pcall(function()
			return game:HttpGet(EGGS_DATA_URL)
		end)
		if okData and type(dataSrc) == "string" then
			local okLoad, loaded = pcall(function()
				local f = loadstring(dataSrc)
				return f and f()
			end)
			if okLoad and type(loaded) == "table" then
				EggsData = loaded
			end
		end
	end
	local function rarityOf(assetName: any): string?
		if type(assetName) ~= "string" then return nil end
		local entry = EggsData[assetName]
		return entry and entry.Rarity or nil
	end

	-- ═══════════════════════════════════════════
	-- STATE + TEARDOWN
	-- ═══════════════════════════════════════════
	local State: {[string]: any} = {
		_alive = true,
		Targets = { "Any" },
		SessionEggs = 0,
		SessionHatches = 0,
		SessionSells = 0,
		SessionUpgrades = 0,
	}
	local Conns: {[number]: any} = {}
	local Highlights: {[number]: any} = {}
	local OriginalWalkSpeed = 16

	local function conn(signal: any, fn: (...any) -> ())
		local c = signal:Connect(fn)
		table.insert(Conns, c)
		return c
	end

	local function getHumanoid(): any
		local char = LocalPlayer.Character
		return char and char:FindFirstChildOfClass("Humanoid") or nil
	end

	local function getRoot(): any
		local char = LocalPlayer.Character
		return char and char:FindFirstChild("HumanoidRootPart") or nil
	end

	Window:OnClose(function()
		State._alive = false
		for _, c in ipairs(Conns) do
			pcall(function()
				c:Disconnect()
			end)
		end
		for _, h in ipairs(Highlights) do
			pcall(function()
				h:Destroy()
			end)
		end
		local hum = getHumanoid()
		if hum then
			hum.WalkSpeed = OriginalWalkSpeed
		end
	end)

	-- ═══════════════════════════════════════════
	-- RUNNER — flag-gated, jittered, self-limiting loops
	-- ═══════════════════════════════════════════
	local Features: {[string]: any} = {}

	local function jitter(base: number): number
		return base * (0.7 + math.random() * 0.6) -- ±30%
	end

	local function addFeature(def: any)
		-- def: { Id, Section, Title, Content, BaseDelay, Loop(state), OnStop }
		Features[def.Id] = { enabled = false, def = def, errors = 0 }
		local entry = Features[def.Id]
		-- No Flag: features always start OFF each session (safety posture — a persisted
		-- ON toggle would restore visually without its loop running).
		entry.toggle = def.Section:Toggle({
			Title = def.Title,
			Content = def.Content or "",
			Default = false,
			Callback = function(v: boolean)
				entry.enabled = v
				entry.errors = 0
				if v then
					task.spawn(function()
						while State._alive and entry.enabled do
							local okRun, runErr = pcall(def.Loop, State)
							if not okRun then
								entry.errors += 1
								if entry.errors >= 5 then
									entry.enabled = false
									Window:Notify({ Title = "Steal An Egg", Content = def.Title .. " disabled after repeated errors: " .. tostring(runErr), Delay = 6 })
									break
								end
							else
								entry.errors = 0
							end
							if not State._alive or not entry.enabled then break end
							task.wait(jitter(def.BaseDelay or 2))
						end
					end)
				else
					if def.OnStop then pcall(def.OnStop, State) end
				end
			end,
		})
	end

	-- ═══════════════════════════════════════════
	-- WALKER — physics-legit MoveTo walking
	-- ═══════════════════════════════════════════
	local Walker = { busy = false, action = "Idle" }

	local function walkTo(targetPos: Vector3, timeout: number?): boolean
		local root = getRoot()
		local hum = getHumanoid()
		if not root or not hum then return false end
		Walker.busy = true
		local deadline = os.clock() + (timeout or 30)
		-- waypoint hops with lateral jitter so movement isn't laser-straight
		local pos = root.Position
		local waypoints = {}
		local dist = (targetPos - pos).Magnitude
		local hops = math.clamp(math.floor(dist / 24) + 1, 1, 12)
		for i = 1, hops do
			local alpha = i / hops
			local wp = pos:Lerp(targetPos, alpha)
			if i < hops then
				wp += Vector3.new((math.random() - 0.5) * 8, 0, (math.random() - 0.5) * 8)
			end
			table.insert(waypoints, wp)
		end
		local reached = true
		for _, wp in ipairs(waypoints) do
			if not State._alive or os.clock() > deadline then
				reached = false
				break
			end
			hum:MoveTo(wp)
			local t0 = os.clock()
			local lastPos = root.Position
			while os.clock() - t0 < 6 do
				if not State._alive then reached = false break end
				local rootNow = getRoot()
				if not rootNow then reached = false break end
				if (rootNow.Position - wp).Magnitude < 5 then break end
				-- stuck detection: jump if barely moved
				if (rootNow.Position - lastPos).Magnitude < 0.5 and (os.clock() - t0) > 1.5 then
					hum.Jump = true
					t0 = os.clock()
				end
				lastPos = rootNow.Position
				task.wait(0.15)
			end
			local rootNow = getRoot()
			if rootNow and (rootNow.Position - wp).Magnitude >= 5 then
				reached = false
				break
			end
		end
		Walker.busy = false
		return reached
	end

	-- ═══════════════════════════════════════════
	-- EGG BUS — live area-egg view via EggCmds cache + signals
	-- ═══════════════════════════════════════════
	local EggBus = { Eggs = {} } -- [uid] = record

	local function refreshEggs()
		local okSnap, snap = pcall(function()
			return EggCmds.GetAreaEggSnapshot()
		end)
		if not okSnap or type(snap) ~= "table" then return end
		local next_ = {}
		for _, rec in ipairs((snap :: any).Records or {}) do
			if rec.State == "Slot" or rec.State == "Dropped" then
				next_[(rec :: any).Uid] = rec
			end
		end
		EggBus.Eggs = next_
	end

	pcall(function()
		refreshEggs()
		conn((EggCmds :: any).AreaEggSnapshotUpdated, function()
			refreshEggs()
		end)
		conn((EggCmds :: any).AreaEggUpdated, function(rec: any)
			if rec and (rec.State == "Slot" or rec.State == "Dropped") then
				EggBus.Eggs[rec.Uid] = rec
			else
				refreshEggs()
			end
		end)
		conn((EggCmds :: any).AreaEggRemoved, function(uid: any)
			EggBus.Eggs[uid] = nil
		end)
		conn((EggCmds :: any).AreaEggBatchUpdated, function()
			refreshEggs()
		end)
	end)

	local function recordAssetName(rec: any): string?
		return rec.AssetId or rec.AssetName or rec.Category or rec.AssetType or rec.EggId
	end

	local function recordRarity(rec: any): string?
		return rarityOf(recordAssetName(rec))
	end

	local function slotPosition(rec: any): Vector3?
		-- world render lives in AreaEggSlotsClient; match by name prefix "<Uid>" or ":Slot_" suffix
		local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
		if not slots then return nil end
		local direct = slots:FindFirstChild(rec.Uid)
		if direct then
			local hit = direct:FindFirstChild("Hitbox") or (direct:IsA("BasePart") and direct or nil)
			if hit then return hit.Position end
		end
		for _, child in ipairs(slots:GetChildren()) do
			if string.find(child.Name, rec.Uid, 1, true) then
				local hit = child:FindFirstChild("Hitbox") or (child:IsA("BasePart") and child or nil)
				if hit then return hit.Position end
			end
		end
		return nil
	end

	local function firstAreaSlotKey(rec: any): string?
		local okId, isFirst = pcall(function()
			return SlotIdentity.IsFirstAreaUid(rec.Uid)
		end)
		if okId and isFirst then
			local okKey, key = pcall(function()
				return SlotIdentity.BuildSlotKey(rec.AreaId, rec.NestId)
			end)
			if okKey then return key end
		end
		return nil
	end

	local function tryCarry(rec: any): boolean
		local okC, carried, err = pcall(function()
			return EggCmds.RequestCarryAreaEgg(rec.Uid, firstAreaSlotKey(rec))
		end)
		if okC and carried then
			State.SessionEggs += 1
			return true
		end
		if okC and err then
			Walker.action = "Carry denied: " .. tostring(err)
		end
		return false
	end

	local function getOwnPlotModel(): any?
		local okPlot, data = pcall(function()
			return PlotCmds.GetPlotData()
		end)
		local plots = Workspace:FindFirstChild("Plots")
		if plots then
			-- prefer plot number from PlotData if present
			local num = nil
			if okPlot and type(data) == "table" then
				num = data.PlotNumber or data.Number or data.Index or data.Plot
			end
			if num then
				local m = plots:FindFirstChild(tostring(num))
				if m then return m end
			end
			-- fallback: plot whose PlotSign billboard says our name is complex; use nearest plot center
			local root = getRoot()
			if root then
				local best, bestDist = nil, math.huge
				for _, m in ipairs(plots:GetChildren()) do
					local cp = m:FindFirstChild("CenterPoint") or m:FindFirstChildWhichIsA("BasePart")
					if cp then
						local d = (cp.Position - root.Position).Magnitude
						if d < bestDist then
							best, bestDist = m, d
						end
					end
				end
				return best
			end
		end
		return nil
	end

	-- ═══════════════════════════════════════════
	-- MAIN PAGE
	-- ═══════════════════════════════════════════
	local Main = Tabs.Main

	-- ── Egg Sniper ──
	local SniperSection = Main:Section({ Title = "Egg Sniper" })

	local rarityOptions = { "Any" }
	local seenRarities = {}
	for _, entry in pairs(EggsData) do
		local r = entry.Rarity
		if type(r) == "string" and not seenRarities[r] then
			seenRarities[r] = true
			table.insert(rarityOptions, r)
		end
	end
	table.sort(rarityOptions)

	SniperSection:Dropdown({
		Title = "Target Rarity",
		Multi = true,
		Options = rarityOptions,
		Default = { "Any" },
		Callback = function(v: any)
			State.Targets = type(v) == "table" and v or { v }
		end,
	})

	SniperSection:Toggle({
		Title = "Notify On Spawn",
		Content = "Notification when a target egg appears",
		Default = false,
		Callback = function(v)
			State.NotifySpawn = v
		end,
		Flag = "SAE/SniperNotify",
	})

	addFeature({
		Id = "EggSniper",
		Section = SniperSection,
		Title = "Egg Sniper (walk + carry)",
		Content = "Walk to target-rarity eggs and steal them",
		BaseDelay = 3,
		Loop = function(st: any)
			refreshEggs()
			local anyTarget = false
			for _, t in ipairs(st.Targets) do
				if t == "Any" then anyTarget = true end
			end
			local best, bestDist, bestPos = nil, math.huge, nil
			local root = getRoot()
			for uid, rec in pairs(EggBus.Eggs) do
				local rarity = recordRarity(rec)
				local name = recordAssetName(rec)
				local match = anyTarget
				if not match then
					for _, t in ipairs(st.Targets) do
						if t == rarity or t == name then match = true break end
					end
				end
				if match then
					local pos = slotPosition(rec)
					if pos and root then
						local d = (pos - root.Position).Magnitude
						if d < bestDist then
							best, bestDist, bestPos = rec, d, pos
						end
					end
				end
			end
			if best and bestPos then
				Walker.action = "Sniping: " .. tostring(recordAssetName(best))
				if walkTo(bestPos + Vector3.new(0, 3, 0), 45) then
					task.wait(jitter(0.4))
					tryCarry(best)
				end
			end
		end,
	})

	-- ── Movement ──
	local Movement = Main:Section({ Title = "Movement" })

	Movement:Toggle({
		Title = "Speed Hack",
		Content = "Increase walk speed",
		Default = false,
		Callback = function(v)
			State.SpeedHack = v
			local hum = getHumanoid()
			if hum then
				hum.WalkSpeed = v and (State.WalkSpeed or 32) or OriginalWalkSpeed
			end
		end,
		Flag = "SAE/SpeedHack",
	})

	Movement:Slider({
		Title = "Walk Speed",
		Min = 16,
		Max = 60,
		Increment = 2,
		Default = 32,
		Callback = function(v)
			State.WalkSpeed = v
			if State.SpeedHack then
				local hum = getHumanoid()
				if hum then hum.WalkSpeed = v end
			end
		end,
	})

	addFeature({
		Id = "NoClip",
		Section = Movement,
		Title = "No Clip",
		Content = "HIGH RISK — server validates movement (CorrectionStarted)",
		BaseDelay = 0.1,
		Loop = function(_st)
			local char = LocalPlayer.Character
			if not char then return end
			for _, part in ipairs(char:GetDescendants()) do
				if part:IsA("BasePart") then
					part.CanCollide = false
				end
			end
		end,
		OnStop = function()
			local char = LocalPlayer.Character
			if char then
				for _, part in ipairs(char:GetDescendants()) do
					if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" then
						part.CanCollide = true
					end
				end
			end
		end,
	})

	-- ── Combat ──
	local Combat = Main:Section({ Title = "Combat" })

	Combat:Dropdown({
		Title = "Bat Targets",
		Options = { "Thieves Only", "Nearest", "All Players" },
		Default = { "Thieves Only" },
		Callback = function(v)
			State.BatMode = type(v) == "table" and v[1] or v
		end,
	})

	Combat:Slider({
		Title = "Bat Range",
		Min = 8,
		Max = 40,
		Increment = 2,
		Default = 14,
		Callback = function(v)
			State.BatRange = v
		end,
	})

	local lastBat = 0
	local function batSwing(): boolean
		if os.clock() - lastBat < (State.BatCooldown or 2) then return false end
		local char = LocalPlayer.Character
		local tool = char and (char:FindFirstChild("Area Bat") or char:FindFirstChildWhichIsA("Tool"))
		if not tool then
			-- try equipping the area bat through the game's own endpoint
			pcall(function()
				Network.Invoke(Endpoints.Index.REQUEST_EQUIP_AREA_BAT, true)
			end)
			task.wait(0.3)
			char = LocalPlayer.Character
			tool = char and (char:FindFirstChild("Area Bat") or char:FindFirstChildWhichIsA("Tool"))
			if not tool then return false end
		end
		lastBat = os.clock()
		local okA, aErr = pcall(function()
			(tool :: any):Activate()
		end)
		if not okA then
			pcall(function()
				Network.Fire(Endpoints.Bat.ACTIVATE)
			end)
		end
		return true
	end

	local function isThief(player: Player): boolean
		-- a thief = another player inside our plot bounds
		local plot = getOwnPlotModel()
		if not plot then return false end
		local theirChar = player.Character
		local theirRoot = theirChar and theirChar:FindFirstChild("HumanoidRootPart")
		local cp = plot:FindFirstChild("CenterPoint")
		if theirRoot and cp then
			return (theirRoot.Position - cp.Position).Magnitude < 70
		end
		return false
	end

	addFeature({
		Id = "AutoBat",
		Section = Combat,
		Title = "Auto Bat",
		Content = "Swing bat at selected targets in range",
		BaseDelay = 1.5,
		Loop = function(st)
			local root = getRoot()
			if not root then return end
			local range = st.BatRange or 14
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr ~= LocalPlayer and plr.Character then
					local theirRoot = plr.Character:FindFirstChild("HumanoidRootPart")
					if theirRoot then
						local d = (theirRoot.Position - root.Position).Magnitude
						local mode = st.BatMode or "Thieves Only"
						local inRange = d <= range
						local wanted = mode == "All Players" or (mode == "Nearest" and inRange) or (mode == "Thieves Only" and inRange and isThief(plr))
						if wanted and batSwing() then
							Walker.action = "Batting " .. plr.Name
							break
						end
					end
				end
			end
		end,
	})

	Combat:Toggle({
		Title = "Anti-Theft",
		Content = "Bat thieves inside your plot",
		Default = false,
		Callback = function(v)
			State.AntiTheft = v
		end,
		Flag = "SAE/AntiTheft",
	})

	addFeature({
		Id = "AntiTheftLoop",
		Section = Combat,
		Title = "Anti-Theft Watch",
		Content = "Requires Auto Bat for the swing",
		BaseDelay = 1,
		Loop = function(st)
			if not st.AntiTheft then return end
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr ~= LocalPlayer and isThief(plr) then
					Walker.action = "Defending vs " .. plr.Name
					batSwing()
				end
			end
		end,
	})

	Combat:Slider({
		Title = "Bat Cooldown",
		Min = 1,
		Max = 10,
		Increment = 1,
		Default = 2,
		Callback = function(v)
			State.BatCooldown = v
		end,
	})

	-- ═══════════════════════════════════════════
	-- AUTOMATION PAGE
	-- ═══════════════════════════════════════════
	local Automation = Tabs.Automation

	-- ── Auto Collect ──
	local CollectSection = Automation:Section({ Title = "Auto Collect" })

	addFeature({
		Id = "AutoCollect",
		Section = CollectSection,
		Title = "Auto Collect Eggs",
		Content = "Walk to nearest field eggs and carry them",
		BaseDelay = 2.5,
		Loop = function(st)
			refreshEggs()
			local onlyDropped = st.CollectDropped
			local root = getRoot()
			local best, bestDist, bestPos = nil, math.huge, nil
			for uid, rec in pairs(EggBus.Eggs) do
				if not onlyDropped or rec.State == "Dropped" then
					local pos = slotPosition(rec)
					if pos and root then
						local d = (pos - root.Position).Magnitude
						if d < bestDist then
							best, bestDist, bestPos = rec, d, pos
						end
					end
				end
			end
			if best and bestPos then
				Walker.action = "Collecting " .. tostring(recordAssetName(best) or best.Uid)
				if walkTo(bestPos + Vector3.new(0, 3, 0), 45) then
					task.wait(jitter(0.4))
					tryCarry(best)
					-- deposit: walk home, then attempt drop (signature unverified — pcall variants)
					if st.DepositAtPlot then
						local plot = getOwnPlotModel()
						local cp = plot and (plot:FindFirstChild("CenterPoint") or plot:FindFirstChildWhichIsA("BasePart"))
						if cp then
							Walker.action = "Depositing"
							walkTo(cp.Position + Vector3.new(0, 3, 0), 45)
							pcall(function()
								(EggCmds :: any).RequestDropAreaEgg()
							end)
						end
					end
				end
			else
				Walker.action = "No eggs in range"
			end
		end,
	})

	CollectSection:Toggle({
		Title = "Dropped Eggs Only",
		Content = "Only target loose/stolen (Dropped) eggs",
		Default = false,
		Callback = function(v)
			State.CollectDropped = v
		end,
		Flag = "SAE/CollectDropped",
	})

	CollectSection:Toggle({
		Title = "Deposit At Plot",
		Content = "Walk home and drop after each carry (experimental)",
		Default = false,
		Callback = function(v)
			State.DepositAtPlot = v
		end,
		Flag = "SAE/Deposit",
	})

	-- ── Auto Hatch ──
	local HatchSection = Automation:Section({ Title = "Auto Hatch" })

	addFeature({
		Id = "AutoHatch",
		Section = HatchSection,
		Title = "Auto Hatch",
		Content = "Hatch ready eggs on your plot",
		BaseDelay = 6,
		Loop = function(_st)
			local okRecs, records = pcall(function()
				return EggCmds.GetOwnerRuntimeRecords(LocalPlayer.UserId)
			end)
			if not okRecs or type(records) ~= "table" then return end
			for _, rec in ipairs(records) do
				if not State._alive then return end
				local ready = false
				pcall(function()
					ready = (EggCmds :: any).IsLocalEggReady(rec.Uid)
				end)
				if ready then
					local okH = pcall(function()
						return EggCmds.RequestHatchEgg(rec.Uid)
					end)
					if okH then
						State.SessionHatches += 1
						task.wait(jitter(1.2))
						pcall(function()
							EggCmds.RequestCompleteHatchEgg(rec.Uid)
						end)
					end
					task.wait(jitter(2))
				end
			end
		end,
	})

	-- ── Auto Sell ──
	local SellSection = Automation:Section({ Title = "Auto Sell" })

	addFeature({
		Id = "AutoSell",
		Section = SellSection,
		Title = "Auto Sell All (one shot)",
		Content = "Fires SellAllAssets once, then turns off",
		BaseDelay = 30,
		Loop = function(st)
			pcall(function()
				Network.Fire(Endpoints.AssetInventory.SELL_ALL_ASSETS)
			end)
			st.SessionSells += 1
			local entry = Features.AutoSell
			if entry then
				entry.enabled = false
				if entry.toggle then entry.toggle:Set(false) end
			end
		end,
	})

	SellSection:Button({
		Title = "Sell All Now",
		Content = "One-shot sell of all assets",
		Callback = function()
			pcall(function()
				Network.Fire(Endpoints.AssetInventory.SELL_ALL_ASSETS)
			end)
		end,
	})

	-- ── Auto Upgrades ──
	local UpgradeSection = Automation:Section({ Title = "Auto Upgrades" })

	addFeature({
		Id = "AutoUpgrade",
		Section = UpgradeSection,
		Title = "Auto Base Upgrade",
		Content = "Buys next base level when affordable",
		BaseDelay = 15,
		Loop = function(_st)
			local okSave, saveData = pcall(function()
				return Save.Get(LocalPlayer, false)
			end)
			if not okSave or type(saveData) ~= "table" then return end
			local okCan, can = pcall(function()
				return BaseUpgradeClient.CanAffordNext(saveData)
			end)
			if okCan and can then
				local okUp = pcall(function()
					return BaseUpgradeClient.RequestCashUpgrade()
				end)
				if okUp then
					State.SessionUpgrades += 1
					task.wait(jitter(3))
				end
			end
		end,
	})

	UpgradeSection:Paragraph({
		Title = "Treadmill Upgrade",
		Content = "Unavailable — remote args unverified",
	})

	-- ── Auto Claims ──
	local ClaimSection = Automation:Section({ Title = "Auto Claims" })

	ClaimSection:Button({
		Title = "Claim All Now",
		Content = "Index claim-all (one shot)",
		Callback = function()
			pcall(function()
				Network.Invoke(Endpoints.Index.REQUEST_CLAIM_ALL)
			end)
			pcall(function()
				Network.Invoke(Endpoints.Index.REQUEST_CLAIM_LIMITED_EGG_REWARD)
			end)
		end,
	})

	addFeature({
		Id = "AutoClaim",
		Section = ClaimSection,
		Title = "Periodic Claim All",
		Content = "Claim index rewards every cycle",
		BaseDelay = 300,
		Loop = function()
			pcall(function()
				Network.Invoke(Endpoints.Index.REQUEST_CLAIM_ALL)
			end)
		end,
	})

	-- ── Auto Steal (Dropped) ──
	local StealSection = Automation:Section({ Title = "Auto Steal" })

	StealSection:Paragraph({
		Title = "How stealing works",
		Content = "Field/dropped eggs are carried via the native Steal prompt path. Placed-asset (DNA) stealing is Robux-gated by the game and not supported.",
	})

	addFeature({
		Id = "AutoSteal",
		Section = StealSection,
		Title = "Auto Steal Dropped",
		Content = "Prioritizes Dropped (loose) eggs anywhere",
		BaseDelay = 4,
		Loop = function(_st)
			refreshEggs()
			local root = getRoot()
			local best, bestDist, bestPos = nil, math.huge, nil
			for uid, rec in pairs(EggBus.Eggs) do
				if rec.State == "Dropped" then
					local pos = slotPosition(rec)
					if pos and root then
						local d = (pos - root.Position).Magnitude
						if d < bestDist then
							best, bestDist, bestPos = rec, d, pos
						end
					end
				end
			end
			if best and bestPos then
				Walker.action = "Stealing dropped egg"
				if walkTo(bestPos + Vector3.new(0, 3, 0), 45) then
					task.wait(jitter(0.5))
					tryCarry(best)
				end
			end
		end,
	})

	-- ═══════════════════════════════════════════
	-- MISC PAGE
	-- ═══════════════════════════════════════════
	local Misc = Tabs.Misc

	-- ── ESP ──
	local EspSection = Misc:Section({ Title = "ESP" })

	local RARITY_COLORS: {[string]: Color3} = {
		Common = Color3.fromRGB(180, 180, 180),
		Uncommon = Color3.fromRGB(85, 200, 85),
		Rare = Color3.fromRGB(70, 140, 255),
		Epic = Color3.fromRGB(170, 85, 255),
		Legendary = Color3.fromRGB(255, 170, 40),
		Mythic = Color3.fromRGB(255, 80, 80),
		Secret = Color3.fromRGB(40, 40, 40),
		Cosmic = Color3.fromRGB(120, 220, 255),
	}

	local function clearHighlights()
		for _, h in ipairs(Highlights) do
			pcall(function()
				h:Destroy()
			end)
		end
		Highlights = {}
	end

	local function addHighlight(parent: Instance, color: Color3, name: string)
		if parent:FindFirstChild("ReHubESP") then return end
		local h = Instance.new("Highlight")
		h.Name = "ReHubESP"
		h.FillTransparency = 0.75
		h.OutlineColor = color
		h.FillColor = color
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.Parent = parent
		table.insert(Highlights, h)
	end

	local function eggEspTick()
		refreshEggs()
		local slots = Workspace:FindFirstChild("AreaEggSlotsClient")
		if not slots then return end
		for uid, rec in pairs(EggBus.Eggs) do
			local pos = slotPosition(rec)
			if pos then
				for _, child in ipairs(slots:GetChildren()) do
					if string.find(child.Name, uid, 1, true) then
						local rarity = recordRarity(rec) or "Common"
						addHighlight(child, RARITY_COLORS[rarity] or Color3.new(1, 1, 1), "egg")
						break
					end
				end
			end
		end
	end

	local function playerEspTick()
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= LocalPlayer and plr.Character then
				addHighlight(plr.Character, Color3.fromRGB(255, 90, 90), "player")
			end
		end
	end

	local function guardEspTick()
		local guards = Workspace:FindFirstChild("_Guards")
		if guards then
			for _, g in ipairs(guards:GetChildren()) do
				addHighlight(g, Color3.fromRGB(255, 200, 0), "guard")
			end
		end
	end

	addFeature({
		Id = "EggESP",
		Section = EspSection,
		Title = "ESP Eggs",
		Content = "Rarity-colored outlines on field eggs",
		BaseDelay = 1.5,
		Loop = function(_st)
			eggEspTick()
		end,
		OnStop = clearHighlights,
	})

	addFeature({
		Id = "PlayerESP",
		Section = EspSection,
		Title = "ESP Players",
		Content = "Red outlines on players",
		BaseDelay = 2,
		Loop = function(_st)
			playerEspTick()
		end,
		OnStop = clearHighlights,
	})

	addFeature({
		Id = "GuardESP",
		Section = EspSection,
		Title = "ESP Guards",
		Content = "Yellow outlines on guards",
		BaseDelay = 2,
		Loop = function(_st)
			guardEspTick()
		end,
		OnStop = clearHighlights,
	})

	-- ── Info + Panic ──
	local Info = Misc:Section({ Title = "Info" })

	local actionPara = Info:Paragraph({
		Title = "Action",
		Content = "Idle",
	})

	local statsPara = Info:Paragraph({
		Title = "Session",
		Content = "Eggs 0 · Hatches 0 · Sells 0 · Upgrades 0",
	})

	task.spawn(function()
		while State._alive and task.wait(1.5) do
			local parts = {}
			for name, entry in pairs(Features) do
				if entry.enabled then
					table.insert(parts, name)
				end
			end
			actionPara:Set({
				Title = "Action — " .. (#parts > 0 and table.concat(parts, ", ") or "no features"),
				Content = Walker.busy and Walker.action or "Idle",
			})
			statsPara:Set({
				Title = "Session",
				Content = "Eggs " .. State.SessionEggs .. " · Hatches " .. State.SessionHatches
					.. " · Sells " .. State.SessionSells .. " · Upgrades " .. State.SessionUpgrades,
			})
		end
	end)

	Info:Button({
		Title = "PANIC — Stop Everything",
		Content = "Disable all features, reset movement",
		Callback = function()
			for _, entry in pairs(Features) do
				entry.enabled = false
			end
			State.SpeedHack = false
			State.AntiTheft = false
			clearHighlights()
			local hum = getHumanoid()
			if hum then hum.WalkSpeed = OriginalWalkSpeed end
			Window:Notify({ Title = "Steal An Egg", Content = "PANIC — all features stopped", Delay = 4 })
		end,
	})

	Window:Notify({ Title = "Steal An Egg", Content = "Feature engine loaded — all features OFF", Delay = 4 })
end
