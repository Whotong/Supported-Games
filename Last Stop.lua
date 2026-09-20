--!strict
-- Re: Hub — Last Stop [Beta] (universe GameId 10759337137, The Hidden Route)
-- Run place: 122776220269735 (client-reported name "Ugc" — internal place name,
-- not the public title). Lobby PlaceId: <unknown>.
-- SAFETY POSTURE: UI-only probe. No remote fires, no hooks, no movement writes.
-- Read-only APIs only (FindFirstChild/GetChildren/GetAttributes/distance math).
-- Contract: function(Window, Tabs) — Tabs.Main/Automation/Misc built by Re-Hub/main.lua.
--
-- Recon (2026-09-20, live client in RUN place, passive only):
--   Knit game (ClientSource.Mutual.Packages.Knit), 133 remotes, 49 services.
--   Containers: PLAYER_CONTAINER / ENTITY_CONTAINER / ITEM_CONTAINER (UUID Tools,
--   ForSale/Feature_Grab attrs, PriceTag) / CHUNKS_CONTAINER (47 streaming chunks).
--   Prompts: Shop Buy, Conveyor Sell, Vault Open, Workbench Craft, Bus Drive/Burn,
--   Ammo Buy, Challenges Board. Player mirrored in PLAYER_CONTAINER (HRP true).
--   BanService (GetBans/Unban) + AnalyticsService telemetry exist — one feature
--   at a time after this probe passes with no kick. Lobby structure: <unknown>.
-- Next (decompile-first, NO __namecall logger until proven safe here):
--   ItemService EquipItem/ToggleEquip, VaultService Store/Unstore, CraftService
--   Craft, ReviveService Heal/ReviveSelf, QuestService ClaimQuest, BadgesService
--   ClaimReward, GameService ResetToBus/ReturnLobby args.

return function(Window: any, Tabs: any)
	local Workspace = game:GetService("Workspace")
	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer

	local State: { [string]: any } = { _alive = true }
	local Conns: { [number]: any } = {}
	local Highlights: { [number]: any } = {}

	local function getRoot(): any?
		local char = LocalPlayer.Character
		return char and char:FindFirstChild("HumanoidRootPart") or nil
	end

	local function clearHighlights()
		for _, h in ipairs(Highlights) do
			pcall(function()
				h:Destroy()
			end)
		end
		Highlights = {}
	end

	-- Phase + float: active whole-duration while Auto Grab is ON (no toggle).
	-- phase(false) restores world collision (HRP never touched). floatTick
	-- floors fall speed at -4 so the body hover-sinks instead of plunging;
	-- nothing is created, so stopping re-asserts restores gravity instantly.
	local function phase(on: boolean)
		local char = LocalPlayer.Character
		if not char then
			return
		end
		for _, p in ipairs(char:GetDescendants()) do
			if p:IsA("BasePart") then
				pcall(function()
					if p.Name == "HumanoidRootPart" then
						return
					end
					p.CanCollide = not on
				end)
			end
		end
	end

	local function floatTick()
		local r = getRoot()
		if not r then
			return
		end
		pcall(function()
			local v = r.AssemblyLinearVelocity
			if v.Y < -4 then
				r.AssemblyLinearVelocity = Vector3.new(v.X, -4, v.Z)
			end
		end)
	end

	-- Stepped hold: the game's own character stack re-enables collision
	-- every frame, so per-tick re-asserts lose. Hold at physics frequency
	-- while ON; single disconnect + restore on OFF.
	local stepConn: any = nil
	local function phaseHold(on: boolean)
		if on then
			if stepConn then
				return
			end
			stepConn = RunService.Stepped:Connect(function()
				phase(true)
			end)
			table.insert(Conns, stepConn)
		elseif stepConn then
			pcall(function()
				stepConn:Disconnect()
			end)
			stepConn = nil
			phase(false)
		else
			phase(false)
		end
	end

	local function moveLock(on: boolean)
		if on then
			if SavedMoveMode == nil then
				SavedMoveMode = LocalPlayer.DevComputerMovementMode
				pcall(function()
					LocalPlayer.DevComputerMovementMode = Enum.DevComputerMovementMode.Scriptable
				end)
			end
		elseif SavedMoveMode ~= nil then
			pcall(function()
				LocalPlayer.DevComputerMovementMode = SavedMoveMode
			end)
			SavedMoveMode = nil
		end
	end

	Window:OnClose(function()
		State._alive = false
		for _, c in ipairs(Conns) do
			pcall(function()
				c:Disconnect()
			end)
		end
		clearHighlights()
		phaseHold(false)
		moveLock(false)
		local char = LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.WalkSpeed = 16
		end
	end)

	-- ═══════════════════════════════════════════
	-- KNIT — game's own service client (decompile-verified call chain)
	-- ═══════════════════════════════════════════
	local ReplicatedStorage = game:GetService("ReplicatedStorage")
	local RunService = game:GetService("RunService")
	local Knit, ItemSvc, ItemCtrl
	local SavedMoveMode: any = nil
	pcall(function()
		Knit = require(ReplicatedStorage.ClientSource.Mutual.Packages.Knit)
	end)

	local function services()
		if ItemSvc then
			return true
		end
		if not Knit then
			return false
		end
		local ok, svc = pcall(function()
			return Knit.GetService("ItemService")
		end)
		if ok and svc then
			ItemSvc = svc
			pcall(function()
				ItemCtrl = Knit.GetController("ItemController")
			end)
			return true
		end
		return false
	end

	-- ═══════════════════════════════════════════
	-- RUNNER — flag-gated, jittered, self-limiting loops
	-- ═══════════════════════════════════════════
	local Features: { [string]: any } = {}

	local function jitter(base: number): number
		return base * (0.7 + math.random() * 0.6) -- ±30%
	end

	local function addFeature(def: any)
		Features[def.Id] = { enabled = false, def = def, errors = 0 }
		local entry = Features[def.Id]
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
									Window:Notify({ Title = "Last Stop", Content = def.Title .. " disabled after repeated errors: " .. tostring(runErr), Delay = 6 })
									break
								end
							else
								entry.errors = 0
							end
							if not State._alive or not entry.enabled then
								break
							end
							task.wait(jitter(def.BaseDelay or 2))
						end
					end)
				else
					if def.OnStop then
						pcall(def.OnStop, State)
					end
				end
			end,
		})
	end

	-- ═══════════════════════════════════════════
	-- WALKER — physics-legit MoveTo, travel-only speed boost
	-- No detectors on items (probed 2026-09-20: 0 ClickDetectors/Prompts) —
	-- grab resolves server-side, so arrival 8 keeps us well inside any
	-- sane server distance check. Tighten if equips get denied.
	-- ═══════════════════════════════════════════
	local ARRIVE = 8
	local Walker = { busy = false }

	local function walkTo(targetPos: Vector3, speed: number, timeout: number?): boolean
		local char = LocalPlayer.Character
		local root = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if not root or not hum then
			return false
		end
		Walker.busy = true
		local saved = hum.WalkSpeed
		hum.WalkSpeed = speed
		local reached = true
		local function cleanup()
			local h = LocalPlayer.Character and LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			if h then
				h.WalkSpeed = saved
			end
			Walker.busy = false
		end
		do
			local pos = root.Position
			local dist = (targetPos - pos).Magnitude
			local spacing = math.clamp(speed * 1.2, 12, 30)
			local hops = math.clamp(math.floor(dist / spacing) + 1, 1, 12)
			local deadline = os.clock() + (timeout or math.min(10 + dist / math.max(speed, 1) * 1.5, 45))
			for i = 1, hops do
				if not State._alive or os.clock() > deadline then
					reached = false
					break
				end
				local wp = pos:Lerp(targetPos, i / hops)
				if i < hops then
					wp += Vector3.new((math.random() - 0.5) * 6, 0, (math.random() - 0.5) * 6)
				end
				local okM, err = pcall(function()
					hum:MoveTo(wp)
				end)
				if not okM then
					reached = false
					break
				end
				local t0 = os.clock()
				local lastPos = root.Position
				while os.clock() - t0 < 6 do
					if not State._alive then
						reached = false
						break
					end
					local r = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
					if not r then
						reached = false
						break
					end
					if (r.Position - wp).Magnitude < 5 then
						break
					end
					if (r.Position - lastPos).Magnitude < 0.5 and (os.clock() - t0) > 1.5 then
						hum.Jump = true
						t0 = os.clock()
					end
					lastPos = r.Position
					-- Hover leg: steer Y-velocity toward the waypoint so the
					-- body glides level/up/down instead of walking grounded.
					pcall(function()
						local v = r.AssemblyLinearVelocity
						local wantY = math.clamp((wp.Y - r.Position.Y) * 2, -10, 10)
						r.AssemblyLinearVelocity = Vector3.new(v.X, math.max(wantY, -4), v.Z)
					end)
					task.wait(0.15)
				end
				local r = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
				if not r or (r.Position - wp).Magnitude >= 5 then
					reached = false
					break
				end
				if (r.Position - targetPos).Magnitude <= ARRIVE then
					reached = true
					break
				end
			end
		end
		cleanup()
		return reached
	end

	-- Place-aware boot: run containers stream in after join, so an instant
	-- FindFirstChild misfires into lobby mode on fast loads (observed:
	-- empty Automation/Misc). Wait up to 15s before deciding.
	local runItems = Workspace:WaitForChild("ITEM_CONTAINER", 15)
	local runChunks = runItems and Workspace:WaitForChild("CHUNKS_CONTAINER", 15) or nil
	if runItems == nil or runChunks == nil then
		local Main = Tabs.Main
		local Lobby = Main:Section({ Title = "Lobby" })
		local lobbyPara = Lobby:Paragraph({
			Title = "Last Stop lobby",
			Content = "GameId "
				.. tostring(game.GameId)
				.. " · PlaceId "
				.. tostring(game.PlaceId)
				.. " — run features live in the run place only.",
		})
		Window:Notify({ Title = "Last Stop", Content = "Lobby place — run features unavailable", Delay = 4 })
		-- Watcher: if run data streams in late, offer a clean reload (the
		-- single-instance guard tears this UI down; fresh boot takes run).
		Lobby:Button({
			Title = "Reload Hub",
			Content = "Re-run loader (also auto-offered when run data arrives)",
			Callback = function()
				pcall(function()
					loadstring(game:HttpGet("https://raw.githubusercontent.com/Whotong/Re-Hub/refs/heads/main/main.lua"))()
				end)
			end,
		})
		task.spawn(function()
			local notified = false
			while State._alive and not notified do
				task.wait(5)
				if Workspace:FindFirstChild("ITEM_CONTAINER") and Workspace:FindFirstChild("CHUNKS_CONTAINER") then
					notified = true
					lobbyPara:Set({ Title = "Run place detected", Content = "Press Reload Hub to load run features." })
					Window:Notify({ Title = "Last Stop", Content = "Run place detected — press Reload Hub", Delay = 8 })
				end
			end
		end)
		return
	end

	-- ═══════════════════════════════════════════
	-- MAIN — identity + read-only recon dashboard (RUN place only)
	-- ═══════════════════════════════════════════
	local Main = Tabs.Main
	local Dash = Main:Section({ Title = "Recon Dashboard" })

	Dash:Paragraph({
		Title = "Last Stop probe",
		Content = "Run place 122776220269735 · dashboard read-only; Auto Grab fires EquipItem",
	})

	local counts = Dash:Paragraph({ Title = "World", Content = "Press Refresh…" })
	Dash:Button({
		Title = "Refresh Counts",
		Content = "Read-only: containers, items, entities, prompts",
		Callback = function()
			local ok, txt = pcall(function()
				local function n(inst: any?): number
					return inst and #inst:GetChildren() or 0
				end
				local items = Workspace:FindFirstChild("ITEM_CONTAINER")
				local ents = Workspace:FindFirstChild("ENTITY_CONTAINER")
				local chunks = Workspace:FindFirstChild("CHUNKS_CONTAINER")
				local sale, grab = 0, 0
				if items then
					for _, t in ipairs(items:GetChildren()) do
						if t:IsA("Tool") then
							local a = t:GetAttributes()
							if a.ForSale then
								sale += 1
							end
							if a.Feature_Grab then
								grab += 1
							end
						end
					end
				end
				return "Items "
					.. n(items)
					.. " (sale "
					.. sale
					.. ", grab "
					.. grab
					.. ") · Entities "
					.. n(ents)
					.. " · Chunks "
					.. n(chunks)
			end)
			counts:Set({ Title = "World", Content = ok and txt or ("error: " .. tostring(txt)) })
		end,
	})

	local nearest = Dash:Paragraph({ Title = "Nearest", Content = "Press Scan…" })
	Dash:Button({
		Title = "Scan Nearest Item",
		Content = "Read-only distance math, no movement",
		Callback = function()
			local ok, txt = pcall(function()
				local root = getRoot()
				if not root then
					return "No character (respawning?)"
				end
				local items = Workspace:FindFirstChild("ITEM_CONTAINER")
				if not items then
					return "No ITEM_CONTAINER"
				end
				local best, bestD = nil, math.huge
				for _, t in ipairs(items:GetChildren()) do
					local m = t:FindFirstChild("Item")
					local anchor = (m and m:IsA("BasePart") and m)
						or t:FindFirstChildWhichIsA("BasePart", true)
					if anchor then
						local d = (anchor.Position - root.Position).Magnitude
						if d < bestD then
							best, bestD = t, d
						end
					end
				end
				if not best then
					return "No anchored items"
				end
				local a = best:GetAttributes()
				return (best :: any).Name
					.. " · "
					.. math.floor(bestD)
					.. " studs · sale="
					.. tostring(a.ForSale)
			end)
			nearest:Set({ Title = "Nearest", Content = ok and txt or ("error: " .. tostring(txt)) })
		end,
	})

	-- ═══════════════════════════════════════════
	-- AUTOMATION — Auto Grab (EquipItem verified 2026-09-20)
	-- ═══════════════════════════════════════════
	local Automation = Tabs.Automation
	local GrabSection = Automation:Section({ Title = "Auto Grab" })

	local grabStatus = GrabSection:Paragraph({ Title = "Status", Content = "Idle — toggle on to start" })

	GrabSection:Toggle({
		Title = "For-Sale Only",
		Content = "Only grab items flagged ForSale",
		Default = false,
		Callback = function(v: boolean)
			State.SaleOnly = v
		end,
	})

	GrabSection:Slider({
		Title = "Travel Speed",
		Min = 16,
		Max = 50,
		Increment = 2,
		Default = 32,
		Callback = function(v: number)
			State.TravelSpeed = v
		end,
	})

	addFeature({
		Id = "AutoGrab",
		Section = GrabSection,
		Title = "Auto Grab",
		Content = "Walk to nearest grabbable item and equip it",
		BaseDelay = 2.5,
		OnStop = function()
			phaseHold(false)
			moveLock(false)
		end,
		Loop = function(st: any)
			if not services() then
				grabStatus:Set({ Title = "Status", Content = "Knit ItemService not ready" })
				return
			end
			local char = LocalPlayer.Character
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if not root then
				return
			end
			phaseHold(true)
			moveLock(true)
			floatTick()
			local items = Workspace:FindFirstChild("ITEM_CONTAINER")
			if not items then
				return
			end
			local best, bestDist, bestPos = nil, math.huge, nil
			for _, t in ipairs(items:GetChildren()) do
				local okA, attrs = pcall(function()
					return t:GetAttributes()
				end)
				if okA and attrs.Feature_Grab then
					if not st.SaleOnly or attrs.ForSale then
						local equipable = true
						if ItemCtrl then
							pcall(function()
								equipable = ItemCtrl:IsItemEquipable(t) ~= false
							end)
						end
						if equipable then
							local anchor = t:FindFirstChildWhichIsA("BasePart", true)
							if anchor then
								local d = (anchor.Position - root.Position).Magnitude
								if d < bestDist then
									best, bestDist, bestPos = t, d, anchor.Position
								end
							end
						end
					end
				end
			end
			if not best or not bestPos then
				grabStatus:Set({ Title = "Status", Content = "No grabbable items" })
				return
			end
			local speed = st.TravelSpeed or 32
			if bestDist > ARRIVE then
				grabStatus:Set({ Title = "Status", Content = "Walking (" .. math.floor(bestDist) .. " studs)" })
				if not walkTo(bestPos, speed) then
					grabStatus:Set({ Title = "Status", Content = "Walk failed, retrying" })
					return
				end
				task.wait(jitter(0.4))
			end
			local okE, res = pcall(function()
				return ItemSvc:EquipItem(best)
			end)
			if okE then
				State.SessionGrabs = (State.SessionGrabs or 0) + 1
				grabStatus:Set({ Title = "Status", Content = "Grabbed (" .. (State.SessionGrabs or 0) .. " this session)" })
			else
				grabStatus:Set({ Title = "Status", Content = "Equip denied: " .. tostring(res) })
			end
		end,
	})

	-- Respawn re-apply: fresh character parts collide by default; restore
	-- phasing while the feature is still on.
	table.insert(Conns, LocalPlayer.CharacterAdded:Connect(function()
		local entry = Features.AutoGrab
		if entry and entry.enabled then
			task.wait(1)
			if State._alive and entry.enabled then
				phase(true)
			end
		end
	end))

	-- ═══════════════════════════════════════════
	-- MISC — visual-only item ESP (local Highlights, OFF default)
	-- ═══════════════════════════════════════════
	local Misc = Tabs.Misc
	local Esp = Misc:Section({ Title = "ESP" })
	local espOn = false
	Esp:Toggle({
		Title = "ESP Items",
		Content = "Local outlines only, no remotes",
		Default = false,
		Callback = function(v: boolean)
			espOn = v
			if v then
				task.spawn(function()
					while State._alive and espOn do
						pcall(function()
							local items = Workspace:FindFirstChild("ITEM_CONTAINER")
							if items then
								for _, t in ipairs(items:GetChildren()) do
									if not t:FindFirstChild("ReHubESP") then
										local h = Instance.new("Highlight")
										h.Name = "ReHubESP"
										h.FillTransparency = 0.85
										h.FillColor = Color3.fromRGB(0, 230, 118)
										h.OutlineColor = Color3.fromRGB(0, 230, 118)
										h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
										h.Parent = t
										table.insert(Highlights, h)
									end
								end
							end
						end)
						task.wait(2)
					end
				end)
			else
				clearHighlights()
			end
		end,
	})

	local Info = Misc:Section({ Title = "Info" })
	Info:Button({
		Title = "PANIC — Clear ESP",
		Content = "Remove all local highlights",
		Callback = function()
			espOn = false
			clearHighlights()
			Window:Notify({ Title = "Last Stop", Content = "ESP cleared", Delay = 3 })
		end,
	})

	Window:Notify({ Title = "Last Stop", Content = "Loaded — Auto Grab ready", Delay = 4 })
end
