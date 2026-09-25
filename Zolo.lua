-- v3.71 Big Froot Egg Modes + v3.69 Notification-Sync + v3.67 Ranch-Smooth
--[[
    Eggs ESP v3.65 - Hatch-Fix + Low-Freeze Egg Automation + Startup-Safe FPS-Friendly ESP
    One-file bootstrap: caches its main runtime to executor storage so
    queue_on_teleport can reload it after a server hop/reconnect.
]]

local __ZOLO_AUTORUN_PATH = "ZoloEggsESP/autorun_main.lua"
local __ZOLO_MAIN_SOURCE = [=====[
--[[

*    Eggs ESP Menu v3.65 - Hatch-Fix + Low-Freeze Egg Automation + Startup-Safe FPS-Friendly ESP*

*    Original by ThiAez | Owner / Editor: Zolo*

*    MEJORAS:*

*    - ESP con aura + nombre + distancia*

*    - ESP individual verde*

*    - Contador de Eggs*

*    - Lista que se actualiza sola*

*    - Buscador mejorado*

*    - Orden por nombre o distancia*

*    - TP más seguro*

*    - Auto Best Egg más resistente*

*    - AutoFarm por Egg + botón rojo de detener*

*    - Iconos de Egg obtenidos desde Index > EggsHolder*

*    - Animaciones suaves de botones y menú*

*    - PC / Mobile*

*    - Minimizar y arrastrar*

*    - Keybind configurable para TP Inicio*

*    IMPORTANTE:*

*    La estructura está separada por sistemas para que sea fácil de entender*

*    y modificar sin tener que buscar dentro de un script gigante.*

]] 

--==================================================

-- SERVICIOS

--==================================================

local Players = game:GetService("Players")

local TweenService = game:GetService("TweenService")

local RunService = game:GetService("RunService")

local UserInputService = game:GetService("UserInputService")

local VirtualInputManager = game:GetService("VirtualInputManager")

local CoreGui = game:GetService("CoreGui")

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Workspace = game:GetService("Workspace")

-- v3.59 STARTUP FIX: after teleport/reconnect, some executors can run the
-- queued chunk before Players.LocalPlayer exists. Never index LocalPlayer until
-- the client has actually created it. A short polling yield avoids the missed-
-- signal race that can happen with GetPropertyChangedSignal(...):Wait().
if not game:IsLoaded() then
    pcall(function() game.Loaded:Wait() end)
end

local LocalPlayer = Players.LocalPlayer
while not LocalPlayer do
    task.wait(0.05)
    LocalPlayer = Players.LocalPlayer
end

-- STRICT POST-REJOIN BOOT GATE
-- Do not register/clean/build ZOLO while Roblox is still assembling the new
-- client after TeleportService:Teleport(). This same gate also protects a
-- manual execution immediately after rejoin.
do
    local deadline = os.clock() + 60
    local stableFrames = 0

    while os.clock() < deadline do
        local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        local camera = Workspace.CurrentCamera
        local mainGui = playerGui and playerGui:FindFirstChild("Main")
        local remotes = ReplicatedStorage:FindFirstChild("Remotes")

        local ready = game:IsLoaded()
            and playerGui ~= nil
            and character ~= nil
            and humanoid ~= nil
            and humanoid.Health > 0
            and root ~= nil
            and root:IsDescendantOf(Workspace)
            and camera ~= nil
            and mainGui ~= nil
            and remotes ~= nil

        if ready then
            stableFrames = stableFrames + 1
            if stableFrames >= 8 then
                break
            end
        else
            stableFrames = 0
        end

        task.wait(0.10)
    end

    -- Give replicated UI/remotes one final settle window after all required
    -- objects have remained present across multiple checks.
    task.wait(0.35)
end

--==================================================
-- SINGLE-INSTANCE RUNTIME / RE-EXECUTE CLEANUP
--==================================================

local RuntimeEnv = (getgenv and getgenv()) or _G
local RuntimeKey = "__ZOLO_EGGS_ESP_RUNTIME"

-- POST-TELEPORT STARTUP FIX
-- Keep startup metadata in ONE local table. This matters because the main ZOLO
-- chunk is already close to Luau's 200-local-register ceiling.
local RuntimeBoot = {
    WasQueued = RuntimeEnv.__ZOLO_EGGS_ESP_QUEUED_BOOT == true,
    JobId = tostring(game.JobId or ""),
}
RuntimeEnv.__ZOLO_EGGS_ESP_QUEUED_BOOT = nil

do
    -- Never abort a fresh execution just because a stale queued/manual runtime
    -- table survived the teleport. The normal cleanup below owns replacement.
    -- Older overlapping executions are stopped later by Runtime.IsSuperseded().
    RuntimeBoot.Generation =
        (tonumber(RuntimeEnv.__ZOLO_EGGS_ESP_BOOT_GENERATION) or 0) + 1
    RuntimeEnv.__ZOLO_EGGS_ESP_BOOT_GENERATION = RuntimeBoot.Generation
end

--==================================================
-- PREVIOUS ZOLO CLEANUP (SEPARATE SUBSYSTEM)
--==================================================
-- Stop only known ZOLO runtimes from older revisions. This deliberately avoids
-- touching unrelated game scripts, LocalScripts, or third-party runtimes.
do
    local knownRuntimeKeys = {
        "__ZOLO_EGGS_ESP_RUNTIME",
        "__ZOLO_ESP_LOCALPLAYER_NOTIFICATIONS_STANDALONE",
        "__ZOLO_BFROOT_ESP_GETDROP_RUNTIME",
        "__ZOLO_BFROOT_ESP_RUNTIME",
        "__ZOLO_BFROOT_ESP_AUTODROP_RUNTIME",
    }

    local function stopKnownZoloRuntime(key)
        local old = RuntimeEnv[key]
        if type(old) ~= "table" then
            RuntimeEnv[key] = nil
            return
        end

        -- Preferred path: every current ZOLO build exposes Cleanup().
        if type(old.Cleanup) == "function" then
            pcall(old.Cleanup, "reexecute")
        end

        -- Fallback path for interrupted/older partial executions.
        old.Alive = false

        if type(old.DropEggQ) == "table" then
            old.DropEggQ.Enabled = false
            old.DropEggQ.Busy = false
            old.DropEggQ.Generation = (old.DropEggQ.Generation or 0) + 1
        end

        if type(old.AutoDrop) == "table" then
            old.AutoDrop.Enabled = false
            if old.AutoDrop.Thread then
                pcall(task.cancel, old.AutoDrop.Thread)
                old.AutoDrop.Thread = nil
            end
        end

        if old.SpawnNotifications and type(old.SpawnNotifications.Stop) == "function" then
            pcall(old.SpawnNotifications.Stop)
        end

        if old.ESPRenderBindName then
            pcall(function()
                RunService:UnbindFromRenderStep(old.ESPRenderBindName)
            end)
        end

        if type(old.Connections) == "table" then
            for _, connection in ipairs(old.Connections) do
                pcall(function()
                    connection:Disconnect()
                end)
            end
            pcall(function()
                table.clear(old.Connections)
            end)
        end

        if old.ScreenGui and old.ScreenGui.Parent then
            pcall(function()
                old.ScreenGui:Destroy()
            end)
        end

        RuntimeEnv[key] = nil
    end

    for _, key in ipairs(knownRuntimeKeys) do
        stopKnownZoloRuntime(key)
    end

    -- Remove GUI leftovers from older ZOLO revisions that may have been created
    -- before their runtime reached a usable Cleanup() function.
    local playerGui = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    local guiNames = {
        "RenderedEggsESP_Menu",
        "Zolo_ESP_LocalPlayer_Notifications",
        "Zolo_BFroot_ESP_GetDrop",
        "Zolo_BFroot_ESP_F8DropDebug",
        "Zolo_BFroot_ESP_AutoDrop",
        "Zolo_BFroot_ESP_DropEggQ",
        "Zolo_BFroot_ESP_DropEgg",
        "Zolo_BFroot_ESP_DropEgg_Button",
    }

    for _, parent in ipairs({playerGui, CoreGui}) do
        if parent then
            for _, guiName in ipairs(guiNames) do
                local oldGui = parent:FindFirstChild(guiName)
                if oldGui then
                    pcall(function()
                        oldGui:Destroy()
                    end)
                end
            end
        end
    end
end

local Runtime: {[string]: any} = {
    BuildID = "ZOLO-2026-09-26-HYBRID-REJOIN1",
    Alive = true,
    Cleaned = false,
    Starting = true,
    Ready = false,
    JobId = RuntimeBoot.JobId,
    BootOrigin = RuntimeBoot.WasQueued and "queued" or "manual",
    StartedAt = os.clock(),
    BootGeneration = RuntimeBoot.Generation,
    Connections = {},
    ScreenGui = nil,
    AutoGet = {
        TravelMode = "TweenHome",
        MinWeightKg = 100000,
        PickupDelay = 1.5,
        PickupMethod = "PromptHold",
        NextPickupAt = 0,
        ConfirmTimeout = 2.5,
        ConfirmPoll = 0.08,
        HomeRetryTimeout = 1.5,
        PickupNoclipActive = false,
        RejoinBelowMin = {
            Enabled = false,
            Busy = false,
            BelowSince = nil,
            GraceSeconds = 1.10,
            LastAttemptAt = 0,
            Cooldown = 6.0,
            UI = {},
        },
        UI = {},
    },
    TargetRanch = {
        Enabled = false,
        TargetUserId = nil,
        UI = {},
        LastStatus = "OFF",
    },
    TeleportDebug = {
        Enabled = false,
        Session = 0,
    },
}

RuntimeEnv[RuntimeKey] = Runtime
RuntimeEnv.__ZOLO_EGGS_ESP_BUILD_ID = Runtime.BuildID
RuntimeEnv.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR = nil

print("[ZOLO BUILD] " .. tostring(Runtime.BuildID))

Runtime.IsCurrentExecution = function()
    return Runtime.Alive and RuntimeEnv[RuntimeKey] == Runtime
end

Runtime.IsSuperseded = function()
    if RuntimeEnv[RuntimeKey] ~= Runtime then
        Runtime.Alive = false
        return true
    end
    return false
end

Runtime.Transport = {
    State = {
        AutoReconnect = true,
        AutoExecute = true,
    },
    UI = {},
    PromptConnection = nil,
    ReconnectBusy = false,
    QueueArmed = false,
    AutorunPath = "ZoloEggsESP/autorun_main.lua",

    -- Reliable post-rejoin design:
    -- main.lua should set getgenv().__ZOLO_REMOTE_RELEASE_URL before loading ZOLO.
    -- The URL is copied into a Roblox TeleportSetting before rejoin so the queued
    -- loader can fetch a fresh release in the destination DataModel.
    RemoteReleaseURL = tostring(
        rawget(RuntimeEnv, "__ZOLO_REMOTE_RELEASE_URL") or ""
    ),
}

-- v3.47: Anti-AFK stays always enabled and input helpers are now device-aware.
-- The official Player.Idled event remains the main trigger, while a light
-- 90-second watchdog uses a touch pulse on mobile or mouse delta on desktop.
Runtime.AntiAFK = {
    Enabled = true,
    UI = {},
    Thread = nil,
    TriggerCount = 0,
    LastPulseAt = 0,
    LastReason = "startup",
    LastMethod = "waiting",
    WatchdogInterval = 90,
}

Runtime.EggAutomation = {
    UI = {},
    Busy = false,
    PlacementMemory = {},
    NestOwners = {},
    LastBagScan = {},
    LastBagScanAt = 0,
    -- v3.40 FIX: Auto Place keeps the exact live bag/slot references it already
    -- discovered. A full inventory/UI traversal happens only when this cache is
    -- explicitly invalidated by a real bag/filter change or a stale slot.
    BagCacheDirty = true,
    BagCacheDirtyReason = "startup",
    BagWatchedRoots = setmetatable({}, {__mode = "k"}),
    -- Auto Place's own Tool equip/unequip moves a Tool between Backpack and
    -- Character. Mute those self-generated events so they do not trigger a full scan.
    BagEventMuteUntil = 0,
    ActiveEggTool = nil,
    RanchSnapshot = nil,
    RanchSnapshotAt = 0,
    RanchSnapshotDirty = true,
    RanchSnapshotDirtyReason = "startup",
    RanchWatchedPlot = nil,
    RanchWatchConnections = {},
    NextHatchFallbackScanAt = 0,
    WorkerThread = nil,
    WakeSerial = 0,
    NextPlaceAttemptAt = 0,
    NextHatchWakeAt = 0,
    LastPlaceFailureAt = 0,
    RanchBoundsCache = nil,
    DirectPlaceFastPath = false,
    RequestingAction = false,
    State = {
        AutoPlace = false,
        AutoPlaceThread = nil, -- legacy field; v3.20 uses one shared worker
        AutoHatch = false,
        AutoHatchThread = nil, -- legacy field; v3.20 uses one shared worker
        PriorityEnabled = true,
        -- v3.39: Auto Place and Auto Hatch use separate per-EGG filters.
        -- Keys are normalized egg names (e.g. "blackholeegg"). ALL OFF by default.
        PlaceEggFilters = {},
        PlaceMinWeightKg = 0,
        HatchEggFilters = {},
        -- Legacy rarity filters are retained only so older saved profiles can load
        -- without errors. They no longer decide Place/Hatch eligibility.
        RarityFilters = {
            Common = false,
            Uncommon = false,
            Rare = false,
            Epic = false,
            Legendary = false,
            Mythic = false,
            Divine = false,
            Ethereal = false,
            Unknown = false,
        },
    },
}

-- Misc Auto Feed Pet. Kept independent from Get Egg and Egg Automation.
-- It only feeds pets that are physically inside the LocalPlayer-owned Ranch.
Runtime.AutoFeed = {
    Enabled = false,
    Busy = false,
    Thread = nil,
    UI = {},
    -- Strict whole-number threshold. A pet is eligible only when PetAge > MinAge.
    -- Max Age pets are NEVER fed. Ride A Pet currently caps pet Age/Level at 100.
    -- 0 therefore feeds Age 1..99 pets; 99 intentionally has no eligible pets.
    MinAge = 0,
    MaxAge = 100,
    LastPrompt = nil,
    LastTarget = nil,
    LastPet = nil,
    LastPetName = nil,
    LastPetAge = nil,
    LastPetIncome = nil,
    LastPetSpeed = nil,
    LastPriorityIndex = nil,
    LastPriorityTotal = nil,
    LastFood = nil,
    LastFoodTool = nil,
    LastActionAt = 0,
    FastFeedCount = 0,
    FullScans = 0,
    NextFullScanAt = 0,
}

-- Hatch Luck announcement silencer. OFF by default.
-- This is intentionally separate from Auto Hatch Luck: ON only means that the
-- specific client-side "Upgraded ... Luck ..." announcement text is suppressed.
Runtime.LuckAlertSilencer = {
    Enabled = false,
    UI = {},
    DescendantConnection = nil,
    WatchConnections = {},
}

local function trackRuntimeConnection(connection)
    if connection then
        table.insert(Runtime.Connections, connection)
    end
    return connection
end

local function disconnectRuntimeConnections()
    for _, connection in ipairs(Runtime.Connections) do
        pcall(function()
            connection:Disconnect()
        end)
    end
    table.clear(Runtime.Connections)
end

Runtime.DebugTeleport = function(channel, message, data)
    if not Runtime.TeleportDebug or not Runtime.TeleportDebug.Enabled then
        return
    end

    -- v3.28.2: keep the debugger executor-safe. Some environments expose a
    -- reduced global set, so no diagnostic value is allowed to crash the script.
    local now = 0
    if os and type(os.clock) == "function" then
        local okClock, clockValue = pcall(os.clock)
        if okClock and type(clockValue) == "number" then
            now = clockValue
        end
    end

    local prefix = string.format(
        "[TP DEBUG][%s][%0.3f]",
        tostring(channel or "GENERAL"),
        now
    )

    local line = prefix .. " " .. tostring(message or "")

    if type(data) == "table" then
        local fields = {}
        for key, value in pairs(data) do
            local rendered = tostring(value)
            local valueKind = type(value)

            -- typeof() is Roblox-specific but may be hidden by some executors.
            -- Probe it safely instead of calling it unconditionally.
            if type(typeof) == "function" then
                local okType, robloxType = pcall(typeof, value)
                if okType then
                    valueKind = robloxType
                end
            end

            if valueKind == "Vector3" then
                local okRender, result = pcall(function()
                    return string.format("(%.2f, %.2f, %.2f)", value.X, value.Y, value.Z)
                end)
                if okRender then rendered = result end
            elseif valueKind == "CFrame" then
                local okRender, result = pcall(function()
                    local p = value.Position
                    return string.format("CFrame(%.2f, %.2f, %.2f)", p.X, p.Y, p.Z)
                end)
                if okRender then rendered = result end
            end

            table.insert(fields, tostring(key) .. "=" .. rendered)
        end
        table.sort(fields)
        if #fields > 0 then
            line = line .. " | " .. table.concat(fields, " | ")
        end
    end

    print(line)
end

-- Minimal fallback cleanup. It is replaced with the full cleanup after all
-- systems are defined. Keeping this here makes partial/failed executions safer.
Runtime.Cleanup = function()
    if Runtime.Cleaned then
        return
    end

    Runtime.Cleaned = true
    Runtime.Alive = false
    disconnectRuntimeConnections()

    if Runtime.ScreenGui and Runtime.ScreenGui.Parent then
        pcall(function()
            Runtime.ScreenGui:Destroy()
        end)
    end
end

--==================================================

-- CONFIGURACIÓN FÁCIL

--==================================================

local Config = {

    -- ESP

    ESPFillTransparency = 0.50,

    ESPOutlineTransparency = 0,

    ESPNameSize = 13,

    ESPDistanceSize = 11,

    -- Colores

    GlobalESPColor = Color3.fromRGB(255, 255, 0),

    CustomESPColor = Color3.fromRGB(0, 255, 0),

    BlackholeESPColor = Color3.fromRGB(48, 0, 72),

    -- TP

    TPHeight = 3,

    MovementSpeed = 500,

    -- AutoFarm void return

    AutoFarmVoidY = -550,

    -- VOID mode safety: stay above Roblox FallenPartsDestroyHeight so the old
    -- character is not destroyed while we are already trying to TP Home.
    -- Set AutoFarmCrossDestroyHeight=true only if you intentionally want a real
    -- character-killing void reset instead of the fast/safe Void Home flow.
    AutoFarmCrossDestroyHeight = false,
    AutoFarmVoidSafetyMargin = 35,

    -- Smooth AutoFarm return-to-Ranch settings.
    -- VoidSpeed is separate from normal egg movement so the descent stays controlled.
    AutoFarmVoidSpeed = 220,

    -- Smoothly reach the REAL Roblox void in about this many seconds.
    -- The script automatically raises the descent speed on very high-altitude maps.
    AutoFarmVoidTravelTime = 4.0,

    AutoFarmVoidTimeout = 5,


    AutoFarmVoidMinDrop = 120,

    AutoFarmPlotPadding = 12,

    MovementArrivalDistance = 2.5,

    MovementVelocityClamp = true,

    AutoHatchLuckDelay = 2.5,

    -- Egg Automation (v3.20 optimized)
    -- One shared worker is used for Auto Place + Auto Hatch. Expensive bag/Ranch
    -- scans are cached and only refreshed when needed/available.
    -- v3.63 LOW-FREEZE: the shared worker backs off harder while idle. Ranch
    -- descendant scans are event-invalidated and use a long safety refresh instead
    -- of rebuilding every second. Direct Plot.Eggs checks remain fast/responsive.
    EggAutomationPoll = 1.10,
    EggHatchPoll = 1.10,
    EggRanchScanInterval = 45.00,
    EggRanchSafetyRescanInterval = 45.00,
    EggBagScanInterval = 60.00, -- safety only; structural watchers invalidate immediately
    EggUnavailablePoll = 2.00,
    EggNoRarityPoll = 2.25,
    EggActionCooldown = 0.35,
    EggHatchPromptFallbackInterval = 8.00,
    EggToolSearchPoll = 0.12,
    EggActionTimeout = 1.35,
    EggHomeRadius = 125,
    EggPromptExtraHold = 0.08,
    -- Auto Place selection -> prompt handoff. Some servers expose/enable the
    -- Place Egg prompt only after the selected basket slot becomes active.
    EggSelectionSettle = 0.10,
    EggPlacePromptWait = 0.48,
    EggPlacePromptPoll = 0.14,
    -- Only the single highest-priority egg is attempted per worker cycle.
    -- This prevents repeated slot clicks/equips from freezing the client.
    EggPlaceCandidateAttempts = 1,
    EggPlaceFailureCooldown = 1.35,
    EggDirectPlaceVerifyWait = 0.24,
    -- Egg Place/Hatch are background helpers only. They yield immediately to
    -- Get Egg / Auto Best / Hatch Luck and run only while those systems have no
    -- active target/action. This also keeps their checks off the hot path.
    EggPrimaryAutomationYieldPoll = 1.10,
    -- After a basket-slot click, current Ride A Pet builds can create an Egg Tool
    -- that must be equipped before a nest becomes placeable. Keep this handoff
    -- short and event-like so Auto Place does not add a heavy polling loop.
    EggToolAppearWait = 0.75,
    EggToolEquipSettle = 0.10,
    -- Strict placement: same egg type stays on the same horizontal ranch level.
    -- If its remembered slot is occupied, use the nearest VALID empty slot beside it.
    -- Never fall back to a slot above/below the remembered cluster.
    EggPlacementVerticalTolerance = 1.5,
    EggPlacementMaxHorizontalDistance = 65,

    -- Auto Feed Pet (Misc). Uses food already owned by the player; no auto-buy.
    -- FAST FEED: the focused-pet hot path runs at 0.08s (~12.5 checks/actions/s).
    -- Heavy Ranch/pet scans are NOT run at this frequency; they are cached.
    AutoFeedFastInterval = 0.08,
    AutoFeedPoll = 0.60,
    AutoFeedActionCooldown = 0.08,
    AutoFeedFullRescanInterval = 0.75,
    AutoFeedPromptExtraHold = 0.02,
    AutoFeedRanchPaddingXZ = 16,
    AutoFeedRanchPaddingY = 55,
    -- Max pet Age/Level. A pet at or above this value is ignored permanently
    -- by the current scan and Auto Feed immediately focuses the next-best pet.
    AutoFeedMaxAge = 100,

    -- FPS-friendly ESP defaults. Screen-space labels do not need render-frame
    -- frequency; 20 Hz stays visually responsive while cutting projection work.
    ESPRenderHz = 20,
    ESPMetadataRefresh = 1.00,
    LiveEggIndexRefresh = 15.00, -- topology safety refresh; ChildAdded/Removed invalidates immediately

    -- Reset / list performance

    ListRefreshDebounce = 0.30,

    ListBuildBatch = 8,

    -- Auto Egg

    BestEggName = "cherub",

    AutoEggHoldTime = 3,

    AutoFarmHoldTime = 2,

    AutoEggDelay = 0.8,

    -- UI

    PCWidth = 720,

    PCHeight = 560,

    MobileWidth = 320,

    MobileHeight = 500,

    AnimationTime = 0.18,

}

--==================================================

-- CARPETAS / OBJETOS PRINCIPALES

--==================================================

local TargetParent = LocalPlayer:FindFirstChildOfClass("PlayerGui")
    or LocalPlayer:WaitForChild("PlayerGui", 60)

if not TargetParent then
    RuntimeEnv.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
        "startup: PlayerGui unavailable after 60 seconds"
    error("ZOLO startup failed: PlayerGui unavailable after strict rejoin wait")
end

-- A stale GUI can survive some executor/teleport edge cases even when its old
-- Runtime table is gone. Remove it before the new build creates anything.
pcall(function()
    local stale = TargetParent:FindFirstChild("RenderedEggsESP_Menu")
    if stale then
        stale:Destroy()
    end
end)

local RenderedEggsFolder = Workspace:WaitForChild("RenderedEggs", 45)

-- A second execution may have started while the first one was yielding above.
-- The older copy must stop before it can build another ScreenGui.
if Runtime.IsSuperseded() then
    return
end

if not RenderedEggsFolder then
    -- UI can still open even if the folder is not ready yet.
end

--==================================================

-- ESTADOS

--==================================================

local mainESPActive = false

local autoBestEggActive = false

local autoBestEggThread = nil

local autoFarmActive = false

local autoFarmThread = nil

local autoFarmEggs = {}

local autoFarmProcessed = {}

local autoFarmCurrentName = nil

local StopAutoFarmBtn

local StatusLabel

local LuckStatusLabel

local currentSearchQuery = ""

local sortMode = "Name"

local tpKeybind = Enum.KeyCode.T

local listeningForKey = false

local isMobileMode = false

local isMinimized = false

local movementMode = "AutoFarm"

local movementActive = false

local movementHumanoid = nil

local movementPartsState = nil

local movementNoclipConnections = {}

local movementSerial = 0

local movementOldAutoRotate = nil

local autoHatchLuckActive = false

local autoHatchLuckThread = nil

local AutoHatchLuckBtn

-- Egg Automation state is consolidated under Runtime to avoid Luau's
-- 200-local-register limit in this large single-file script.
local EggAutoState = Runtime.EggAutomation.State

local eggImageCache = {}

local listBuildGeneration = 0

local listRefreshGeneration = 0

local espRefreshGeneration = 0

local pendingEggESPUpdates = {}

local eggESPWorkerRunning = false

local populateList

local ModeAutoFarmBtn

local ModeTeleportBtn

-- Guarda la información de cada Egg.

-- [Egg] = {

--     Highlight = Highlight,

--     NameBillboard = BillboardGui,

--     CustomActive = true/false,

--     CustomColor = Color3

-- }

local eggData = {}

--==================================================

-- FUNCIONES PEQUEÑAS Y FÁCILES

--==================================================

local function getCharacter()

    return LocalPlayer.Character

end

local function getRootPart()

    local character = getCharacter()

    if not character then

        return nil

    end

    return character:FindFirstChild("HumanoidRootPart")

end

--==================================================
-- CROSS-PLATFORM INPUT (PC + MOBILE)
--==================================================
-- v3.47 REGISTER FIX:
-- Keep these helpers on Runtime.InputCompat instead of allocating more top-level
-- locals. Large Luau chunks have a hard 200-local-register limit; v3.47 crossed
-- that limit before ensureSharedEggWorker could be allocated on some executors.
-- This preserves the same PC/mobile behavior without consuming those registers.
Runtime.InputCompat = Runtime.InputCompat or {
    TouchSerial = 42000,
}

Runtime.InputCompat.IsTouchPreferred = function()
    local preferred = nil
    pcall(function()
        preferred = UserInputService.PreferredInput
    end)

    if preferred == Enum.PreferredInput.Touch then
        return true
    end

    return UserInputService.TouchEnabled == true
        and UserInputService.KeyboardEnabled ~= true
end

Runtime.InputCompat.SendAdaptiveScreenPress = function(x, y, holdSeconds)
    x = math.max(1, math.floor(tonumber(x) or 1))
    y = math.max(1, math.floor(tonumber(y) or 1))
    holdSeconds = math.max(0.025, tonumber(holdSeconds) or 0.045)

    if Runtime.InputCompat.IsTouchPreferred() then
        Runtime.InputCompat.TouchSerial = (Runtime.InputCompat.TouchSerial or 42000) + 1
        local touchId = Runtime.InputCompat.TouchSerial
        local ok, err = pcall(function()
            VirtualInputManager:SendTouchEvent(
                touchId,
                Enum.UserInputState.Begin.Value,
                x,
                y
            )
            task.wait(holdSeconds)
            VirtualInputManager:SendTouchEvent(
                touchId,
                Enum.UserInputState.End.Value,
                x,
                y
            )
        end)
        return ok, ok and "touch" or ("touch failed: " .. tostring(err))
    end

    local ok, err = pcall(function()
        VirtualInputManager:SendMouseMoveEvent(x, y, game)
        RunService.Heartbeat:Wait()
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, true, game, 0)
        task.wait(holdSeconds)
        VirtualInputManager:SendMouseButtonEvent(x, y, 0, false, game, 0)
    end)
    return ok, ok and "mouse" or ("mouse failed: " .. tostring(err))
end

Runtime.InputCompat.GetPromptWorldPosition = function(prompt)
    local current = prompt and prompt.Parent
    while current do
        if current:IsA("Attachment") then
            return current.WorldPosition
        elseif current:IsA("BasePart") then
            return current.Position
        elseif current:IsA("Model") then
            local ok, pivot = pcall(function() return current:GetPivot() end)
            if ok and pivot then return pivot.Position end
        end
        current = current.Parent
    end
    return nil
end

Runtime.InputCompat.SendTouchToPromptFallback = function(prompt, holdSeconds)
    if not Runtime.InputCompat.IsTouchPreferred() then
        return false, "touch input not preferred"
    end

    local camera = Workspace.CurrentCamera
    local worldPosition = Runtime.InputCompat.GetPromptWorldPosition(prompt)
    if not camera or not worldPosition then
        return false, "prompt screen position unavailable"
    end

    local viewportPoint, onScreen = camera:WorldToViewportPoint(worldPosition)
    if not onScreen then
        return false, "prompt is off-screen"
    end

    return Runtime.InputCompat.SendAdaptiveScreenPress(viewportPoint.X, viewportPoint.Y, holdSeconds)
end

Runtime.InputCompat.InteractProximityPromptPortable = function(prompt, extraHold)
    if not prompt or not prompt.Parent or not prompt:IsA("ProximityPrompt") or not prompt.Enabled then
        return false, "prompt unavailable"
    end

    local hold = math.max(0.05, tonumber(prompt.HoldDuration) or 0)
        + math.max(0, tonumber(extraHold) or 0)

    local firePrompt = fireproximityprompt
    if type(firePrompt) == "function" then
        local ok = pcall(function() firePrompt(prompt, hold) end)
        if not ok then
            ok = pcall(function() firePrompt(prompt) end)
        end
        if ok then
            return true, "fireproximityprompt"
        end
    end

    local began = pcall(function() prompt:InputHoldBegin() end)
    if began then
        task.wait(hold)
        local ended = pcall(function()
            if prompt and prompt.Parent then
                prompt:InputHoldEnd()
            end
        end)
        if ended then
            return true, "InputHoldBegin/InputHoldEnd"
        end
    end

    if Runtime.InputCompat.IsTouchPreferred() then
        local okTouch, whyTouch = Runtime.InputCompat.SendTouchToPromptFallback(prompt, hold)
        if okTouch then
            return true, "touch prompt fallback"
        end
        return false, whyTouch
    end

    local keyCode = prompt.KeyboardKeyCode
    if keyCode == Enum.KeyCode.Unknown then
        keyCode = Enum.KeyCode.E
    end
    local okKey, errKey = pcall(function()
        VirtualInputManager:SendKeyEvent(true, keyCode, false, game)
        task.wait(hold)
        VirtualInputManager:SendKeyEvent(false, keyCode, false, game)
    end)
    return okKey, okKey and "keyboard fallback" or ("keyboard failed: " .. tostring(errKey))
end

--==================================================

-- IMAGEN DEL EGG

--==================================================

local function getEggImage(eggName)

    if eggImageCache[eggName] ~= nil then
        return eggImageCache[eggName]
    end

    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")

    if not playerGui then
        return ""
    end

    local main = playerGui:FindFirstChild("Main")
    local index = main and main:FindFirstChild("Index")
    local holders = index and index:FindFirstChild("Holders")
    local eggsHolder = holders and holders:FindFirstChild("EggsHolder")

    if not eggsHolder then
        return ""
    end

    local eggFrame = eggsHolder:FindFirstChild(eggName)

    if not eggFrame then
        return ""
    end

    local imageLabel = eggFrame:FindFirstChild("ImageLabel")

    if imageLabel and imageLabel:IsA("ImageLabel") then
        local image = imageLabel.Image or ""
        eggImageCache[eggName] = image
        return image
    end

    return ""

end

local function getTargetCFrame(target)

    if not target or not target.Parent then

        return nil

    end

    if target:IsA("Model") then

        return target:GetPivot()

    end

    if target:IsA("BasePart") then

        return target.CFrame

    end

    return nil

end

local function getTargetPosition(target)

    local targetCFrame = getTargetCFrame(target)

    if not targetCFrame then

        return nil

    end

    return targetCFrame.Position

end

local function getDistanceToTarget(target)

    local root = getRootPart()

    local targetPosition = getTargetPosition(target)

    if not root or not targetPosition then

        return math.huge

    end

    return (root.Position - targetPosition).Magnitude

end

local function tween(object, properties, duration)

    if not object or not object.Parent then

        return

    end

    local info = TweenInfo.new(

        duration or Config.AnimationTime,

        Enum.EasingStyle.Quart,

        Enum.EasingDirection.Out

    )

    TweenService:Create(object, info, properties):Play()

end

--==================================================

-- ESP: CREAR NOMBRE + DISTANCIA

--==================================================

local function createEggLabel(egg)

    local data = eggData[egg]
    if not data then return end

    if data.NameBillboard and data.NameBillboard.Parent then return end

    -- Screen-space text only. No dark panel/background: this keeps the ESP
    -- readable without covering the world behind the egg.
    local targetPart = egg:IsA("BasePart") and egg
        or egg.PrimaryPart
        or egg:FindFirstChildWhichIsA("BasePart", true)

    if not targetPart then
        Runtime.ESPNoAdornee = (Runtime.ESPNoAdornee or 0) + 1
        return
    end

    if not Runtime.ScreenGui or not Runtime.ScreenGui.Parent then return end

    if not Runtime.ESPOverlay or not Runtime.ESPOverlay.Parent then
        local overlay = Instance.new("Frame")
        overlay.Name = "ZoloEggESP_ScreenOverlay"
        overlay.Size = UDim2.new(1, 0, 1, 0)
        overlay.Position = UDim2.new(0, 0, 0, 0)
        overlay.BackgroundTransparency = 1
        overlay.BorderSizePixel = 0
        overlay.Active = false
        overlay.ZIndex = 850
        overlay.Parent = Runtime.ScreenGui
        Runtime.ESPOverlay = overlay
    end

    local holder = Instance.new("Frame")
    holder.Name = "EggESP_Info"
    holder.Size = UDim2.fromOffset(220, 58)
    holder.AnchorPoint = Vector2.new(0.5, 1)
    holder.BackgroundTransparency = 1
    holder.BorderSizePixel = 0
    holder.Visible = false
    holder.ZIndex = 900
    holder.Parent = Runtime.ESPOverlay

    local function makeInfoLabel(name, y, height, textSize, font)
        local label = Instance.new("TextLabel")
        label.Name = name
        label.Size = UDim2.new(1, 0, 0, height)
        label.Position = UDim2.new(0, 0, 0, y)
        label.BackgroundTransparency = 1
        label.TextColor3 = Color3.fromRGB(255, 255, 255)
        -- A thin text outline keeps labels legible without a black rectangle.
        label.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        label.TextStrokeTransparency = 0.18
        label.TextSize = textSize
        label.Font = font
        label.TextXAlignment = Enum.TextXAlignment.Center
        label.TextTruncate = Enum.TextTruncate.AtEnd
        label.ZIndex = 901
        label.Parent = holder
        return label
    end

    local nameLabel = makeInfoLabel("EggName", 0, 21, Config.ESPNameSize, Enum.Font.SourceSansBold)
    local weightLabel = makeInfoLabel("EggWeight", 20, 18, Config.ESPDistanceSize, Enum.Font.SourceSans)
    local mutationLabel = makeInfoLabel("EggMutation", 38, 18, Config.ESPDistanceSize, Enum.Font.SourceSans)

    nameLabel.Text = (Runtime.EggIdentity and select(2, Runtime.EggIdentity.Resolve(egg))) or egg.Name
    weightLabel.Text = "Weight: ? kg"
    mutationLabel.Text = "Mutation: Unknown"

    data.NameBillboard = holder
    data.ESPPart = targetPart
    data.ESPNameLabel = nameLabel
    data.ESPWeightLabel = weightLabel
    data.ESPMutationLabel = mutationLabel
end

local function updateEggLabel(egg)

    local data = eggData[egg]
    if not data or not data.NameBillboard or not data.NameBillboard.Parent then return end

    local nameLabel = data.ESPNameLabel
    local weightLabel = data.ESPWeightLabel
    local mutationLabel = data.ESPMutationLabel
    local activeTextColor = data.CustomColor or Color3.fromRGB(255, 255, 255)

    -- Metadata is cached and sourced from ReplicatedStorage.ServerData.ActiveEggs.
    -- Keep this outside the render-step callback; only text refreshes use it.
    local metadata = Runtime.ESPFilter and Runtime.ESPFilter.Metadata
        and Runtime.ESPFilter.Metadata(egg) or nil
    local liveInfo = metadata and metadata.LiveInfo or nil

    if nameLabel and nameLabel.Parent then
        nameLabel.Text = (liveInfo and liveInfo.Egg)
            or ((Runtime.EggIdentity and select(2, Runtime.EggIdentity.Resolve(egg))) or egg.Name)
        nameLabel.TextColor3 = activeTextColor
    end

    if weightLabel and weightLabel.Parent then
        local weight = metadata and metadata.Weight
        if type(weight) == "number" then
            local formatted = string.format("%.2f", weight):gsub("0+$", ""):gsub("%.$", "")
            weightLabel.Text = "Weight: " .. formatted .. " kg"
        else
            weightLabel.Text = "Weight: ? kg"
        end
        weightLabel.TextColor3 = activeTextColor
    end

    if mutationLabel and mutationLabel.Parent then
        local mutationNames = {}
        if metadata and type(metadata.Mutations) == "table" then
            for key, value in pairs(metadata.Mutations) do
                if key ~= "unknown" and key ~= "none" then
                    table.insert(mutationNames, tostring(value))
                elseif key == "none" and #mutationNames == 0 then
                    table.insert(mutationNames, "None")
                end
            end
        end
        table.sort(mutationNames)
        local liveMutation = liveInfo and Runtime.LiveEggData.MutationLabel(liveInfo) or nil
        mutationLabel.Text = "Mutation: " .. (liveMutation or (#mutationNames > 0 and table.concat(mutationNames, ", ") or "Unknown"))
        mutationLabel.TextColor3 = activeTextColor
    end
end

--==================================================

-- ESP: COLOR RULES

-- Every egg name receives its own deterministic color.
-- Blackhole Egg is always forced to the requested black-violet.

-- Register-safe: store this helper on Runtime instead of consuming another top-level local.
Runtime.GetResolvedEggESPName = function(eggOrName)
    if typeof(eggOrName) == "Instance" then
        if Runtime.EggIdentity and Runtime.EggIdentity.Resolve then
            local _, resolvedName = Runtime.EggIdentity.Resolve(eggOrName)
            if type(resolvedName) == "string" and resolvedName ~= "" then
                return resolvedName
            end
        end
        return eggOrName.Name
    end
    return tostring(eggOrName or "Egg")
end

local function isBlackholeEgg(eggOrName)
    local lower = Runtime.GetResolvedEggESPName(eggOrName):lower()

    return string.find(lower, "blackhole", 1, true) ~= nil
        or string.find(lower, "black hole", 1, true) ~= nil
end

local function getPerEggESPColor(eggOrName)
    if isBlackholeEgg(eggOrName) then
        return Config.BlackholeESPColor
    end

    local name = Runtime.GetResolvedEggESPName(eggOrName)
    local hash = 17

    for i = 1, #name do
        hash = (hash * 131 + string.byte(name, i)) % 104729
    end

    -- Golden-ratio spacing makes nearby hash values visually distinct while
    -- remaining deterministic across refreshes/re-executions.
    local hue = ((hash * 0.618033988749895) % 1)
    local saturation = 0.78 + ((hash % 13) / 100)
    local value = 1

    return Color3.fromHSV(hue, math.min(saturation, 0.92), value)
end

local function getSelectedESPColorForEgg(egg)
    return getPerEggESPColor(egg)
end

local function getSelectedESPColorDisplayName(egg)
    if isBlackholeEgg(egg) then
        return "Black Violet"
    end

    return "Auto / Per Egg"
end

--==================================================

-- ESP: UPDATE ONE EGG

--==================================================

local function updateEggESP(egg)

    if not egg then return end
    if not egg:IsA("Model") and not egg:IsA("BasePart") then return end

    if not eggData[egg] then
        eggData[egg] = {
            Highlight = nil,
            NameBillboard = nil,
            ESPPart = nil,
            ESPNameLabel = nil,
            ESPWeightLabel = nil,
            ESPMutationLabel = nil,
            ESPShouldShow = false,
            CustomColor = getSelectedESPColorForEgg(egg),
            CustomActive = false
        }
    end

    local data = eggData[egg]
    local shouldShow = false
    local color = Config.GlobalESPColor

    if data.CustomActive then
        shouldShow = true
        color = isBlackholeEgg(egg)
            and Config.BlackholeESPColor
            or (data.CustomColor or getSelectedESPColorForEgg(egg))
    elseif mainESPActive then
        shouldShow = true
        color = getSelectedESPColorForEgg(egg)
    end

    if shouldShow and Runtime.ESPFilter and Runtime.ESPFilter.Allows then
        shouldShow = Runtime.ESPFilter.Allows(egg)
    end

    -- Screen-space labels don't need Roblox Highlight/BillboardGui instances.
    -- Remove leftovers from older builds so nothing flashes or fights the new renderer.
    if data.Highlight then
        pcall(function() data.Highlight:Destroy() end)
        data.Highlight = nil
    end

    if data.NameBillboard and not data.NameBillboard.Parent then
        data.NameBillboard = nil
    end

    -- Repair the world anchor if the experience swaps the rendered part.
    if not data.ESPPart
        or not data.ESPPart.Parent
        or not data.ESPPart:IsA("BasePart")
        or not data.ESPPart:IsDescendantOf(Workspace) then
        data.ESPPart = egg:IsA("BasePart") and egg
            or egg.PrimaryPart
            or egg:FindFirstChildWhichIsA("BasePart", true)
        Runtime.ESPBillboardRepairs = (Runtime.ESPBillboardRepairs or 0) + 1
    end

    data.CustomColor = color

    -- Keep a tiny active-label count so the render callback can fully idle when
    -- ESP is off instead of walking every cached egg 20 times per second.
    local wasShowing = data.ESPShouldShow == true
    data.ESPShouldShow = shouldShow == true
    if wasShowing ~= data.ESPShouldShow then
        Runtime.ESPRequestedCount = math.max(
            0,
            (Runtime.ESPRequestedCount or 0) + (data.ESPShouldShow and 1 or -1)
        )
    end

    if shouldShow then
        createEggLabel(egg)
        if data.NameBillboard then
            updateEggLabel(egg)
        end
    elseif data.NameBillboard then
        data.NameBillboard.Visible = false
    end
end

--==================================================

-- ESP: ACTUALIZAR TODOS

--==================================================

local function queueEggESPUpdate(egg)
    if not egg then
        return
    end

    pendingEggESPUpdates[egg] = true

    if eggESPWorkerRunning then
        return
    end

    eggESPWorkerRunning = true

    task.defer(function()
        local processedThisFrame = 0

        while Runtime.Alive and next(pendingEggESPUpdates) do
            local target = next(pendingEggESPUpdates)
            pendingEggESPUpdates[target] = nil

            if target and target.Parent == RenderedEggsFolder then
                local ok, err = pcall(updateEggESP, target)
                if not ok then
                    Runtime.ESPErrors = (Runtime.ESPErrors or 0) + 1
                    Runtime.LastESPError = tostring(err)
                    if Runtime.TeleportDebug.Enabled then Runtime.DebugTeleport("ESP", "Egg refresh failed", {egg=target.Name,error=tostring(err)}) end
                end
            end

            processedThisFrame = processedThisFrame + 1

            if processedThisFrame >= 4 then
                processedThisFrame = 0
                RunService.Heartbeat:Wait()
            end
        end

        eggESPWorkerRunning = false
    end)
end

local function updateAllESP()
    if not RenderedEggsFolder then return end

    -- Full refreshes are deliberately synchronous. The previous deferred worker
    -- could leave the UI reporting globalActive=true/allEggs=true while zero
    -- labels had actually been created yet. 70-100 rendered eggs is small enough
    -- for a direct pass, while ChildAdded still uses the lightweight queue.
    for _, egg in ipairs(RenderedEggsFolder:GetChildren()) do
        if egg:IsA("Model") or egg:IsA("BasePart") then
            local ok, err = pcall(updateEggESP, egg)
            if not ok then
                Runtime.ESPErrors = (Runtime.ESPErrors or 0) + 1
                Runtime.LastESPError = tostring(err)
                if Runtime.TeleportDebug.Enabled then
                    Runtime.DebugTeleport("ESP", "Direct refresh failed", {egg=egg.Name,error=tostring(err)})
                end
            end
        end
    end
end

local function applyGlobalESP(state)

    mainESPActive = state

    updateAllESP()

end

--==================================================

-- LIMPIAR EGG ELIMINADO

--==================================================

local function removeEggData(egg)

    local data = eggData[egg]

    if not data then

        return

    end

    if data.Highlight then

        data.Highlight:Destroy()

    end

    if data.NameBillboard then

        data.NameBillboard:Destroy()

    end

    if data.ESPShouldShow then
        Runtime.ESPRequestedCount = math.max(0, (Runtime.ESPRequestedCount or 0) - 1)
    end

    eggData[egg] = nil

end

--==================================================

-- TP A UN OBJETO

--==================================================

local function getHumanoid()
    local character = getCharacter()
    return character and character:FindFirstChildOfClass("Humanoid") or nil
end

local function makeUprightCFrame(position, referenceCFrame)
    referenceCFrame = referenceCFrame or CFrame.new(position)

    local look = referenceCFrame.LookVector
    local flatLook = Vector3.new(look.X, 0, look.Z)

    if flatLook.Magnitude < 0.001 then
        flatLook = Vector3.new(0, 0, -1)
    else
        flatLook = flatLook.Unit
    end

    return CFrame.lookAt(
        position,
        position + flatLook,
        Vector3.new(0, 1, 0)
    )
end

local function getExternalSeatModel()
    local character = getCharacter()
    local humanoid = getHumanoid()
    local seatPart = humanoid and humanoid.SeatPart

    if not seatPart or not character or seatPart:IsDescendantOf(character) then
        return nil
    end

    return seatPart:FindFirstAncestorWhichIsA("Model")
end

local function zeroMovementVelocity()
    if not Config.MovementVelocityClamp then
        return
    end

    local root = getRootPart()
    if not root then
        return
    end

    local assemblies = {}

    local function zeroPart(part)
        if not part or not part:IsA("BasePart") then
            return
        end

        local assemblyRoot = part.AssemblyRootPart or part
        if assemblies[assemblyRoot] then
            return
        end

        assemblies[assemblyRoot] = true

        pcall(function()
            assemblyRoot.AssemblyLinearVelocity = Vector3.zero
            assemblyRoot.AssemblyAngularVelocity = Vector3.zero
        end)
    end

    zeroPart(root)

    local humanoid = getHumanoid()
    if humanoid and humanoid.SeatPart then
        zeroPart(humanoid.SeatPart)
    end
end

local function recoverHumanoidFromPhysics()
    local humanoid = getHumanoid()

    if not humanoid or humanoid.Health <= 0 then
        return
    end

    humanoid.PlatformStand = false

    local state = humanoid:GetState()

    if state == Enum.HumanoidStateType.FallingDown
        or state == Enum.HumanoidStateType.Ragdoll
        or state == Enum.HumanoidStateType.Physics then

        pcall(function()
            humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
        end)
    end
end

local function pivotControlledAssemblyTo(position, referenceCFrame, forceCharacterOnly)
    local character = getCharacter()
    local root = getRootPart()

    if not character or not root then
        return false
    end

    local desiredRootCFrame = makeUprightCFrame(
        position,
        referenceCFrame or root.CFrame
    )

    local delta = desiredRootCFrame * root.CFrame:Inverse()
    local moved = false
    local controlledModel = nil

    if not forceCharacterOnly then
        controlledModel = getExternalSeatModel()
    end

    if controlledModel and controlledModel.Parent then
        moved = pcall(function()
            controlledModel:PivotTo(delta * controlledModel:GetPivot())
        end)

        if not moved then
            controlledModel = nil
        end
    end

    if not controlledModel then
        moved = pcall(function()
            character:PivotTo(delta * character:GetPivot())
        end)
    end

    zeroMovementVelocity()
    return moved
end

local function clearNoclipConnections()
    for _, connection in ipairs(movementNoclipConnections) do
        pcall(function()
            connection:Disconnect()
        end)
    end

    table.clear(movementNoclipConnections)
end

local function setNoclip(enabled)
    local character = getCharacter()

    if not character then
        return
    end

    if enabled then
        if movementPartsState then
            return
        end

        movementPartsState = {}

        local roots = {character}
        local seatModel = getExternalSeatModel()

        if seatModel and seatModel ~= character then
            table.insert(roots, seatModel)
        end

        local function registerPart(part)
            if not part:IsA("BasePart") or movementPartsState[part] ~= nil then
                return
            end

            movementPartsState[part] = part.CanCollide
            part.CanCollide = false
        end

        for _, rootObject in ipairs(roots) do
            registerPart(rootObject)

            for _, part in ipairs(rootObject:GetDescendants()) do
                registerPart(part)
            end

            table.insert(
                movementNoclipConnections,
                rootObject.DescendantAdded:Connect(function(descendant)
                    if movementPartsState and descendant:IsA("BasePart") then
                        registerPart(descendant)
                    end
                end)
            )
        end
    else
        clearNoclipConnections()

        if movementPartsState then
            for part, oldCanCollide in pairs(movementPartsState) do
                if part and part.Parent then
                    pcall(function()
                        part.CanCollide = oldCanCollide
                    end)
                end
            end

            movementPartsState = nil
        end
    end
end

-- AUTO GET PICKUP NOCLIP LEASE
-- Only active from arrival at a selected Egg until its pickup signal is observed.
-- It includes the mounted/seat model because setNoclip() already tracks that model.
Runtime.AutoGet.SetPickupNoclip = function(enabled)
    Runtime.AutoGet.PickupNoclipActive = enabled == true

    if Runtime.AutoGet.PickupNoclipActive then
        setNoclip(true)
        zeroMovementVelocity()
    elseif not movementActive then
        setNoclip(false)
        zeroMovementVelocity()
    end
end

local function finishMovement(serial)
    if serial and serial ~= movementSerial then
        return
    end

    movementActive = false

    if movementHumanoid and movementHumanoid.Parent then
        if movementOldAutoRotate ~= nil then
            movementHumanoid.AutoRotate = movementOldAutoRotate
        end

        movementHumanoid.PlatformStand = false
    end

    movementHumanoid = nil
    movementOldAutoRotate = nil

    -- Auto Get can hold a short noclip lease while it waits for / holds the
    -- target Egg prompt. This prevents a mounted pet from colliding and bouncing
    -- the player away between movement completion and the actual pickup input.
    if Runtime.AutoGet and Runtime.AutoGet.PickupNoclipActive then
        setNoclip(true)
    else
        setNoclip(false)
    end
    zeroMovementVelocity()
    recoverHumanoidFromPhysics()
end

local function stopMovement()
    movementSerial = movementSerial + 1
    movementActive = false
    finishMovement()
end

local function teleportToModel(target)
    stopMovement()

    local root = getRootPart()
    local targetPosition = getTargetPosition(target)

    if not root or not targetPosition then
        return false
    end

    zeroMovementVelocity()

    local success = pivotControlledAssemblyTo(
        targetPosition + Vector3.new(0, Config.TPHeight, 0),
        root.CFrame,
        false
    )

    zeroMovementVelocity()
    recoverHumanoidFromPhysics()

    return success
end

local function moveToModel(target, forceSmooth)
    if not forceSmooth and movementMode == "Teleport" then
        return teleportToModel(target)
    end

    stopMovement()

    local root = getRootPart()
    local humanoid = getHumanoid()
    local targetPosition = getTargetPosition(target)

    if forceSmooth then
        Runtime.DebugTeleport("TWEEN", "moveToModel precheck", {
            target = target and target:GetFullName() or "nil",
            rootValid = root ~= nil,
            humanoidValid = humanoid ~= nil,
            targetValid = targetPosition ~= nil,
            start = root and root.Position or "nil",
            destination = targetPosition and (targetPosition + Vector3.new(0, Config.TPHeight, 0)) or "nil",
            noclipBefore = movementPartsState ~= nil,
        })
    end

    if not root or not humanoid or not targetPosition then
        if forceSmooth then
            Runtime.DebugTeleport("TWEEN", "moveToModel FAILED precheck")
        end
        return false
    end

    local destination = targetPosition + Vector3.new(0, Config.TPHeight, 0)
    local startDistance = (root.Position - destination).Magnitude

    if startDistance <= Config.MovementArrivalDistance then
        if forceSmooth then
            setNoclip(true)
        end

        local arrived = pivotControlledAssemblyTo(destination, root.CFrame, false)

        if forceSmooth then
            setNoclip(false)
            recoverHumanoidFromPhysics()
            local finalRoot = getRootPart()
            Runtime.DebugTeleport("TWEEN", "already-near target branch finished", {
                pivotResult = arrived,
                final = finalRoot and finalRoot.Position or "nil",
                finalDistance = finalRoot and (finalRoot.Position - destination).Magnitude or -1,
                noclipAfter = movementPartsState ~= nil,
            })
        end

        return arrived
    end

    movementSerial = movementSerial + 1
    local mySerial = movementSerial

    movementActive = true
    movementHumanoid = humanoid
    movementOldAutoRotate = humanoid.AutoRotate

    local success = false
    local startTime = os.clock()
    local maxTime = math.max(
        3,
        (startDistance / math.max(1, Config.MovementSpeed)) + 2
    )
    local debugEndReason = "movement timeout"
    local nextDebugSample = os.clock()

    setNoclip(true)

    humanoid.PlatformStand = false
    humanoid.AutoRotate = false

    zeroMovementVelocity()

    while movementActive
        and movementSerial == mySerial
        and os.clock() - startTime <= maxTime do

        if not target or not target.Parent then
            debugEndReason = "target removed while moving"
            break
        end

        root = getRootPart()

        if not root then
            debugEndReason = "HumanoidRootPart lost while moving"
            break
        end

        if humanoid.Health <= 0 then
            debugEndReason = "Humanoid died while moving"
            break
        end

        local offset = destination - root.Position
        local distance = offset.Magnitude

        if distance <= Config.MovementArrivalDistance then
            pivotControlledAssemblyTo(destination, root.CFrame, false)
            success = true
            debugEndReason = "arrival distance reached"
            break
        end

        if forceSmooth and Runtime.TeleportDebug.Enabled and os.clock() >= nextDebugSample then
            nextDebugSample = os.clock() + 0.40
            Runtime.DebugTeleport("TWEEN", "movement sample", {
                current = root.Position,
                destination = destination,
                distance = distance,
                noclip = movementPartsState ~= nil,
                elapsed = os.clock() - startTime,
            })
        end

        local dt = RunService.Heartbeat:Wait()
        local step = math.min(
            distance,
            math.max(1, Config.MovementSpeed) * math.min(dt, 0.05)
        )

        local nextPosition = root.Position + offset.Unit * step

        if not pivotControlledAssemblyTo(
            nextPosition,
            root.CFrame,
            false
        ) then
            debugEndReason = "PivotTo failed during smooth movement"
            break
        end
    end

    if not success
        and movementActive
        and movementSerial == mySerial
        and os.clock() - startTime >= maxTime then
        debugEndReason = "movement timeout"
    elseif not success and movementSerial ~= mySerial then
        debugEndReason = "movement serial changed/canceled"
    elseif not success and not movementActive then
        debugEndReason = "movementActive became false"
    end

    if movementSerial == mySerial then
        finishMovement(mySerial)
    end

    if forceSmooth then
        local finalRoot = getRootPart()
        Runtime.DebugTeleport("TWEEN", success and "moveToModel SUCCESS" or "moveToModel FAILED", {
            reason = debugEndReason,
            elapsed = os.clock() - startTime,
            final = finalRoot and finalRoot.Position or "nil",
            finalDistance = finalRoot and (finalRoot.Position - destination).Magnitude or -1,
            noclipAfter = movementPartsState ~= nil,
            movementActive = movementActive,
        })
    end

    return success
end

local function updateMovementModeButtons()

    if not ModeAutoFarmBtn or not ModeTeleportBtn then return end

    if movementMode == "AutoFarm" then

        ModeAutoFarmBtn.BackgroundColor3 = Color3.fromRGB(0, 150, 70)

        ModeAutoFarmBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

        ModeTeleportBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)

        ModeTeleportBtn.TextColor3 = Color3.fromRGB(220, 220, 220)

    else

        ModeAutoFarmBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)

        ModeAutoFarmBtn.TextColor3 = Color3.fromRGB(220, 220, 220)

        ModeTeleportBtn.BackgroundColor3 = Color3.fromRGB(0, 120, 170)

        ModeTeleportBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

    end

end

local function setMovementMode(mode)

    if mode ~= "AutoFarm" and mode ~= "Teleport" then return end

    stopMovement()

    movementMode = mode

    updateMovementModeButtons()

    if StatusLabel then

        StatusLabel.Text = mode == "AutoFarm" and "● AutoFarm mode: movement + noclip (500)" or "● Teleport mode: instant TP"

        StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)

    end

end

--==================================================

-- TP A TU PARCELA

--==================================================

local function teleportToHomePlot()

    local plotsFolder = Workspace:FindFirstChild("Plots")

    if not plotsFolder then

        return false

    end

    for _, plot in ipairs(plotsFolder:GetChildren()) do

        local dataFolder = plot:FindFirstChild("Data")

        if dataFolder then

            local ownerValue = dataFolder:FindFirstChild("Owner")

            if ownerValue then

                local isOwner = false

                if ownerValue:IsA("StringValue") then

                    isOwner = ownerValue.Value == LocalPlayer.Name

                elseif ownerValue:IsA("ObjectValue") then

                    isOwner = ownerValue.Value == LocalPlayer

                else

                    isOwner = tostring(ownerValue.Value) == LocalPlayer.Name

                end

                if isOwner then

                    return moveToModel(plot)

                end

            end

        end

    end

    return false

end

--==================================================

-- AUTOFARM RETURN: VOID -> SEPARATE HOME TELEPORT

-- This is intentionally used ONLY by selected-Egg AutoFarm.
-- The normal Home button, keybind, and Auto Best Egg keep their existing home behavior.
-- Flow: collect egg -> descend into void once -> release movement -> instant stabilized TP to owned Ranch.

local function teleportToHomePlotInstant()
    local plotsFolder = Workspace:FindFirstChild("Plots")
    if not plotsFolder then
        return false
    end

    for _, plot in ipairs(plotsFolder:GetChildren()) do
        local dataFolder = plot:FindFirstChild("Data")
        local ownerValue = dataFolder and dataFolder:FindFirstChild("Owner")

        if ownerValue then
            local isOwner = false

            if ownerValue:IsA("StringValue") then
                isOwner = ownerValue.Value == LocalPlayer.Name
            elseif ownerValue:IsA("ObjectValue") then
                isOwner = ownerValue.Value == LocalPlayer
            else
                isOwner = tostring(ownerValue.Value) == LocalPlayer.Name
            end

            if isOwner then
                -- Always use the stabilized instant teleport here, independent
                -- of the selected movement mode. This is intentionally separate
                -- from the normal Home button behavior.
                return teleportToModel(plot)
            end
        end
    end

    return false
end

local function returnAutoFarmViaVoid()
    -- Traverse the Void route; safe mode stops above Roblox destroy height.
    -- This game can place the map around Y=40,000+, so the old fixed 220 studs/sec
    -- descent could take minutes before the rest of Auto Get ever ran.
    stopMovement()

    local function detachFromSeat()
        local humanoid = getHumanoid()
        if not humanoid then
            return false
        end

        if humanoid.SeatPart then
            humanoid.Sit = false
            humanoid.Jump = true

            local detachStarted = os.clock()
            while Runtime.Alive
                and autoFarmActive
                and humanoid.Parent
                and humanoid.SeatPart
                and os.clock() - detachStarted < 0.55 do
                RunService.Heartbeat:Wait()
            end
        end

        return getRootPart() ~= nil
    end

    local character = getCharacter()
    local humanoid = getHumanoid()
    local root = getRootPart()

    if not character or not humanoid or not root then
        Runtime.DebugTeleport("VOID", "FAILED precheck", {
            character = character ~= nil,
            humanoid = humanoid ~= nil,
            root = root ~= nil,
        })
        return false
    end

    if not detachFromSeat() then
        Runtime.DebugTeleport("VOID", "FAILED: could not detach from seat/root unavailable")
        return false
    end

    root = getRootPart()
    humanoid = getHumanoid()

    if not root or not humanoid then
        Runtime.DebugTeleport("VOID", "FAILED after seat detach", {
            root = root ~= nil,
            humanoid = humanoid ~= nil,
        })
        return false
    end

    local startPosition = root.Position
    local startY = startPosition.Y

    local fallenDestroyY = -500
    pcall(function()
        fallenDestroyY = Workspace.FallenPartsDestroyHeight
    end)

    -- FAST/SAFE VOID MODE:
    -- By default we stop slightly ABOVE FallenPartsDestroyHeight. Crossing below
    -- that engine threshold schedules destruction of HumanoidRootPart/character,
    -- which races the Home TP and causes the exact death seen in the F8 log.
    local destroyY = tonumber(fallenDestroyY) or -500
    local configuredVoidY = tonumber(Config.AutoFarmVoidY) or -550
    local safetyMargin = math.max(15, tonumber(Config.AutoFarmVoidSafetyMargin) or 35)
    local crossDestroyHeight = Config.AutoFarmCrossDestroyHeight == true

    local effectiveVoidY
    local targetY

    if crossDestroyHeight then
        effectiveVoidY = math.min(configuredVoidY, destroyY - 25)
        targetY = effectiveVoidY - 35
    else
        effectiveVoidY = math.max(configuredVoidY, destroyY + safetyMargin)
        targetY = effectiveVoidY
    end
    local totalDrop = math.max(1, startY - targetY)
    local desiredTravelTime = math.max(1.5, tonumber(Config.AutoFarmVoidTravelTime) or 4.0)

    -- Cleaner two-stage Void travel for high-altitude maps: first reposition
    -- near the Void route, then smoothly descend to the selected safe/real target.
    -- This avoids streaming tens of thousands of studs of CFrame updates.
    local stagingY = effectiveVoidY + 1400
    local finalDrop = math.max(1, stagingY - targetY)
    local adaptiveSpeed = math.max(
        tonumber(Config.AutoFarmVoidSpeed) or 220,
        finalDrop / math.max(2.5, desiredTravelTime)
    )

    Runtime.DebugTeleport("VOID", "Void descent START", {
        configuredVoidY = Config.AutoFarmVoidY,
        fallenPartsDestroyHeight = fallenDestroyY,
        effectiveVoidY = effectiveVoidY,
        crossDestroyHeight = crossDestroyHeight,
        safetyMargin = safetyMargin,
        startY = startY,
        totalDrop = totalDrop,
        stagingY = stagingY,
        finalDrop = finalDrop,
        baseSpeed = Config.AutoFarmVoidSpeed,
        adaptiveSpeed = adaptiveSpeed,
        estimatedSeconds = finalDrop / adaptiveSpeed,
        noclipBefore = movementPartsState ~= nil,
    })

    movementSerial = movementSerial + 1
    local mySerial = movementSerial

    movementActive = true
    movementHumanoid = humanoid
    movementOldAutoRotate = humanoid.AutoRotate

    setNoclip(true)
    humanoid.PlatformStand = false
    humanoid.AutoRotate = false
    zeroMovementVelocity()

    -- Stage close to the Void target first; this removes the huge 40k+ stud
    -- high-speed network stream seen in the debugger.
    if root.Position.Y > stagingY + 250 then
        local stageCFrame = root.CFrame
        if not pivotControlledAssemblyTo(
            Vector3.new(root.Position.X, stagingY, root.Position.Z),
            stageCFrame,
            true
        ) then
            setNoclip(false)
            Runtime.DebugTeleport("VOID", "FAILED: staging PivotTo was rejected", {
                stagingY = stagingY,
                root = root.Position,
            })
            return false
        end
        zeroMovementVelocity()
        task.wait(0.40)
        root = getRootPart()
        if not root then
            setNoclip(false)
            Runtime.DebugTeleport("VOID", "FAILED: root missing after staging")
            return false
        end
        Runtime.DebugTeleport("VOID", "Void staging complete", {
            stagingY = stagingY,
            actualY = root.Position.Y,
        })
    end

    local referenceCFrame = root.CFrame
    local anchorX = root.Position.X
    local anchorZ = root.Position.Z
    local plannedY = root.Position.Y
    local reachedVoid = false
    local autoResetDetected = false
    local endReason = "loop ended"
    local nextDebugSample = os.clock()
    local descentStarted = os.clock()
    local lowestObservedY = startY

    Runtime.DebugTeleport("VOID", "Descent prepared", {
        start = root.Position,
        targetY = targetY,
        effectiveVoidY = effectiveVoidY,
        speed = adaptiveSpeed,
        noclip = movementPartsState ~= nil,
        seated = humanoid.SeatPart ~= nil,
    })

    if StatusLabel then
        StatusLabel.Text = crossDestroyHeight
            and "● Get Egg: traveling through real void..."
            or "● Get Egg: safe Void descent..."
        StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
    end

    local function findOwnedPlotPosition()
        local plotsFolder = Workspace:FindFirstChild("Plots")
        if not plotsFolder then
            return nil
        end

        for _, plot in ipairs(plotsFolder:GetChildren()) do
            local dataFolder = plot:FindFirstChild("Data")
            local ownerValue = dataFolder and dataFolder:FindFirstChild("Owner")
            if ownerValue then
                local isOwner = false
                if ownerValue:IsA("StringValue") then
                    isOwner = ownerValue.Value == LocalPlayer.Name
                elseif ownerValue:IsA("ObjectValue") then
                    isOwner = ownerValue.Value == LocalPlayer
                else
                    isOwner = tostring(ownerValue.Value) == LocalPlayer.Name
                end

                if isOwner then
                    local position = getTargetPosition(plot)
                    if position then
                        return position + Vector3.new(0, Config.TPHeight, 0)
                    end
                end
            end
        end

        return nil
    end

    local function isNearOwnedPlot(checkRoot)
        local destination = checkRoot and findOwnedPlotPosition() or nil
        if not destination then
            return false, nil
        end
        return (checkRoot.Position - destination).Magnitude <= 55, destination
    end

    -- Smooth, monotonic Heartbeat movement. The adaptive speed only compensates
    -- for the unusually high map altitude; we still physically traverse the void.
    while Runtime.Alive
        and autoFarmActive
        and movementActive
        and movementSerial == mySerial do

        root = getRootPart()
        if not root then
            -- The engine may destroy/recreate the character after crossing the real
            -- FallenPartsDestroyHeight. Wait briefly for the Ranch respawn.
            local dropped = startY - lowestObservedY
            if dropped >= (Config.AutoFarmVoidMinDrop or 120) then
                Runtime.DebugTeleport("VOID", "Root lost after descent; waiting for real void reset", {
                    dropped = dropped,
                    lowestY = lowestObservedY,
                })

                local resetWaitStart = os.clock()
                while Runtime.Alive and autoFarmActive and os.clock() - resetWaitStart < 2.5 do
                    RunService.Heartbeat:Wait()
                    local newRoot = getRootPart()
                    if newRoot then
                        local atHome = isNearOwnedPlot(newRoot)
                        if atHome then
                            autoResetDetected = true
                            reachedVoid = true
                            endReason = "game respawned player at Ranch after real void"
                        else
                            reachedVoid = newRoot.Position.Y <= effectiveVoidY + 50
                            endReason = reachedVoid
                                and "new root remained at/below real void"
                                or "root recreated away from Ranch"
                        end
                        break
                    end
                end
            else
                endReason = "root lost before meaningful void descent"
            end
            break
        end

        lowestObservedY = math.min(lowestObservedY, root.Position.Y)

        -- If the game's void logic already returned us Home, stop moving down
        -- immediately so we never drag the reset character back into the void.
        if startY - lowestObservedY >= (Config.AutoFarmVoidMinDrop or 120) then
            local atHome, homeDestination = isNearOwnedPlot(root)
            if atHome then
                autoResetDetected = true
                reachedVoid = true
                endReason = "game auto-returned player to owned Ranch"
                Runtime.DebugTeleport("VOID", "Game Home reset detected during descent", {
                    root = root.Position,
                    home = homeDestination or "nil",
                    lowestY = lowestObservedY,
                })
                break
            end
        end

        local dt = RunService.Heartbeat:Wait()
        local step = adaptiveSpeed * math.min(dt, 0.05)
        plannedY = math.max(targetY, plannedY - step)

        if not pivotControlledAssemblyTo(
            Vector3.new(anchorX, plannedY, anchorZ),
            referenceCFrame,
            true
        ) then
            endReason = "PivotTo failed during descent"
            break
        end

        zeroMovementVelocity()

        if Runtime.TeleportDebug.Enabled and os.clock() >= nextDebugSample then
            nextDebugSample = os.clock() + 0.40
            local sampleRoot = getRootPart()
            Runtime.DebugTeleport("VOID", "Descent sample", {
                plannedY = plannedY,
                actualY = sampleRoot and sampleRoot.Position.Y or "nil",
                lowestY = lowestObservedY,
                adaptiveSpeed = adaptiveSpeed,
                noclip = movementPartsState ~= nil,
            })
        end

        root = getRootPart()
        if root then
            lowestObservedY = math.min(lowestObservedY, root.Position.Y)
            if root.Position.Y <= effectiveVoidY then
                reachedVoid = true
                endReason = crossDestroyHeight
                    and "real void threshold reached"
                    or "safe void threshold reached"
                break
            end
        end

        if plannedY <= targetY then
            reachedVoid = root ~= nil and root.Position.Y <= effectiveVoidY + 50
            endReason = reachedVoid
                and (crossDestroyHeight and "real void target reached" or "safe void target reached")
                or "planned target reached but server kept player above real void"
            break
        end

        if os.clock() - descentStarted > math.max(Config.AutoFarmVoidTimeout or 6, desiredTravelTime + 2) then
            endReason = "adaptive void descent timeout"
            break
        end
    end

    -- Release noclip/movement as soon as the Void stage is done.
    if movementSerial == mySerial then
        finishMovement(mySerial)
    else
        setNoclip(false)
    end

    if StatusLabel and autoFarmActive then
        StatusLabel.Text = reachedVoid
            and (autoResetDetected
                and "● Get Egg: void reset detected — confirming bag/slot..."
                or (crossDestroyHeight
                    and "● Get Egg: real void reached — confirming bag/slot..."
                    or "● Get Egg: safe Void reached — confirming bag/slot..."))
            or "● Get Egg: void travel failed"
        StatusLabel.TextColor3 = reachedVoid
            and Color3.fromRGB(255, 210, 90)
            or Color3.fromRGB(255, 120, 120)
    end

    local finalRoot = getRootPart()
    Runtime.DebugTeleport("VOID", reachedVoid and "Void descent SUCCESS" or "Void descent FAILED", {
        reason = endReason,
        autoResetDetected = autoResetDetected,
        final = finalRoot and finalRoot.Position or "nil",
        lowestY = lowestObservedY,
        effectiveVoidY = effectiveVoidY,
        noclipAfter = movementPartsState ~= nil,
        movementActive = movementActive,
    })

    return reachedVoid
end

--==================================================

-- HATCH LUCK DISCOVERY

-- Ride A Pet exposes the Hatch Luck upgrade through the player's Ranch UI/board.
-- These helpers only inspect client-visible objects and interact with a matching
-- prompt if one exists. They do not fabricate or force a server-side luck value.

local function getOwnedPlotForLuck()

    local plotsFolder = Workspace:FindFirstChild("Plots")

    if not plotsFolder then

        return nil

    end

    for _, plot in ipairs(plotsFolder:GetChildren()) do

        local dataFolder = plot:FindFirstChild("Data")

        local ownerValue = dataFolder and dataFolder:FindFirstChild("Owner")

        if ownerValue then

            local isOwner = false

            if ownerValue:IsA("StringValue") then

                isOwner = ownerValue.Value == LocalPlayer.Name

            elseif ownerValue:IsA("ObjectValue") then

                isOwner = ownerValue.Value == LocalPlayer

            else

                isOwner = tostring(ownerValue.Value) == LocalPlayer.Name

            end

            if isOwner then

                return plot

            end

        end

    end

    return nil

end

-- STRICT OWNED-RANCH GUARD FOR EGG AUTOMATION.
-- Auto Place / Auto Hatch must never interact with another player's Plot, even if
-- that Plot exposes a closer prompt or has an identical model/name. Ownership is
-- revalidated immediately before movement and immediately before interaction.
local function isPlotOwnedByLocalPlayer(plot)
    if not plot or not plot.Parent then
        return false
    end

    local dataFolder = plot:FindFirstChild("Data")
    local ownerValue = dataFolder and dataFolder:FindFirstChild("Owner")
    if not ownerValue then
        return false
    end

    if ownerValue:IsA("StringValue") then
        return ownerValue.Value == LocalPlayer.Name
    elseif ownerValue:IsA("ObjectValue") then
        return ownerValue.Value == LocalPlayer
    end

    return tostring(ownerValue.Value) == LocalPlayer.Name
end

local function getStrictOwnedPlot()
    local plot = getOwnedPlotForLuck()
    if plot and isPlotOwnedByLocalPlayer(plot) then
        return plot
    end
    return nil
end

-- v3.67 RANCH-SMOOTH: Model:GetBoundingBox() can traverse a large Ranch model.
-- Cache the stable Plot bounds and invalidate them only when Ranch topology changes.
Runtime.EggAutomation.GetCachedPlotBounds = function(plot, maxAge)
    if not plot or not plot.Parent then return nil, nil end
    local now = os.clock()
    local cache = Runtime.EggAutomation.RanchBoundsCache
    local ttl = math.max(5, tonumber(maxAge) or 20)
    if cache and cache.Plot == plot and cache.CFrame and cache.Size
        and now - (cache.At or 0) < ttl then
        return cache.CFrame, cache.Size
    end

    local boxCFrame, boxSize
    local ok = pcall(function()
        if plot:IsA("Model") then
            boxCFrame, boxSize = plot:GetBoundingBox()
        elseif plot:IsA("BasePart") then
            boxCFrame, boxSize = plot.CFrame, plot.Size
        end
    end)
    if ok and boxCFrame and boxSize then
        Runtime.EggAutomation.RanchBoundsCache = {
            Plot = plot, CFrame = boxCFrame, Size = boxSize, At = now,
        }
        return boxCFrame, boxSize
    end
    return nil, nil
end

local function belongsToStrictOwnedPlot(object, expectedPlot)
    if not object or not object.Parent then
        return false, "object unavailable"
    end

    local ownedPlot = getStrictOwnedPlot()
    if not ownedPlot then
        return false, "owned Ranch not found"
    end

    if expectedPlot and expectedPlot ~= ownedPlot then
        return false, "target Plot is not the currently owned Ranch"
    end

    if object == ownedPlot or object:IsDescendantOf(ownedPlot) then
        return true, "owned Ranch verified"
    end

    return false, "target is outside owned Ranch"
end

local function isWorldPositionInsideOwnedPlot(plot, position, paddingXZ, paddingY)
    if not plot or not isPlotOwnedByLocalPlayer(plot) or typeof(position) ~= "Vector3" then
        return false
    end

    local available = false
    local inside = false
    local boxCFrame, boxSize = Runtime.EggAutomation.GetCachedPlotBounds(plot, 20)
    if boxCFrame and boxSize then
        available = true
        local localPos = boxCFrame:PointToObjectSpace(position)
        local pxz = tonumber(paddingXZ) or 10
        local py = tonumber(paddingY) or 35
        inside = math.abs(localPos.X) <= (boxSize.X * 0.5 + pxz)
            and math.abs(localPos.Y) <= (boxSize.Y * 0.5 + py)
            and math.abs(localPos.Z) <= (boxSize.Z * 0.5 + pxz)
    end

    if available then
        return inside
    end

    local center = getTargetPosition(plot)
    return center ~= nil and (position - center).Magnitude <= 90
end

--==================================================
-- MISC: AUTO FEED PET (STRICT OWNED RANCH ONLY)
--==================================================

-- Current public Ride A Pet references agree that food works on placed Ranch pets.
-- This implementation deliberately avoids guessing a private server remote. It
-- equips a real food Tool already owned by the player and uses the individual
-- Feed interaction on pets inside the verified LocalPlayer-owned Plot.
local AUTO_FEED_FOOD_ORDER = {
    {Key = "grass", Name = "Grass", XP = 500},
    {Key = "bone", Name = "Bone", XP = 10000},
    {Key = "meat", Name = "Meat", XP = 100000},
    {Key = "magicapple", Name = "Magic Apple", XP = 300000},
    {Key = "dragonfruit", Name = "Dragonfruit", XP = 1000000},
}

local function normalizeAutoFeedName(value)
    return tostring(value or ""):lower():gsub("[^%w]", "")
end

-- Public/current Ride A Pet base-stat fallback. Live pet values ALWAYS win when
-- the game exposes them on the placed pet. Income is the primary ranch "best"
-- metric because the game's Place Best behavior prioritizes high earners.
local AUTO_FEED_KNOWN_PETS = {
    snail      = {Income = 3,         Speed = 15},
    turtle     = {Income = 5,         Speed = 50},
    sloth      = {Income = 7,         Speed = 90},
    axolotl    = {Income = 9,         Speed = 165},
    koala      = {Income = 5,         Speed = 300},
    capybara   = {Income = 20,        Speed = 407},
    chicken    = {Income = 25,        Speed = 553},
    pig        = {Income = 30,        Speed = 750},
    elephant   = {Income = 35,        Speed = 1020},
    panda      = {Income = 50,        Speed = 1380},
    kangaroo   = {Income = 120,       Speed = 3050},
    deer       = {Income = 150,       Speed = 3250},
    spider     = {Income = 160,       Speed = 3690},
    crocodile  = {Income = 170,       Speed = 3940},
    gorilla    = {Income = 200,       Speed = 4480},
    snake      = {Income = 240,       Speed = 4780},
    horse      = {Income = 350,       Speed = 5340},
    wolf       = {Income = 375,       Speed = 5710},
    shark      = {Income = 400,       Speed = 6100},
    lion       = {Income = 510,       Speed = 6520},
    ostrich    = {Income = 750,       Speed = 6960},
    fox        = {Income = 1200,      Speed = 19500},
    giraffe    = {Income = 2200,      Speed = 27400},
    cheetah    = {Income = 3500,      Speed = 38400},
    unicorn    = {Income = 30000,     Speed = 137000},
    trex       = {Income = 50000,     Speed = 266000},
    phoenix    = {Income = 100000,    Speed = 1000000},
    cerberus   = {Income = 30000000,  Speed = 100000000},
    kitsune    = {Income = 90000000,  Speed = 1000000000},
    dragon     = {Income = 300000000, Speed = 300000000},
}

local AUTO_FEED_RARITY_RANK = {
    common = 10,
    uncommon = 20,
    rare = 30,
    epic = 40,
    legendary = 50,
    mythic = 60,
    mythical = 60,
    divine = 70,
    ethereal = 80,
    secret = 90,
}

local function clampWholeAutoFeedAge(value)
    local number = tonumber(value)
    if not number then
        number = 0
    end
    -- Strict integer only: nearest whole number, then hard clamp to 0..99.
    number = math.floor(number + 0.5)
    return math.clamp(number, 0, 99)
end

local function parseAutoFeedScaledNumber(value)
    if type(value) == "number" then
        return value
    end

    local textValue = tostring(value or ""):lower():gsub(",", "")
    local numberText, suffix = textValue:match("([%d%.]+)%s*([kmbt]?[a-z]?)")
    local number = tonumber(numberText)
    if not number then
        return nil
    end

    suffix = tostring(suffix or ""):lower()
    local multiplier = 1
    if suffix == "k" then multiplier = 1e3
    elseif suffix == "m" then multiplier = 1e6
    elseif suffix == "b" then multiplier = 1e9
    elseif suffix == "t" then multiplier = 1e12
    elseif suffix == "qa" then multiplier = 1e15
    elseif suffix == "qi" then multiplier = 1e18
    end
    return number * multiplier
end

local function autoFeedTextValues(object, maxDescendants)
    local values = {}
    local seen = {}
    local function add(value)
        value = tostring(value or "")
        if value ~= "" and not seen[value] then
            seen[value] = true
            table.insert(values, value)
        end
    end

    local function inspect(item)
        if not item then return end
        add(item.Name)
        if item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
            add(item.Text)
        elseif item:IsA("StringValue") then
            add(item.Value)
        elseif item:IsA("IntValue") or item:IsA("NumberValue") then
            add(item.Value)
        end
        for name, value in pairs(item:GetAttributes()) do
            add(name)
            add(value)
            add(tostring(name) .. "=" .. tostring(value))
        end
    end

    inspect(object)
    if object and maxDescendants and maxDescendants > 0 then
        local descendants = object:GetDescendants()
        for index, item in ipairs(descendants) do
            if index > maxDescendants then break end
            inspect(item)
        end
    end
    return values
end

local function getKnownAutoFeedPetStats(pet)
    local normalized = normalizeAutoFeedName(pet and pet.Name or "")
    local exact = AUTO_FEED_KNOWN_PETS[normalized]
    if exact then
        return exact
    end

    -- Mutation/prefix/suffix names can wrap the base species name.
    local bestKey = nil
    for key in pairs(AUTO_FEED_KNOWN_PETS) do
        if string.find(normalized, key, 1, true)
            and (not bestKey or #key > #bestKey) then
            bestKey = key
        end
    end
    return bestKey and AUTO_FEED_KNOWN_PETS[bestKey] or nil
end

local function autoFeedAgeFromText(value)
    local textValue = tostring(value or ""):lower():gsub(",", "")
    -- Frontier markers prevent "damage 10" from being misread as "age 10".
    local age = textValue:match("%f[%a]age%f[%A][^%d]*(%d+)")
    if not age then
        age = textValue:match("(%d+)%s*%f[%a]age%f[%A]")
    end
    return age and tonumber(age) or nil
end

local AUTO_FEED_AGE_KEYS = {
    age = true,
    petage = true,
    currentage = true,
    agelevel = true,
    petagelevel = true,
}

Runtime.AutoFeed.GetPetAge = function(pet)
    if not pet or not pet.Parent then
        return nil
    end

    local function inspect(item)
        for name, value in pairs(item:GetAttributes()) do
            local key = normalizeAutoFeedName(name)
            if AUTO_FEED_AGE_KEYS[key] then
                local age = tonumber(value)
                if age then return math.max(0, math.floor(age + 0.00001)) end
            end
        end

        local key = normalizeAutoFeedName(item.Name)
        if AUTO_FEED_AGE_KEYS[key] then
            if item:IsA("IntValue") or item:IsA("NumberValue") then
                return math.max(0, math.floor(tonumber(item.Value) or 0))
            elseif item:IsA("StringValue") then
                local age = tonumber(item.Value) or autoFeedAgeFromText(item.Value)
                if age then return math.max(0, math.floor(age)) end
            elseif item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
                local age = tonumber(item.Text) or autoFeedAgeFromText(item.Text)
                if age then return math.max(0, math.floor(age)) end
            end
        end

        if item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") or item:IsA("StringValue") then
            local raw = item:IsA("StringValue") and item.Value or item.Text
            local age = autoFeedAgeFromText(raw)
            if age then return math.max(0, math.floor(age)) end
        end
        return nil
    end

    local age = inspect(pet)
    if age ~= nil then return age end

    local descendants = pet:GetDescendants()
    for index, item in ipairs(descendants) do
        if index > 180 then break end
        age = inspect(item)
        if age ~= nil then return age end
    end
    return nil
end

local AUTO_FEED_INCOME_KEYS = {
    income = true, baseincome = true, currentincome = true,
    cashpersecond = true, cashsec = true, cashrate = true,
    cps = true, earning = true, earnings = true, moneypersecond = true,
}
local AUTO_FEED_SPEED_KEYS = {
    speed = true, basespeed = true, currentspeed = true,
    mph = true, spd = true, ridespeed = true,
}
local AUTO_FEED_RARITY_KEYS = {
    rarity = true, petrarity = true, tier = true, pettier = true,
}

local function getAutoFeedNumericStat(pet, keySet, words)
    if not pet or not pet.Parent then return nil end
    local best = nil

    local function considerNumber(value)
        local number = parseAutoFeedScaledNumber(value)
        if number and number >= 0 and (best == nil or number > best) then
            best = number
        end
    end

    local function inspect(item)
        for name, value in pairs(item:GetAttributes()) do
            local key = normalizeAutoFeedName(name)
            if keySet[key] then
                considerNumber(value)
            end
        end

        local itemKey = normalizeAutoFeedName(item.Name)
        if keySet[itemKey] then
            if item:IsA("IntValue") or item:IsA("NumberValue") or item:IsA("StringValue") then
                considerNumber(item.Value)
            elseif item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
                considerNumber(item.Text)
            end
        end

        if item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") or item:IsA("StringValue") then
            local raw = tostring(item:IsA("StringValue") and item.Value or item.Text or "")
            local lower = raw:lower()

            local function lastScaledNumber(prefix)
                local last = nil
                local cleaned = tostring(prefix or ""):lower():gsub(",", "")
                for numberText, suffix in cleaned:gmatch("([%d%.]+)%s*([kmbt]?)") do
                    local number = tonumber(numberText)
                    if number then
                        suffix = tostring(suffix or ""):lower()
                        local multiplier = suffix == "k" and 1e3
                            or suffix == "m" and 1e6
                            or suffix == "b" and 1e9
                            or suffix == "t" and 1e12
                            or 1
                        last = number * multiplier
                    end
                end
                return last
            end

            for _, word in ipairs(words) do
                local first, last = string.find(lower, word, 1, true)
                if first then
                    -- Prefer the number immediately AFTER the stat label ("Income 500").
                    local after = parseAutoFeedScaledNumber(raw:sub(last + 1))
                    -- For suffix labels ("500 MPH"), use the closest number before it.
                    local before = lastScaledNumber(raw:sub(1, first - 1))
                    local near = after or before
                    if near then
                        considerNumber(near)
                    elseif (string.find(lower, "/s", 1, true) and string.find(lower, "$", 1, true)) then
                        considerNumber(raw)
                    end
                    break
                end
            end
        end
    end

    inspect(pet)
    for index, item in ipairs(pet:GetDescendants()) do
        if index > 180 then break end
        inspect(item)
    end
    return best
end

local function getAutoFeedRarityRank(pet)
    if not pet or not pet.Parent then return 0 end
    local best = 0

    local function consider(value)
        local lower = tostring(value or ""):lower()
        for rarity, rank in pairs(AUTO_FEED_RARITY_RANK) do
            if string.find(lower, rarity, 1, true) and rank > best then
                best = rank
            end
        end
    end

    local function inspect(item)
        for name, value in pairs(item:GetAttributes()) do
            if AUTO_FEED_RARITY_KEYS[normalizeAutoFeedName(name)] then
                consider(value)
            end
        end
        if AUTO_FEED_RARITY_KEYS[normalizeAutoFeedName(item.Name)] then
            if item:IsA("StringValue") then
                consider(item.Value)
            elseif item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
                consider(item.Text)
            end
        end
    end

    inspect(pet)
    for index, item in ipairs(pet:GetDescendants()) do
        if index > 120 then break end
        inspect(item)
    end
    return best
end

Runtime.AutoFeed.GetPetPriority = function(pet)
    local known = getKnownAutoFeedPetStats(pet)
    local liveIncome = getAutoFeedNumericStat(
        pet,
        AUTO_FEED_INCOME_KEYS,
        {"income", "cash/sec", "cash / sec", "cash/s", "$/s", "earning"}
    )
    local liveSpeed = getAutoFeedNumericStat(
        pet,
        AUTO_FEED_SPEED_KEYS,
        {"speed", " mph", "mph", " spd", "spd"}
    )

    return {
        Income = liveIncome or (known and known.Income) or 0,
        Speed = liveSpeed or (known and known.Speed) or 0,
        RarityRank = getAutoFeedRarityRank(pet),
        LiveIncome = liveIncome,
        LiveSpeed = liveSpeed,
        UsedKnownFallback = liveIncome == nil and known ~= nil,
    }
end

local function compareAutoFeedCandidates(a, b)
    if math.abs((a.Income or 0) - (b.Income or 0)) > 0.0001 then
        return (a.Income or 0) > (b.Income or 0)
    end
    if math.abs((a.Speed or 0) - (b.Speed or 0)) > 0.0001 then
        return (a.Speed or 0) > (b.Speed or 0)
    end
    if (a.RarityRank or 0) ~= (b.RarityRank or 0) then
        return (a.RarityRank or 0) > (b.RarityRank or 0)
    end
    if (a.Age or 0) ~= (b.Age or 0) then
        return (a.Age or 0) > (b.Age or 0)
    end
    return tostring(a.Name or ""):lower() < tostring(b.Name or ""):lower()
end

local function refreshAutoFeedAgeUI()
    local minAge = clampWholeAutoFeedAge(Runtime.AutoFeed.MinAge)
    Runtime.AutoFeed.MinAge = minAge

    local ui = Runtime.AutoFeed.UI or {}
    if ui.AgeLabel and ui.AgeLabel.Parent then
        ui.AgeLabel.Text = "Feed only pets ABOVE Age: " .. tostring(minAge)
    end
    if ui.AgeValue and ui.AgeValue.Parent and not ui.AgeValue:IsFocused() then
        ui.AgeValue.Text = tostring(minAge)
    end
    if ui.AgeKnob and ui.AgeKnob.Parent then
        ui.AgeKnob.Position = UDim2.new(minAge / 99, -5, 0.5, -5)
    end
    if ui.AgeFill and ui.AgeFill.Parent then
        ui.AgeFill.Size = UDim2.new(minAge / 99, 0, 1, 0)
    end
end

Runtime.AutoFeed.SetMinAge = function(value)
    Runtime.AutoFeed.MinAge = clampWholeAutoFeedAge(value)
    Runtime.AutoFeed.LastPet = nil
    Runtime.AutoFeed.LastPrompt = nil
    Runtime.AutoFeed.LastTarget = nil
    refreshAutoFeedAgeUI()
    return Runtime.AutoFeed.MinAge
end

local function setAutoFeedStatus(text, good)
    Runtime.AutoFeed.LastStatus = tostring(text or "")
    local label = Runtime.AutoFeed.UI and Runtime.AutoFeed.UI.Status
    if label and label.Parent then
        label.Text = Runtime.AutoFeed.LastStatus
        label.TextColor3 = good == false
            and Color3.fromRGB(255, 145, 120)
            or Color3.fromRGB(170, 215, 195)
    end
end

local function refreshAutoFeedButton()
    local button = Runtime.AutoFeed.UI and Runtime.AutoFeed.UI.Toggle
    if not button or not button.Parent then
        return
    end

    if Runtime.AutoFeed.Enabled then
        button.Text = "Auto Feed Pet: ON"
        button.BackgroundColor3 = Color3.fromRGB(0, 145, 85)
        button.TextColor3 = Color3.fromRGB(255, 255, 255)
    else
        button.Text = "Auto Feed Pet: OFF"
        button.BackgroundColor3 = Color3.fromRGB(35, 45, 58)
        button.TextColor3 = Color3.fromRGB(220, 228, 238)
    end
end

local function getAutoFeedFoodInfo(tool)
    if not tool or not tool.Parent or not tool:IsA("Tool") then
        return nil
    end

    local values = {tool.Name}
    for name, value in pairs(tool:GetAttributes()) do
        table.insert(values, tostring(name))
        table.insert(values, tostring(value))
        table.insert(values, tostring(name) .. "=" .. tostring(value))
    end

    for index, food in ipairs(AUTO_FEED_FOOD_ORDER) do
        for _, value in ipairs(values) do
            local normalized = normalizeAutoFeedName(value)
            if normalized == food.Key or string.find(normalized, food.Key, 1, true) then
                return {
                    Tool = tool,
                    Name = food.Name,
                    XP = food.XP,
                    Order = index,
                    Known = true,
                }
            end
        end
    end

    local normalizedName = normalizeAutoFeedName(tool.Name)
    if string.find(normalizedName, "food", 1, true)
        and not string.find(normalizedName, "egg", 1, true)
        and not string.find(normalizedName, "radar", 1, true) then
        return {
            Tool = tool,
            Name = tool.Name,
            XP = 0,
            Order = 999,
            Known = false,
        }
    end

    return nil
end

Runtime.AutoFeed.GetFoodTool = function()
    local character = getCharacter()
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")

    -- Respect the player's choice first: if a valid food Tool is already equipped,
    -- keep using it instead of silently consuming a more expensive food.
    if character then
        for _, child in ipairs(character:GetChildren()) do
            local info = getAutoFeedFoodInfo(child)
            if info then
                return info
            end
        end
    end

    -- Otherwise use the cheapest/lowest-tier known food first (Grass -> ...),
    -- avoiding accidental Dragonfruit/Magic Apple burn when cheaper food exists.
    local best = nil
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            local info = getAutoFeedFoodInfo(child)
            if info and (not best or info.Order < best.Order) then
                best = info
            end
        end
    end

    return best
end

local function getAutoFeedPromptText(prompt)
    local parts = {
        prompt and prompt.Name or "",
        prompt and prompt.ActionText or "",
        prompt and prompt.ObjectText or "",
        prompt and prompt.Parent and prompt.Parent.Name or "",
    }

    local current = prompt and prompt.Parent
    for _ = 1, 4 do
        if current and current.Parent then
            current = current.Parent
            table.insert(parts, current.Name)
        end
    end

    return table.concat(parts, " "):lower()
end

local function isStrictIndividualFeedPrompt(prompt, plot)
    if not prompt or not prompt.Parent or not prompt:IsA("ProximityPrompt") or not prompt.Enabled then
        return false, "prompt unavailable"
    end

    local owned, ownedReason = belongsToStrictOwnedPlot(prompt, plot)
    if not owned then
        return false, ownedReason
    end

    local eggsFolder = plot and plot:FindFirstChild("Eggs")
    if eggsFolder and prompt:IsDescendantOf(eggsFolder) then
        return false, "egg prompt"
    end

    local text = getAutoFeedPromptText(prompt)
    local hasFeed = string.find(text, "feed", 1, true) ~= nil
        or string.find(text, "give food", 1, true) ~= nil
        or string.find(text, "givefood", 1, true) ~= nil

    if not hasFeed then
        return false, "not a feed prompt"
    end

    -- Never touch ranch-wide/mass actions or unrelated systems.
    local blockedPhrases = {
        "feed all", "all pets", "all pet", "skip all", "grow all",
        "hatch all", "egg", "upgrade", "luck", "sell", "remove",
        "delete", "release", "claim all", "collect all",
    }
    for _, phrase in ipairs(blockedPhrases) do
        if string.find(text, phrase, 1, true) then
            return false, "blocked: " .. phrase
        end
    end

    return true, "strict individual Feed prompt"
end

Runtime.AutoFeed.GetFeedPrompts = function(plot)
    plot = plot or getStrictOwnedPlot()
    if not plot or not isPlotOwnedByLocalPlayer(plot) then
        return {}
    end

    local result = {}
    for _, object in ipairs(plot:GetDescendants()) do
        if object:IsA("ProximityPrompt") then
            local valid = isStrictIndividualFeedPrompt(object, plot)
            if valid then
                table.insert(result, object)
            end
        end
    end

    table.sort(result, function(a, b)
        return a:GetFullName() < b:GetFullName()
    end)
    return result
end

local function getAutoFeedTargetPosition(target)
    if not target or not target.Parent then return nil end
    if target:IsA("BasePart") then return target.Position end
    if target:IsA("Model") then
        local ok, pivot = pcall(function() return target:GetPivot() end)
        if ok and pivot then return pivot.Position end
    end
    return nil
end

local function getAutoFeedPetAncestor(object, plot)
    local current = object
    local fallback = nil

    while current and current ~= plot do
        if current:IsA("Model") or current:IsA("BasePart") then
            local lower = current.Name:lower()
            local blocked = lower == "eggs"
                or lower == "nests"
                or lower == "hatchupgrade"
                or lower == "plot"

            if not blocked then
                -- Keep the OUTERMOST plausible pet object as fallback, but return
                -- immediately once live Age or known species metadata identifies it.
                fallback = current
                local age = Runtime.AutoFeed.GetPetAge(current)
                local known = getKnownAutoFeedPetStats(current)
                if age ~= nil or known ~= nil then
                    return current
                end

                local parent = current.Parent
                if parent then
                    local parentName = parent.Name:lower()
                    if parentName == "pets"
                        or parentName == "placedpets"
                        or parentName == "animals" then
                        return current
                    end
                end
            end
        end
        current = current.Parent
    end

    return fallback
end

Runtime.AutoFeed.GetPlacedPetTargets = function(plot)
    plot = plot or getStrictOwnedPlot()
    if not plot or not isPlotOwnedByLocalPlayer(plot) then
        return {}
    end

    local targets = {}
    local seen = {}
    local function add(target)
        if target and target.Parent and not seen[target] then
            local owned = belongsToStrictOwnedPlot(target, plot)
            if owned then
                seen[target] = true
                table.insert(targets, target)
            end
        end
    end

    -- Prefer explicit placed-pet containers if this build exposes one.
    for _, name in ipairs({"Pets", "PlacedPets", "Animals"}) do
        local folder = plot:FindFirstChild(name)
        if folder then
            for _, child in ipairs(folder:GetChildren()) do
                if child:IsA("Model") or child:IsA("BasePart") then
                    add(child)
                end
            end
        end
    end

    -- Fallback: mounted pets normally expose Ride/Mount interaction prompts.
    for _, object in ipairs(plot:GetDescendants()) do
        if object:IsA("ProximityPrompt") then
            local text = getAutoFeedPromptText(object)
            if string.find(text, "ride", 1, true) or string.find(text, "mount", 1, true) then
                add(getAutoFeedPetAncestor(object.Parent, plot))
            end
        end
    end

    table.sort(targets, function(a, b)
        return a:GetFullName() < b:GetFullName()
    end)
    return targets
end

local function getAutoFeedMaxAge()
    local configured = tonumber(Config.AutoFeedMaxAge) or tonumber(Runtime.AutoFeed.MaxAge) or 100
    configured = math.floor(configured + 0.5)
    if configured < 1 then configured = 100 end
    Runtime.AutoFeed.MaxAge = configured
    return configured
end

local function buildAutoFeedCandidate(pet, prompt)
    if not pet or not pet.Parent then
        return nil
    end

    local age = Runtime.AutoFeed.GetPetAge(pet)
    if age == nil and prompt then
        age = autoFeedAgeFromText(getAutoFeedPromptText(prompt))
    end

    -- STRICT age behavior:
    --   * unknown age is never guessed and never fed
    --   * Age must be strictly ABOVE the user threshold
    --   * max-Age pets are always skipped so food moves to the next-best pet
    local minAge = clampWholeAutoFeedAge(Runtime.AutoFeed.MinAge)
    local maxAge = getAutoFeedMaxAge()
    if age == nil or age <= minAge or age >= maxAge then
        return nil
    end

    local priority = Runtime.AutoFeed.GetPetPriority(pet)
    return {
        Pet = pet,
        Prompt = prompt,
        Name = pet.Name,
        Age = age,
        Income = priority.Income or 0,
        Speed = priority.Speed or 0,
        RarityRank = priority.RarityRank or 0,
        LiveIncome = priority.LiveIncome,
        LiveSpeed = priority.LiveSpeed,
        UsedKnownFallback = priority.UsedKnownFallback == true,
    }
end

Runtime.AutoFeed.GetFeedCandidates = function(plot)
    plot = plot or getStrictOwnedPlot()
    if not plot or not isPlotOwnedByLocalPlayer(plot) then
        return {}
    end

    local result = {}
    local seenPets = {}

    for _, prompt in ipairs(Runtime.AutoFeed.GetFeedPrompts(plot)) do
        local pet = getAutoFeedPetAncestor(prompt.Parent, plot)
        if pet and not seenPets[pet] then
            local candidate = buildAutoFeedCandidate(pet, prompt)
            if candidate then
                seenPets[pet] = true
                table.insert(result, candidate)
            end
        end
    end

    table.sort(result, compareAutoFeedCandidates)
    return result
end

Runtime.AutoFeed.GetPlacedPetCandidates = function(plot)
    plot = plot or getStrictOwnedPlot()
    if not plot or not isPlotOwnedByLocalPlayer(plot) then
        return {}
    end

    local result = {}
    local seenPets = {}
    for _, pet in ipairs(Runtime.AutoFeed.GetPlacedPetTargets(plot)) do
        if pet and pet.Parent and not seenPets[pet] then
            local candidate = buildAutoFeedCandidate(pet, nil)
            if candidate then
                seenPets[pet] = true
                table.insert(result, candidate)
            end
        end
    end

    table.sort(result, compareAutoFeedCandidates)
    return result
end

local function chooseAutoFeedPriorityCandidate(candidates, previousPet)
    if type(candidates) ~= "table" or #candidates == 0 then
        return nil, nil
    end

    -- FOCUS MODE: keep feeding the SAME highest-priority pet while it remains
    -- eligible. It leaves this list automatically when it reaches MaxAge, drops
    -- below the threshold, disappears, or otherwise becomes invalid. Only then
    -- do we move to candidates[1], which is the next-best remaining pet.
    if previousPet then
        for index, candidate in ipairs(candidates) do
            if candidate.Pet == previousPet then
                return candidate, index
            end
        end
    end

    return candidates[1], 1
end

local function describeAutoFeedCandidate(candidate, index, total)
    if not candidate then return "nil" end
    return string.format(
        "%s | Age %d | Income %.0f | Speed %.0f | priority %d/%d",
        tostring(candidate.Name or "Pet"),
        tonumber(candidate.Age) or -1,
        tonumber(candidate.Income) or 0,
        tonumber(candidate.Speed) or 0,
        tonumber(index) or 1,
        tonumber(total) or 1
    )
end

local function chooseRoundRobin(list, previous)
    if type(list) ~= "table" or #list == 0 then
        return nil
    end
    if not previous then
        return list[1]
    end
    for index, item in ipairs(list) do
        if item == previous then
            return list[(index % #list) + 1]
        end
    end
    return list[1]
end

local function ensureAutoFeedFoodEquipped(info)
    if not info or not info.Tool or not info.Tool.Parent then
        return false, "food unavailable"
    end

    local character = getCharacter()
    if character and info.Tool:IsDescendantOf(character) then
        return true, "food already equipped"
    end

    local humanoid = getHumanoid()
    if not humanoid or humanoid.Health <= 0 then
        return false, "humanoid unavailable"
    end

    local ok = pcall(function()
        humanoid:EquipTool(info.Tool)
    end)
    if not ok then
        return false, "EquipTool failed"
    end

    task.wait(0.08)
    character = getCharacter()
    return character and info.Tool.Parent and info.Tool:IsDescendantOf(character), "food equipped"
end

local function dismountForAutoFeed()
    local humanoid = getHumanoid()
    if humanoid and humanoid.SeatPart then
        humanoid.Sit = false
        humanoid.Jump = true
        task.wait(0.12)
    end
end

local function getAutoFeedPromptPart(prompt)
    local current = prompt and prompt.Parent
    while current and current.Parent do
        if current:IsA("BasePart") then
            return current
        end
        current = current.Parent
    end
    return nil
end

local function autoFeedShouldYieldToGetEgg()
    -- Get Egg has absolute priority over Auto Feed. Auto Feed never changes
    -- Get Egg filters/state; it simply gets out of the way whenever Get Egg is
    -- processing OR has a rendered target ready to process.
    if autoFarmCurrentName ~= nil then
        return true, "Get Egg actively processing " .. tostring(autoFarmCurrentName)
    end

    if autoFarmActive
        and Runtime.AutoGet
        and type(Runtime.AutoGet.HasPendingRenderedTarget) == "function" then
        local ok, pending = pcall(Runtime.AutoGet.HasPendingRenderedTarget)
        if ok and pending then
            return true, "Get Egg target detected"
        end
    end

    return false, "Get Egg idle"
end

local function interactAutoFeedPrompt(prompt, plot)
    local getEggPriority, getEggReason = autoFeedShouldYieldToGetEgg()
    if getEggPriority then
        return false, "yielded to " .. tostring(getEggReason)
    end

    local valid, reason = isStrictIndividualFeedPrompt(prompt, plot)
    if not valid then
        return false, reason
    end

    local part = getAutoFeedPromptPart(prompt)
    if not part then
        return false, "Feed prompt has no physical part"
    end

    local owned = belongsToStrictOwnedPlot(part, plot)
    if not owned then
        return false, "Feed target left owned Ranch"
    end

    local root = getRootPart()
    if not root then
        return false, "root unavailable"
    end

    local maxDistance = math.max(4, tonumber(prompt.MaxActivationDistance) or 10)
    if (root.Position - part.Position).Magnitude > math.max(3, maxDistance - 1) then
        local moved = moveToModel(part, true)
        if not moved then
            return false, "could not reach owned pet Feed prompt"
        end
    end

    local getEggAfterMove, getEggAfterMoveReason = autoFeedShouldYieldToGetEgg()
    if getEggAfterMove then
        return false, "yielded to " .. tostring(getEggAfterMoveReason)
    end

    valid, reason = isStrictIndividualFeedPrompt(prompt, plot)
    if not valid then
        return false, "Feed prompt invalid after movement: " .. tostring(reason)
    end

    local ok, method = Runtime.InputCompat.InteractProximityPromptPortable(
        prompt,
        tonumber(Config.AutoFeedPromptExtraHold) or 0.05
    )
    return ok, ok
        and ("individual Feed prompt via " .. tostring(method))
        or ("Feed input failed: " .. tostring(method))
end

-- FAST FOCUSED FEED PATH -------------------------------------------------------
-- Once a best pet has been chosen, reuse that exact pet + prompt + food Tool.
-- This path intentionally avoids GetDescendants(), candidate sorting, and bag scans.
-- It returns nil,"rescan" when the cache is stale so TryOnce can do one full rebuild.
Runtime.AutoFeed.TryFocusedFast = function(plot)
    local pet = Runtime.AutoFeed.LastPet
    local prompt = Runtime.AutoFeed.LastPrompt

    if not pet or not pet.Parent then
        return nil, "rescan"
    end
    if not plot or not isPlotOwnedByLocalPlayer(plot) then
        return nil, "rescan"
    end

    local getEggPriority, getEggReason = autoFeedShouldYieldToGetEgg()
    if getEggPriority then
        return false, "yielded to " .. tostring(getEggReason)
    end
    if movementActive or (Runtime.EggAutomation and (Runtime.EggAutomation.Busy or Runtime.EggAutomation.RequestingAction)) then
        return false, "yielded to active/requested Egg Automation"
    end

    local owned = belongsToStrictOwnedPlot(pet, plot)
    if not owned then
        Runtime.AutoFeed.LastPet = nil
        Runtime.AutoFeed.LastPrompt = nil
        Runtime.AutoFeed.LastTarget = nil
        return nil, "rescan"
    end

    local age = Runtime.AutoFeed.GetPetAge(pet)
    if age == nil and prompt and prompt.Parent then
        age = autoFeedAgeFromText(getAutoFeedPromptText(prompt))
    end
    local minAge = clampWholeAutoFeedAge(Runtime.AutoFeed.MinAge)
    local maxAge = getAutoFeedMaxAge()
    if age == nil or age <= minAge or age >= maxAge then
        Runtime.AutoFeed.LastPet = nil
        Runtime.AutoFeed.LastPrompt = nil
        Runtime.AutoFeed.LastTarget = nil
        Runtime.AutoFeed.LastPetAge = age
        return nil, age and age >= maxAge
            and ("Pet reached MAX Age " .. tostring(maxAge) .. " — focusing next-best pet")
            or "rescan"
    end

    -- Reuse the exact prompt when possible. If it vanished/changed, request one
    -- full rescan instead of deep-scanning the Ranch in the 0.08s hot loop.
    if not prompt or not prompt.Parent then
        Runtime.AutoFeed.LastPrompt = nil
        return nil, "rescan"
    end
    local promptOK = isStrictIndividualFeedPrompt(prompt, plot)
    if not promptOK then
        Runtime.AutoFeed.LastPrompt = nil
        return nil, "rescan"
    end

    local promptPet = getAutoFeedPetAncestor(prompt.Parent, plot)
    if promptPet and promptPet ~= pet then
        Runtime.AutoFeed.LastPrompt = nil
        return nil, "rescan"
    end

    -- Reuse the cached food Tool. Auto Place/Get Egg may temporarily equip another
    -- Tool; after they release their action lock we simply re-equip this food Tool.
    local foodTool = Runtime.AutoFeed.LastFoodTool
    local foodInfo = nil
    if foodTool and foodTool.Parent then
        foodInfo = getAutoFeedFoodInfo(foodTool)
    end
    if not foodInfo then
        foodInfo = Runtime.AutoFeed.GetFoodTool()
        if not foodInfo then
            Runtime.AutoFeed.LastFoodTool = nil
            return false, "No food found (Grass/Bone/Meat/Magic Apple/Dragonfruit)"
        end
        Runtime.AutoFeed.LastFoodTool = foodInfo.Tool
        Runtime.AutoFeed.LastFood = foodInfo.Name
    end

    local equipped, equipReason = ensureAutoFeedFoodEquipped(foodInfo)
    if not equipped then
        return false, "Food equip failed: " .. tostring(equipReason)
    end

    local getEggBeforeFeed, getEggBeforeFeedReason = autoFeedShouldYieldToGetEgg()
    if getEggBeforeFeed then
        return false, "yielded to " .. tostring(getEggBeforeFeedReason)
    end
    if movementActive or (Runtime.EggAutomation and (Runtime.EggAutomation.Busy or Runtime.EggAutomation.RequestingAction)) then
        return false, "yielded before feed action"
    end

    local fed, feedReason = interactAutoFeedPrompt(prompt, plot)
    if not fed then
        return nil, "rescan"
    end

    Runtime.AutoFeed.LastTarget = pet
    Runtime.AutoFeed.LastPetAge = age
    Runtime.AutoFeed.LastActionAt = os.clock()
    Runtime.AutoFeed.FastFeedCount = (Runtime.AutoFeed.FastFeedCount or 0) + 1
    return true,
        "Fast-fed " .. tostring(Runtime.AutoFeed.LastPetName or pet.Name)
        .. " | Age " .. tostring(age)
        .. " using " .. tostring(Runtime.AutoFeed.LastFood or foodInfo.Name)
        .. " (" .. tostring(feedReason) .. ")"
end

Runtime.AutoFeed.TryOnce = function()
    if Runtime.AutoFeed.Busy then
        return false, "Auto Feed busy"
    end

    -- Do not fight travel/egg movement. Feeding resumes automatically when those
    -- higher-motion actions finish; it never changes Get Egg state or filters.
    if movementActive then
        return false, "movement active"
    end
    local getEggPriority, getEggReason = autoFeedShouldYieldToGetEgg()
    if getEggPriority then
        return false, "yielded to " .. tostring(getEggReason)
    end
    if autoBestEggActive then
        return false, "Auto Best Egg active"
    end
    if Runtime.EggAutomation and (Runtime.EggAutomation.Busy or Runtime.EggAutomation.RequestingAction) then
        return false, Runtime.EggAutomation.RequestingAction
            and "Egg Automation requesting action"
            or "Egg Automation busy"
    end

    Runtime.AutoFeed.Busy = true
    local ok, success, message = pcall(function()
        local plot = getStrictOwnedPlot()
        if not plot then
            return false, "owned Ranch not found"
        end

        local root = getRootPart()
        if not root then
            return false, "root unavailable"
        end

        if not isWorldPositionInsideOwnedPlot(
            plot,
            root.Position,
            tonumber(Config.AutoFeedRanchPaddingXZ) or 16,
            tonumber(Config.AutoFeedRanchPaddingY) or 55
        ) then
            local moved = moveToModel(plot, true)
            if not moved then
                return false, "could not return to owned Ranch"
            end

            plot = getStrictOwnedPlot()
            root = getRootPart()
            if not plot or not root or not isWorldPositionInsideOwnedPlot(
                plot,
                root.Position,
                tonumber(Config.AutoFeedRanchPaddingXZ) or 16,
                tonumber(Config.AutoFeedRanchPaddingY) or 55
            ) then
                return false, "owned Ranch verification failed after return"
            end
        end

        -- Fast cached path first. This is the normal path after the first successful
        -- feed and avoids all heavy Ranch/pet scans at the 0.08s action cadence.
        local fastSuccess, fastMessage = Runtime.AutoFeed.TryFocusedFast(plot)
        if fastSuccess ~= nil then
            return fastSuccess, fastMessage
        end

        dismountForAutoFeed()

        Runtime.AutoFeed.FullScans = (Runtime.AutoFeed.FullScans or 0) + 1
        local food = Runtime.AutoFeed.GetFoodTool()
        if not food then
            return false, "No food found (Grass/Bone/Meat/Magic Apple/Dragonfruit)"
        end

        local getEggBeforeEquip, getEggBeforeEquipReason = autoFeedShouldYieldToGetEgg()
        if getEggBeforeEquip then
            return false, "yielded to " .. tostring(getEggBeforeEquipReason)
        end

        local equipped, equipReason = ensureAutoFeedFoodEquipped(food)
        if not equipped then
            return false, "Food equip failed: " .. tostring(equipReason)
        end
        Runtime.AutoFeed.LastFood = food.Name
        Runtime.AutoFeed.LastFoodTool = food.Tool

        -- Equipping food can make Feed prompts appear, so scan after equip.
        task.wait(0.08)
        plot = getStrictOwnedPlot()
        if not plot then
            return false, "owned Ranch lost after food equip"
        end

        -- STRICT AGE + BEST->LOWEST FOCUS priority:
        -- 1) Age must be known, strictly greater than MinAge, and BELOW MaxAge.
        -- 2) Highest current/live Income first, then Speed, rarity, Age, name.
        -- 3) Keep feeding the current best pet until it reaches MaxAge. Then it is
        --    excluded and the next-best remaining pet becomes the focused target.
        -- 4) Get Egg always preempts this entire feeder.
        local feedCandidates = Runtime.AutoFeed.GetFeedCandidates(plot)
        local candidate, priorityIndex = chooseAutoFeedPriorityCandidate(
            feedCandidates,
            Runtime.AutoFeed.LastPet
        )

        if candidate and candidate.Prompt then
            -- Final live Age gate immediately before the interaction. If the pet's
            -- metadata moved/changed, never consume food unless it still passes.
            local liveAge = Runtime.AutoFeed.GetPetAge(candidate.Pet)
            if liveAge == nil then
                liveAge = autoFeedAgeFromText(getAutoFeedPromptText(candidate.Prompt))
            end
            local maxAge = getAutoFeedMaxAge()
            if liveAge == nil
                or liveAge <= clampWholeAutoFeedAge(Runtime.AutoFeed.MinAge)
                or liveAge >= maxAge then
                Runtime.AutoFeed.LastPet = nil
                return false,
                    liveAge and liveAge >= maxAge
                        and ("Pet reached MAX Age " .. tostring(maxAge) .. " — focusing next-best pet")
                        or ("Pet no longer passes Age > " .. tostring(Runtime.AutoFeed.MinAge))
            end
            candidate.Age = liveAge

            local fed, feedReason = interactAutoFeedPrompt(candidate.Prompt, plot)
            if fed then
                Runtime.AutoFeed.LastPrompt = candidate.Prompt
                Runtime.AutoFeed.LastTarget = candidate.Pet
                Runtime.AutoFeed.LastPet = candidate.Pet
                Runtime.AutoFeed.LastPetName = candidate.Name
                Runtime.AutoFeed.LastPetAge = candidate.Age
                Runtime.AutoFeed.LastPetIncome = candidate.Income
                Runtime.AutoFeed.LastPetSpeed = candidate.Speed
                Runtime.AutoFeed.LastPriorityIndex = priorityIndex
                Runtime.AutoFeed.LastPriorityTotal = #feedCandidates
                Runtime.AutoFeed.LastActionAt = os.clock()
                return true,
                    "Fed " .. describeAutoFeedCandidate(candidate, priorityIndex, #feedCandidates)
                    .. " using " .. tostring(food.Name)
                    .. " (" .. tostring(feedReason) .. ")"
            end
            return false, tostring(feedReason)
        end

        -- Compatibility fallback: some builds expose no individual Feed prompt and
        -- instead consume the equipped food when Tool:Activate() is used beside a
        -- placed pet. The SAME strict age filter and best->lowest order applies.
        local placedCandidates = Runtime.AutoFeed.GetPlacedPetCandidates(plot)
        candidate, priorityIndex = chooseAutoFeedPriorityCandidate(
            placedCandidates,
            Runtime.AutoFeed.LastPet
        )

        if not candidate or not candidate.Pet then
            return false,
                "No eligible owned-ranch pet with Age > "
                .. tostring(Runtime.AutoFeed.MinAge)
                .. " and Age < " .. tostring(getAutoFeedMaxAge())
                .. " (MAX/unknown ages are skipped)"
        end

        local target = candidate.Pet
        local targetPosition = getAutoFeedTargetPosition(target)
        if not targetPosition or not isWorldPositionInsideOwnedPlot(plot, targetPosition, 4, 35) then
            return false, "placed pet target failed strict Ranch bounds"
        end

        root = getRootPart()
        if not root then
            return false, "root unavailable before pet fallback"
        end
        if (root.Position - targetPosition).Magnitude > 8 then
            local moved = moveToModel(target, true)
            if not moved then
                return false, "could not reach placed pet fallback target"
            end
        end

        local stillOwned = belongsToStrictOwnedPlot(target, plot)
        if not stillOwned then
            return false, "placed pet fallback left owned Ranch"
        end

        -- Re-read Age immediately before consuming food. This prevents a stale scan
        -- from feeding a pet that no longer passes the configured strict threshold.
        local liveAge = Runtime.AutoFeed.GetPetAge(target)
        local maxAge = getAutoFeedMaxAge()
        if liveAge == nil
            or liveAge <= clampWholeAutoFeedAge(Runtime.AutoFeed.MinAge)
            or liveAge >= maxAge then
            Runtime.AutoFeed.LastPet = nil
            return false,
                liveAge and liveAge >= maxAge
                    and ("Pet reached MAX Age " .. tostring(maxAge) .. " — focusing next-best pet")
                    or ("Pet no longer passes Age > " .. tostring(Runtime.AutoFeed.MinAge))
        end
        candidate.Age = liveAge

        local activeFood = Runtime.AutoFeed.GetFoodTool()
        if not activeFood or not activeFood.Tool then
            return false, "food disappeared before fallback activation"
        end
        local character = getCharacter()
        if not character or not activeFood.Tool:IsDescendantOf(character) then
            local reEquipped = ensureAutoFeedFoodEquipped(activeFood)
            if not reEquipped then
                return false, "could not re-equip food for fallback"
            end
        end

        local getEggBeforeActivate, getEggBeforeActivateReason = autoFeedShouldYieldToGetEgg()
        if getEggBeforeActivate then
            return false, "yielded to " .. tostring(getEggBeforeActivateReason)
        end

        local activated = pcall(function()
            activeFood.Tool:Activate()
        end)
        if not activated then
            return false, "food Tool:Activate failed"
        end

        Runtime.AutoFeed.LastPrompt = nil
        Runtime.AutoFeed.LastTarget = target
        Runtime.AutoFeed.LastPet = target
        Runtime.AutoFeed.LastPetName = candidate.Name
        Runtime.AutoFeed.LastPetAge = candidate.Age
        Runtime.AutoFeed.LastPetIncome = candidate.Income
        Runtime.AutoFeed.LastPetSpeed = candidate.Speed
        Runtime.AutoFeed.LastPriorityIndex = priorityIndex
        Runtime.AutoFeed.LastPriorityTotal = #placedCandidates
        Runtime.AutoFeed.LastActionAt = os.clock()
        return true,
            "Activated " .. tostring(activeFood.Name)
            .. " beside " .. describeAutoFeedCandidate(candidate, priorityIndex, #placedCandidates)
            .. " (no Feed prompt fallback)"
    end)

    Runtime.AutoFeed.Busy = false
    if not ok then
        return false, "Auto Feed error: " .. tostring(success)
    end
    return success, message
end

Runtime.AutoFeed.Stop = function()
    Runtime.AutoFeed.Enabled = false
    Runtime.AutoFeed.Busy = false
    Runtime.EggAutomation.RequestingAction = false
    Runtime.AutoFeed.LastPrompt = nil
    Runtime.AutoFeed.LastTarget = nil
    Runtime.AutoFeed.LastPet = nil
    Runtime.AutoFeed.LastFoodTool = nil
    if Runtime.AutoFeed.Thread then
        pcall(function()
            task.cancel(Runtime.AutoFeed.Thread)
        end)
        Runtime.AutoFeed.Thread = nil
    end
    refreshAutoFeedButton()
    setAutoFeedStatus("Auto Feed Pet: OFF", true)
end

Runtime.AutoFeed.Start = function()
    Runtime.AutoFeed.Stop()
    Runtime.AutoFeed.Enabled = true
    refreshAutoFeedButton()
    setAutoFeedStatus(
        "Auto Feed armed — YOUR Ranch only; focus best until MAX; Age > "
        .. tostring(Runtime.AutoFeed.MinAge)
        .. ", MAX " .. tostring(getAutoFeedMaxAge())
        .. "; best income pet -> lowest.",
        true
    )

    Runtime.AutoFeed.Thread = task.spawn(function()
        while Runtime.Alive and Runtime.AutoFeed.Enabled do
            local success, message = Runtime.AutoFeed.TryOnce()
            if Runtime.AutoFeed.Enabled then
                setAutoFeedStatus(message, success)
                Runtime.DebugTeleport("AUTO-FEED", success and "FEED SUCCESS" or "FEED WAIT/SKIP", {
                    success = success,
                    message = message,
                    food = Runtime.AutoFeed.LastFood or "nil",
                    minAge = Runtime.AutoFeed.MinAge,
                    maxAge = getAutoFeedMaxAge(),
                    focusMode = true,
                    fastInterval = tonumber(Config.AutoFeedFastInterval) or 0.08,
                    fastFeedCount = Runtime.AutoFeed.FastFeedCount or 0,
                    fullScans = Runtime.AutoFeed.FullScans or 0,
                    eggAutoRequesting = Runtime.EggAutomation and Runtime.EggAutomation.RequestingAction or false,
                    pet = Runtime.AutoFeed.LastPetName or "nil",
                    petAge = Runtime.AutoFeed.LastPetAge or -1,
                    petIncome = Runtime.AutoFeed.LastPetIncome or 0,
                    priority = Runtime.AutoFeed.LastPriorityIndex
                        and (tostring(Runtime.AutoFeed.LastPriorityIndex) .. "/" .. tostring(Runtime.AutoFeed.LastPriorityTotal or "?"))
                        or "nil",
                })
            end
            local waitTime
            if success then
                waitTime = math.max(0.05, tonumber(Config.AutoFeedFastInterval) or tonumber(Config.AutoFeedActionCooldown) or 0.08)
            elseif Runtime.AutoFeed.LastPet and Runtime.AutoFeed.LastPrompt then
                -- A focused pet exists but another automation currently owns movement/action.
                -- Retry quickly without doing a full scan.
                waitTime = math.max(0.08, tonumber(Config.AutoFeedFastInterval) or 0.08)
            else
                -- No stable focused target: back off before the next full Ranch scan.
                waitTime = math.max(0.25, tonumber(Config.AutoFeedPoll) or 0.35)
            end
            task.wait(waitTime)
        end
        Runtime.AutoFeed.Thread = nil
    end)
end

--==================================================
-- MISC: DROP EGG [Q] (SEPARATE + STRICT)
--==================================================
-- Independent from Get Egg / ESP / notifications / movement.
-- OFF -> no Q polling/action.
-- ON  -> one physical Q press performs one bounded BasketDrop sequence.
--
-- IMPORTANT:
-- Only canonical Egg catalog names are allowed. Generic UI/container names such
-- as "EggFrame" are NEVER passed to BasketDrop.
Runtime.DropEggQ = {
    Enabled = false,
    Busy = false,
    Generation = 0,
    QWasDown = false,
    LastQTriggerAt = 0,
    LastEggName = nil,
    LastFireAt = 0,
    BurstInterval = 0.15,
    BurstCount = 10,
    KeyConnection = nil,
    UI = {},
}

Runtime.DropEggQ.GetRemote = function()
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local gameRemotes = remotes and remotes:FindFirstChild("Game")
    local remote = gameRemotes and gameRemotes:FindFirstChild("BasketDrop")

    if remote and remote:IsA("RemoteEvent") then
        return remote
    end

    return nil
end

Runtime.DropEggQ.IsEggTool = function(tool)
    if not tool or not tool:IsA("Tool") then
        return false
    end

    local name = tostring(tool.Name or "")
    return name ~= "" and string.find(name:lower(), "egg", 1, true) ~= nil
end

Runtime.DropEggQ.FindCarriedEggName = function()
    local drop = Runtime.DropEggQ

    -- Same strict behavior as the standalone build that worked:
    -- build/refresh the canonical catalog once, then only accept catalog matches.
    if not Runtime.EggIdentity
        or type(Runtime.EggIdentity.Catalog) ~= "function"
        or type(Runtime.EggIdentity.Key) ~= "function" then
        return nil, nil
    end

    Runtime.EggIdentity.Catalog()

    local function matchValue(value)
        if type(value) ~= "string" or value == "" then
            return nil
        end

        local cleaned = value:gsub("<[^>]*>", "")
        local normalized = Runtime.EggIdentity.Key(cleaned)
        local compact = cleaned:lower():gsub("[^%w]", "")

        for _, entry in ipairs(Runtime.EggIdentity.Keys or {}) do
            if normalized == entry.Key
                or compact == entry.Key
                or compact:find(entry.Key .. "egg", 1, true)
                or compact:find(entry.Key, 1, true) then
                return entry.Name
            end
        end

        return nil
    end

    local function inspect(object)
        if not object then
            return nil
        end

        local matched = matchValue(object.Name)
        if matched then
            return matched
        end

        for _, value in pairs(object:GetAttributes()) do
            matched = matchValue(value)
            if matched then
                return matched
            end
        end

        if object:IsA("StringValue") then
            return matchValue(object.Value)
        elseif object:IsA("TextLabel")
            or object:IsA("TextButton")
            or object:IsA("TextBox") then
            return matchValue(object.Text)
        end

        return nil
    end

    -- 1) Actually equipped/carried Egg Tool.
    local character = LocalPlayer.Character
    if character then
        for _, child in ipairs(character:GetChildren()) do
            if drop.IsEggTool(child) then
                local matched = matchValue(child.Name)
                if matched then
                    return matched, "Character Tool"
                end
            end
        end

        for _, object in ipairs(character:GetDescendants()) do
            local matched = inspect(object)
            if matched then
                return matched, "Character State"
            end
        end
    end

    -- 2) Exact live carry UI used by Ride A Pet.
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local main = playerGui and playerGui:FindFirstChild("Main")
    local tracker = main and main:FindFirstChild("EggTracker")
    local handler = tracker and tracker:FindFirstChild("Handler")
    local eggFrame = handler and handler:FindFirstChild("EggFrame")

    if eggFrame and (not eggFrame:IsA("GuiObject") or eggFrame.Visible ~= false) then
        -- Do NOT inspect EggFrame.Name as a generic egg fallback.
        -- Strict catalog matching makes "EggFrame" resolve to nil.
        local matched = inspect(eggFrame)
        if matched then
            return matched, "EggTracker"
        end

        for _, object in ipairs(eggFrame:GetDescendants()) do
            matched = inspect(object)
            if matched then
                return matched, "EggTracker"
            end
        end
    end

    -- 3) Backpack fallback, after active carry state.
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if backpack then
        for _, child in ipairs(backpack:GetChildren()) do
            if drop.IsEggTool(child) then
                local matched = matchValue(child.Name)
                if matched then
                    return matched, "Backpack Tool"
                end
            end
        end

        for _, object in ipairs(backpack:GetDescendants()) do
            local matched = inspect(object)
            if matched then
                return matched, "Backpack State"
            end
        end
    end

    return nil, nil
end

Runtime.DropEggQ.RefreshUI = function()
    local drop = Runtime.DropEggQ
    local button = drop.UI and drop.UI.Toggle

    if button and button.Parent then
        if drop.Busy then
            button.Text = "Drop Egg [Q]  •  DROPPING"
        else
            button.Text = drop.Enabled
                and "Drop Egg [Q]  •  ON"
                or "Drop Egg [Q]  •  OFF"
        end

        button.BackgroundColor3 = drop.Enabled
            and Color3.fromRGB(0, 145, 85)
            or Color3.fromRGB(35, 45, 58)

        button.TextColor3 = drop.Enabled
            and Color3.fromRGB(255, 255, 255)
            or Color3.fromRGB(220, 228, 238)
    end
end

Runtime.DropEggQ.SetEnabled = function(enabled)
    local drop = Runtime.DropEggQ
    drop.Enabled = enabled == true

    -- Sample the current physical state when turning ON so enabling the toggle
    -- while Q is already held cannot count as a new Q press.
    local qDownNow = false
    if drop.Enabled then
        pcall(function()
            qDownNow = UserInputService:IsKeyDown(Enum.KeyCode.Q)
        end)
    end
    drop.QWasDown = qDownNow

    if not drop.Enabled then
        drop.Generation = (drop.Generation or 0) + 1
        drop.Busy = false
    end

    drop.RefreshUI()

    if StatusLabel then
        if drop.Enabled then
            StatusLabel.Text = "● Drop Egg [Q] ON — press Q once to drop"
            StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
        else
            StatusLabel.Text = "● Drop Egg [Q] OFF"
            StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
        end
    end
end

Runtime.DropEggQ.DropOnce = function()
    local drop = Runtime.DropEggQ

    if not Runtime.Alive then
        return false, "runtime stopped"
    end

    if not drop.Enabled then
        return false, "Drop Egg [Q] is OFF"
    end

    if drop.Busy then
        return false, "drop already running"
    end

    local eggName, source = drop.FindCarriedEggName()
    if not eggName then
        if StatusLabel then
            StatusLabel.Text = "● Drop Egg [Q]: no carried Egg detected"
            StatusLabel.TextColor3 = Color3.fromRGB(255, 140, 120)
        end
        return false, "no carried Egg"
    end

    local remote = drop.GetRemote()
    if not remote then
        if StatusLabel then
            StatusLabel.Text = "● Drop Egg [Q]: BasketDrop remote unavailable"
            StatusLabel.TextColor3 = Color3.fromRGB(255, 140, 120)
        end
        return false, "BasketDrop remote unavailable"
    end

    drop.Generation = (drop.Generation or 0) + 1
    local generation = drop.Generation

    drop.Busy = true
    drop.LastEggName = eggName
    drop.RefreshUI()

    task.spawn(function()
        local count = math.max(1, math.floor(tonumber(drop.BurstCount) or 10))
        local interval = math.max(0.05, tonumber(drop.BurstInterval) or 0.15)

        if StatusLabel then
            StatusLabel.Text = "● Drop Egg [Q]: dropping " .. tostring(eggName)
                .. " [" .. tostring(source or "carry") .. "]"
            StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
        end

        for _ = 1, count do
            if not Runtime.Alive
                or not drop.Enabled
                or generation ~= drop.Generation then
                break
            end

            pcall(function()
                remote:FireServer(eggName)
            end)

            drop.LastFireAt = os.clock()
            task.wait(interval)
        end

        if generation == drop.Generation then
            drop.Busy = false
        end

        drop.RefreshUI()

        if Runtime.Alive and StatusLabel then
            if drop.Enabled then
                StatusLabel.Text = "● Drop Egg [Q] ON — press Q once to drop"
                StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
            else
                StatusLabel.Text = "● System ready"
                StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
            end
        end
    end)

    return true, eggName
end

Runtime.DropEggQ.StartKeyWatcher = function()
    local drop = Runtime.DropEggQ
    if drop.KeyConnection then
        return
    end

    -- Start this watcher with the subsystem itself instead of waiting for the
    -- giant LateBootstrap to finish. That keeps Q functional even if a later,
    -- unrelated UI feature fails to initialize.
    drop.KeyConnection = trackRuntimeConnection(RunService.Heartbeat:Connect(function()
        if not Runtime.Alive then
            return
        end

        -- Optimization: when OFF there is no IsKeyDown polling at all.
        if not drop.Enabled then
            drop.QWasDown = false
            return
        end

        local qDown = false
        pcall(function()
            qDown = UserInputService:IsKeyDown(Enum.KeyCode.Q)
        end)

        if qDown and not drop.QWasDown then
            local now = os.clock()

            if not drop.Busy
                and now - (drop.LastQTriggerAt or 0) >= 0.20
                and not UserInputService:GetFocusedTextBox() then

                drop.LastQTriggerAt = now
                drop.DropOnce()
            end
        end

        drop.QWasDown = qDown
    end))
end

Runtime.DropEggQ.Stop = function()
    local drop = Runtime.DropEggQ
    drop.Enabled = false
    drop.Busy = false
    drop.QWasDown = false
    drop.Generation = (drop.Generation or 0) + 1

    if drop.KeyConnection then
        pcall(function()
            drop.KeyConnection:Disconnect()
        end)
        drop.KeyConnection = nil
    end

    drop.RefreshUI()
end

-- Start the independent Q watcher immediately.
Runtime.DropEggQ.StartKeyWatcher()

--==================================================
-- AUTO GET: TRAVEL + BAG/SLOT CONFIRMATION
--==================================================

Runtime.AutoGet.GetOwnedPlot = getOwnedPlotForLuck

Runtime.AutoGet.TweenHome = function()
    local plot = getOwnedPlotForLuck()
    local root = getRootPart()
    local targetPosition = plot and getTargetPosition(plot) or nil

    Runtime.DebugTeleport("TWEEN", "Tween Home requested", {
        plot = plot and plot:GetFullName() or "nil",
        start = root and root.Position or "nil",
        target = targetPosition or "nil",
        noclipBefore = movementPartsState ~= nil,
    })

    if not plot then
        Runtime.DebugTeleport("TWEEN", "FAILED: owned plot not found")
        return false
    end

    -- Force the smooth movement branch. moveToModel(..., true) keeps noclip
    -- active for the full trip and restores collision after arrival.
    local success = moveToModel(plot, true)
    local finalRoot = getRootPart()
    local destination = targetPosition and (targetPosition + Vector3.new(0, Config.TPHeight, 0)) or nil

    Runtime.DebugTeleport("TWEEN", success and "Tween Home SUCCESS" or "Tween Home FAILED", {
        final = finalRoot and finalRoot.Position or "nil",
        finalDistance = finalRoot and destination and (finalRoot.Position - destination).Magnitude or -1,
        noclipAfter = movementPartsState ~= nil,
        movementActive = movementActive,
    })

    return success
end

Runtime.AutoGet.VoidTeleportHomeImmediate = function()
    -- Dedicated Void-mode Home TP.
    -- Safe Void normally keeps the current character alive. If the user enables
    -- real destroy-height crossing, this also survives the resulting character reset.
    Runtime.DebugTeleport("VOID-HOME", "Dedicated Home TP START")

    stopMovement()
    setNoclip(false)
    zeroMovementVelocity()

    local plot = getOwnedPlotForLuck()
    local targetPosition = plot and getTargetPosition(plot) or nil

    if not plot or not targetPosition then
        Runtime.DebugTeleport("VOID-HOME", "Dedicated Home TP FAILED", {
            reason = not plot and "owned plot missing" or "plot target position missing",
            runtimeAlive = Runtime.Alive,
            autoGetActive = autoFarmActive,
        })
        return false
    end

    local destination = targetPosition + Vector3.new(0, Config.TPHeight, 0)
    local started = os.clock()
    local timeout = math.max(0.6, tonumber(Runtime.AutoGet.HomeRetryTimeout) or 1.5)
    local deadline = started + timeout
    local attempts = 0
    local lastReason = "waiting for live character"
    local attemptsByCharacter = {}
    local sawVoidReset = false
    local previousCharacter = getCharacter()

    while Runtime.Alive and autoFarmActive and os.clock() <= deadline do
        setNoclip(false)

        local character = getCharacter()
        local humanoid = getHumanoid()
        local root = getRootPart()

        if not character or not humanoid or not root or humanoid.Health <= 0 then
            sawVoidReset = true
            lastReason = "void reset in progress; waiting for new root"
            RunService.Heartbeat:Wait()
            continue
        end

        if previousCharacter and character ~= previousCharacter then
            sawVoidReset = true
            Runtime.DebugTeleport("VOID-HOME", "New character detected after void reset", {
                root = root.Position,
                elapsed = os.clock() - started,
            })
        end
        previousCharacter = character

        local distance = (root.Position - destination).Magnitude
        if distance <= 35 then
            zeroMovementVelocity()
            recoverHumanoidFromPhysics()
            setNoclip(false)
            Runtime.DebugTeleport("VOID-HOME", "Dedicated Home TP SUCCESS", {
                attempts = attempts,
                final = root.Position,
                finalDistance = distance,
                naturalRespawn = sawVoidReset,
                elapsed = os.clock() - started,
            })
            return true
        end

        local charAttempts = attemptsByCharacter[character] or 0
        if charAttempts < 2 then
            charAttempts = charAttempts + 1
            attemptsByCharacter[character] = charAttempts
            attempts = attempts + 1

            humanoid.Sit = false
            humanoid.PlatformStand = false
            humanoid.AutoRotate = true
            pcall(function()
                humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
            end)

            Runtime.DebugTeleport("VOID-HOME", "TP attempt", {
                attempt = attempts,
                characterAttempt = charAttempts,
                root = root.Position,
                destination = destination,
                preDistance = distance,
                noclip = movementPartsState ~= nil,
                seated = humanoid.SeatPart ~= nil,
            })

            local moved = pivotControlledAssemblyTo(destination, root.CFrame, true)
            setNoclip(false)
            zeroMovementVelocity()
            recoverHumanoidFromPhysics()

            if not moved then
                lastReason = "PivotTo pcall failed"
                RunService.Heartbeat:Wait()
                continue
            end

            -- Verify only one frame later. Safe Void should remain alive; real-void
            -- mode may invalidate this root, in which case we switch to the respawn.
            RunService.Heartbeat:Wait()

            local afterCharacter = getCharacter()
            local afterHumanoid = getHumanoid()
            local afterRoot = getRootPart()

            if afterCharacter ~= character
                or not afterHumanoid
                or not afterRoot
                or afterHumanoid.Health <= 0 then

                sawVoidReset = true
                lastReason = "old root invalidated by void reset"
                Runtime.DebugTeleport("VOID-HOME", "Old root invalidated; waiting for respawn", {
                    attempt = attempts,
                    elapsed = os.clock() - started,
                })
                continue
            end

            local afterDistance = (afterRoot.Position - destination).Magnitude
            if afterDistance <= 35 then
                zeroMovementVelocity()
                recoverHumanoidFromPhysics()
                setNoclip(false)
                Runtime.DebugTeleport("VOID-HOME", "Dedicated Home TP SUCCESS", {
                    attempts = attempts,
                    final = afterRoot.Position,
                    finalDistance = afterDistance,
                    naturalRespawn = false,
                    elapsed = os.clock() - started,
                })
                return true
            end

            lastReason = string.format("server snapback / too far (%.2f studs)", afterDistance)
        else
            lastReason = "same character already retried; waiting for correction/reset"
            RunService.Heartbeat:Wait()
        end
    end

    setNoclip(false)
    zeroMovementVelocity()
    recoverHumanoidFromPhysics()

    Runtime.DebugTeleport("VOID-HOME", "Dedicated Home TP FAILED", {
        attempts = attempts,
        reason = lastReason,
        runtimeAlive = Runtime.Alive,
        autoGetActive = autoFarmActive,
        sawVoidReset = sawVoidReset,
        elapsed = os.clock() - started,
    })

    return false
end

Runtime.AutoGet.GetInventoryRoots = function(forceRefresh)
    if not forceRefresh
        and Runtime.AutoGet.InventoryRoots
        and os.clock() - (Runtime.AutoGet.InventoryRootsBuiltAt or 0) < 1.25 then
        return Runtime.AutoGet.InventoryRoots
    end

    local roots = {}
    local seen = {}

    local function add(object)
        if object and object.Parent and not seen[object] then
            seen[object] = true
            table.insert(roots, object)
        end
    end

    add(LocalPlayer:FindFirstChildOfClass("Backpack"))
    add(getCharacter())

    -- Exact live egg/slot frame discovered in the game UI. This is separate
    -- from EggTracker.EggsHolder (the static catalog), so it can help confirm
    -- that the picked egg reached the active bag/slot display.
    do
        local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
        local main = playerGui and playerGui:FindFirstChild("Main")
        local tracker = main and main:FindFirstChild("EggTracker")
        local handler = tracker and tracker:FindFirstChild("Handler")
        add(handler and handler:FindFirstChild("EggFrame"))
    end

    local function hasInventoryWord(name)
        local lower = tostring(name or ""):lower()
        return string.find(lower, "inventory", 1, true)
            or string.find(lower, "backpack", 1, true)
            or string.find(lower, "bag", 1, true)
            or string.find(lower, "slot", 1, true)
            or string.find(lower, "hotbar", 1, true)
            or string.find(lower, "storage", 1, true)
            or string.find(lower, "equipped", 1, true)
    end

    local function isBlockedCatalog(object)
        local current = object
        while current and current ~= LocalPlayer do
            local lower = current.Name:lower()
            if lower == "index" or lower == "eggsholder" then
                return true
            end
            current = current.Parent
        end
        return false
    end

    -- Find only top-level inventory-like containers once per refresh window.
    for _, object in ipairs(LocalPlayer:GetDescendants()) do
        if not isBlockedCatalog(object) and hasInventoryWord(object.Name) then
            local parent = object.Parent
            local nested = false

            while parent and parent ~= LocalPlayer do
                if hasInventoryWord(parent.Name) and not isBlockedCatalog(parent) then
                    nested = true
                    break
                end
                parent = parent.Parent
            end

            if not nested then
                add(object)
            end
        end
    end

    Runtime.AutoGet.InventoryRoots = roots
    Runtime.AutoGet.InventoryRootsBuiltAt = os.clock()
    return roots
end

Runtime.AutoGet.CountOwnedEgg = function(eggName, roots)
    local target = tostring(eggName or ""):lower()
    if target == "" then
        return 0
    end

    local count = 0
    local seen = {}

    local function inspect(object)
        if not object or seen[object] then
            return
        end
        seen[object] = true

        if object.Name:lower() == target then
            count = count + 1
            return
        end

        for _, value in pairs(object:GetAttributes()) do
            if tostring(value or ""):lower() == target then
                count = count + 1
                return
            end
        end

        if object:IsA("ObjectValue") then
            local value = object.Value
            if value and tostring(value.Name or ""):lower() == target then
                count = count + 1
                return
            end
        elseif object:IsA("StringValue") then
            if tostring(object.Value or ""):lower() == target then
                count = count + 1
                return
            end
        elseif object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
            local text = tostring(object.Text or ""):lower()
            if text == target or string.find(text, target, 1, true) then
                count = count + 1
                return
            end
        end
    end

    for _, root in ipairs(roots or {}) do
        if root and root.Parent then
            inspect(root)
            for _, object in ipairs(root:GetDescendants()) do
                inspect(object)
            end
        end
    end

    return count
end

Runtime.AutoGet.GetInventorySignature = function(roots)
    local parts = {}

    local function addObject(object)
        if not object or not object.Parent then
            return
        end

        local value = object:GetFullName() .. "|" .. object.ClassName

        if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
            value = value .. "|T=" .. tostring(object.Text or "")
            value = value .. "|V=" .. tostring(object.Visible)
        elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
            value = value .. "|I=" .. tostring(object.Image or "")
            value = value .. "|V=" .. tostring(object.Visible)
        elseif object:IsA("StringValue") then
            value = value .. "|S=" .. tostring(object.Value or "")
        elseif object:IsA("ObjectValue") then
            value = value .. "|O=" .. tostring(object.Value and object.Value:GetFullName() or "nil")
        elseif object:IsA("BoolValue") or object:IsA("IntValue") or object:IsA("NumberValue") then
            value = value .. "|N=" .. tostring(object.Value)
        end

        local attrs = object:GetAttributes()
        local attrNames = {}
        for name in pairs(attrs) do
            table.insert(attrNames, name)
        end
        table.sort(attrNames)
        for _, name in ipairs(attrNames) do
            value = value .. "|A:" .. name .. "=" .. tostring(attrs[name])
        end

        table.insert(parts, value)
    end

    local function shouldFingerprintRoot(root)
        if not root then
            return false
        end

        if root:IsA("Backpack") or root.Name == "EggFrame" then
            return true
        end

        local lower = root.Name:lower()
        return string.find(lower, "inventory", 1, true)
            or string.find(lower, "backpack", 1, true)
            or string.find(lower, "bag", 1, true)
            or string.find(lower, "slot", 1, true)
            or string.find(lower, "hotbar", 1, true)
            or string.find(lower, "storage", 1, true)
            or string.find(lower, "equipped", 1, true)
    end

    for _, root in ipairs(roots or {}) do
        -- Character is still used by the exact-name counter, but it is excluded
        -- from the fingerprint because animation/seat state can change there and
        -- would create a false acquisition signal.
        if root and root.Parent and shouldFingerprintRoot(root) then
            addObject(root)
            for _, object in ipairs(root:GetDescendants()) do
                addObject(object)
            end
        end
    end

    table.sort(parts)
    return table.concat(parts, "\n")
end


Runtime.AutoGet.GetCarrySignature = function()
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local main = playerGui and playerGui:FindFirstChild("Main")
    local tracker = main and main:FindFirstChild("EggTracker")
    local handler = tracker and tracker:FindFirstChild("Handler")
    local eggFrame = handler and handler:FindFirstChild("EggFrame")

    if not eggFrame then
        return "NO_EGG_FRAME"
    end

    local parts = {}

    local function inspect(object)
        if not object then
            return
        end

        local value = object.Name .. "|" .. object.ClassName

        if object:IsA("GuiObject") then
            value = value .. "|V=" .. tostring(object.Visible)
        end

        if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
            value = value .. "|T=" .. tostring(object.Text or "")
        elseif object:IsA("ImageLabel") or object:IsA("ImageButton") then
            value = value .. "|I=" .. tostring(object.Image or "")
        elseif object:IsA("StringValue") then
            value = value .. "|S=" .. tostring(object.Value or "")
        elseif object:IsA("ObjectValue") then
            value = value .. "|O=" .. tostring(object.Value and object.Value:GetFullName() or "nil")
        elseif object:IsA("BoolValue") or object:IsA("IntValue") or object:IsA("NumberValue") then
            value = value .. "|N=" .. tostring(object.Value)
        end

        local attrs = object:GetAttributes()
        local attrNames = {}
        for name in pairs(attrs) do
            table.insert(attrNames, name)
        end
        table.sort(attrNames)

        for _, name in ipairs(attrNames) do
            value = value .. "|A:" .. name .. "=" .. tostring(attrs[name])
        end

        table.insert(parts, value)
    end

    inspect(eggFrame)
    for _, object in ipairs(eggFrame:GetDescendants()) do
        inspect(object)
    end

    table.sort(parts)
    return table.concat(parts, "\n")
end

Runtime.AutoGet.CaptureOwnership = function(eggName)
    local roots = Runtime.AutoGet.GetInventoryRoots(true)
    return {
        Roots = roots,
        Count = Runtime.AutoGet.CountOwnedEgg(eggName, roots),
        Signature = Runtime.AutoGet.GetInventorySignature(roots),
        CarrySignature = Runtime.AutoGet.GetCarrySignature(),
    }
end

Runtime.AutoGet.WaitForOwnershipIncrease = function(eggName, before, timeoutOverride)
    -- STRICT ownership confirmation: only an exact matching egg-count increase
    -- is accepted. Generic inventory fingerprint changes are NOT enough, because
    -- Tween Home tests showed transient UI changes could look like a pickup even
    -- when the egg was later returned by the game.
    local started = os.clock()
    local roots = before and before.Roots or Runtime.AutoGet.GetInventoryRoots(true)
    local beforeCount = before and before.Count or 0
    local timeout = timeoutOverride or Runtime.AutoGet.ConfirmTimeout
    local nextRootRefresh = os.clock() + 0.25
    local finalCount = beforeCount

    Runtime.DebugTeleport("CONFIRM", "STRICT ownership confirmation START", {
        egg = eggName,
        beforeCount = beforeCount,
        watchedRoots = #roots,
        timeout = timeout,
    })

    while Runtime.Alive
        and autoFarmActive
        and os.clock() - started <= timeout do

        if os.clock() >= nextRootRefresh then
            roots = Runtime.AutoGet.GetInventoryRoots(true)
            nextRootRefresh = os.clock() + 0.25
        end

        finalCount = Runtime.AutoGet.CountOwnedEgg(eggName, roots)
        if finalCount > beforeCount then
            Runtime.DebugTeleport("CONFIRM", "STRICT CONFIRMED: exact egg count increased", {
                egg = eggName,
                beforeCount = beforeCount,
                afterCount = finalCount,
                elapsed = os.clock() - started,
            })
            return true, finalCount
        end

        task.wait(Runtime.AutoGet.ConfirmPoll)
    end

    Runtime.DebugTeleport("CONFIRM", "STRICT FAILED: exact egg count did not increase", {
        egg = eggName,
        beforeCount = beforeCount,
        finalCount = finalCount,
        elapsed = os.clock() - started,
        runtimeAlive = Runtime.Alive,
        autoGetActive = autoFarmActive,
    })

    return false, finalCount
end


Runtime.AutoGet.WaitForCarryReady = function(eggName, before, sourceEgg, timeout)
    local started = os.clock()
    local beforeCount = before and before.Count or 0
    local beforeCarrySignature = before and before.CarrySignature or Runtime.AutoGet.GetCarrySignature()
    timeout = timeout or 1.25

    local sourceLeftSince = nil
    local changedSince = nil
    local lastChangedSignature = nil
    local lastCount = beforeCount

    Runtime.DebugTeleport("CONFIRM", "Tween carry-ready check START", {
        egg = eggName,
        beforeCount = beforeCount,
        timeout = timeout,
        sourceValid = sourceEgg ~= nil,
    })

    while Runtime.Alive
        and autoFarmActive
        and os.clock() - started <= timeout do

        local roots = Runtime.AutoGet.GetInventoryRoots(true)
        lastCount = Runtime.AutoGet.CountOwnedEgg(eggName, roots)

        if lastCount > beforeCount then
            Runtime.DebugTeleport("CONFIRM", "Tween carry-ready CONFIRMED: exact egg count increased", {
                egg = eggName,
                beforeCount = beforeCount,
                afterCount = lastCount,
                elapsed = os.clock() - started,
            })
            return true, "count", lastCount
        end

        local sourceLeftRendered = sourceEgg
            and (not sourceEgg.Parent or sourceEgg.Parent ~= RenderedEggsFolder)

        if sourceLeftRendered then
            sourceLeftSince = sourceLeftSince or os.clock()
            if os.clock() - sourceLeftSince >= 0.22 then
                Runtime.DebugTeleport("CONFIRM", "Tween carry-ready CONFIRMED: source egg left RenderedEggs", {
                    egg = eggName,
                    elapsed = os.clock() - started,
                })
                return true, "source-left", lastCount
            end
        else
            sourceLeftSince = nil
        end

        local carrySignature = Runtime.AutoGet.GetCarrySignature()
        if carrySignature ~= beforeCarrySignature then
            if carrySignature == lastChangedSignature then
                changedSince = changedSince or os.clock()
            else
                lastChangedSignature = carrySignature
                changedSince = os.clock()
            end

            if changedSince and os.clock() - changedSince >= 0.30 then
                Runtime.DebugTeleport("CONFIRM", "Tween carry-ready CONFIRMED: live EggFrame changed and stayed stable", {
                    egg = eggName,
                    elapsed = os.clock() - started,
                })
                return true, "eggframe", lastCount
            end
        else
            lastChangedSignature = nil
            changedSince = nil
        end

        task.wait(Runtime.AutoGet.ConfirmPoll)
    end

    -- Some servers do not expose a count/object while the player is still at the egg.
    -- Depart only after a short settle window, then use a strict post-arrival check.
    Runtime.DebugTeleport("CONFIRM", "Tween carry-ready FALLBACK: departing after server settle", {
        egg = eggName,
        beforeCount = beforeCount,
        finalCount = lastCount,
        elapsed = os.clock() - started,
    })

    return true, "settle-fallback", lastCount
end

Runtime.AutoGet.VerifyTweenRetention = function(eggName, before, sourceEgg, carryReason, timeout)
    local started = os.clock()
    local beforeCount = before and before.Count or 0
    local beforeCarrySignature = before and before.CarrySignature or Runtime.AutoGet.GetCarrySignature()
    timeout = timeout or 1.8

    local stableSince = nil
    local lastReason = "no retained signal"

    Runtime.DebugTeleport("CONFIRM", "Tween post-arrival retention START", {
        egg = eggName,
        carryReason = carryReason,
        beforeCount = beforeCount,
        timeout = timeout,
    })

    while Runtime.Alive
        and autoFarmActive
        and os.clock() - started <= timeout do

        local roots = Runtime.AutoGet.GetInventoryRoots(true)
        local currentCount = Runtime.AutoGet.CountOwnedEgg(eggName, roots)

        if currentCount > beforeCount then
            task.wait(0.18)
            roots = Runtime.AutoGet.GetInventoryRoots(true)
            local stableCount = Runtime.AutoGet.CountOwnedEgg(eggName, roots)
            if stableCount > beforeCount then
                Runtime.DebugTeleport("CONFIRM", "Tween post-arrival retention SUCCESS: exact egg count retained", {
                    egg = eggName,
                    beforeCount = beforeCount,
                    finalCount = stableCount,
                    elapsed = os.clock() - started,
                })
                return true
            end
            lastReason = "exact count increase was transient"
        end

        local sourceReturned = sourceEgg
            and sourceEgg.Parent == RenderedEggsFolder

        if sourceReturned and carryReason == "source-left" then
            Runtime.DebugTeleport("CONFIRM", "Tween post-arrival retention FAILED: source egg returned", {
                egg = eggName,
                elapsed = os.clock() - started,
            })
            return false
        end

        local carrySignature = Runtime.AutoGet.GetCarrySignature()
        local carryStillChanged = carrySignature ~= beforeCarrySignature

        if carryStillChanged and not sourceReturned then
            stableSince = stableSince or os.clock()
            if os.clock() - stableSince >= 0.45 then
                Runtime.DebugTeleport("CONFIRM", "Tween post-arrival retention SUCCESS: live carry/slot state stayed changed", {
                    egg = eggName,
                    elapsed = os.clock() - started,
                    carryReason = carryReason,
                })
                return true
            end
            lastReason = "waiting for stable live carry/slot state"
        else
            stableSince = nil
            if sourceReturned then
                lastReason = "source egg is back in RenderedEggs"
            else
                lastReason = "live carry state returned to baseline"
            end
        end

        task.wait(Runtime.AutoGet.ConfirmPoll)
    end

    Runtime.DebugTeleport("CONFIRM", "Tween post-arrival retention FAILED", {
        egg = eggName,
        elapsed = os.clock() - started,
        reason = lastReason,
    })

    return false
end

Runtime.AutoGet.WaitForOwnershipAtLeast = function(eggName, requiredCount, timeout)
    -- Used after Tween Home to make sure the server did not return/remove the egg
    -- while the player was travelling.
    local started = os.clock()
    timeout = timeout or 1.2
    local finalCount = 0

    Runtime.DebugTeleport("CONFIRM", "Post-travel retention check START", {
        egg = eggName,
        requiredCount = requiredCount,
        timeout = timeout,
    })

    while Runtime.Alive
        and autoFarmActive
        and os.clock() - started <= timeout do
        local roots = Runtime.AutoGet.GetInventoryRoots(true)
        finalCount = Runtime.AutoGet.CountOwnedEgg(eggName, roots)

        if finalCount >= requiredCount then
            -- Require the state to remain present briefly instead of accepting a
            -- one-frame/transient UI update.
            task.wait(0.18)
            roots = Runtime.AutoGet.GetInventoryRoots(true)
            local stableCount = Runtime.AutoGet.CountOwnedEgg(eggName, roots)
            if stableCount >= requiredCount then
                Runtime.DebugTeleport("CONFIRM", "Post-travel retention SUCCESS", {
                    egg = eggName,
                    requiredCount = requiredCount,
                    finalCount = stableCount,
                    elapsed = os.clock() - started,
                })
                return true
            end
        end

        task.wait(Runtime.AutoGet.ConfirmPoll)
    end

    Runtime.DebugTeleport("CONFIRM", "Post-travel retention FAILED: egg returned/lost", {
        egg = eggName,
        requiredCount = requiredCount,
        finalCount = finalCount,
        elapsed = os.clock() - started,
    })

    return false
end

Runtime.AutoGet.GetKnownEggNames = function()
    if Runtime.EggIdentity then return Runtime.EggIdentity.Catalog() end
    local names = {}
    local seen = {}

    local function add(name)
        name = tostring(name or "")
        if name ~= "" and not seen[name] then
            seen[name] = true
            table.insert(names, name)
        end
    end

    -- Primary catalog: all eggs known by the game's own Index, even when the
    -- egg is not currently rendered in Workspace.RenderedEggs.
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local main = playerGui and playerGui:FindFirstChild("Main")
    local index = main and main:FindFirstChild("Index")
    local holders = index and index:FindFirstChild("Holders")
    local eggsHolder = holders and holders:FindFirstChild("EggsHolder")

    if eggsHolder then
        for _, entry in ipairs(eggsHolder:GetChildren()) do
            if entry:IsA("GuiObject") and entry:FindFirstChild("ImageLabel") then
                add(entry.Name)
            end
        end
    end

    -- Also include currently rendered eggs in case the Index is still loading.
    if RenderedEggsFolder then
        for _, egg in ipairs(RenderedEggsFolder:GetChildren()) do
            if egg:IsA("Model") or egg:IsA("BasePart") then
                add(egg.Name)
            end
        end
    end

    -- Keep persistent TRUE filters even through temporary catalog/reset gaps.
    for name, enabled in pairs(autoFarmEggs) do
        if enabled == true then
            add(name)
        end
    end

    table.sort(names, function(a, b)
        return a:lower() < b:lower()
    end)

    return names
end

Runtime.AutoGet.HasFilter = function()
    for _, enabled in pairs(autoFarmEggs) do
        if enabled == true then
            return true
        end
    end
    return false
end

--==================================================
-- OPTIONAL TARGET-RANCH DELIVERY (isolated from normal Get Egg)
--==================================================
Runtime.AutoGet.TargetRanch = Runtime.AutoGet.TargetRanch or Runtime.TargetRanch or {
    Enabled=false,
    Active=false,
    Thread=nil,
    TargetUserId=nil,
    UI={},
    LastStatus="OFF",
    Processed=setmetatable({}, {__mode="k"}),
}
Runtime.TargetRanch = Runtime.AutoGet.TargetRanch
Runtime.PathfindingService = Runtime.PathfindingService or game:GetService("PathfindingService")

-- Manual-style travel is used ONLY by the optional Target Ranch branch.
-- The original Get Egg pickup, carry confirmation and normal Tween Home path are untouched.
Runtime.AutoGet.ManualTravelToTargetRanch = function(plot, prompt, targetPlayer, isActive)
    local activeCheck = type(isActive) == "function"
        and isActive
        or function() return autoFarmActive end

    if not plot or not plot.Parent then
        return false, "target Ranch unavailable"
    end

    stopMovement()
    setNoclip(false)
    zeroMovementVelocity()
    recoverHumanoidFromPhysics()

    local character = getCharacter()
    local humanoid = getHumanoid()
    local root = getRootPart()
    if not character or not humanoid or not root or humanoid.Health <= 0 then
        return false, "character unavailable"
    end

    if humanoid.SeatPart then
        humanoid.Sit = false
        humanoid.Jump = true
        task.wait(0.12)
        root = getRootPart()
        if not root then return false, "root unavailable after dismount" end
    end

    local destination = nil
    if prompt and prompt.Parent and Runtime.InputCompat and Runtime.InputCompat.GetPromptWorldPosition then
        destination = Runtime.InputCompat.GetPromptWorldPosition(prompt)
    end
    if not destination then
        destination = getTargetPosition(plot)
    end
    if not destination then
        return false, "target position unavailable"
    end

    -- Keep the final walking point slightly above the Ranch surface/prompt anchor.
    destination = Vector3.new(destination.X, destination.Y + 1.5, destination.Z)

    local overallStarted = os.clock()
    local overallTimeout = 18
    local maxRepaths = 5

    local function waitForMovePoint(point, timeout, blockedCheck)
        humanoid:MoveTo(point)
        local started = os.clock()
        while Runtime.Alive and activeCheck() and humanoid.Parent and humanoid.Health > 0 do
            local currentRoot = getRootPart()
            if not currentRoot then return false, "root lost" end

            local horizontal = Vector3.new(
                point.X - currentRoot.Position.X,
                0,
                point.Z - currentRoot.Position.Z
            ).Magnitude
            local vertical = math.abs(point.Y - currentRoot.Position.Y)
            if horizontal <= 3.5 and vertical <= 7 then
                return true, "reached"
            end

            if blockedCheck and blockedCheck() then
                return false, "path blocked"
            end
            if os.clock() - started >= timeout then
                return false, "waypoint timeout"
            end
            RunService.Heartbeat:Wait()
        end
        return false, "delivery canceled"
    end

    local function recoveryStep(attempt)
        local currentRoot = getRootPart()
        if not currentRoot then return false end

        local delta = destination - currentRoot.Position
        local flat = Vector3.new(delta.X, 0, delta.Z)
        if flat.Magnitude < 0.1 then return true end
        flat = flat.Unit

        local side = Vector3.new(-flat.Z, 0, flat.X)
        if attempt % 2 == 0 then side = -side end

        -- Behave like a player squeezing around a blocker: jump and step sideways,
        -- then let PathfindingService calculate a fresh route.
        humanoid.Jump = true
        pcall(function()
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
        end)

        local recoveryPoint = currentRoot.Position + side * 7 + flat * 4
        humanoid:MoveTo(recoveryPoint)
        local recoverStarted = os.clock()
        while Runtime.Alive and activeCheck()
            and os.clock() - recoverStarted < 0.70 do
            RunService.Heartbeat:Wait()
        end
        return true
    end

    for attempt = 1, maxRepaths do
        if os.clock() - overallStarted >= overallTimeout then
            return false, "manual travel timeout"
        end

        root = getRootPart()
        humanoid = getHumanoid()
        if not root or not humanoid or humanoid.Health <= 0 then
            return false, "character unavailable during travel"
        end

        local directDistance = (root.Position - destination).Magnitude
        if directDistance <= 8 then
            return true, "already at target Ranch"
        end

        local path = Runtime.PathfindingService:CreatePath({
            AgentRadius = 2.2,
            AgentHeight = 5,
            AgentCanJump = true,
            AgentJumpHeight = 8,
            AgentMaxSlope = 48,
            WaypointSpacing = 4,
        })

        local computed = pcall(function()
            path:ComputeAsync(root.Position, destination)
        end)

        if computed and path.Status == Enum.PathStatus.Success then
            local waypoints = path:GetWaypoints()
            local currentWaypointIndex = 2
            local blockedAt = nil
            local blockedConnection = path.Blocked:Connect(function(index)
                if index >= currentWaypointIndex then
                    blockedAt = index
                end
            end)

            local pathOK = true
            for index = 2, #waypoints do
                currentWaypointIndex = index
                local waypoint = waypoints[index]

                if waypoint.Action == Enum.PathWaypointAction.Jump then
                    humanoid.Jump = true
                    pcall(function()
                        humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
                    end)
                end

                local reached, why = waitForMovePoint(
                    waypoint.Position,
                    2.4,
                    function()
                        return blockedAt ~= nil and blockedAt <= index
                    end
                )

                if not reached then
                    pathOK = false
                    Runtime.DebugTeleport("TARGET-RANCH", "Manual waypoint retry", {
                        target = targetPlayer and targetPlayer.Name or "unknown",
                        attempt = attempt,
                        waypoint = index,
                        reason = why,
                    })
                    break
                end

                if not activeCheck() then
                    pathOK = false
                    break
                end
            end

            pcall(function() blockedConnection:Disconnect() end)

            root = getRootPart()
            if pathOK and root and (root.Position - destination).Magnitude <= 10 then
                zeroMovementVelocity()
                recoverHumanoidFromPhysics()
                return true, "manual path complete"
            end
        end

        recoveryStep(attempt)
    end

    local finalRoot = getRootPart()
    return finalRoot ~= nil and (finalRoot.Position - destination).Magnitude <= 10,
        "manual travel retries exhausted"
end

Runtime.AutoGet.GetPlotForPlayer = function(player)
    if not player then return nil end
    local plotsFolder = Workspace:FindFirstChild("Plots")
    if not plotsFolder then return nil end
    for _, plot in ipairs(plotsFolder:GetChildren()) do
        local dataFolder = plot:FindFirstChild("Data")
        local ownerValue = dataFolder and dataFolder:FindFirstChild("Owner")
        if ownerValue then
            local owned = false
            if ownerValue:IsA("StringValue") then
                owned = ownerValue.Value == player.Name
            elseif ownerValue:IsA("ObjectValue") then
                owned = ownerValue.Value == player
            else
                owned = tostring(ownerValue.Value) == player.Name
            end
            if owned then return plot end
        end
    end
    return nil
end

Runtime.AutoGet.GetSelectedTargetPlayer = function()
    local state = Runtime.AutoGet.TargetRanch
    local userId = state and tonumber(state.TargetUserId) or nil
    if not userId then return nil end
    for _, player in ipairs(Players:GetPlayers()) do
        if player ~= LocalPlayer and player.UserId == userId then return player end
    end
    return nil
end

Runtime.AutoGet.FindTargetRanchPlacePrompt = function(plot)
    if not plot or not plot.Parent then return nil end
    local best, bestScore = nil, -math.huge
    local processed = 0
    for _, object in ipairs(plot:GetDescendants()) do
        processed = processed + 1
        if processed % 80 == 0 then RunService.Heartbeat:Wait() end
        if object:IsA("ProximityPrompt") and object.Enabled then
            local textValue = table.concat({
                object.Name or "", object.ActionText or "", object.ObjectText or "",
                object.Parent and object.Parent.Name or ""
            }, " "):lower()
            local score = 0
            if string.find(textValue, "place", 1, true) then score = score + 80 end
            if string.find(textValue, "egg", 1, true) then score = score + 45 end
            if string.find(textValue, "nest", 1, true) then score = score + 25 end
            if string.find(textValue, "drop", 1, true) then score = score + 20 end
            for _, blocked in ipairs({"hatch", "luck", "upgrade", "feed", "ride", "sell", "pickup", "pick up"}) do
                if string.find(textValue, blocked, 1, true) then score = score - 120 end
            end
            if score > bestScore then bestScore, best = score, object end
        end
    end
    return bestScore >= 40 and best or nil
end

Runtime.AutoGet.TryTargetRanchDelivery = function(eggName, beforeOwnership, sourceEgg, carryReason)
    local state = Runtime.AutoGet.TargetRanch
    if not state or not state.Enabled then return false, false end

    local targetPlayer = Runtime.AutoGet.GetSelectedTargetPlayer()
    if not targetPlayer then
        state.LastStatus = "Target unavailable — normal Home fallback"
        return false, false
    end
    local plot = Runtime.AutoGet.GetPlotForPlayer(targetPlayer)
    if not plot then
        state.LastStatus = targetPlayer.Name .. " Ranch not found — normal Home fallback"
        return false, false
    end

    -- Resolve a Place Egg prompt before walking when possible so the manual
    -- route aims at the actual drop location instead of merely the Plot pivot.
    local prompt = Runtime.AutoGet.FindTargetRanchPlacePrompt(plot)

    if StatusLabel then
        StatusLabel.Text = "● Carry ready — walking to " .. targetPlayer.Name .. " Ranch..."
        StatusLabel.TextColor3 = Color3.fromRGB(0, 200, 255)
    end

    local moved, moveReason = Runtime.AutoGet.ManualTravelToTargetRanch(
        plot,
        prompt,
        targetPlayer
    )
    if not moved or not autoFarmActive then
        state.LastStatus = "Target Ranch manual travel failed — normal Home fallback"
        Runtime.DebugTeleport("TARGET-RANCH", "Manual delivery travel failed", {
            target = targetPlayer.Name,
            reason = moveReason,
        })
        return false, false
    end

    task.wait(0.08)

    -- Prompt availability can change while walking. Refresh only once on arrival.
    if not prompt or not prompt.Parent or not prompt.Enabled then
        prompt = Runtime.AutoGet.FindTargetRanchPlacePrompt(plot)
    end
    if not prompt or not prompt.Parent then
        state.LastStatus = "No empty Place Egg prompt — normal Home fallback"
        return false, false
    end

    local eggsFolder = plot:FindFirstChild("Eggs")
    local beforeTargetCount = eggsFolder and #eggsFolder:GetChildren() or nil

    local okInput, inputMethod = Runtime.InputCompat.InteractProximityPromptPortable(
        prompt,
        tonumber(Config.EggPromptExtraHold) or 0.08
    )
    if not okInput then
        state.LastStatus = "Target drop input failed — normal Home fallback"
        return false, false
    end

    local started = os.clock()
    local beforeCarrySignature = beforeOwnership and beforeOwnership.CarrySignature or nil
    while Runtime.Alive and autoFarmActive and os.clock() - started <= 1.6 do
        local carryNow = Runtime.AutoGet.GetCarrySignature()
        local sourceReturned = sourceEgg and sourceEgg.Parent == RenderedEggsFolder
        local carryCleared = beforeCarrySignature and carryNow == beforeCarrySignature
        local targetCountRaised = false
        eggsFolder = plot:FindFirstChild("Eggs")
        if eggsFolder and beforeTargetCount ~= nil then
            targetCountRaised = #eggsFolder:GetChildren() > beforeTargetCount
        end
        if not sourceReturned and (targetCountRaised or (os.clock() - started >= 0.20 and carryCleared)) then
            state.LastStatus = "Delivered to " .. targetPlayer.Name .. " Ranch"
            Runtime.DebugTeleport("TARGET-RANCH", "Get Egg delivered", {
                egg=eggName, target=targetPlayer.Name, input=inputMethod, carryReason=carryReason
            })
            if StatusLabel then
                StatusLabel.Text = "● Delivered " .. eggName .. " to " .. targetPlayer.Name .. " Ranch"
                StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
            end
            return true, true
        end
        task.wait(0.10)
    end

    state.LastStatus = "Drop not confirmed — normal Home fallback"
    return false, false
end

Runtime.AutoGet.TravelAndConfirm = function(eggName, beforeOwnership, sourceEgg)
    Runtime.DebugTeleport("FLOW", "TravelAndConfirm START", {
        egg = eggName,
        mode = Runtime.AutoGet.TravelMode,
        beforeCount = beforeOwnership and beforeOwnership.Count or -1,
    })

    if Runtime.AutoGet.TravelMode == "TweenHome" then
        -- TWEEN MODE:
        -- hold E -> wait briefly for a real carried/slot signal (or server settle)
        -- -> smooth Home with noclip -> verify the egg did not return.
        if StatusLabel then
            StatusLabel.Text = "● Get Egg: securing carry state — " .. eggName
            StatusLabel.TextColor3 = Color3.fromRGB(255, 210, 90)
        end

        local carryReady, carryReason, observedCount = Runtime.AutoGet.WaitForCarryReady(
            eggName,
            beforeOwnership,
            sourceEgg,
            1.25
        )

        Runtime.DebugTeleport("FLOW", carryReady
            and "Pre-tween carry state READY"
            or "Pre-tween carry state FAILED", {
            egg = eggName,
            carryReason = carryReason,
            observedCount = observedCount,
        })

        if not carryReady or not autoFarmActive then
            return false
        end

        if StatusLabel then
            StatusLabel.Text = "● Carry ready — Tween Home..."
            StatusLabel.TextColor3 = Color3.fromRGB(0, 200, 255)
        end

        local traveled = Runtime.AutoGet.TweenHome()
        Runtime.DebugTeleport("FLOW", traveled and "Tween travel SUCCESS" or "Tween travel FAILED", {
            egg = eggName,
            carryReason = carryReason,
        })

        if not traveled or not autoFarmActive then
            return false
        end

        local retained = Runtime.AutoGet.VerifyTweenRetention(
            eggName,
            beforeOwnership,
            sourceEgg,
            carryReason,
            1.8
        )

        Runtime.DebugTeleport("FLOW", retained
            and "Tween ownership retained at Home"
            or "Tween ownership LOST/RETURNED", {
            egg = eggName,
            carryReason = carryReason,
        })

        if StatusLabel then
            if retained then
                StatusLabel.Text = "● Get Egg confirmed at Home: " .. eggName
                StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
            else
                StatusLabel.Text = "● Egg returned during Tween — will retry: " .. eggName
                StatusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
            end
        end

        return retained
    end

    return false -- Only the selected Tween Home return path is supported.
end

local function containsLuckWords(text)

    text = tostring(text or ""):lower()

    return string.find(text, "hatch luck", 1, true)
        or string.find(text, "luck", 1, true)
        or string.find(text, "hatch", 1, true)

end

-- Exact client-visible Hatch Luck display discovered from runtime debug output.
local function getHatchLuckLabel()

    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
    local main = playerGui and playerGui:FindFirstChild("Main")
    local eggTracker = main and main:FindFirstChild("EggTracker")
    local handler = eggTracker and eggTracker:FindFirstChild("Handler")
    local eggFrame = handler and handler:FindFirstChild("EggFrame")
    local luckDisplay = eggFrame and eggFrame:FindFirstChild("LuckDisplay")
    local luckLabel = luckDisplay and luckDisplay:FindFirstChild("Luck")

    if luckLabel and luckLabel:IsA("TextLabel") then
        return luckLabel
    end

    return nil

end

local function getDisplayedHatchLuck()

    local luckLabel = getHatchLuckLabel()

    if not luckLabel then
        return nil
    end

    local text = tostring(luckLabel.Text or "")

    if text == "" then
        return "(blank)"
    end

    return text

end

-- Hatch Luck diagnostics removed after the real Ranch upgrade path was identified.

local function findHatchLuckTarget()
    local plot = getOwnedPlotForLuck()

    if not plot then
        return nil, nil
    end

    -- Runtime scan confirmed this exact Ranch model. Prefer it over generic
    -- egg "Hatch" prompts so the Luck tab never mistakes an egg for the board.
    local hatchUpgrade = plot:FindFirstChild("HatchUpgrade", true)

    if hatchUpgrade and hatchUpgrade:IsA("Model") then
        local bestPrompt = hatchUpgrade:FindFirstChildWhichIsA("ProximityPrompt", true)
        local maxPart = hatchUpgrade:FindFirstChild("MaxUpgrade", true)

        if maxPart and maxPart:IsA("BasePart") then
            return maxPart, bestPrompt
        end

        if hatchUpgrade.PrimaryPart then
            return hatchUpgrade.PrimaryPart, bestPrompt
        end

        for _, object in ipairs(hatchUpgrade:GetDescendants()) do
            if object:IsA("BasePart") then
                return object, bestPrompt
            end
        end

        return hatchUpgrade, bestPrompt
    end

    local bestTarget = nil
    local bestPrompt = nil
    local bestScore = 0

    for _, object in ipairs(plot:GetDescendants()) do
        local score = 0
        local prompt = nil

        if object:IsA("ProximityPrompt") then
            local promptText = tostring(object.Name)
                .. " "
                .. tostring(object.ActionText)
                .. " "
                .. tostring(object.ObjectText)

            local ancestorName = object.Parent and object.Parent:GetFullName():lower() or ""

            if string.find(ancestorName, "upgrade", 1, true)
                and containsLuckWords(promptText) then
                score = 110
                prompt = object
            elseif string.find(promptText:lower(), "upgrade", 1, true) then
                score = 80
                prompt = object
            end
        elseif object:IsA("BasePart") or object:IsA("Model") then
            local name = object.Name:lower()

            if string.find(name, "hatchluck", 1, true)
                or string.find(name, "hatch_luck", 1, true) then
                score = 100
            elseif string.find(name, "luck", 1, true)
                and string.find(name, "upgrade", 1, true) then
                score = 95
            elseif string.find(name, "upgrade", 1, true) then
                score = 50
            end
        end

        if score > bestScore then
            local target = object

            if object:IsA("ProximityPrompt") then
                target = object.Parent

                if target and not (
                    target:IsA("BasePart")
                    or target:IsA("Model")
                ) then
                    target = target:FindFirstAncestorWhichIsA("Model")
                        or target:FindFirstAncestorWhichIsA("BasePart")
                end
            end

            if target and (
                target:IsA("BasePart")
                or target:IsA("Model")
            ) then
                bestScore = score
                bestTarget = target
                bestPrompt = prompt
            end
        end
    end

    if bestTarget and not bestPrompt then
        bestPrompt = bestTarget:FindFirstChildWhichIsA(
            "ProximityPrompt",
            true
        )
    end

    return bestTarget, bestPrompt
end

local function openHatchLuckBoard()

    local target, prompt = findHatchLuckTarget()

    if not target then

        return false, "No Hatch Luck board/prompt was identified in your Ranch."

    end

    local moved = moveToModel(target)

    if not moved then

        return false, "Hatch Luck target was found, but movement failed."

    end

    task.wait(0.25)

    if prompt and prompt.Parent then

        local interacted, method = Runtime.InputCompat.InteractProximityPromptPortable(prompt, 0.08)
        if interacted then
            return true, "Hatch Luck board found and interaction sent via " .. tostring(method) .. "."
        end

    end

    return true, "Hatch Luck target found. Use the game interaction when it appears."

end

local hatchUpgradeRemote = nil

local function getHatchUpgradeRemote()
    if hatchUpgradeRemote and hatchUpgradeRemote.Parent then
        return hatchUpgradeRemote
    end

    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local gameRemotes = remotes and remotes:FindFirstChild("Game")
    local plotRemotes = gameRemotes and gameRemotes:FindFirstChild("Plot")
    local upgrades = plotRemotes and plotRemotes:FindFirstChild("Upgrades")

    if upgrades and upgrades:IsA("RemoteEvent") then
        hatchUpgradeRemote = upgrades
        return upgrades
    end

    return nil
end

-- The game exposes the MAX Hatch Luck option through the Plot.Upgrades
-- RemoteEvent using the exact string argument "Max". This is lighter and
-- more reliable than probing Ranch prompts/click/touch objects.
local function activateHatchUpgradeOnce()
    local event = getHatchUpgradeRemote()

    if not event then
        return false, "Plot.Upgrades remote is not available yet.", "MAX"
    end

    local beforeLuck = getDisplayedHatchLuck()

    local ok, err = pcall(function()
        event:FireServer("Max")
    end)

    if not ok then
        return false, "MAX upgrade request failed: " .. tostring(err), "MAX"
    end

    local message = "MAX Hatch Luck upgrade sent."

    if beforeLuck then
        message = message .. " Displayed luck: " .. tostring(beforeLuck)
    end

    return true, message, "MAX"
end

local function setAutoHatchLuckButtonState()
    if not AutoHatchLuckBtn then
        return
    end

    if autoHatchLuckActive then
        AutoHatchLuckBtn.Text = "Auto Hatch Luck: ON [MAX]"
        AutoHatchLuckBtn.BackgroundColor3 = Color3.fromRGB(0, 145, 85)
        AutoHatchLuckBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    else
        AutoHatchLuckBtn.Text = "Auto Hatch Luck: OFF"
        AutoHatchLuckBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 58)
        AutoHatchLuckBtn.TextColor3 = Color3.fromRGB(220, 228, 238)
    end
end

local function stopAutoHatchLuck()
    autoHatchLuckActive = false

    if autoHatchLuckThread then
        task.cancel(autoHatchLuckThread)
        autoHatchLuckThread = nil
    end

    setAutoHatchLuckButtonState()
end

local function startAutoHatchLuck()
    stopAutoHatchLuck()

    autoHatchLuckActive = true
    setAutoHatchLuckButtonState()

    autoHatchLuckThread = task.spawn(function()
        while Runtime.Alive and autoHatchLuckActive do
            local success, message = activateHatchUpgradeOnce()

            if LuckStatusLabel then
                LuckStatusLabel.Text = message
            end

            if AutoHatchLuckBtn then
                AutoHatchLuckBtn.Text = "Auto Hatch Luck: ON [MAX]"
            end

            if StatusLabel then
                StatusLabel.Text = success
                    and "● Auto Hatch Luck: MAX upgrade sent"
                    or "● Auto Hatch Luck: " .. tostring(message)

                StatusLabel.TextColor3 = success
                    and Color3.fromRGB(0, 255, 120)
                    or Color3.fromRGB(255, 190, 80)
            end

            task.wait(Config.AutoHatchLuckDelay)
        end
    end)
end

--==================================================

-- AUTO BEST EGG

--==================================================

local function holdEKey(duration, target)
    duration = math.max(0.05, tonumber(duration) or 0.05)

    -- Auto Best used to hold the desktop E key blindly. Prefer the exact prompt
    -- under the target Egg so the same action works on touch devices.
    if target and target.Parent then
        local bestPrompt = nil
        local bestScore = -math.huge
        for _, object in ipairs(target:GetDescendants()) do
            if object:IsA("ProximityPrompt") and object.Enabled then
                local textValue = table.concat({
                    object.Name, object.ActionText, object.ObjectText,
                    object.Parent and object.Parent.Name or "",
                }, " "):lower()
                local score = 0
                for _, word in ipairs({"pickup", "pick up", "carry", "get", "take", "grab", "collect", "egg"}) do
                    if string.find(textValue, word, 1, true) then score = score + 20 end
                end
                for _, word in ipairs({"hatch", "place", "nest", "luck", "upgrade", "feed", "ride", "sell", "skip"}) do
                    if string.find(textValue, word, 1, true) then score = score - 100 end
                end
                if score > bestScore then
                    bestScore = score
                    bestPrompt = object
                end
            end
        end

        if bestPrompt then
            local extra = math.max(0, duration - (tonumber(bestPrompt.HoldDuration) or 0))
            return Runtime.InputCompat.InteractProximityPromptPortable(bestPrompt, extra)
        end

        -- If this build handles the Egg through world touch/tool input instead of
        -- a prompt, tap/click the target's projected screen position.
        local camera = Workspace.CurrentCamera
        local position = getTargetPosition(target)
        if camera and position then
            local point, onScreen = camera:WorldToViewportPoint(position)
            if onScreen then
                return Runtime.InputCompat.SendAdaptiveScreenPress(point.X, point.Y, duration)
            end
        end
    end

    -- Last-resort desktop-only compatibility. Mobile never depends on E.
    if not Runtime.InputCompat.IsTouchPreferred() then
        local ok, err = pcall(function()
            VirtualInputManager:SendKeyEvent(true, Enum.KeyCode.E, false, game)
            task.wait(duration)
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
        end)
        return ok, ok and "desktop E fallback" or tostring(err)
    end

    return false, "no portable target interaction available"
end



--==================================================
-- GET EGG: TARGETED ANGLE-INDEPENDENT PICKUP
--==================================================
-- Resolve ONLY a ProximityPrompt under the exact rendered egg target. This
-- removes camera/facing-angle dependence and prevents another visible prompt
-- from stealing the Get Egg E-hold.
Runtime.AutoGet.FindPickupPromptForEgg = function(egg)
    if not egg or not egg.Parent or egg.Parent ~= RenderedEggsFolder then
        return nil, "target egg unavailable"
    end

    local bestPrompt = nil
    local bestScore = -math.huge

    local function promptScore(prompt)
        if not prompt or not prompt:IsA("ProximityPrompt") or not prompt.Parent then
            return -math.huge
        end

        local textValue = table.concat({
            prompt.Name,
            prompt.ActionText,
            prompt.ObjectText,
            prompt.Parent and prompt.Parent.Name or "",
            egg.Name,
        }, " "):lower()

        local score = prompt.Enabled and 20 or -200
        for _, word in ipairs({"pickup", "pick up", "pick-up", "carry", "get", "take", "grab", "collect"}) do
            if string.find(textValue, word, 1, true) then
                score = score + 80
            end
        end
        if string.find(textValue, "egg", 1, true) then
            score = score + 15
        end
        if prompt.KeyboardKeyCode == Enum.KeyCode.E then
            score = score + 5
        end

        for _, word in ipairs({"hatch", "place", "nest", "luck", "upgrade", "feed", "ride", "mount", "sell", "skip", "grow"}) do
            if string.find(textValue, word, 1, true) then
                score = score - 250
            end
        end
        return score
    end

    for _, object in ipairs(egg:GetDescendants()) do
        if object:IsA("ProximityPrompt") then
            local score = promptScore(object)
            if score > bestScore then
                bestScore = score
                bestPrompt = object
            end
        end
    end

    if bestPrompt and bestScore > -100 then
        return bestPrompt, "target egg prompt"
    end
    return nil, "no enabled pickup prompt under target egg"
end

Runtime.AutoGet.ActivateTargetEggPrompt = function(egg, requestedHold)
    if not egg or not egg.Parent or egg.Parent ~= RenderedEggsFolder then
        return false, "target egg unavailable"
    end

    local prompt = nil
    local findReason = "prompt not checked"
    local promptDeadline = os.clock() + 0.65
    repeat
        prompt, findReason = Runtime.AutoGet.FindPickupPromptForEgg(egg)
        if prompt then break end
        task.wait(0.04)
    until not Runtime.Alive or not autoFarmActive or not egg.Parent or os.clock() >= promptDeadline

    if not prompt or not prompt.Parent or not prompt:IsDescendantOf(egg) then
        return false, findReason or "target pickup prompt unavailable"
    end

    local function getPromptPosition(targetPrompt)
        local current = targetPrompt and targetPrompt.Parent
        while current do
            if current:IsA("Attachment") then
                return current.WorldPosition
            elseif current:IsA("BasePart") then
                return current.Position
            elseif current:IsA("Model") then
                local okPivot, pivot = pcall(function() return current:GetPivot() end)
                if okPivot and pivot then
                    return pivot.Position
                end
            end
            if current == egg then break end
            current = current.Parent
        end
        return getTargetPosition(egg)
    end

    local root = getRootPart()
    local promptPosition = getPromptPosition(prompt)
    local maxDistance = math.max(2, tonumber(prompt.MaxActivationDistance) or 10)

    -- Keep both the player and mounted pet non-collidable while approaching and
    -- holding the exact target prompt. This is deliberately scoped to Auto Get.
    Runtime.AutoGet.SetPickupNoclip(true)

    if root and promptPosition and (root.Position - promptPosition).Magnitude > math.max(2, maxDistance - 0.75) then
        local moved = moveToModel(egg, true)
        if not moved then
            return false, "could not reach target egg prompt"
        end
        task.wait(0.05)
        root = getRootPart()
        promptPosition = getPromptPosition(prompt)
        Runtime.AutoGet.SetPickupNoclip(true)
    end

    if not root or not promptPosition or (root.Position - promptPosition).Magnitude > maxDistance + 1.5 then
        return false, "outside target egg prompt range"
    end
    if not prompt.Enabled then
        return false, "target egg prompt disabled"
    end

    -- Face the mounted/controlled assembly toward the real prompt position.
    -- This avoids relying on whichever direction the pet happened to be facing.
    local flatTarget = Vector3.new(promptPosition.X, root.Position.Y, promptPosition.Z)
    if (flatTarget - root.Position).Magnitude > 0.05 then
        pcall(function()
            pivotControlledAssemblyTo(
                root.Position,
                CFrame.lookAt(root.Position, flatTarget),
                false
            )
        end)
        zeroMovementVelocity()
        root = getRootPart() or root
    end

    local hold = math.max(0.05, tonumber(requestedHold) or 0, tonumber(prompt.HoldDuration) or 0)
    local oldRequiresLineOfSight = prompt.RequiresLineOfSight
    pcall(function() prompt.RequiresLineOfSight = false end)

    local function restorePrompt()
        if prompt and prompt.Parent then
            pcall(function() prompt.RequiresLineOfSight = oldRequiresLineOfSight end)
        end
    end

    -- Alternative to executor prompt firing: use Roblox's documented hold API.
    -- This is input delivery only; server carry/ownership confirmation remains mandatory.
    if Runtime.AutoGet.PickupMethod == "PromptHold" then
        if not Runtime.Weight.GetAllowed(egg) then
            restorePrompt()
            return false, "egg below minimum kg"
        end
        if (root.Position - promptPosition).Magnitude > maxDistance then
            restorePrompt()
            return false, "outside normal pickup range"
        end
        local began, why = pcall(function() prompt:InputHoldBegin() end)
        if not began then
            restorePrompt()
            return false, tostring(why)
        end
        local deadline = os.clock() + hold + 0.1
        while Runtime.Alive and autoFarmActive and prompt.Parent and os.clock() < deadline do
            zeroMovementVelocity()
            task.wait(0.05)
        end
        pcall(function() if prompt.Parent then prompt:InputHoldEnd() end end)
        restorePrompt()
        return Runtime.Alive and autoFarmActive, "normal prompt hold sent; awaiting carry confirmation"
    end



    local firePrompt = fireproximityprompt
    if type(firePrompt) == "function" then
        local okFire, fireErr = pcall(function()
            firePrompt(prompt, hold)
        end)
        restorePrompt()
        if okFire then
            return true, "target fireproximityprompt"
        end
        Runtime.DebugTeleport("GET-EGG", "fireproximityprompt failed; using direct prompt fallback", {
            egg = egg.Name,
            error = tostring(fireErr),
        })
    end

    local began = pcall(function() prompt:InputHoldBegin() end)
    if began then
        local started = os.clock()
        while Runtime.Alive and autoFarmActive and prompt.Parent and os.clock() - started < hold do
            task.wait(math.min(0.05, math.max(0.01, hold - (os.clock() - started))))
        end
        pcall(function()
            if prompt and prompt.Parent then prompt:InputHoldEnd() end
        end)
        restorePrompt()
        return autoFarmActive, autoFarmActive and "target InputHoldBegin/InputHoldEnd" or "Get Egg stopped during prompt hold"
    end

    local portableOk, portableMethod = Runtime.InputCompat.InteractProximityPromptPortable(
        prompt,
        math.max(0, hold - (tonumber(prompt.HoldDuration) or 0))
    )
    restorePrompt()
    if not portableOk then
        return false, "target portable prompt failed: " .. tostring(portableMethod)
    end
    return autoFarmActive, autoFarmActive
        and ("target portable prompt via " .. tostring(portableMethod))
        or "Get Egg stopped during prompt interaction"
end

Runtime.AutoGet.UnequipAfterPickupSignal = function(sourceEgg, timeout)
    local deadline = os.clock() + math.max(0.15, tonumber(timeout) or 0.70)
    while Runtime.Alive and autoFarmActive and sourceEgg and sourceEgg.Parent == RenderedEggsFolder and os.clock() < deadline do
        task.wait(0.035)
    end

    if sourceEgg and sourceEgg.Parent == RenderedEggsFolder then
        return false, "source egg still rendered"
    end

    local humanoid = getHumanoid()
    if not humanoid or humanoid.Health <= 0 then
        return false, "humanoid unavailable"
    end

    local okUnequip = pcall(function() humanoid:UnequipTools() end)
    return okUnequip, okUnequip and "egg/tool unequipped after pickup" or "UnequipTools failed"
end

Runtime.AutoGet.UnequipConfirmedEgg = function()
    local humanoid = getHumanoid()
    if not humanoid or humanoid.Health <= 0 then return false end
    return pcall(function() humanoid:UnequipTools() end)
end

--==================================================
-- EGG AUTOMATION: BAG/SLOT -> NEST -> HATCH
--==================================================

do
local EGG_RARITY_RANK = {
    Unknown = 0,
    Common = 10,
    Uncommon = 20,
    Rare = 30,
    Epic = 40,
    Legendary = 50,
    Mythic = 60,
    Divine = 70,
    Ethereal = 80,
}

-- Fallback only. Live rarity metadata/text from the bag/slot always overrides this.
local KNOWN_EGG_RARITY = {
    ["whiteegg"] = "Common",
    ["brownegg"] = "Common",
    ["crackedegg"] = "Rare",
    ["easteregg"] = "Rare",
    ["stoneegg"] = "Rare",
    ["leafegg"] = "Rare",
    ["mushroomegg"] = "Epic",
    ["floweregg"] = "Epic",
    ["slimeegg"] = "Epic",
    ["iceegg"] = "Epic",
    ["glassegg"] = "Legendary",
    ["goldenegg"] = "Legendary",
    ["crystalegg"] = "Mythic",
    ["skullegg"] = "Mythic",
    ["dominusegg"] = "Mythic",
    ["flamingegg"] = "Mythic",
    ["sinisteregg"] = "Mythic",
    ["soulegg"] = "Mythic",
    ["auroraegg"] = "Divine",
    ["galaxyegg"] = "Divine",
    ["blackholeegg"] = "Ethereal",
    ["solarisegg"] = "Ethereal",
    ["solaris"] = "Ethereal", -- compatibility if the live name omits "Egg"
    ["cherubegg"] = "Ethereal",
}

-- Verified public luck ladder fallback. Live client-visible Luck/Clover metadata
-- always overrides this table when available. Cherub (1T) therefore outranks
-- Black Hole (100B) even though both are Ethereal.
Runtime.EggAutomation.KnownEggLuck = {
    ["whiteegg"] = 1,
    ["brownegg"] = 5,
    ["crackedegg"] = 30,
    ["easteregg"] = 50,
    ["stoneegg"] = 100,
    ["leafegg"] = 200,
    ["mushroomegg"] = 500,
    ["floweregg"] = 750,
    ["slimeegg"] = 1000,
    ["iceegg"] = 3000,
    ["glassegg"] = 10000,
    ["goldenegg"] = 30000,
    ["crystalegg"] = 150000,
    ["skullegg"] = 250000,
    ["dominusegg"] = 700000,
    ["flamingegg"] = 1000000,
    ["sinisteregg"] = 3000000,
    ["soulegg"] = 7000000,
    ["auroraegg"] = 300000000,
    ["galaxyegg"] = 1500000000,
    ["blackholeegg"] = 100000000000,
    ["solarisegg"] = 300000000000,
    ["solaris"] = 300000000000, -- compatibility if the live name omits "Egg"
    ["cherubegg"] = 1000000000000,
}

-- Human-readable fallback names used only when the live Index is not ready yet.
-- Runtime.AutoGet.GetKnownEggNames() remains the PRIMARY source and automatically
-- includes future eggs exposed by Main.Index.Holders.EggsHolder.
Runtime.EggAutomation.KnownEggFallbackNames = {
    "White Egg", "Brown Egg", "Cracked Egg", "Easter Egg", "Striped Egg", "Lotus Egg", "Stone Egg", "Leaf Egg",
    "Mushroom Egg", "Flower Egg", "Slime Egg", "Ice Egg", "Glass Egg", "Golden Egg",
    "Crystal Egg", "Skull Egg", "Dominus Egg", "Flaming Egg", "Sinister Egg", "Soul Egg",
    "Aurora Egg", "Galaxy Egg", "Blackhole Egg", "Solaris Egg", "Cherub Egg",
}

-- One identity layer for display names, model names and replicated metadata.
Runtime.EggIdentity = {CatalogAt=-10, Names={}, Keys={}, Cache=setmetatable({}, {__mode="k"})}
Runtime.EggIdentity.Key = function(value)
    return tostring(value or ""):gsub("<[^>]*>", ""):lower():gsub("[^%w]", ""):gsub("egg$", "")
end
Runtime.EggIdentity.Catalog = function()
    local id = Runtime.EggIdentity
    if os.clock() - id.CatalogAt < 2 then return id.Names end
    local names, seen = {}, {}
    local function add(name)
        if type(name) ~= "string" then return end
        name = name:gsub("<[^>]*>", ""):match("^%s*(.-)%s*$")
        local key = id.Key(name)
        if key ~= "" and not seen[key] then seen[key]=true; table.insert(names,name) end
    end
    for _, name in ipairs(Runtime.EggAutomation.KnownEggFallbackNames or {}) do add(name) end
    local gui = LocalPlayer:FindFirstChild("PlayerGui")
    local main = gui and gui:FindFirstChild("Main")
    local index = main and main:FindFirstChild("Index")
    local holder = index and index:FindFirstChild("EggsHolder", true)
    -- No ImageLabel requirement: a locked/new catalog card is still an egg.
    if holder then
        for _, item in ipairs(holder:GetDescendants()) do
            if item:IsA("GuiObject") then
                local name = item.Name
                if name:lower():match("egg%s*$") and not ({egg=true,eggframe=true,eggholder=true})[name:lower()] then add(name) end
                for _, attr in ipairs({"EggName", "EggType"}) do
                    local value = item:GetAttribute(attr)
                    if type(value)=="string" then add(value) end
                end
                if item:IsA("TextLabel") and item.Text:match("^[%a%s%-]+[Ee]gg%s*$") then add(item.Text) end
            end
        end
        for _, item in ipairs(holder:GetChildren()) do
            if item:IsA("GuiObject") and (seen[id.Key(item.Name)] or item:FindFirstChildWhichIsA("ImageLabel", true)) then add(item.Name) end
        end
    end
    table.sort(names, function(a,b) return a:lower()<b:lower() end)
    id.Names, id.Keys, id.CatalogAt = names, {}, os.clock()
    for _, name in ipairs(names) do table.insert(id.Keys, {Key=id.Key(name), Name=name}) end
    table.sort(id.Keys,function(a,b) return #a.Key>#b.Key end)
    return names
end
Runtime.EggIdentity.Resolve = function(egg)
    local id=Runtime.EggIdentity
    id.Catalog()
    local cached=id.Cache[egg]
    if cached and cached.Raw==egg.Name and os.clock()-cached.At<2 then return cached.Key,cached.Name end
    local function match(value)
        if type(value)~="string" then return nil end
        local text=value:gsub("<[^>]*>", ""):lower():gsub("[^%w]", "")
        for _, entry in ipairs(id.Keys) do
            if id.Key(value)==entry.Key or text:find(entry.Key.."egg",1,true) then return entry.Key,entry.Name end
        end
    end
    local function ownedUI(item)
        local parent=item
        while parent and parent~=egg do
            if parent.Name=="EggESP_Info" then return true end
            parent=parent.Parent
        end
        return false
    end
    local function explicit(item)
        for _, attr in ipairs({"EggName","EggType","TypeName","DisplayName"}) do
            local k,n=match(item:GetAttribute(attr)); if k then return k,n end
        end
        local key=item.Name:lower():gsub("[^%a]", "")
        local parent=item.Parent
        local info=parent and parent.Name:lower()=="egginfo"
        if item:IsA("StringValue") and
            (({eggname=true,eggtype=true,displayname=true,egg=true})[key] or (info and (key=="name" or key=="type"))) then
            return match(item.Value)
        end
    end
    local key,name=explicit(egg)
    local descendants
    if not key then
        descendants=egg:GetDescendants()
        for _, item in ipairs(descendants) do
            if not ownedUI(item) then key,name=explicit(item); if key then break end end
        end
    end
    -- A template model name can be White Egg while its live metadata identifies
    -- another egg. Read native metadata/labels before that fallback.
    if not key then
        for _, item in ipairs(descendants or {}) do
            if not ownedUI(item) and (item:IsA("TextLabel") or item:IsA("TextButton")) then
                key,name=match(item.Text); if key then break end
            end
        end
    end
    if not key then key,name=match(egg.Name) end
    id.Cache[egg]={Raw=egg.Name,At=os.clock(),Key=key,Name=name}
    return key,name
end
Runtime.EggIdentity.GetSelected = function(egg)
    local key=Runtime.EggIdentity.Resolve(egg)
    return key~=nil and autoFarmEggs[key]==true
end

local function normalizeEggKey(value)
    return tostring(value or ""):lower():gsub("[^%w]", "")
end

local function isEggNameFilterEnabled(filterTable, eggName)
    if type(filterTable) ~= "table" then
        return false
    end
    local key = normalizeEggKey(eggName)
    return key ~= "" and filterTable[key] == true
end

local function setEggNameFilterEnabled(filterTable, eggName, enabled)
    if type(filterTable) ~= "table" then
        return
    end
    local key = normalizeEggKey(eggName)
    if key ~= "" then
        filterTable[key] = enabled == true

        -- Enabling/disabling an Auto Place egg changes which cached slots are
        -- eligible. Invalidate once; the next Auto Place pass rebuilds only then.
        if filterTable == EggAutoState.PlaceEggFilters
            and Runtime.EggAutomation
            and type(Runtime.EggAutomation.MarkBagCacheDirty) == "function" then
            Runtime.EggAutomation.MarkBagCacheDirty("Place filter changed: " .. tostring(eggName))
        end
    end
end

local function anyEggNameFilterEnabled(filterTable)
    if type(filterTable) ~= "table" then
        return false
    end
    for _, enabled in pairs(filterTable) do
        if enabled == true then
            return true
        end
    end
    return false
end

local function getAutomationKnownEggNames()
    local names = {}
    local seen = {}

    local function add(name)
        name = tostring(name or "")
        local key = normalizeEggKey(name)
        if name ~= "" and key ~= "" and not seen[key] then
            seen[key] = true
            table.insert(names, name)
        end
    end

    -- PRIMARY SOURCE: current game's own Index + currently rendered eggs.
    for _, name in ipairs(Runtime.AutoGet.GetKnownEggNames()) do
        add(name)
    end

    -- Fallback only for the brief period before the Index finishes loading.
    for _, name in ipairs(Runtime.EggAutomation.KnownEggFallbackNames or {}) do
        add(name)
    end

    table.sort(names, function(a, b)
        return a:lower() < b:lower()
    end)
    return names
end

local function canonicalRarity(value)
    local text = tostring(value or ""):lower()
    if text == "" then
        return nil
    end

    if string.find(text, "ethereal", 1, true) then return "Ethereal" end
    if string.find(text, "divine", 1, true) then return "Divine" end
    if string.find(text, "mythic", 1, true) or string.find(text, "mythical", 1, true) then return "Mythic" end
    if string.find(text, "legendary", 1, true) then return "Legendary" end
    if string.find(text, "epic", 1, true) then return "Epic" end
    if string.find(text, "uncommon", 1, true) then return "Uncommon" end
    if string.find(text, "rare", 1, true) then return "Rare" end
    if string.find(text, "common", 1, true) then return "Common" end
    return nil
end

-- v3.47: Only explicit weight metadata or kg-labelled text counts as weight.
-- Official prompt timing reference: https://create.roblox.com/docs/ui/proximity-prompts
Runtime.Weight = {}
Runtime.Weight.Parse = function(value, allowBare)
    if type(value) == "number" then
        if allowBare and value == value and value >= 0 and value < math.huge then return value end
        return nil
    end
    local text = tostring(value or ""):lower():gsub("<[^>]*>", ""):gsub(",", "")
    if text:match("%-%s*%d") then return nil end
    local number, suffix
    if allowBare then
        number, suffix = text:match("^%s*(%d*%.?%d+)%s*([kmbt]?)%s*$")
    end
    if not number then
        number, suffix = text:match("(%d*%.?%d+)%s*([kmbt]?)%s*kgs?%f[%A]")
    end
    local parsed = tonumber(number)
    if not parsed then return nil end
    local scale = ({k=1e3, m=1e6, b=1e9, t=1e12})[suffix] or 1
    parsed = parsed * scale
    if parsed ~= parsed or parsed < 0 or parsed == math.huge then return nil end
    return parsed
end
Runtime.Weight.Allows = function(weight, minimum)
    minimum = tonumber(minimum) or 0
    return minimum == 0 or (type(weight) == "number" and weight >= minimum and weight < math.huge)
end
local function parseKg(value)
    return Runtime.Weight.Parse(value, true)
end

Runtime.EggAutomation.ParseLuckNumber = function(value)
    if type(value) == "number" then
        return value
    end

    local text = tostring(value or ""):lower():gsub(",", "")
    local function scaled(numberText, suffix)
        local number = tonumber(numberText)
        if not number then return nil end
        suffix = tostring(suffix or ""):lower()
        local multiplier = suffix == "k" and 1e3
            or suffix == "m" and 1e6
            or suffix == "b" and 1e9
            or suffix == "t" and 1e12
            or 1
        return number * multiplier
    end

    local numberText, suffix = text:match("luck[^%d]*([%d%.]+)%s*([kmbt]?)")
    if not numberText then
        numberText, suffix = text:match("([%d%.]+)%s*([kmbt]?)%s*luck")
    end
    if not numberText then
        numberText, suffix = text:match("clover[^%d]*([%d%.]+)%s*([kmbt]?)")
    end
    if not numberText and string.find(text, "🍀", 1, true) then
        numberText, suffix = text:match("([%d%.]+)%s*([kmbt]?)")
    end

    return scaled(numberText, suffix)
end

local function objectTextValues(object, includeDescendants)
    local values = {}
    local seen = {}

    local function add(value)
        value = tostring(value or "")
        if value ~= "" and not seen[value] then
            seen[value] = true
            table.insert(values, value)
        end
    end

    local function inspect(item)
        if not item then return end
        add(item.Name)

        if item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
            add(item.Text)
        elseif item:IsA("StringValue") then
            add(item.Value)
        elseif item:IsA("ObjectValue") and item.Value then
            add(item.Value.Name)
        elseif item:IsA("NumberValue") or item:IsA("IntValue") then
            add(item.Value)
        end

        for name, value in pairs(item:GetAttributes()) do
            add(name)
            add(value)
            add(name .. "=" .. tostring(value))
        end
    end

    inspect(object)
    if includeDescendants then
        local descendants = object:GetDescendants()
        for index, item in ipairs(descendants) do
            if index > 40 then break end
            inspect(item)
        end
    end

    return values
end

local function getKnownEggLookup()
    local names = Runtime.AutoGet.GetKnownEggNames()
    table.sort(names, function(a, b)
        return #a > #b
    end)
    return names
end

local function extractEggName(object, knownNames)
    local values = objectTextValues(object, true)

    for _, knownName in ipairs(knownNames) do
        local lowerKnown = knownName:lower()
        for _, value in ipairs(values) do
            if string.find(value:lower(), lowerKnown, 1, true) then
                return knownName
            end
        end
    end

    local objectName = tostring(object and object.Name or "")
    local lowerName = objectName:lower()
    if string.find(lowerName, "egg", 1, true)
        and lowerName ~= "egg"
        and lowerName ~= "eggframe"
        and lowerName ~= "eggs"
        and lowerName ~= "eggtracker" then
        return objectName
    end

    return nil
end

local function extractRarity(object, eggName)
    local attrs = object:GetAttributes()
    for name, value in pairs(attrs) do
        if string.find(name:lower(), "rarity", 1, true) then
            local rarity = canonicalRarity(value)
            if rarity then return rarity end
        end
    end

    for _, value in ipairs(objectTextValues(object, true)) do
        local rarity = canonicalRarity(value)
        if rarity then return rarity end
    end

    return KNOWN_EGG_RARITY[normalizeEggKey(eggName)] or "Unknown"
end

Runtime.EggAutomation.ExtractLuck = function(object, eggName)
    local best = nil

    local function consider(value)
        local luck = Runtime.EggAutomation.ParseLuckNumber(value)
        if luck and luck >= 0 and (not best or luck > best) then
            best = luck
        end
    end

    for name, value in pairs(object:GetAttributes()) do
        local lower = tostring(name):lower()
        if string.find(lower, "luck", 1, true) or string.find(lower, "clover", 1, true) then
            consider(tostring(name) .. "=" .. tostring(value))
            consider(value)
        end
    end

    for _, value in ipairs(objectTextValues(object, true)) do
        local lower = tostring(value):lower()
        if string.find(lower, "luck", 1, true)
            or string.find(lower, "clover", 1, true)
            or string.find(value, "🍀", 1, true) then
            consider(value)
        end
    end

    return best or Runtime.EggAutomation.KnownEggLuck[normalizeEggKey(eggName)] or 0
end

-- Live world egg metadata is replicated separately from Workspace.RenderedEggs.
-- Current Ride A Pet clients expose it at ReplicatedStorage.ServerData.ActiveEggs.
-- v3.56 indexes that folder once per short interval instead of scanning every
-- ActiveEgg for every rendered egg, which removes a major source of frame spikes.
Runtime.LiveEggData = Runtime.LiveEggData or {
    Cache=setmetatable({}, {__mode="k"}),
    General=nil,
    GeneralChecked=false,
    IndexAt=-10,
    Records={},
    ByKey={},
    IndexBuilds=0,
    IndexDirty=true,
    WatchedFolder=nil,
    WatchConnections={},
}
Runtime.LiveEggData.GetFolder = function()
    local serverData = ReplicatedStorage:FindFirstChild("ServerData")
    return serverData and serverData:FindFirstChild("ActiveEggs") or nil
end
Runtime.LiveEggData.GetGeneral = function()
    local live = Runtime.LiveEggData
    if live.GeneralChecked then return live.General end
    live.GeneralChecked = true
    local gameData = ReplicatedStorage:FindFirstChild("GameData")
    local module = gameData and gameData:FindFirstChild("General")
    if module and module:IsA("ModuleScript") then
        local ok, result = pcall(require, module)
        if ok and type(result) == "table" then live.General = result end
    end
    return live.General
end
Runtime.LiveEggData.ShownKG = function(rawWeight)
    local raw = tonumber(rawWeight)
    if not raw then return nil end
    local general = Runtime.LiveEggData.GetGeneral()
    if general and type(general.ShownEggKG) == "function" then
        local ok, value = pcall(general.ShownEggKG, raw)
        if ok and type(value) == "number" then return value end
    end
    return raw
end
Runtime.LiveEggData.ClearWatchers = function()
    local live = Runtime.LiveEggData
    for _, connection in ipairs(live.WatchConnections or {}) do
        pcall(function() connection:Disconnect() end)
    end
    live.WatchConnections = {}
    live.WatchedFolder = nil
end
Runtime.LiveEggData.EnsureWatchers = function(folder)
    local live = Runtime.LiveEggData
    if live.WatchedFolder == folder then return end
    live.ClearWatchers()
    live.WatchedFolder = folder
    live.IndexDirty = true
    if not folder then return end

    local function dirty()
        if Runtime.Alive then
            live.IndexDirty = true
        end
    end
    table.insert(live.WatchConnections, folder.ChildAdded:Connect(dirty))
    table.insert(live.WatchConnections, folder.ChildRemoved:Connect(dirty))
end
Runtime.LiveEggData.RefreshIndex = function(force)
    local live = Runtime.LiveEggData
    local now = os.clock()
    local refreshInterval = math.max(5, tonumber(Config.LiveEggIndexRefresh) or 15.00)
    local folder = live.GetFolder()
    live.EnsureWatchers(folder)

    if not force and not live.IndexDirty
        and now - (live.IndexAt or -10) < refreshInterval then
        return live.Records
    end

    local records, byKey = {}, {}
    if folder then
        for _, object in ipairs(folder:GetChildren()) do
            local eggName = object:GetAttribute("Egg")
            local position = object:GetAttribute("Position")
            if type(eggName) == "string" and eggName ~= "" and typeof(position) == "Vector3" then
                local key = Runtime.EggIdentity.Key(eggName)
                local rawWeight = object:GetAttribute("Weight")
                local record = {
                    Object=object, ID=object.Name, Egg=eggName, Key=key,
                    Position=position, RawWeight=rawWeight,
                    KG=live.ShownKG(rawWeight),
                    Mutation=object:GetAttribute("Mutation"),
                    SpawnMutation=object:GetAttribute("SpawnMutation"),
                    Source="ReplicatedStorage.ServerData.ActiveEggs",
                }
                table.insert(records, record)
                if key ~= "" then
                    byKey[key] = byKey[key] or {}
                    table.insert(byKey[key], record)
                end
            end
        end
    end

    live.Records = records
    live.ByKey = byKey
    live.IndexAt = now
    live.IndexDirty = false
    live.IndexBuilds = (live.IndexBuilds or 0) + 1
    return records
end
Runtime.LiveEggData.RefreshMappedRecord = function(cached, egg)
    local live = Runtime.LiveEggData
    local object = cached and cached.Object
    if not object or not object.Parent then return nil end

    local position = object:GetAttribute("Position")
    local targetPosition = getTargetPosition(egg)
    if typeof(position) == "Vector3" and targetPosition then
        local delta = (position - targetPosition).Magnitude
        if delta > 14 then return nil end
        cached.Position = position
        cached.Delta = delta
    end

    cached.At = os.clock()
    cached.ID = object.Name
    cached.Egg = object:GetAttribute("Egg") or cached.Egg
    cached.RawWeight = object:GetAttribute("Weight")
    cached.KG = live.ShownKG(cached.RawWeight)
    cached.Mutation = object:GetAttribute("Mutation")
    cached.SpawnMutation = object:GetAttribute("SpawnMutation")
    cached.Source = "ReplicatedStorage.ServerData.ActiveEggs"
    return cached
end
Runtime.LiveEggData.FindForRendered = function(egg, force)
    if not egg then return nil end
    local live = Runtime.LiveEggData
    local cached = live.Cache[egg]
    local now = os.clock()

    -- Once a rendered egg is mapped to its authoritative ActiveEgg object, reuse
    -- that exact object and read its changing attributes directly. This keeps
    -- weight/mutation fresh without rebuilding the entire ActiveEgg index every second.
    if not force and cached and cached.Object and cached.Object.Parent then
        local refreshed = live.RefreshMappedRecord(cached, egg)
        if refreshed then return refreshed end
        live.IndexDirty = true
    elseif not force and cached and not cached.Object
        and not live.IndexDirty and now - (cached.At or 0) < 1.25 then
        return cached
    end

    if cached and not cached.Object and now - (cached.At or 0) >= 1.25 then
        -- A newly replicated ActiveEgg may have received attributes just after
        -- ChildAdded. One recovery rebuild is allowed for a stale miss.
        live.IndexDirty = true
    end
    live.RefreshIndex(force == true)
    if #live.Records == 0 then
        cached = {At=now, Source="ActiveEggs-missing"}
        live.Cache[egg] = cached
        return cached
    end

    local targetPosition = getTargetPosition(egg)
    local resolvedKey = select(1, Runtime.EggIdentity.Resolve(egg))
    local rawKey = Runtime.EggIdentity.Key(egg.Name)
    local candidates = live.ByKey[resolvedKey or ""] or live.ByKey[rawKey] or live.Records
    local best, bestDelta = nil, math.huge

    for _, record in ipairs(candidates) do
        if record.Object and record.Object.Parent and typeof(record.Position) == "Vector3" then
            local delta = targetPosition and (record.Position - targetPosition).Magnitude or math.huge
            if delta < bestDelta then
                best = record
                bestDelta = delta
            end
        end
    end

    if best and bestDelta <= 14 then
        cached = {
            At=now, Object=best.Object, ID=best.ID, Egg=best.Egg,
            Position=best.Position, Delta=bestDelta, RawWeight=best.RawWeight,
            KG=best.KG, Mutation=best.Mutation, SpawnMutation=best.SpawnMutation,
            Source=best.Source,
        }
        cached = live.RefreshMappedRecord(cached, egg) or cached
    else
        cached = {At=now, Source="ActiveEggs-no-position-match", Delta=bestDelta}
    end
    live.Cache[egg] = cached
    return cached
end
Runtime.LiveEggData.MutationLabel = function(info)
    if type(info) ~= "table" then return "Unknown" end
    local out, seen = {}, {}
    for _, value in ipairs({info.Mutation, info.SpawnMutation}) do
        value = tostring(value or ""):match("^%s*(.-)%s*$")
        if value ~= "" and value:lower() ~= "none" and not seen[value:lower()] then
            seen[value:lower()] = true
            table.insert(out, value)
        end
    end
    return #out > 0 and table.concat(out, " + ") or "None"
end

Runtime.Weight.Read = function(object)
    if not object then return nil, "nil-object" end
    if RenderedEggsFolder and object.Parent == RenderedEggsFolder
        and Runtime.LiveEggData and Runtime.LiveEggData.FindForRendered then
        local liveInfo = Runtime.LiveEggData.FindForRendered(object)
        if liveInfo and type(liveInfo.KG) == "number" then
            return liveInfo.KG, "ActiveEggs:" .. tostring(liveInfo.ID) .. ".Weight(raw=" .. tostring(liveInfo.RawWeight) .. ")"
        end
    end
    local function fullName(item)
        local ok, value = pcall(function() return item:GetFullName() end)
        return ok and value or tostring(item)
    end
    local function inspect(item)
        for name, value in pairs(item:GetAttributes()) do
            local key = tostring(name):lower():gsub("[^%a]", "")
            if key == "weight" or key == "weightkg" or key == "kg" or key == "eggweight" then
                local kg = Runtime.Weight.Parse(value, true)
                if kg then return kg, "attribute:" .. fullName(item) .. "." .. tostring(name) end
            end
        end
        local key = item.Name:lower():gsub("[^%a]", "")
        if item:IsA("ValueBase") and (key == "weight" or key == "weightkg" or key == "kg" or key == "eggweight") then
            local kg = Runtime.Weight.Parse(item.Value, true)
            if kg then return kg, "value:" .. fullName(item) end
        end
        if item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
            local kg = Runtime.Weight.Parse(item.Text, false)
            if kg then return kg, "text:" .. fullName(item) end
        elseif item:IsA("ProximityPrompt") then
            local kg = Runtime.Weight.Parse(item.ObjectText, false)
            if kg then return kg, "prompt-object:" .. fullName(item) end
            kg = Runtime.Weight.Parse(item.ActionText, false)
            if kg then return kg, "prompt-action:" .. fullName(item) end
        end
        local kg = Runtime.Weight.Parse(item.Name, false)
        if kg then return kg, "name:" .. fullName(item) end
        return nil, nil
    end
    local function isOwnedESPUI(item)
        local parent = item
        while parent and parent ~= object do
            if parent.Name == "EggESP_Info" then return true end
            parent = parent.Parent
        end
        return false
    end

    local kg, source = inspect(object)
    if kg then return kg, source end
    for _, item in ipairs(object:GetDescendants()) do
        if not isOwnedESPUI(item) then
            kg, source = inspect(item)
            if kg then return kg, source end
        end
    end
    return nil, "not-found"
end
Runtime.Weight.GetAllowed = function(egg)
    return Runtime.Weight.Allows(Runtime.Weight.Read(egg), Runtime.AutoGet.MinWeightKg)
end

-- Resolve Auto Place weight from the whole LIVE SLOT CONTEXT, not only from the
-- exact child that happened to contain the egg name. Ride A Pet commonly puts
-- the egg name and kg text on sibling GuiObjects inside the same slot/button.
Runtime.EggAutomation.ResolveCandidateWeight = function(candidate)
    if type(candidate) ~= "table" then
        return nil, "invalid-candidate"
    end

    local checked = {}

    local function read(object, label)
        if not object or not object.Parent or checked[object] then
            return nil, nil
        end
        checked[object] = true

        local kg, source = Runtime.Weight.Read(object)
        if type(kg) == "number" then
            return kg, tostring(label or "object") .. ":" .. tostring(source or "weight")
        end
        return nil, nil
    end

    -- Best context first: GuiButton/Tool normally owns all sibling labels for
    -- the selected slot, so its descendants include both name and kg.
    local kg, source = read(candidate.Interactable, "interactable")
    if kg then return kg, source end

    kg, source = read(candidate.Source, "source")
    if kg then return kg, source end

    -- If the source is a label nested under a slot frame, check only nearby
    -- parents. Stop before EggFrame/EggTracker so we never steal another slot's
    -- weight from the full basket container.
    local current = candidate.Source and candidate.Source.Parent or nil
    for depth = 1, 3 do
        if not current or not current.Parent then break end
        local lower = current.Name:lower()
        if lower == "eggframe"
            or lower == "eggtracker"
            or lower == "handler"
            or lower == "eggsholder" then
            break
        end

        kg, source = read(current, "parent" .. tostring(depth))
        if kg then return kg, source end
        current = current.Parent
    end

    return nil, "slot-weight-not-found"
end

Runtime.Weight.PlaceAllowed = function(candidate)
    local minimum = tonumber(EggAutoState.PlaceMinWeightKg) or 0

    -- 0 means kg filtering is disabled. Do not make Auto Place depend on weight
    -- discovery at all in this mode.
    if minimum <= 0 then
        return true
    end

    local weight = type(candidate) == "table" and tonumber(candidate.WeightKg) or nil
    if not weight or weight <= 0 then
        local source
        weight, source = Runtime.EggAutomation.ResolveCandidateWeight(candidate)
        if type(candidate) == "table" then
            candidate.WeightKg = weight or 0
            candidate.WeightSource = source
        end
    end

    return type(weight) == "number"
        and weight >= minimum
        and weight < math.huge
end

local function extractWeightKg(object)
    return Runtime.Weight.Read(object) or 0
end

local function getCandidateInteractable(object)
    if not object then return nil end

    if object:IsA("Tool") or object:IsA("GuiButton") then
        return object
    end

    local ancestor = object.Parent
    while ancestor and ancestor ~= LocalPlayer do
        if ancestor:IsA("Tool") or ancestor:IsA("GuiButton") then
            return ancestor
        end
        ancestor = ancestor.Parent
    end

    for _, descendant in ipairs(object:GetDescendants()) do
        if descendant:IsA("GuiButton") then
            return descendant
        end
    end

    return object
end

local function candidateInteractPriority(object)
    if not object then return 0 end
    if object:IsA("Tool") then return 30 end
    if object:IsA("GuiButton") then return 20 end
    if object:IsA("GuiObject") then return 10 end
    return 1
end

-- v3.67 RANCH-SMOOTH: incremental descendant traversal. Heavy discovery work
-- is spread across Heartbeats so a large Ranch/bag cannot monopolize one frame.
Runtime.EggAutomation.ForEachDescendantYielded = function(root, callback, batchSize)
    if not root or not root.Parent or type(callback) ~= "function" then return end
    local queue = root:GetChildren()
    local index = 1
    local processed = 0
    local batch = math.max(12, tonumber(batchSize) or 28)
    while Runtime.Alive and index <= #queue do
        local object = queue[index]
        index = index + 1
        if object and object.Parent then
            callback(object)
            for _, child in ipairs(object:GetChildren()) do
                table.insert(queue, child)
            end
        end
        processed = processed + 1
        if processed % batch == 0 then
            RunService.Heartbeat:Wait()
        end
    end
end

Runtime.EggAutomation.ScanBagSlots = function(forceRefresh)
    local now = os.clock()

    -- Do not rebuild the whole bag every poll interval. Reuse cached exact slot
    -- references until a real bag/filter change or a stale slot invalidates them.
    if not forceRefresh
        and not Runtime.EggAutomation.BagCacheDirty
        and Runtime.EggAutomation.LastBagScan then
        local validator = Runtime.EggAutomation.ValidateCachedBagCandidates
        if type(validator) == "function" then
            local cached, clean = validator()
            if clean then return cached end
        else
            return Runtime.EggAutomation.LastBagScan
        end
    end

    local roots = Runtime.AutoGet.GetInventoryRoots(false)
    if type(Runtime.EggAutomation.EnsureBagWatchers) == "function" then
        Runtime.EggAutomation.EnsureBagWatchers(roots)
    end
    local knownNames = getKnownEggLookup()
    local candidatesByKey = {}

    local function looksLikeCandidateObject(object)
        if not object or not object.Parent then return false end
        if object:IsA("Tool") or object:IsA("GuiButton") then return true end
        local lower = object.Name:lower()
        -- EggFrame is the whole live basket/tracker container, not a single egg.
        -- Parsing it as one candidate can pair the first egg label with the first
        -- unrelated button. Its real slot/button descendants are scanned below.
        if lower == "eggframe" or lower == "eggtracker" or lower == "eggsholder" then
            return false
        end
        return string.find(lower, "egg", 1, true) ~= nil
            or string.find(lower, "slot", 1, true) ~= nil
    end

    local function consider(object)
        if not looksLikeCandidateObject(object) then return end
        if object == getCharacter() or object:IsA("Backpack") then return end

        local eggName = extractEggName(object, knownNames)
        if not eggName then return end

        local interactable = getCandidateInteractable(object)
        if not interactable or not interactable.Parent then return end

        local rarity = extractRarity(object, eggName)
        local luck = Runtime.EggAutomation.ExtractLuck(object, eggName)

        local candidate = {
            Name = eggName,
            Rarity = rarity,
            Luck = luck,
            WeightKg = 0,
            WeightSource = "unresolved",
            Source = object,
            Interactable = interactable,
            RarityRank = EGG_RARITY_RANK[rarity] or 0,
        }

        local resolvedWeight, resolvedWeightSource =
            Runtime.EggAutomation.ResolveCandidateWeight(candidate)
        candidate.WeightKg = resolvedWeight or 0
        candidate.WeightSource = resolvedWeightSource or "slot-weight-not-found"

        local key = normalizeEggKey(eggName)
            .. "|" .. tostring(rarity)
            .. "|" .. string.format("%.4f", luck)
            .. "|" .. string.format("%.4f", candidate.WeightKg)

        local previous = candidatesByKey[key]
        if not previous
            or candidateInteractPriority(interactable) > candidateInteractPriority(previous.Interactable) then
            candidatesByKey[key] = candidate
        end
    end

    -- IMPORTANT: do not run the old O(N x descendants) deep inspection against
    -- every inventory object. Only likely egg/tool/slot containers are parsed.
    for _, root in ipairs(roots) do
        if root and root.Parent then
            consider(root)
            Runtime.EggAutomation.ForEachDescendantYielded(root, function(object)
                if looksLikeCandidateObject(object) then
                    consider(object)
                end
            end, 24)
        end
    end

    local candidates = {}
    for _, candidate in pairs(candidatesByKey) do
        -- v3.39 STRICT AUTO PLACE FILTER: eligibility is per egg NAME and completely
        -- independent from Auto Hatch. Every egg is OFF until explicitly enabled.
        if isEggNameFilterEnabled(EggAutoState.PlaceEggFilters, candidate.Name)
            and Runtime.Weight.PlaceAllowed(candidate) then
            table.insert(candidates, candidate)
        end
    end

    -- Fixed priority among the ENABLED Auto Place eggs: highest LUCK first, then rarity, then KG.
    -- This intentionally puts Cherub (1T) ahead of Black Hole (100B).
    EggAutoState.PriorityEnabled = true
    table.sort(candidates, function(a, b)
        local aLuck = tonumber(a.Luck) or 0
        local bLuck = tonumber(b.Luck) or 0
        if math.abs(aLuck - bLuck) > 0.0001 then
            return aLuck > bLuck
        end
        if a.RarityRank ~= b.RarityRank then
            return a.RarityRank > b.RarityRank
        end
        if math.abs(a.WeightKg - b.WeightKg) > 0.0001 then
            return a.WeightKg > b.WeightKg
        end
        return a.Name:lower() < b.Name:lower()
    end)

    Runtime.EggAutomation.LastBagScan = candidates
    Runtime.EggAutomation.LastBagScanAt = now
    Runtime.EggAutomation.BagCacheDirty = false
    Runtime.EggAutomation.BagCacheDirtyReason = nil
    return candidates
end

Runtime.EggAutomation.MarkBagCacheDirty = function(reason)
    Runtime.EggAutomation.BagCacheDirty = true
    Runtime.EggAutomation.BagCacheDirtyReason = tostring(reason or "bag changed")
    Runtime.EggAutomation.LastBagScanAt = 0
    Runtime.EggAutomation.WakeSerial = (Runtime.EggAutomation.WakeSerial or 0) + 1
end

Runtime.EggAutomation.EnsureBagWatchers = function(roots)
    local watched = Runtime.EggAutomation.BagWatchedRoots
    if type(watched) ~= "table" then
        watched = setmetatable({}, {__mode = "k"})
        Runtime.EggAutomation.BagWatchedRoots = watched
    end

    for _, root in ipairs(roots or {}) do
        if root and root.Parent and not watched[root] then
            watched[root] = true

            local function invalidate(child)
                if not Runtime.Alive then return end
                if os.clock() < (Runtime.EggAutomation.BagEventMuteUntil or 0) then
                    return
                end
                local relevant = root:IsA("Backpack")
                    or root.Name == "EggFrame"
                    or (child and child:IsA("Tool"))
                    or string.find(root.Name:lower(), "slot", 1, true) ~= nil
                    or string.find(root.Name:lower(), "bag", 1, true) ~= nil
                    or string.find(root.Name:lower(), "hotbar", 1, true) ~= nil
                if relevant then
                    Runtime.EggAutomation.MarkBagCacheDirty("bag/slot object changed")
                end
            end

            if root:IsA("Backpack") then
                trackRuntimeConnection(root.ChildAdded:Connect(invalidate))
                trackRuntimeConnection(root.ChildRemoved:Connect(invalidate))
            elseif root.Name == "EggFrame" then
                trackRuntimeConnection(root.DescendantAdded:Connect(invalidate))
                trackRuntimeConnection(root.DescendantRemoving:Connect(invalidate))
            else
                trackRuntimeConnection(root.ChildAdded:Connect(invalidate))
                trackRuntimeConnection(root.ChildRemoved:Connect(invalidate))
            end
        end
    end
end

Runtime.EggAutomation.ValidateCachedBagCandidates = function()
    local list = Runtime.EggAutomation.LastBagScan
    if type(list) ~= "table" then
        Runtime.EggAutomation.MarkBagCacheDirty("bag cache missing")
        return {}, false
    end
    -- v3.67: no time-based forced full scan. Backpack/EggFrame structural
    -- watchers mark the cache dirty immediately; cached candidates are also
    -- validated live below. This removes the old 5-second Ranch hitch.
    if #list == 0 then return list, true end

    local knownNames = getKnownEggLookup()
    local valid = {}
    local stale = false

    for _, candidate in ipairs(list) do
        local source = candidate and candidate.Source
        local interactable = candidate and candidate.Interactable
        local live = source and source.Parent and interactable and interactable.Parent

        if live and isEggNameFilterEnabled(EggAutoState.PlaceEggFilters, candidate.Name)
            and Runtime.Weight.PlaceAllowed(candidate) then
            -- Validate ONLY the cached source/slot, never the whole bag tree.
            local detectedName = extractEggName(source, knownNames)
            if not detectedName and interactable ~= source then
                detectedName = extractEggName(interactable, knownNames)
            end
            if normalizeEggKey(detectedName or candidate.Name) == normalizeEggKey(candidate.Name) then
                table.insert(valid, candidate)
            else
                stale = true
            end
        elseif live then
            -- Disabled Place filter: simply omit this cached candidate.
        else
            stale = true
        end
    end

    Runtime.EggAutomation.LastBagScan = valid
    if stale then
        Runtime.EggAutomation.BagCacheDirty = true
        Runtime.EggAutomation.BagCacheDirtyReason = "cached slot became stale"
    end
    return valid, not stale
end

Runtime.EggAutomation.GetPlaceFilterSummary = function()
    local minKg = tonumber(EggAutoState.PlaceMinWeightKg) or 0
    local enabledCount = 0
    for _, enabled in pairs(EggAutoState.PlaceEggFilters or {}) do
        if enabled == true then
            enabledCount = enabledCount + 1
        end
    end
    return enabledCount, minKg
end

Runtime.EggAutomation.SetPlaceMinWeight = function(value)
    local parsed = Runtime.Weight.Parse(value, true)
    if type(parsed) ~= "number" then
        return false, "invalid kg"
    end

    EggAutoState.PlaceMinWeightKg = math.max(0, parsed)

    -- IMPORTANT: a previous high minimum may have removed lower-weight entries
    -- from LastBagScan. Drop the filtered cache entirely whenever Min kg changes.
    Runtime.EggAutomation.LastBagScan = {}
    Runtime.EggAutomation.LastBagScanAt = 0
    Runtime.EggAutomation.BagCacheDirty = true
    Runtime.EggAutomation.BagCacheDirtyReason = "Place Min kg changed"
    Runtime.EggAutomation.WakeSerial = (Runtime.EggAutomation.WakeSerial or 0) + 1
    Runtime.EggAutomation.NextPlaceAttemptAt = 0

    return true, EggAutoState.PlaceMinWeightKg
end

Runtime.EggAutomation.GetPlaceMinWeight = function()
    return tonumber(EggAutoState.PlaceMinWeightKg) or 0
end

Runtime.EggAutomation.GetPlaceCandidatesLight = function(forceRefresh)
    if forceRefresh then
        return Runtime.EggAutomation.ScanBagSlots(true)
    end

    if not Runtime.EggAutomation.BagCacheDirty then
        local cached, clean = Runtime.EggAutomation.ValidateCachedBagCandidates()
        if clean then return cached end
    end

    -- Recovery-only full discovery: after this, exact slot refs are reused.
    return Runtime.EggAutomation.ScanBagSlots(true)
end

local function getPromptSearchText(prompt)
    local parts = {
        prompt.Name,
        prompt.ActionText,
        prompt.ObjectText,
        prompt.Parent and prompt.Parent.Name or "",
    }
    local current = prompt.Parent
    for _ = 1, 3 do
        if current and current.Parent then
            current = current.Parent
            table.insert(parts, current.Name)
        end
    end
    return table.concat(parts, " "):lower()
end

-- HARD PROMPT SAFETY FILTER. Auto Place / Auto Hatch must never trigger ranch-wide
-- actions such as "Skip All Egg". This guard is deliberately checked during
-- discovery AND again immediately before input is sent.
local function isBlockedEggAutomationPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then
        return true, "invalid prompt"
    end

    local text = getPromptSearchText(prompt)
    local blockedPhrases = {
        "skip all egg",
        "skip all eggs",
        "skip all",
        "grow all egg",
        "grow all eggs",
        "grow all",
        "hatch all",
        "open all",
        "crack all",
        "collect all",
        "claim all",
        "remove all",
        "sell all",
        "feed all",
    }

    for _, phrase in ipairs(blockedPhrases) do
        if string.find(text, phrase, 1, true) then
            return true, phrase
        end
    end

    -- Extra mass-action guard in case the game slightly renames the button, e.g.
    -- "Skip All Eggs Now" or "All Eggs Skip". Only block when BOTH an
    -- all/mass word and an egg-action word are present.
    local hasAll = string.find(text, "all", 1, true) ~= nil
    local hasEggAction = string.find(text, "egg", 1, true) ~= nil
        and (string.find(text, "skip", 1, true) ~= nil
            or string.find(text, "grow", 1, true) ~= nil
            or string.find(text, "hatch", 1, true) ~= nil
            or string.find(text, "open", 1, true) ~= nil
            or string.find(text, "crack", 1, true) ~= nil
            or string.find(text, "collect", 1, true) ~= nil
            or string.find(text, "claim", 1, true) ~= nil)

    if hasAll and hasEggAction then
        return true, "mass egg action"
    end

    return false, "allowed individual egg prompt"
end

local function looksLikePlaceEggPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then
        return false
    end
    local blocked = isBlockedEggAutomationPrompt(prompt)
    if blocked then
        return false
    end

    local text = getPromptSearchText(prompt)
    if string.find(text, "hatch", 1, true)
        or string.find(text, "luck", 1, true)
        or string.find(text, "upgrade", 1, true) then
        return false
    end
    return (string.find(text, "place", 1, true) and string.find(text, "egg", 1, true))
        or (string.find(text, "place", 1, true) and string.find(text, "nest", 1, true))
end

local function isPlaceEggPrompt(prompt)
    return prompt and prompt.Enabled and looksLikePlaceEggPrompt(prompt)
end

local function looksLikeHatchEggPrompt(prompt)
    if not prompt or not prompt:IsA("ProximityPrompt") then
        return false
    end

    local blocked = isBlockedEggAutomationPrompt(prompt)
    if blocked then
        return false
    end

    local text = getPromptSearchText(prompt)
    if string.find(text, "luck", 1, true)
        or string.find(text, "upgrade", 1, true)
        or string.find(text, "max", 1, true)
        or string.find(text, "place", 1, true) then
        return false
    end

    -- Current/alternate builds may label the ready action Hatch, Open Egg, or
    -- Crack Egg. Keep the match egg-specific so unrelated Open prompts are ignored.
    return string.find(text, "hatch", 1, true) ~= nil
        or (string.find(text, "open", 1, true) ~= nil and string.find(text, "egg", 1, true) ~= nil)
        or (string.find(text, "crack", 1, true) ~= nil and string.find(text, "egg", 1, true) ~= nil)
end

local function isHatchEggPrompt(prompt)
    return prompt and prompt.Enabled and looksLikeHatchEggPrompt(prompt)
end

-- Some current servers use a generic interaction label on a finished egg instead
-- of literally writing "Hatch". If an ENABLED prompt lives under Plot.Eggs, it is
-- treated as a hatch-ready fallback unless its text clearly belongs to another
-- action. This keeps Auto Hatch working across small prompt-label changes.
local function isPlacedEggHatchFallbackPrompt(prompt, plot)
    if not prompt or not prompt.Parent or not prompt:IsA("ProximityPrompt") or not prompt.Enabled then
        return false
    end

    local eggsFolder = plot and plot:FindFirstChild("Eggs")
    if not eggsFolder or not prompt:IsDescendantOf(eggsFolder) then
        return false
    end

    local blocked, blockedReason = isBlockedEggAutomationPrompt(prompt)
    if blocked then
        return false
    end

    local text = getPromptSearchText(prompt)
    local blockedWords = {
        "place", "luck", "upgrade", "max", "ride", "mount",
        "pickup", "pick up", "carry", "remove", "cancel", "sell", "feed",
        "skip", "grow",
    }
    for _, word in ipairs(blockedWords) do
        if string.find(text, word, 1, true) then
            return false
        end
    end

    return true
end

local function getPromptPart(prompt)
    local current = prompt and prompt.Parent
    while current do
        if current:IsA("BasePart") then
            return current
        end
        current = current.Parent
    end
    return nil
end

local function getNestAnchor(prompt, plot)
    if not prompt then return nil end

    -- Use the nearest physical BasePart as the slot anchor. The previous code
    -- could climb to a broad Nests/Ranch container when individual slots had
    -- numeric/generic names; then a Hatch prompt in ONE occupied nest made every
    -- neighboring Place prompt look occupied.
    local part = getPromptPart(prompt)
    if part and (not plot or part:IsDescendantOf(plot)) then
        return part
    end

    -- Model-only fallback for unusual prompt hierarchies with no BasePart parent.
    local current = prompt.Parent
    while current and current ~= plot do
        if current:IsA("Model") then
            return current
        end
        current = current.Parent
    end

    return prompt.Parent
end

local function getNestKey(prompt, plot)
    local anchor = getNestAnchor(prompt, plot)
    if not anchor then return "unknown" end
    return anchor:GetFullName()
end

local function getEntryPosition(entry)
    if entry and entry.Part and entry.Part.Parent then
        return entry.Part.Position
    end
    return nil
end

local function isTruthyValue(value)
    if value == true then return true end
    if type(value) == "number" then return value ~= 0 end
    local text = tostring(value or ""):lower()
    return text == "true" or text == "yes" or text == "1" or text == "occupied"
end

local function anchorReportsOccupied(anchor)
    if not anchor or not anchor.Parent then return true end

    -- STRICT but LOCAL occupancy only. Never inherit a Plot/Nests-level HasEgg
    -- flag, because that describes the ranch as a whole and can falsely block
    -- every empty neighboring slot.
    for name, value in pairs(anchor:GetAttributes()) do
        local lower = tostring(name):lower()
        if lower == "occupied"
            or lower == "isoccupied"
            or lower == "hasegg"
            or lower == "eggplaced"
            or lower == "inuse" then
            if isTruthyValue(value) then
                return true
            end
        end
    end

    for _, child in ipairs(anchor:GetChildren()) do
        local lower = child.Name:lower()
        if lower == "occupied"
            or lower == "isoccupied"
            or lower == "hasegg"
            or lower == "eggplaced" then
            if child:IsA("BoolValue") and child.Value == true then
                return true
            elseif child:IsA("ObjectValue") and child.Value ~= nil then
                return true
            elseif child:IsA("StringValue") and child.Value ~= "" and child.Value:lower() ~= "false" then
                return true
            elseif (child:IsA("IntValue") or child:IsA("NumberValue")) and child.Value ~= 0 then
                return true
            end
        end
    end

    return false
end

local function entryHasOccupiedEggSignal(entry)
    if not entry or not entry.Prompt or not entry.Prompt.Parent then
        return true, "prompt missing"
    end
    if not entry.Prompt.Enabled or not isPlaceEggPrompt(entry.Prompt) then
        return true, "place prompt disabled/invalid"
    end
    if not entry.Part or not entry.Part.Parent then
        return true, "prompt part missing"
    end

    local anchor = entry.Anchor
    if anchorReportsOccupied(anchor) then
        return true, "nest reports occupied"
    end

    -- v3.63 LOW-FREEZE: use the already-built Ranch snapshot instead of doing
    -- anchor:GetDescendants() for every candidate/poll. A matching Hatch entry
    -- means this nest is occupied. Otherwise an enabled Place prompt is accepted.
    local snapshot = Runtime.EggAutomation.RanchSnapshot
    if snapshot and snapshot.Plot == (entry.Plot or getStrictOwnedPlot()) then
        for _, hatchEntry in ipairs(snapshot.HatchPrompts or {}) do
            if hatchEntry.Key == entry.Key and hatchEntry.Prompt and hatchEntry.Prompt.Parent and hatchEntry.Prompt.Enabled then
                return true, "cached hatch prompt indicates occupied nest"
            end
        end
    end

    return false, "empty live place prompt"
end

local function isEntryValidForPlacement(entry)
    local occupied, reason = entryHasOccupiedEggSignal(entry)
    return not occupied, reason
end

Runtime.EggAutomation.InvalidateRanchSnapshot = function(reason)
    Runtime.EggAutomation.RanchSnapshotDirty = true
    Runtime.EggAutomation.RanchBoundsCache = nil
    Runtime.EggAutomation.NextHatchWakeAt = 0
    Runtime.EggAutomation.RanchSnapshotDirtyReason = tostring(reason or "Ranch changed")
    Runtime.EggAutomation.RanchSnapshotAt = 0
end

-- v3.63 LOW-FREEZE: keep one lightweight watcher on the owned Ranch. The old
-- worker rebuilt plot:GetDescendants() every ~1 second even while nothing changed.
-- Now a deep snapshot is rebuilt only after egg/nest/prompt topology changes or a
-- long safety interval. Existing prompt Enabled changes are handled by the live
-- Place watcher during an actual placement attempt.
Runtime.EggAutomation.ClearRanchWatchers = function()
    for _, connection in ipairs(Runtime.EggAutomation.RanchWatchConnections or {}) do
        pcall(function() connection:Disconnect() end)
    end
    Runtime.EggAutomation.RanchWatchConnections = {}
    Runtime.EggAutomation.RanchWatchedPlot = nil
end

Runtime.EggAutomation.EnsureRanchWatchers = function(plot)
    if not plot or not plot.Parent then return end
    if Runtime.EggAutomation.RanchWatchedPlot == plot then return end

    Runtime.EggAutomation.ClearRanchWatchers()
    Runtime.EggAutomation.RanchWatchedPlot = plot

    local function addConnection(connection)
        if connection then
            table.insert(Runtime.EggAutomation.RanchWatchConnections, connection)
            table.insert(Runtime.Connections, connection)
        end
    end

    local function relevant(object)
        if not object then return false end
        if object:IsA("ProximityPrompt") then return true end
        local lower = object.Name:lower()
        return string.find(lower, "egg", 1, true) ~= nil
            or string.find(lower, "nest", 1, true) ~= nil
            or string.find(lower, "slot", 1, true) ~= nil
            or string.find(lower, "capacity", 1, true) ~= nil
    end

    addConnection(plot.DescendantAdded:Connect(function(object)
        if relevant(object) then
            Runtime.EggAutomation.InvalidateRanchSnapshot("Ranch relevant descendant added")
        end
    end))
    addConnection(plot.DescendantRemoving:Connect(function(object)
        if relevant(object) then
            Runtime.EggAutomation.InvalidateRanchSnapshot("Ranch relevant descendant removed")
        end
    end))

    local eggsFolder = plot:FindFirstChild("Eggs")
    if eggsFolder then
        addConnection(eggsFolder.ChildAdded:Connect(function()
            Runtime.EggAutomation.InvalidateRanchSnapshot("Plot.Eggs child added")
        end))
        addConnection(eggsFolder.ChildRemoved:Connect(function()
            Runtime.EggAutomation.InvalidateRanchSnapshot("Plot.Eggs child removed")
        end))
    end
end

Runtime.EggAutomation.GetRanchSnapshot = function(forceRefresh)
    local now = os.clock()
    local cached = Runtime.EggAutomation.RanchSnapshot
    local interval = math.max(2.5, tonumber(Config.EggRanchSafetyRescanInterval) or tonumber(Config.EggRanchScanInterval) or 8.0)
    if not forceRefresh
        and not Runtime.EggAutomation.RanchSnapshotDirty
        and cached
        and cached.Plot
        and cached.Plot.Parent
        and isPlotOwnedByLocalPlayer(cached.Plot)
        and now - (Runtime.EggAutomation.RanchSnapshotAt or 0) < interval then
        return cached
    end

    local plot = getStrictOwnedPlot()
    if plot then
        Runtime.EggAutomation.EnsureRanchWatchers(plot)
    end
    local snapshot = {
        Plot = plot,
        PlacePrompts = {},
        HatchPrompts = {},
        -- Keep all discovered prompt objects, including currently disabled ones,
        -- so an actual placement attempt can watch them without another deep scan.
        PlacePromptObjects = {},
        HatchPromptObjects = {},
        Current = nil,
        Capacity = nil,
        Full = false,
        CanPlace = false,
        CanHatch = false,
        Reason = "Ranch unavailable",
    }

    if not plot then
        Runtime.EggAutomation.RanchSnapshot = snapshot
        Runtime.EggAutomation.RanchSnapshotAt = now
        Runtime.EggAutomation.RanchSnapshotDirty = false
        Runtime.EggAutomation.RanchSnapshotDirtyReason = nil
        return snapshot
    end

    local knownNestKeys = {}
    local occupiedNestKeys = {}
    local rawPlacePrompts = {}
    local explicitCurrent = nil
    local explicitCapacity = nil

    -- Prefer the live Ranch egg container over GUI counters. The GUI/counter can
    -- remain at 10/10 for a short time after a hatch and used to keep Auto Place
    -- capacity-gated even after a physical nest had been freed. The runtime log
    -- shows placed eggs under Plot.Eggs.<EggName>.Handle, so this is the strongest
    -- client-visible occupancy signal when that folder exists.
    local livePlacedEggCount = nil
    local liveEggsFolder = plot:FindFirstChild("Eggs")
    if liveEggsFolder then
        local count = 0
        for _, child in ipairs(liveEggsFolder:GetChildren()) do
            if child:IsA("Model") or child:IsA("BasePart") then
                local lowerName = child.Name:lower()
                local looksLikePlacedEgg = string.find(lowerName, "egg", 1, true) ~= nil

                if child:IsA("Model") then
                    local handle = child:FindFirstChild("Handle", true)
                    if handle and handle:IsA("BasePart") then
                        looksLikePlacedEgg = true
                    end
                end

                if looksLikePlacedEgg then
                    count = count + 1
                end
            end
        end
        livePlacedEggCount = count
    end

    local function inspectNumberSignal(name, value)
        local number = tonumber(value)
        if not number then return end
        local lower = tostring(name or ""):lower():gsub("[^%w]", "")

        if string.find(lower, "maxegg", 1, true)
            or string.find(lower, "eggcapacity", 1, true)
            or string.find(lower, "maxnest", 1, true)
            or string.find(lower, "maxslot", 1, true)
            or lower == "capacity" then
            explicitCapacity = math.max(explicitCapacity or 0, number)
        elseif string.find(lower, "eggcount", 1, true)
            or string.find(lower, "placedegg", 1, true)
            or string.find(lower, "currentegg", 1, true)
            or string.find(lower, "occupiedegg", 1, true)
            or string.find(lower, "usedslot", 1, true) then
            explicitCurrent = math.max(explicitCurrent or 0, number)
        end
    end

    local function inspectCounterText(object, text)
        text = tostring(text or "")
        local currentText, maxText = string.match(text, "(%d+)%s*/%s*(%d+)")
        local current = tonumber(currentText)
        local maximum = tonumber(maxText)
        if not current or not maximum or maximum <= 0 then return end

        local context = tostring(object and object.Name or ""):lower()
        local parent = object and object.Parent
        for _ = 1, 3 do
            if not parent then break end
            context = context .. " " .. parent.Name:lower()
            parent = parent.Parent
        end

        local relevant = maximum == 10
            or string.find(context, "egg", 1, true)
            or string.find(context, "nest", 1, true)
            or string.find(context, "ranch", 1, true)
            or string.find(context, "slot", 1, true)
            or string.find(context, "capacity", 1, true)
        if relevant then
            explicitCurrent = math.max(explicitCurrent or 0, current)
            explicitCapacity = math.max(explicitCapacity or 0, maximum)
        end
    end

    -- ONE Ranch traversal feeds both systems. v3.63 deliberately avoids calling
    -- anchor:GetDescendants() again for every Place prompt: hatch occupancy is
    -- collected into occupiedNestKeys during this same pass, then applied once.
    Runtime.EggAutomation.ForEachDescendantYielded(plot, function(object)
        if object:IsA("ProximityPrompt") then
            if looksLikePlaceEggPrompt(object) then
                local key = getNestKey(object, plot)
                knownNestKeys[key] = true
                table.insert(snapshot.PlacePromptObjects, object)

                if object.Enabled then
                    table.insert(rawPlacePrompts, {
                        Prompt = object,
                        Part = getPromptPart(object),
                        Anchor = getNestAnchor(object, plot),
                        Key = key,
                        Plot = plot,
                    })
                end
            elseif looksLikeHatchEggPrompt(object) or isPlacedEggHatchFallbackPrompt(object, plot) then
                local key = getNestKey(object, plot)
                knownNestKeys[key] = true
                occupiedNestKeys[key] = true
                table.insert(snapshot.HatchPromptObjects, object)
                if object.Enabled then
                    table.insert(snapshot.HatchPrompts, {
                        Prompt = object,
                        Part = getPromptPart(object),
                        Anchor = getNestAnchor(object, plot),
                        Key = key,
                        Fallback = not looksLikeHatchEggPrompt(object),
                        Plot = plot,
                    })
                end
            end
        end

        local lowerName = object.Name:lower()
        if string.find(lowerName, "egg", 1, true)
            or string.find(lowerName, "nest", 1, true)
            or string.find(lowerName, "slot", 1, true)
            or string.find(lowerName, "capacity", 1, true) then
            for attrName, attrValue in pairs(object:GetAttributes()) do
                inspectNumberSignal(attrName, attrValue)
            end

            if object:IsA("IntValue") or object:IsA("NumberValue") then
                inspectNumberSignal(object.Name, object.Value)
            elseif object:IsA("StringValue") then
                inspectCounterText(object, object.Value)
            elseif object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
                inspectCounterText(object, object.Text)
            end
        end
    end, 28)

    -- Filter the already-collected Place entries without any nested descendant scan.
    for _, entry in ipairs(rawPlacePrompts) do
        local occupied = occupiedNestKeys[entry.Key] == true
            or anchorReportsOccupied(entry.Anchor)
        if not occupied and entry.Prompt and entry.Prompt.Parent and entry.Prompt.Enabled then
            entry.PrevalidatedEmpty = true
            entry.PrevalidatedAt = now
            table.insert(snapshot.PlacePrompts, entry)
        end
    end

    -- If the Ranch itself does not expose a numeric counter, check only GUI text
    -- when placement appears unavailable / near capacity. The loop is capped so
    -- this cannot turn into another expensive full-GUI scanner.
    if not liveEggsFolder and not explicitCapacity and #snapshot.PlacePrompts == 0 then
        local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
        local main = playerGui and playerGui:FindFirstChild("Main")
        if main then
            local checked = 0
            for _, object in ipairs(main:GetDescendants()) do
                if object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox") then
                    checked = checked + 1
                    inspectCounterText(object, object.Text)
                    if checked >= 350 or explicitCapacity == 10 then
                        break
                    end
                end
            end
        end
    end

    local knownSlots = 0
    for _ in pairs(knownNestKeys) do
        knownSlots = knownSlots + 1
    end

    -- LIVE placed-egg count wins over stale UI/counter text whenever Plot.Eggs
    -- exists. This is what lets Auto Place resume immediately after Auto Hatch
    -- actually removes an egg from the Ranch.
    if livePlacedEggCount ~= nil then
        snapshot.Current = livePlacedEggCount
        -- Current Ride A Pet Ranches use 10 egg slots. When Plot.Eggs exists it is
        -- authoritative enough that we do not need a PlayerGui-wide 10/10 search.
        snapshot.Capacity = (explicitCapacity and explicitCapacity > 0) and explicitCapacity or 10
        snapshot.CountSource = "Plot.Eggs live children"
        snapshot.Full = livePlacedEggCount >= snapshot.Capacity
    elseif explicitCapacity and explicitCapacity > 0 then
        snapshot.Capacity = explicitCapacity
        snapshot.Current = explicitCurrent
        snapshot.CountSource = "numeric/UI counter"
        if explicitCurrent and explicitCurrent >= explicitCapacity then
            snapshot.Full = true
        end
    elseif knownSlots > 0 then
        snapshot.Capacity = knownSlots
        snapshot.Current = math.max(0, knownSlots - #snapshot.PlacePrompts)
        snapshot.CountSource = "nest topology"
    end

    -- Hard 10/10 gate. IMPORTANT: the no-Place-prompt fallback is only allowed
    -- when there is no live Plot.Eggs occupancy source. Place prompts may be
    -- selection-gated, so zero prompts by itself cannot mean full.
    if snapshot.Capacity == 10 and snapshot.Current and snapshot.Current >= 10 then
        snapshot.Full = true
    elseif livePlacedEggCount == nil and knownSlots >= 10 and #snapshot.PlacePrompts == 0 then
        snapshot.Capacity = 10
        snapshot.Current = 10
        snapshot.Full = true
        snapshot.CountSource = snapshot.CountSource or "nest topology fallback"
    end

    table.sort(snapshot.PlacePrompts, function(a, b)
        local ap = getEntryPosition(a) or Vector3.zero
        local bp = getEntryPosition(b) or Vector3.zero
        if math.abs(ap.Y - bp.Y) > 0.05 then return ap.Y < bp.Y end
        if math.abs(ap.X - bp.X) > 0.05 then return ap.X < bp.X end
        if math.abs(ap.Z - bp.Z) > 0.05 then return ap.Z < bp.Z end
        return a.Key < b.Key
    end)
    table.sort(snapshot.HatchPrompts, function(a, b)
        return a.Key < b.Key
    end)

    snapshot.CanPlace = (not snapshot.Full) and #snapshot.PlacePrompts > 0
    snapshot.CanHatch = #snapshot.HatchPrompts > 0

    if snapshot.Full then
        if snapshot.Current and snapshot.Capacity then
            snapshot.Reason = string.format("Ranch full %d/%d — Auto Place armed but idle", snapshot.Current, snapshot.Capacity)
        else
            snapshot.Reason = "Ranch full — Auto Place armed but idle"
        end
    elseif #snapshot.PlacePrompts == 0 then
        snapshot.Reason = "No valid empty Place Egg slot — Auto Place idle"
    else
        local suffix = snapshot.Current and snapshot.Capacity
            and string.format(" (%d/%d)", snapshot.Current, snapshot.Capacity)
            or ""
        snapshot.Reason = "Placement available" .. suffix
    end

    Runtime.EggAutomation.RanchSnapshot = snapshot
    Runtime.EggAutomation.RanchSnapshotAt = now
    Runtime.EggAutomation.RanchSnapshotDirty = false
    Runtime.EggAutomation.RanchSnapshotDirtyReason = nil
    return snapshot
end

Runtime.EggAutomation.GetPlacePrompts = function(forceRefresh)
    local snapshot = Runtime.EggAutomation.GetRanchSnapshot(forceRefresh)
    return snapshot.PlacePrompts or {}, snapshot.Plot
end

Runtime.EggAutomation.GetHatchPrompts = function(forceRefresh)
    local snapshot = Runtime.EggAutomation.GetRanchSnapshot(forceRefresh)
    return snapshot.HatchPrompts or {}, snapshot.Plot
end

-- Resolve one ready Hatch prompt back to the actual placed egg under Plot.Eggs.
-- Primary path: prompt ancestry -> Plot.Eggs.<EggName>. This matches the live
-- structure already observed by the Ranch counter (Plot.Eggs.<EggName>.Handle).
-- Fallback: nearest placed egg to the prompt part, with a strict distance cap.
Runtime.EggAutomation.GetHatchEntryEggName = function(entry, plot)
    plot = plot or (entry and entry.Plot) or getStrictOwnedPlot()
    local eggsFolder = plot and plot:FindFirstChild("Eggs")
    if not entry or not entry.Prompt or not entry.Prompt.Parent or not eggsFolder then
        return nil, nil, "hatch entry/Plot.Eggs unavailable"
    end

    local knownNames = getAutomationKnownEggNames()

    local current = entry.Prompt.Parent
    while current and current ~= plot do
        if current.Parent == eggsFolder then
            local name = extractEggName(current, knownNames)
            if name then
                return name, current, "Plot.Eggs prompt ancestor"
            end
            break
        end
        current = current.Parent
    end

    local targetPosition = getEntryPosition(entry)
    if not targetPosition then
        local promptPart = getPromptPart(entry.Prompt)
        targetPosition = promptPart and promptPart.Position or nil
    end
    if not targetPosition then
        return nil, nil, "hatch prompt has no world position"
    end

    local nearest = nil
    local nearestDistance = math.huge
    for _, child in ipairs(eggsFolder:GetChildren()) do
        if child:IsA("Model") or child:IsA("BasePart") then
            local position = getTargetPosition(child)
            if position then
                local distance = (position - targetPosition).Magnitude
                if distance < nearestDistance then
                    nearest = child
                    nearestDistance = distance
                end
            end
        end
    end

    -- Do not associate a prompt with a distant egg; that could hatch the wrong filter.
    if nearest and nearestDistance <= 18 then
        local name = extractEggName(nearest, knownNames)
        if name then
            return name, nearest, string.format("nearest Plot.Eggs child %.1f studs", nearestDistance)
        end
    end

    return nil, nearest, nearest and string.format("nearest egg too far/unidentified %.1f studs", nearestDistance) or "no placed egg found"
end

local function memoryPosition(memory)
    if type(memory) ~= "table" then return nil end
    local x, y, z = tonumber(memory.X), tonumber(memory.Y), tonumber(memory.Z)
    if x and y and z then
        return Vector3.new(x, y, z)
    end
    return nil
end

local function rememberPlacement(eggName, entry)
    local position = getEntryPosition(entry)
    if not position then return end
    local eggKey = normalizeEggKey(eggName)
    local existing = Runtime.EggAutomation.PlacementMemory[eggKey]

    -- Keep the FIRST successful position as the cluster origin. Additional eggs
    -- of this type are placed beside this origin rather than moving the origin.
    if type(existing) ~= "table" then
        Runtime.EggAutomation.PlacementMemory[eggKey] = {
            Key = entry.Key,
            X = position.X,
            Y = position.Y,
            Z = position.Z,
        }
    end

    if entry.Key then
        Runtime.EggAutomation.NestOwners[entry.Key] = eggKey
    end
end

local function horizontalDistance(a, b)
    local dx = a.X - b.X
    local dz = a.Z - b.Z
    return math.sqrt(dx * dx + dz * dz)
end

local function findPreferredNestForEgg(eggName, promptEntries)
    local eggKey = normalizeEggKey(eggName)
    local remembered = Runtime.EggAutomation.PlacementMemory[eggKey]

    -- Backward compatibility with older session memory that stored only a key.
    if type(remembered) == "string" then
        for _, entry in ipairs(promptEntries) do
            if entry.Key == remembered then
                local valid = isEntryValidForPlacement(entry)
                if valid then
                    return entry, "remembered exact"
                end
            end
        end
        remembered = nil
        Runtime.EggAutomation.PlacementMemory[eggKey] = nil
    end

    local origin = memoryPosition(remembered)
    if origin then
        -- Exact remembered slot first IF it is genuinely empty again.
        for _, entry in ipairs(promptEntries) do
            if entry.Key == remembered.Key then
                local valid = isEntryValidForPlacement(entry)
                if valid then
                    return entry, "remembered exact"
                end
            end
        end

        -- Otherwise place BESIDE it: same horizontal level only. Never select a
        -- prompt above/below the remembered egg cluster.
        local verticalTolerance = math.max(0.5, tonumber(Config.EggPlacementVerticalTolerance) or 1.5)
        local maxHorizontal = math.max(4, tonumber(Config.EggPlacementMaxHorizontalDistance) or 65)
        local nearby = {}

        for _, entry in ipairs(promptEntries) do
            local position = getEntryPosition(entry)
            local owner = Runtime.EggAutomation.NestOwners[entry.Key]
            local valid = isEntryValidForPlacement(entry)
            if valid and position and (not owner or owner == eggKey) then
                local yDelta = math.abs(position.Y - origin.Y)
                local flatDistance = horizontalDistance(position, origin)
                if yDelta <= verticalTolerance and flatDistance <= maxHorizontal then
                    table.insert(nearby, {
                        Entry = entry,
                        Distance = flatDistance,
                        YDelta = yDelta,
                    })
                end
            end
        end

        table.sort(nearby, function(a, b)
            if math.abs(a.YDelta - b.YDelta) > 0.05 then
                return a.YDelta < b.YDelta
            end
            if math.abs(a.Distance - b.Distance) > 0.05 then
                return a.Distance < b.Distance
            end
            return a.Entry.Key < b.Entry.Key
        end)

        if nearby[1] then
            return nearby[1].Entry, "nearest beside remembered cluster"
        end

        return nil, "no valid empty slot beside remembered egg; refused vertical stacking"
    end

    -- First placement for this egg type: prefer a truly unreserved empty slot.
    -- A reservation is only affinity memory, not proof that a currently-empty
    -- nest must stay unusable forever after its previous egg has hatched.
    for _, entry in ipairs(promptEntries) do
        local owner = Runtime.EggAutomation.NestOwners[entry.Key]
        local valid = isEntryValidForPlacement(entry)
        if valid and (not owner or owner == eggKey) then
            return entry, "new cluster origin"
        end
    end

    -- If every live empty slot has stale affinity from another egg type, reuse
    -- the first physically valid empty slot. rememberPlacement() will transfer
    -- ownership only after the server confirms the new egg was actually placed.
    for _, entry in ipairs(promptEntries) do
        local valid = isEntryValidForPlacement(entry)
        if valid then
            return entry, "reused empty slot with stale affinity"
        end
    end

    return nil, "no valid empty place slot"
end

local function setEggAutomationStatus(text, good)
    if Runtime.EggAutomation.UI.StatusLabel and Runtime.EggAutomation.UI.StatusLabel.Parent then
        Runtime.EggAutomation.UI.StatusLabel.Text = tostring(text)
        Runtime.EggAutomation.UI.StatusLabel.TextColor3 = good == false
            and Color3.fromRGB(255, 145, 120)
            or Color3.fromRGB(170, 215, 195)
    end
end

-- Remove one successfully placed candidate from the cached, already-sorted bag
-- list instead of forcing another full PlayerGui/inventory traversal immediately.
-- The exact slot is revalidated after placement; a full rebuild is recovery-only.
Runtime.EggAutomation.ConsumeCachedCandidate = function(candidate)
    local list = Runtime.EggAutomation.LastBagScan
    if not candidate or type(list) ~= "table" then return end

    -- Re-check only this known slot after placement. If another copy/stack of the
    -- same egg remains there, keep reusing it. Otherwise invalidate once.
    task.defer(function()
        task.wait(0.10)
        if not Runtime.Alive then return end

        local source = candidate.Source
        local interactable = candidate.Interactable
        local keep = source and source.Parent and interactable and interactable.Parent

        if keep then
            local knownNames = getKnownEggLookup()
            local detectedName = extractEggName(source, knownNames)
            if not detectedName and interactable ~= source then
                detectedName = extractEggName(interactable, knownNames)
            end
            keep = normalizeEggKey(detectedName or "") == normalizeEggKey(candidate.Name)
        end

        if keep then
            Runtime.EggAutomation.LastBagScanAt = os.clock()
            return
        end

        for index = #list, 1, -1 do
            local item = list[index]
            if item == candidate
                or (item and candidate.Interactable and item.Interactable == candidate.Interactable)
                or (item and candidate.Source and item.Source == candidate.Source) then
                table.remove(list, index)
            end
        end
        Runtime.EggAutomation.MarkBagCacheDirty("placed egg slot changed/emptied")
    end)
end
-- STRICT PRIORITY GATE. Auto Place / Auto Hatch are background helpers only.
-- They may run while Get Egg is ARMED but waiting; the moment a selected rendered
-- egg is detected, Get Egg is processing an egg, another movement is active, or a
-- higher-priority automation is running, Egg Automation yields.
Runtime.EggAutomation.ShouldYieldToPrimaryAutomation = function()
    -- Auto Place / Auto Hatch are independent from Get Egg's filter/queue.
    -- They yield ONLY while Get Egg is actually processing an egg (or another
    -- movement/primary automation is actively using the character). Merely having
    -- a filtered rendered Get Egg target must never starve Place/Hatch forever.
    if movementActive then
        return true, "movement active"
    end
    if autoFarmCurrentName ~= nil then
        return true, "Get Egg actively processing " .. tostring(autoFarmCurrentName)
    end
    if autoBestEggActive then
        return true, "Auto Best Egg active"
    end
    if Runtime.AutoFeed and Runtime.AutoFeed.Busy then
        return true, "Auto Feed Pet active"
    end
    -- Auto Hatch Luck only fires the Ranch upgrade remote in the background.
    -- It does NOT move the player, select an egg, or use a nest, so it must never
    -- block Auto Place / Auto Hatch. Keeping it in this yield gate was the reason
    -- both egg automations stayed permanently armed-but-idle whenever Luck was ON.
    return false, "independent egg automation window available"
end

local function clickGuiButton(button)
    if not button or not button.Parent or not button:IsA("GuiButton") then
        return false, "button unavailable"
    end

    -- Device-aware physical input first. On mobile this is a real touch event;
    -- on desktop this remains a mouse click. This fixes the old mobile path that
    -- claimed success after injecting mouse input into a touch-only client.
    if button.Visible and button.AbsoluteSize.X > 1 and button.AbsoluteSize.Y > 1 then
        local pos = button.AbsolutePosition + (button.AbsoluteSize / 2)
        local sent, method = Runtime.InputCompat.SendAdaptiveScreenPress(pos.X, pos.Y, 0.045)
        if sent then
            return true, method .. " button input"
        end
    end

    -- Executor signal fallback. Prefer Activated because Roblox defines it as the
    -- cross-platform click/tap event. MouseButton1Click is retained only for old
    -- game UIs that explicitly subscribed to that legacy event.
    local fireSignalFunction = firesignal
    if type(fireSignalFunction) == "function" then
        local okActivated = pcall(function()
            fireSignalFunction(button.Activated)
        end)
        if okActivated then return true, "Activated signal" end

        local okClick = pcall(function()
            fireSignalFunction(button.MouseButton1Click)
        end)
        if okClick then return true, "MouseButton1Click compatibility signal" end
    end

    return false, "no supported button input path"
end


-- Find the live Tool created/used by the selected basket egg. Public current
-- Ride A Pet automation reports an explicit "auto equip egg tool" step; a GUI
-- slot click alone is not sufficient on every server/client build.
Runtime.EggAutomation.FindMatchingEggTool = function(candidate)
    if not candidate then return nil, "no candidate" end

    local character = getCharacter()
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    local knownNames = getKnownEggLookup()
    local targetName = normalizeEggKey(candidate.Name)
    local targetWeight = tonumber(candidate.WeightKg) or 0

    -- Fast common case: after a basket slot is selected there is normally only
    -- one active egg Tool directly under Character. Avoid descendant scoring.
    if character then
        for _, child in ipairs(character:GetChildren()) do
            if child:IsA("Tool") then
                local detectedName = extractEggName(child, knownNames)
                if normalizeEggKey(detectedName or child.Name) == targetName then
                    return child, "name+character-fast"
                end
            end
        end
    end

    local bestTool = nil
    local bestScore = -math.huge
    local bestWhy = "no egg tool"

    local function scoreTool(tool)
        if not tool or not tool.Parent or not tool:IsA("Tool") then return end

        local detectedName = extractEggName(tool, knownNames)
        local normalizedDetected = normalizeEggKey(detectedName or tool.Name)
        local toolWeight = extractWeightKg(tool)
        -- Candidate weight was already validated from its bag/slot source.
        -- The equipped Tool frequently omits kg metadata, so never reject the
        -- correct Tool merely because its own weight cannot be read.
        if normalizedDetected ~= targetName then return end
        local score = 0
        local why = {}

        if normalizedDetected == targetName and targetName ~= "" then
            score = score + 100
            table.insert(why, "name")
        elseif targetName ~= ""
            and (string.find(normalizedDetected, targetName, 1, true)
                or string.find(targetName, normalizedDetected, 1, true)) then
            score = score + 65
            table.insert(why, "partial-name")
        elseif string.find(tool.Name:lower(), "egg", 1, true) then
            score = score + 15
            table.insert(why, "egg-tool")
        end

        if targetWeight > 0 and toolWeight > 0 then
            local delta = math.abs(toolWeight - targetWeight)
            if delta <= 0.05 then
                score = score + 55
                table.insert(why, "exact-kg")
            elseif delta <= 0.6 then
                score = score + 25
                table.insert(why, "near-kg")
            end
        end

        -- A Tool already parented to Character is very likely the active carried
        -- item, while a Backpack Tool still needs Humanoid:EquipTool().
        if character and tool:IsDescendantOf(character) then
            score = score + 8
            table.insert(why, "character")
        elseif backpack and tool:IsDescendantOf(backpack) then
            score = score + 4
            table.insert(why, "backpack")
        end

        if score > bestScore then
            bestScore = score
            bestTool = tool
            bestWhy = (#why > 0 and table.concat(why, "+") or "generic tool")
        end
    end

    -- Tools are parented directly to Character or Backpack in Roblox. Scanning all
    -- descendants here used to run up to ~60 times/sec while waiting for a slot
    -- handoff and was one of the largest Auto Place frame spikes.
    if character then
        for _, object in ipairs(character:GetChildren()) do
            if object:IsA("Tool") then scoreTool(object) end
        end
    end
    if backpack then
        for _, object in ipairs(backpack:GetChildren()) do
            if object:IsA("Tool") then scoreTool(object) end
        end
    end

    -- Require at least an egg-like signal. Never equip a random food/radar tool.
    if bestTool and bestScore >= 15 then
        return bestTool, bestWhy
    end
    return nil, "matching egg Tool not present"
end

Runtime.EggAutomation.WaitForMatchingEggTool = function(candidate, timeout)
    local deadline = os.clock() + math.max(0.10, tonumber(timeout) or tonumber(Config.EggToolAppearWait) or 0.90)
    local lastWhy = "not checked"

    repeat
        local shouldYield = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation
            and Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
        if shouldYield then
            return nil, "yielded to primary automation"
        end

        local tool, why = Runtime.EggAutomation.FindMatchingEggTool(candidate)
        if tool then
            return tool, why
        end
        lastWhy = why or lastWhy
        task.wait(math.max(0.08, tonumber(Config.EggToolSearchPoll) or 0.12))
    until not Runtime.Alive or os.clock() >= deadline

    return nil, lastWhy
end

Runtime.EggAutomation.EquipMatchingEggTool = function(candidate, timeout)
    local tool, why = Runtime.EggAutomation.WaitForMatchingEggTool(candidate, timeout)
    if not tool then
        return false, "no matching egg Tool after slot selection", nil
    end

    local character = getCharacter()
    if character and tool:IsDescendantOf(character) then
        return true, "egg Tool already equipped (" .. tostring(why) .. ")", tool
    end

    local humanoid = getHumanoid()
    if not humanoid or humanoid.Health <= 0 then
        return false, "humanoid unavailable for egg Tool equip", tool
    end

    local ok = pcall(function()
        humanoid:EquipTool(tool)
    end)
    if not ok then
        return false, "Humanoid:EquipTool failed", tool
    end

    task.wait(math.max(0.03, tonumber(Config.EggToolEquipSettle) or 0.10))
    character = getCharacter()
    if character and tool.Parent and tool:IsDescendantOf(character) then
        return true, "slot selected + egg Tool equipped (" .. tostring(why) .. ")", tool
    end

    return false, "egg Tool found but did not equip", tool
end

Runtime.EggAutomation.UnequipActiveEggTool = function()
    local tool = Runtime.EggAutomation.ActiveEggTool
    Runtime.EggAutomation.ActiveEggTool = nil
    Runtime.EggAutomation.BagEventMuteUntil = math.max(
        Runtime.EggAutomation.BagEventMuteUntil or 0,
        os.clock() + 0.35
    )
    if not tool or not tool.Parent then return false end

    local character = getCharacter()
    if not character or not tool:IsDescendantOf(character) then return false end

    local humanoid = getHumanoid()
    if not humanoid or humanoid.Health <= 0 then return false end
    return pcall(function() humanoid:UnequipTools() end)
end

local function activateEggCandidate(candidate)
    if not candidate or not candidate.Interactable or not candidate.Interactable.Parent then
        return false, "candidate unavailable"
    end

    -- Slot selection/equip temporarily moves Tool instances. Ignore those own
    -- Backpack events; the exact cached slot is validated after placement instead.
    Runtime.EggAutomation.BagEventMuteUntil = math.max(
        Runtime.EggAutomation.BagEventMuteUntil or 0,
        os.clock() + 4.0
    )

    local object = candidate.Interactable
    if object:IsA("Tool") then
        -- Do not re-check kg on the Tool. Weight eligibility belongs to the
        -- candidate's bag/slot source and was already checked before activation.
        local humanoid = getHumanoid()
        if not humanoid then
            return false, "humanoid unavailable"
        end
        local ok = pcall(function()
            humanoid:EquipTool(object)
        end)
        if ok then
            Runtime.EggAutomation.ActiveEggTool = object
            task.wait(math.max(0.03, tonumber(Config.EggToolEquipSettle) or 0.10))
        end
        return ok, ok and "egg Tool equipped directly" or "EquipTool failed"
    end

    if object:IsA("GuiButton") then
        local clicked, clickMethod = clickGuiButton(object)
        if not clicked then
            return false, "slot selection failed: " .. tostring(clickMethod)
        end

        -- Critical v3.27 handoff: clicking the basket slot can create/select an
        -- Egg Tool without equipping it. Equip the matching rarity/KG egg Tool
        -- before waiting for Place Egg In Nest.
        local equipped, equipReason, tool = Runtime.EggAutomation.EquipMatchingEggTool(
            candidate,
            tonumber(Config.EggToolAppearWait) or 0.90
        )

        if equipped and tool then
            Runtime.EggAutomation.ActiveEggTool = tool
        end

        Runtime.DebugTeleport("EGG-AUTO", "Basket slot handoff", {
            egg = candidate.Name,
            luck = candidate.Luck or 0,
            rarity = candidate.Rarity,
            weightKg = candidate.WeightKg,
            slot = object:GetFullName(),
            tool = tool and tool:GetFullName() or "nil",
            equipped = equipped,
            reason = tostring(clickMethod) .. "; " .. tostring(equipReason),
        })

        -- Preserve compatibility with servers where the Place prompt is exposed
        -- directly by the slot click and no client Tool is replicated.
        return true, equipped
            and (tostring(clickMethod) .. "; " .. tostring(equipReason))
            or (tostring(clickMethod) .. "; " .. tostring(equipReason))
    end

    return true, "candidate represented by live bag/slot state"
end

-- Lightweight Place-prompt watcher. One Ranch traversal is done up front, then
-- existing prompt objects are polled and only newly-added descendants are watched.
-- This replaces the old forced full Ranch scan every ~0.08 seconds.
Runtime.EggAutomation.WaitForPlacePromptsLight = function(plot, timeout)
    if not plot or not plot.Parent then return {}, "plot unavailable" end
    if not isPlotOwnedByLocalPlayer(plot) then
        return {}, "STRICT OWNED RANCH: refused non-owned Plot"
    end

    local watched = {}
    local function register(object)
        if object and object:IsA("ProximityPrompt") and looksLikePlaceEggPrompt(object) then
            watched[object] = true
        end
    end

    -- Reuse the prompt index from the cached Ranch snapshot. PlaceBestOnce builds
    -- that snapshot before selecting a slot, so this normally performs ZERO deep
    -- Ranch traversals. Fall back to one traversal only if no prompt index exists.
    local cachedSnapshot = Runtime.EggAutomation.RanchSnapshot
    if cachedSnapshot and cachedSnapshot.Plot == plot and type(cachedSnapshot.PlacePromptObjects) == "table" then
        for _, prompt in ipairs(cachedSnapshot.PlacePromptObjects) do
            register(prompt)
        end
    else
        Runtime.EggAutomation.ForEachDescendantYielded(plot, register, 28)
    end

    local connection = plot.DescendantAdded:Connect(register)
    local deadline = os.clock() + math.max(0.15, tonumber(timeout) or 0.70)
    local result = {}

    repeat
        local shouldYield = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation
            and Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
        if shouldYield then
            connection:Disconnect()
            return {}, "yielded to primary automation"
        end

        table.clear(result)
        for prompt in pairs(watched) do
            if not prompt or not prompt.Parent then
                watched[prompt] = nil
            elseif prompt.Enabled and isPlaceEggPrompt(prompt) then
                local entry = {
                    Prompt = prompt,
                    Part = getPromptPart(prompt),
                    Anchor = getNestAnchor(prompt, plot),
                    Key = getNestKey(prompt, plot),
                    Plot = plot,
                }
                if isEntryValidForPlacement(entry) then
                    table.insert(result, entry)
                end
            end
        end

        if #result > 0 then break end
        task.wait(math.max(0.08, tonumber(Config.EggPlacePromptPoll) or 0.12))
    until not Runtime.Alive or os.clock() >= deadline

    connection:Disconnect()
    return result, #result > 0 and "live Place prompt" or "no live Place prompt"
end

Runtime.EggAutomation.GetPlacedEggFocusPosition = function(plot, eggName)
    if not plot or not isPlotOwnedByLocalPlayer(plot) then
        return nil, "STRICT OWNED RANCH: refused non-owned placement focus"
    end

    local eggKey = normalizeEggKey(eggName)
    local remembered = Runtime.EggAutomation.PlacementMemory[eggKey]
    local rememberedPosition = memoryPosition(remembered)
    if rememberedPosition then
        if isWorldPositionInsideOwnedPlot(plot, rememberedPosition, 12, 40) then
            return rememberedPosition, "remembered egg cluster inside owned Ranch"
        end

        -- Never follow stale coordinates into another Ranch.
        Runtime.EggAutomation.PlacementMemory[eggKey] = nil
        Runtime.DebugTeleport("EGG-AUTO", "STRICT OWNED RANCH cleared stale placement memory", {
            egg = eggName,
            remembered = rememberedPosition,
            plot = plot:GetFullName(),
        })
    end

    local eggsFolder = plot and plot:FindFirstChild("Eggs")
    if eggsFolder then
        local sum = Vector3.zero
        local count = 0
        for _, child in ipairs(eggsFolder:GetChildren()) do
            local position = nil
            if child:IsA("BasePart") then
                position = child.Position
            elseif child:IsA("Model") then
                local handle = child:FindFirstChild("Handle", true)
                if handle and handle:IsA("BasePart") then
                    position = handle.Position
                else
                    local ok, pivot = pcall(function() return child:GetPivot() end)
                    if ok then position = pivot.Position end
                end
            end
            if position then
                sum = sum + position
                count = count + 1
            end
        end
        if count > 0 then
            return sum / count, "live placed-egg cluster"
        end
    end

    local fallback = plot and getTargetPosition(plot) or nil
    return fallback, fallback and "plot center" or "no placement focus"
end

Runtime.EggAutomation.SnapshotPlacedEggChildren = function(plot)
    local result = {}
    local folder = plot and plot:FindFirstChild("Eggs")
    if folder then
        for _, child in ipairs(folder:GetChildren()) do
            result[child] = true
        end
    end
    return result
end

Runtime.EggAutomation.RememberNewPlacedEggPosition = function(plot, eggName, beforeSet)
    local folder = plot and plot:FindFirstChild("Eggs")
    if not folder then return end

    for _, child in ipairs(folder:GetChildren()) do
        if not beforeSet[child] then
            local position = nil
            if child:IsA("BasePart") then
                position = child.Position
            elseif child:IsA("Model") then
                local handle = child:FindFirstChild("Handle", true)
                if handle and handle:IsA("BasePart") then
                    position = handle.Position
                else
                    local ok, pivot = pcall(function() return child:GetPivot() end)
                    if ok then position = pivot.Position end
                end
            end

            if position then
                local key = normalizeEggKey(eggName)
                if type(Runtime.EggAutomation.PlacementMemory[key]) ~= "table" then
                    Runtime.EggAutomation.PlacementMemory[key] = {
                        Key = nil,
                        X = position.X,
                        Y = position.Y,
                        Z = position.Z,
                    }
                end
                return
            end
        end
    end
end

-- Current Ride A Pet builds can require a physical-style world input while the
-- Egg Tool is equipped. Desktop uses a mouse click; mobile uses a touch event.
-- Tool:Activate() remains the second fallback after the physical input is verified.
local function sendRealEggPlacementInput(worldFocus)
    local camera = Workspace.CurrentCamera
    local viewport = camera and camera.ViewportSize or Vector2.new(1280, 720)
    local playerGui = LocalPlayer:FindFirstChild("PlayerGui")

    -- Keep the synthetic click away from this script's centered menu. Temporarily
    -- disabling only OUR ScreenGui prevents the click from toggling Auto Place off.
    local screenGui = Runtime.ScreenGui
    local restoreEnabled = nil
    if screenGui and screenGui.Parent and screenGui:IsA("ScreenGui") then
        restoreEnabled = screenGui.Enabled
        screenGui.Enabled = false
    end

    -- If the held Tool reads Mouse.Hit, briefly aim the camera at the verified
    -- owned-Ranch focus so the synthetic click resolves to Ranch geometry instead
    -- of whatever direction the player's camera happened to be facing.
    local restoreCameraCFrame = nil
    if camera and typeof(worldFocus) == "Vector3" then
        local cameraPosition = camera.CFrame.Position
        if (worldFocus - cameraPosition).Magnitude > 1 then
            restoreCameraCFrame = camera.CFrame
            pcall(function()
                camera.CFrame = CFrame.lookAt(cameraPosition, worldFocus, Vector3.new(0, 1, 0))
            end)
        end
    end

    -- Prefer the screen center after our menu is hidden because the temporary
    -- camera aim puts the Ranch focus on that ray. If another clickable game GUI
    -- occupies it, try several quiet gameplay points instead.
    local points = {
        Vector2.new(viewport.X * 0.50, viewport.Y * 0.50),
        Vector2.new(viewport.X * 0.72, viewport.Y * 0.62),
        Vector2.new(viewport.X * 0.28, viewport.Y * 0.62),
        Vector2.new(viewport.X * 0.78, viewport.Y * 0.78),
        Vector2.new(viewport.X * 0.22, viewport.Y * 0.78),
    }

    local clickPoint = points[1]
    if playerGui and type(playerGui.GetGuiObjectsAtPosition) == "function" then
        for _, point in ipairs(points) do
            local blocked = false
            local okObjects, guiObjects = pcall(function()
                return playerGui:GetGuiObjectsAtPosition(point.X, point.Y)
            end)
            if okObjects and type(guiObjects) == "table" then
                for _, guiObject in ipairs(guiObjects) do
                    if guiObject
                        and guiObject.Visible
                        and guiObject:IsA("GuiButton")
                        and guiObject.Active then
                        blocked = true
                        break
                    end
                end
            end
            if not blocked then
                clickPoint = point
                break
            end
        end
    end

    local clickX = math.max(8, math.floor(clickPoint.X))
    local clickY = math.max(8, math.floor(clickPoint.Y))

    local ok, inputMethod = Runtime.InputCompat.SendAdaptiveScreenPress(clickX, clickY, 0.045)

    if camera and restoreCameraCFrame then
        pcall(function()
            camera.CFrame = restoreCameraCFrame
        end)
    end
    if screenGui and screenGui.Parent and restoreEnabled ~= nil then
        screenGui.Enabled = restoreEnabled
    end

    return ok, ok
        and string.format("%s placement input sent at %d,%d", tostring(inputMethod), clickX, clickY)
        or ("placement input failed: " .. tostring(inputMethod))
end

Runtime.EggAutomation.TryDirectEggToolPlacement = function(candidate, plot, beforeCount, beforeRanchCurrent, beforePlacedSet)
    if not plot or not isPlotOwnedByLocalPlayer(plot) then
        return false, "STRICT OWNED RANCH: direct placement refused non-owned Plot"
    end

    local shouldYield, yieldReason = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
    if shouldYield then
        return false, "yielded to " .. tostring(yieldReason)
    end

    local tool = Runtime.EggAutomation.FindMatchingEggTool(candidate)
    local character = getCharacter()
    if not tool or not character or not tool:IsDescendantOf(character) then
        return false, "equipped egg Tool unavailable for direct place"
    end

    local focus, focusWhy = Runtime.EggAutomation.GetPlacedEggFocusPosition(plot, candidate.Name)
    local root = getRootPart()
    if focus and not isWorldPositionInsideOwnedPlot(plot, focus, 12, 45) then
        return false, "STRICT OWNED RANCH: placement focus was outside owned Plot"
    end
    if focus and root then
        local destination = Vector3.new(focus.X, focus.Y + math.max(2, Config.TPHeight or 3), focus.Z)
        if not isWorldPositionInsideOwnedPlot(plot, destination, 15, 55) then
            return false, "STRICT OWNED RANCH: placement destination was outside owned Plot"
        end
        if (root.Position - destination).Magnitude > 10 then
            -- Character-only pivot; do not enter the shared movement loop. Get Egg
            -- therefore remains free to take priority immediately after this point.
            pivotControlledAssemblyTo(destination, root.CFrame, true)
            zeroMovementVelocity()
            task.wait(0.04)
        end
    end

    shouldYield, yieldReason = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
    if shouldYield then
        return false, "yielded to " .. tostring(yieldReason)
    end

    local eggsFolder = plot and plot:FindFirstChild("Eggs")
    local beforeLiveCount = eggsFolder and #eggsFolder:GetChildren() or nil
    local addedChild = nil
    local addedConnection = nil

    if eggsFolder then
        addedConnection = eggsFolder.ChildAdded:Connect(function(child)
            addedChild = addedChild or child
        end)
    end

    local function livePlacementObserved()
        if addedChild and eggsFolder and addedChild.Parent == eggsFolder then
            return true
        end
        if eggsFolder and beforeLiveCount ~= nil and #eggsFolder:GetChildren() > beforeLiveCount then
            return true
        end
        return false
    end

    local function waitForLivePlacement(seconds)
        local deadline = os.clock() + math.max(0.10, tonumber(seconds) or 0.24)
        repeat
            local nowYield, nowReason = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
            if nowYield then
                return false, "yielded to " .. tostring(nowReason)
            end
            if livePlacementObserved() then
                return true, "live Plot.Eggs advanced"
            end
            task.wait(0.04)
        until not Runtime.Alive or os.clock() >= deadline

        return livePlacementObserved(), "no live placement change"
    end

    -- v3.47: send a physical-style input matching the active device first.
    -- Tool:Activate() can return successfully while the game never receives the
    -- placement input it expects; touch clients therefore get touch, not mouse.
    local clickSent, clickReason = sendRealEggPlacementInput(focus)
    local placed = false
    local verifyReason = "physical placement input was not sent"

    if clickSent then
        placed, verifyReason = waitForLivePlacement(
            math.max(0.18, tonumber(Config.EggDirectPlaceVerifyWait) or 0.24)
        )
    end

    -- Compatibility fallback for builds where Tool:Activate() really is sufficient.
    -- Do this ONLY if the real click was verified as not placing an egg, preventing
    -- accidental double placement.
    local activateReason = "Tool:Activate fallback not needed"
    if not placed then
        local activated, activateErr = pcall(function()
            tool:Activate()
        end)

        if activated then
            activateReason = "Tool:Activate fallback sent"
            placed, verifyReason = waitForLivePlacement(
                math.max(0.18, tonumber(Config.EggDirectPlaceVerifyWait) or 0.24)
            )
        else
            activateReason = "Tool:Activate failed: " .. tostring(activateErr)
        end
    end

    if addedConnection then addedConnection:Disconnect() end

    if placed then
        Runtime.EggAutomation.RememberNewPlacedEggPosition(
            plot,
            candidate.Name,
            beforePlacedSet or Runtime.EggAutomation.SnapshotPlacedEggChildren(plot)
        )
        Runtime.EggAutomation.ConsumeCachedCandidate(candidate)
        Runtime.EggAutomation.DirectPlaceFastPath = true
        Runtime.EggAutomation.InvalidateRanchSnapshot()

        return true,
            "direct held-tool place verified ("
            .. tostring(clickReason)
            .. "; " .. tostring(activateReason)
            .. "; " .. tostring(verifyReason)
            .. "; " .. tostring(focusWhy) .. ")"
    end

    -- Compatibility fallback only when this server does not expose Plot.Eggs.
    -- Compare the exact owned egg count after both input methods.
    if not eggsFolder then
        local roots = Runtime.AutoGet.GetInventoryRoots(true)
        local afterCount = Runtime.AutoGet.CountOwnedEgg(candidate.Name, roots)
        if afterCount < beforeCount then
            Runtime.EggAutomation.ConsumeCachedCandidate(candidate)
            Runtime.EggAutomation.DirectPlaceFastPath = true
            Runtime.EggAutomation.InvalidateRanchSnapshot()
            return true,
                "direct held-tool place verified by inventory decrease ("
                .. tostring(clickReason) .. "; " .. tostring(activateReason) .. ")"
        end
    end

    return false,
        "physical placement input + Tool:Activate produced no placement"
        .. " | input=" .. tostring(clickReason)
        .. " | activate=" .. tostring(activateReason)
        .. " | verify=" .. tostring(verifyReason)
end

local function interactPrompt(entry)
    local prompt = entry and entry.Prompt
    if not prompt or not prompt.Parent or not prompt.Enabled then
        return false, "prompt unavailable"
    end

    -- FINAL HARD GUARD: even if a bad prompt slipped through a cached Ranch
    -- snapshot, never send input to Skip All Egg or any other ranch-wide egg action.
    local blockedPrompt, blockedReason = isBlockedEggAutomationPrompt(prompt)
    if blockedPrompt then
        Runtime.DebugTeleport("EGG-AUTO", "BLOCKED NON-INDIVIDUAL EGG PROMPT", {
            target = prompt:GetFullName(),
            promptText = getPromptSearchText(prompt),
            reason = blockedReason,
        })
        return false, "blocked unsafe/mass egg prompt: " .. tostring(blockedReason)
    end

    -- STRICT: resolve ownership again immediately before any movement/input.
    -- A cached prompt from another Plot or a Plot whose owner changed is rejected.
    local expectedPlot = entry and entry.Plot or nil
    local promptOwned, promptOwnedReason = belongsToStrictOwnedPlot(prompt, expectedPlot)
    if not promptOwned then
        Runtime.DebugTeleport("EGG-AUTO", "STRICT OWNED RANCH BLOCK", {
            target = prompt:GetFullName(),
            reason = promptOwnedReason,
        })
        return false, "STRICT OWNED RANCH: " .. tostring(promptOwnedReason)
    end

    local ownedPlot = getStrictOwnedPlot()
    local part = entry.Part or getPromptPart(prompt)
    if part then
        local partOwned, partOwnedReason = belongsToStrictOwnedPlot(part, ownedPlot)
        if not partOwned then
            return false, "STRICT OWNED RANCH: " .. tostring(partOwnedReason)
        end
    end

    local root = getRootPart()
    if part and root then
        local maxDistance = math.max(4, tonumber(prompt.MaxActivationDistance) or 10)
        if (root.Position - part.Position).Magnitude > math.max(3, maxDistance - 1) then
            local moved = moveToModel(part, true)
            if not moved then
                return false, "could not reach prompt"
            end
            task.wait(0.05)
        end
    end

    -- Re-check after movement as a final anti-cross-ranch guard.
    local finalOwned, finalOwnedReason = belongsToStrictOwnedPlot(prompt, ownedPlot)
    if not finalOwned then
        return false, "STRICT OWNED RANCH after movement: " .. tostring(finalOwnedReason)
    end

    local ok, method = Runtime.InputCompat.InteractProximityPromptPortable(
        prompt,
        tonumber(Config.EggPromptExtraHold) or 0.08
    )
    return ok, ok and tostring(method) or ("prompt input failed: " .. tostring(method))
end

local function isNearOwnedPlot(radius)
    local plot = getStrictOwnedPlot()
    local root = getRootPart()
    if not plot or not root then
        return false
    end

    -- STRICT ranch membership: when bounding boxes are available, being merely
    -- close to our Plot is NOT enough. This prevents standing in a neighboring
    -- player's Ranch from being mistaken for our own Ranch.
    local boundsAvailable = false
    local insideBounds = false
    local boxCFrame, boxSize = Runtime.EggAutomation.GetCachedPlotBounds(plot, 20)
    if boxCFrame and boxSize then
        boundsAvailable = true
        local localPos = boxCFrame:PointToObjectSpace(root.Position)
        local paddingXZ = 10
        local paddingY = 35
        insideBounds = math.abs(localPos.X) <= (boxSize.X * 0.5 + paddingXZ)
            and math.abs(localPos.Y) <= (boxSize.Y * 0.5 + paddingY)
            and math.abs(localPos.Z) <= (boxSize.Z * 0.5 + paddingXZ)
    end

    if boundsAvailable then
        return insideBounds
    end

    -- Last-resort fallback only for unusual Plot objects that cannot expose bounds.
    -- Require OUR Plot to be the closest Plot and keep the allowed radius tight.
    local ownPosition = getTargetPosition(plot)
    if not ownPosition then
        return false
    end

    local ownDistance = (root.Position - ownPosition).Magnitude
    local nearestPlot = nil
    local nearestDistance = math.huge
    local plotsFolder = Workspace:FindFirstChild("Plots")
    if plotsFolder then
        for _, candidatePlot in ipairs(plotsFolder:GetChildren()) do
            local candidatePosition = getTargetPosition(candidatePlot)
            if candidatePosition then
                local distance = (root.Position - candidatePosition).Magnitude
                if distance < nearestDistance then
                    nearestDistance = distance
                    nearestPlot = candidatePlot
                end
            end
        end
    end

    if nearestPlot and nearestPlot ~= plot then
        return false
    end

    local fallbackRadius = math.min(90, math.max(45, tonumber(radius) or 75))
    return ownDistance <= fallbackRadius
end

-- Export the scoped helper for F8 diagnostics. The old F8 callback referenced the
-- local by name from outside this block, which resolved as nil and caused the
-- [InsideRanch] attempt-to-call-a-nil-value error.
Runtime.EggAutomation.IsNearOwnedPlot = isNearOwnedPlot

local function ensureAtStrictOwnedRanchForEggAutomation()
    local plot = getStrictOwnedPlot()
    if not plot then
        return false, nil, "STRICT OWNED RANCH: owned Plot not found"
    end

    if isNearOwnedPlot(Config.EggHomeRadius) then
        return true, plot, "already at owned Ranch"
    end

    Runtime.DebugTeleport("EGG-AUTO", "STRICT OWNED RANCH RETURN", {
        plot = plot:GetFullName(),
        owner = LocalPlayer.Name,
        root = getRootPart() and getRootPart().Position or "nil",
    })

    -- Move only to the Plot that is currently verified as owned by LocalPlayer.
    local moved = moveToModel(plot, true)
    if not moved then
        return false, plot, "STRICT OWNED RANCH: failed to reach owned Plot"
    end

    task.wait(0.05)

    -- Ownership can theoretically change during a server update; verify again.
    if not plot.Parent or not isPlotOwnedByLocalPlayer(plot) or getStrictOwnedPlot() ~= plot then
        return false, nil, "STRICT OWNED RANCH: ownership changed during movement"
    end

    if not isNearOwnedPlot(Config.EggHomeRadius) then
        return false, plot, "STRICT OWNED RANCH: arrival verification failed"
    end

    return true, plot, "arrived at owned Ranch"
end

Runtime.EggAutomation.EnsureAtOwnedRanch = ensureAtStrictOwnedRanchForEggAutomation

local function ensureDismountedForEggHatch(timeout)
    local humanoid = getHumanoid()
    if not humanoid or humanoid.Health <= 0 then
        return false, "humanoid unavailable"
    end

    local waitTime = math.max(0.35, tonumber(timeout) or 0.90)

    -- Current Ride A Pet mounts are tracked by the player's IsRiding attribute and
    -- are dismounted through Remotes.Game.PetDismount. Humanoid.SeatPart alone is
    -- not reliable for the custom mount system after the recent game update.
    if LocalPlayer:GetAttribute("IsRiding") == true then
        local remotes = ReplicatedStorage:FindFirstChild("Remotes")
        local gameRemotes = remotes and remotes:FindFirstChild("Game")
        local petDismount = gameRemotes and gameRemotes:FindFirstChild("PetDismount")
        if petDismount and petDismount:IsA("RemoteEvent") then
            pcall(function()
                petDismount:FireServer()
            end)

            local remoteDeadline = os.clock() + waitTime
            while Runtime.Alive
                and LocalPlayer:GetAttribute("IsRiding") == true
                and os.clock() < remoteDeadline do
                RunService.Heartbeat:Wait()
            end

            if LocalPlayer:GetAttribute("IsRiding") ~= true then
                return true, "dismounted through PetDismount"
            end
        end
    end

    if not humanoid.SeatPart then
        return true, "already dismounted"
    end

    humanoid.Sit = false
    humanoid.Jump = true
    pcall(function()
        humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
    end)

    local deadline = os.clock() + waitTime
    while Runtime.Alive and humanoid.Parent and humanoid.SeatPart and os.clock() < deadline do
        RunService.Heartbeat:Wait()
    end

    return humanoid.SeatPart == nil, humanoid.SeatPart == nil and "dismounted" or "seat still attached"
end

-- Auto Hatch ride preservation. The primary EggKey remote path is attempted while
-- mounted. Only if that hatch is not confirmed do we briefly dismount, retry once,
-- and then re-use the same Ride/Mount prompt when one can be identified. These
-- helpers run only on a failed ready-egg hatch, so they stay off the normal FPS path.
Runtime.EggAutomation.CaptureRideResumeState = function(plot)
    local state = {
        WasRiding = LocalPlayer:GetAttribute("IsRiding") == true,
        Prompt = nil,
        Target = nil,
    }

    if not state.WasRiding or not plot then
        return state
    end

    local humanoid = getHumanoid()
    if humanoid and humanoid.SeatPart then
        state.Target = humanoid.SeatPart:FindFirstAncestorWhichIsA("Model") or humanoid.SeatPart
        if state.Target then
            for _, object in ipairs(state.Target:GetDescendants()) do
                if object:IsA("ProximityPrompt") then
                    local promptText = getPromptSearchText(object)
                    if (string.find(promptText, "ride", 1, true)
                        or string.find(promptText, "mount", 1, true))
                        and not string.find(promptText, "dismount", 1, true) then
                        state.Prompt = object
                        return state
                    end
                end
            end
        end
    end

    -- Custom mounts may not populate Humanoid.SeatPart. In that case remember the
    -- nearest Ride/Mount prompt inside OUR Ranch before dismounting. This scan happens
    -- only on a ready hatch while mounted, never every frame.
    local root = getRootPart()
    if not root then
        return state
    end

    local bestDistance = math.huge
    for _, object in ipairs(plot:GetDescendants()) do
        if object:IsA("ProximityPrompt") then
            local promptText = getPromptSearchText(object)
            if (string.find(promptText, "ride", 1, true)
                or string.find(promptText, "mount", 1, true))
                and not string.find(promptText, "dismount", 1, true) then
                local part = getPromptPart(object)
                if part then
                    local distance = (root.Position - part.Position).Magnitude
                    if distance < bestDistance then
                        bestDistance = distance
                        state.Prompt = object
                        state.Target = part:FindFirstAncestorWhichIsA("Model") or part
                    end
                end
            end
        end
    end

    return state
end

Runtime.EggAutomation.ResumeCapturedRide = function(state)
    if type(state) ~= "table" or not state.WasRiding then
        return true, "ride resume not needed"
    end

    if LocalPlayer:GetAttribute("IsRiding") == true then
        return true, "still riding"
    end

    local prompt = state.Prompt
    if (not prompt or not prompt.Parent) and state.Target and state.Target.Parent then
        for _, object in ipairs(state.Target:GetDescendants()) do
            if object:IsA("ProximityPrompt") then
                local promptText = getPromptSearchText(object)
                if (string.find(promptText, "ride", 1, true)
                    or string.find(promptText, "mount", 1, true))
                    and not string.find(promptText, "dismount", 1, true) then
                    prompt = object
                    break
                end
            end
        end
    end

    if not prompt or not prompt.Parent then
        return false, "original Ride/Mount prompt unavailable"
    end

    local enableDeadline = os.clock() + 0.45
    while Runtime.Alive and prompt.Parent and not prompt.Enabled and os.clock() < enableDeadline do
        RunService.Heartbeat:Wait()
    end
    if not prompt.Parent or not prompt.Enabled then
        return false, "Ride/Mount prompt did not re-enable"
    end

    local part = getPromptPart(prompt)
    local root = getRootPart()
    if part and root then
        local maxDistance = math.max(4, tonumber(prompt.MaxActivationDistance) or 10)
        if (root.Position - part.Position).Magnitude > math.max(3, maxDistance - 1) then
            local moved = moveToModel(part, true)
            if not moved then
                return false, "could not reach original mount"
            end
        end
    end

    local ok, method = Runtime.InputCompat.InteractProximityPromptPortable(prompt, 0.05)
    if not ok then
        return false, "Ride/Mount input failed: " .. tostring(method)
    end

    local deadline = os.clock() + 1.15
    while Runtime.Alive and os.clock() < deadline do
        if LocalPlayer:GetAttribute("IsRiding") == true then
            return true, "re-mounted through " .. tostring(method)
        end
        local humanoid = getHumanoid()
        if humanoid and humanoid.SeatPart then
            return true, "re-seated through " .. tostring(method)
        end
        RunService.Heartbeat:Wait()
    end

    return false, "mount interaction sent but riding state was not confirmed"
end

Runtime.EggAutomation.WaitForHatchRemoval = function(egg, eggsFolder, timeout)
    local deadline = os.clock() + math.max(0.25, tonumber(timeout) or 1.5)
    while Runtime.Alive
        and egg
        and egg.Parent == eggsFolder
        and os.clock() < deadline do
        task.wait(0.05)
    end
    return not egg or egg.Parent ~= eggsFolder
end

local function acquireEggActionLock(timeout)
    local started = os.clock()
    timeout = timeout or 0.8

    -- Signal intent BEFORE waiting. The fast Auto Feed loop sees this flag and
    -- immediately yields, preventing 0.08s feeding from starving Auto Place/Hatch.
    Runtime.EggAutomation.RequestingAction = true

    while Runtime.Alive
        and (Runtime.EggAutomation.Busy or (Runtime.AutoFeed and Runtime.AutoFeed.Busy))
        and os.clock() - started < timeout do
        RunService.Heartbeat:Wait()
    end

    if Runtime.EggAutomation.Busy or (Runtime.AutoFeed and Runtime.AutoFeed.Busy) then
        Runtime.EggAutomation.RequestingAction = false
        return false
    end

    Runtime.EggAutomation.Busy = true
    return true
end

local function releaseEggActionLock()
    Runtime.EggAutomation.Busy = false
    Runtime.EggAutomation.RequestingAction = false
end

Runtime.EggAutomation.PlaceBestOnce = function(options)
    options = options or {}
    Runtime.EggAutomation.ActiveEggTool = nil

    local shouldYield, yieldReason = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
    if shouldYield then
        return false, "yielded to " .. tostring(yieldReason)
    end

    if not acquireEggActionLock(options.LockTimeout or 0.6) then
        return false, "egg automation busy"
    end

    local ok, success, message, placedCandidate = pcall(function()
        local atOwnedRanch, strictPlot, strictReason = ensureAtStrictOwnedRanchForEggAutomation()
        if not atOwnedRanch or not strictPlot then
            return false, strictReason or "STRICT OWNED RANCH: could not verify Ranch", nil
        end

        -- IMPORTANT: only a confirmed FULL Ranch is a pre-selection hard stop.
        -- Do NOT require a live Place prompt here. On current servers the prompt
        -- can be absent/disabled until a basket egg/slot becomes the active egg.
        local ranch = options.RanchSnapshot
        if not ranch or ranch.Plot ~= strictPlot or not isPlotOwnedByLocalPlayer(ranch.Plot) then
            -- LOW-FREEZE: use the event-invalidated cache first. A forced deep Ranch
            -- traversal here made every placement attempt hitch even when nothing changed.
            ranch = Runtime.EggAutomation.GetRanchSnapshot(false)
        end
        if not ranch.Plot or ranch.Plot ~= strictPlot then
            return false, "STRICT OWNED RANCH: Ranch snapshot did not match owned Plot", nil
        end
        if ranch.Full then
            return false, ranch.Reason or "Ranch full — placement unavailable", nil
        end

        local candidates = options.Candidates or Runtime.EggAutomation.GetPlaceCandidatesLight(options.ForceBagScan == true)
        if #candidates == 0 then
            local _, placeMinKg = Runtime.EggAutomation.GetPlaceFilterSummary()
            if placeMinKg > 0 then
                return false,
                    "no enabled Auto Place egg with readable weight ≥ "
                        .. tostring(placeMinKg) .. " kg found in bag/slot",
                    nil
            end
            return false, "no allowed egg found in bag/slot", nil
        end

        -- Highest Luck -> rarity -> KG is already enforced by the cached/full bag discovery path.
        -- Only the top candidate is attempted per worker cycle to avoid repeated
        -- UI clicks/equips and expensive prompt discovery in one frame window.
        -- A candidate is not considered
        -- selected merely because a click API returned without an exception;
        -- the live Ranch Place prompt is the confirmation that selection worked.
        local candidateAttempts = 0
        for _, candidate in ipairs(candidates) do
            -- FINAL PLACE MIN-KG HARD GUARD.
            -- Re-read the LIVE slot context immediately before any click/equip/
            -- direct-place path. Cached candidates can never bypass the minimum.
            local placeMinKg = Runtime.EggAutomation.GetPlaceMinWeight()

            if placeMinKg > 0 then
                local freshKg, freshKgSource =
                    Runtime.EggAutomation.ResolveCandidateWeight(candidate)

                candidate.WeightKg = freshKg or 0
                candidate.WeightSource =
                    freshKgSource or "final-weight-not-found"

                if not freshKg or freshKg < placeMinKg then
                    if Runtime.F8DebugEnabled then
                        print(
                            "[ZOLO KG BLOCK]"
                            .. " egg=" .. tostring(candidate.Name)
                            .. " kg=" .. tostring(freshKg or "unknown")
                            .. " min=" .. tostring(placeMinKg)
                            .. " source=" .. tostring(candidate.WeightSource)
                        )
                    end
                    continue
                end
            end

            if not Runtime.Weight.PlaceAllowed(candidate) then
                continue
            end

            candidateAttempts = candidateAttempts + 1
            if candidateAttempts > math.max(1, tonumber(Config.EggPlaceCandidateAttempts) or 3) then
                break
            end

            local liveEggsFolder = ranch.Plot and ranch.Plot:FindFirstChild("Eggs")
            local useFastDirect = Runtime.EggAutomation.DirectPlaceFastPath
                and liveEggsFolder ~= nil

            -- NONBLOCKING placement verification. Prefer the authoritative live Ranch
            -- egg folder and avoid rebuilding inventory/UI signatures on the hot path.
            local beforeLiveCount = liveEggsFolder and #liveEggsFolder:GetChildren() or nil
            local beforeCount = 0
            if not liveEggsFolder and not useFastDirect then
                local beforeRoots = Runtime.AutoGet.GetInventoryRoots(false)
                beforeCount = Runtime.AutoGet.CountOwnedEgg(candidate.Name, beforeRoots)
            end

            local activated, activateReason = activateEggCandidate(candidate)
            if activated then
                task.wait(math.max(0.04, tonumber(Config.EggSelectionSettle) or 0.12))

                -- No second kg gate here. Some servers create an equipped Tool
                -- without weight metadata even though its basket slot had the
                -- correct readable kg. Re-checking the Tool caused false failures.
                local shouldYieldNow, yieldWhyNow = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
                if shouldYieldNow then
                    return false, "yielded to " .. tostring(yieldWhyNow), candidate
                end

                -- Once direct held-tool placement has been confirmed on this server,
                -- skip the old Place-prompt wait entirely on following eggs. This is
                -- the low-stutter path used by the runtime shown in the F8 logs.
                if Runtime.EggAutomation.DirectPlaceFastPath then
                    local fastRanch = ranch
                    local beforePlacedSet = Runtime.EggAutomation.SnapshotPlacedEggChildren(fastRanch.Plot)
                    local directSuccess, directReason = Runtime.EggAutomation.TryDirectEggToolPlacement(
                        candidate,
                        fastRanch.Plot,
                        beforeCount,
                        fastRanch.Current,
                        beforePlacedSet
                    )

                    Runtime.DebugTeleport("EGG-AUTO", directSuccess and "FAST DIRECT PLACE SUCCESS" or "FAST DIRECT PLACE FAILED", {
                        egg = candidate.Name,
                        luck = candidate.Luck or 0,
                        rarity = candidate.Rarity,
                        weightKg = candidate.WeightKg,
                        direct = directReason,
                    })

                    if directSuccess then
                        return true,
                            string.format(
                                "Placed %s [Luck %.0f, %s, %.2f kg] via fast held-tool activation",
                                candidate.Name,
                                candidate.Luck or 0,
                                candidate.Rarity,
                                candidate.WeightKg
                            ),
                            candidate
                    end

                    if string.find(tostring(directReason), "yielded to", 1, true) then
                        return false, directReason, candidate
                    end

                    -- If the fast path unexpectedly stops working, disable it and
                    -- return. The next worker cycle may do one normal discovery pass;
                    -- never stack both expensive paths into the same frame window.
                    Runtime.EggAutomation.DirectPlaceFastPath = false
                    return false, directReason, candidate
                end

                local selectedRanch = Runtime.EggAutomation.GetRanchSnapshot(false)
                if not selectedRanch.Plot or selectedRanch.Plot ~= strictPlot or not isPlotOwnedByLocalPlayer(selectedRanch.Plot) then
                    return false, "STRICT OWNED RANCH: selected Ranch changed/refused", candidate
                end
                if selectedRanch.Full then
                    return false, selectedRanch.Reason or "Ranch became full before placement", candidate
                end

                -- Lightweight watcher: one prompt snapshot + DescendantAdded,
                -- instead of force-rescanning the full Ranch every poll tick.
                local prompts = Runtime.EggAutomation.WaitForPlacePromptsLight(
                    selectedRanch.Plot,
                    math.max(0.20, tonumber(Config.EggPlacePromptWait) or 0.70)
                )

                -- If a Place prompt was already visible before selection and is
                -- still valid, keep it as a fallback. This supports both server
                -- behaviors: always-visible prompts and selection-gated prompts.
                if (not prompts or #prompts == 0) and ranch and ranch.PlacePrompts then
                    local fallbackPrompts = {}
                    for _, entry in ipairs(ranch.PlacePrompts) do
                        local valid = isEntryValidForPlacement(entry)
                        if valid then
                            table.insert(fallbackPrompts, entry)
                        end
                    end
                    prompts = fallbackPrompts
                    selectedRanch = ranch
                end

                if prompts and #prompts > 0 then
                    local entry, affinityReason = findPreferredNestForEgg(candidate.Name, prompts)
                    if entry then
                        local beforeNestPrompt = entry.Prompt
                        local beforeRanchCurrent = selectedRanch and selectedRanch.Current or nil
                        local interacted, interactReason = interactPrompt(entry)

                        if interacted then
                            local verifyStarted = os.clock()
                            local timeout = math.max(0.55, tonumber(Config.EggActionTimeout) or 1.35)
                            local nextRanchVerify = 0
                            local addedChild = nil
                            local addedConnection = nil

                            if liveEggsFolder and liveEggsFolder.Parent then
                                addedConnection = liveEggsFolder.ChildAdded:Connect(function(child)
                                    addedChild = addedChild or child
                                end)
                            end

                            while Runtime.Alive and os.clock() - verifyStarted < timeout do
                                task.wait(0.06)

                                local promptGone = not beforeNestPrompt
                                    or not beforeNestPrompt.Parent
                                    or not beforeNestPrompt.Enabled
                                    or not looksLikePlaceEggPrompt(beforeNestPrompt)

                                local liveCountAdvanced = liveEggsFolder
                                    and beforeLiveCount ~= nil
                                    and #liveEggsFolder:GetChildren() > beforeLiveCount
                                local childAdded = addedChild and addedChild.Parent == liveEggsFolder

                                local hatchAppearedAtNest = false
                                local ranchCountAdvanced = false
                                if not liveEggsFolder
                                    and not childAdded
                                    and not liveCountAdvanced
                                    and os.clock() >= nextRanchVerify then
                                    nextRanchVerify = os.clock() + 0.30
                                    local refreshedRanch = Runtime.EggAutomation.GetRanchSnapshot(true)
                                    for _, hatchEntry in ipairs(refreshedRanch.HatchPrompts or {}) do
                                        if hatchEntry.Key == entry.Key then
                                            hatchAppearedAtNest = true
                                            break
                                        end
                                    end
                                    ranchCountAdvanced = beforeRanchCurrent
                                        and refreshedRanch.Current
                                        and refreshedRanch.Current > beforeRanchCurrent
                                end

                                if childAdded
                                    or liveCountAdvanced
                                    or hatchAppearedAtNest
                                    or ranchCountAdvanced
                                    or (not liveEggsFolder and promptGone) then
                                    if addedConnection then addedConnection:Disconnect() end
                                    rememberPlacement(candidate.Name, entry)
                                    Runtime.EggAutomation.ConsumeCachedCandidate(candidate)
                                    Runtime.EggAutomation.InvalidateRanchSnapshot()

                                    return true,
                                        string.format(
                                            "Placed %s [%s, %.2f kg] -> strict same-level cluster (%s)",
                                            candidate.Name,
                                            candidate.Rarity,
                                            candidate.WeightKg,
                                            affinityReason
                                        ),
                                        candidate
                                end
                            end

                            if addedConnection then addedConnection:Disconnect() end

                            -- Rare compatibility fallback for servers without Plot.Eggs.
                            -- Run ONCE after timeout, never repeatedly inside the 0.06s loop.
                            if not liveEggsFolder then
                                local roots = Runtime.AutoGet.GetInventoryRoots(false)
                                local afterCount = Runtime.AutoGet.CountOwnedEgg(candidate.Name, roots)
                                if afterCount < beforeCount then
                                    rememberPlacement(candidate.Name, entry)
                                    Runtime.EggAutomation.ConsumeCachedCandidate(candidate)
                                    Runtime.EggAutomation.InvalidateRanchSnapshot()
                                    return true,
                                        string.format(
                                            "Placed %s [%s, %.2f kg] -> inventory fallback (%s)",
                                            candidate.Name, candidate.Rarity, candidate.WeightKg, affinityReason
                                        ),
                                        candidate
                                end
                            end

                            Runtime.DebugTeleport("EGG-AUTO", "Place verification timed out", {
                                egg = candidate.Name,
                                rarity = candidate.Rarity,
                                weightKg = candidate.WeightKg,
                                activate = activateReason,
                                interact = interactReason,
                                placePrompts = prompts and #prompts or 0,
                            })
                        else
                            Runtime.DebugTeleport("EGG-AUTO", "Place prompt interaction failed", {
                                egg = candidate.Name,
                                reason = interactReason,
                            })
                        end
                    end
                else
                    local selectedTool, selectedToolWhy = Runtime.EggAutomation.FindMatchingEggTool(candidate)
                    local beforePlacedSet = Runtime.EggAutomation.SnapshotPlacedEggChildren(selectedRanch.Plot)
                    local directSuccess, directReason = Runtime.EggAutomation.TryDirectEggToolPlacement(
                        candidate,
                        selectedRanch.Plot,
                        beforeCount,
                        selectedRanch.Current,
                        beforePlacedSet
                    )

                    Runtime.DebugTeleport("EGG-AUTO", directSuccess and "DIRECT PLACE SUCCESS" or "Selected candidate but no Place prompt appeared", {
                        egg = candidate.Name,
                        luck = candidate.Luck or 0,
                        rarity = candidate.Rarity,
                        weightKg = candidate.WeightKg,
                        activate = activateReason,
                        direct = directReason,
                        tool = selectedTool and selectedTool:GetFullName() or "nil",
                        toolWhy = selectedToolWhy,
                        toolEquipped = selectedTool and getCharacter() and selectedTool:IsDescendantOf(getCharacter()) or false,
                    })

                    if directSuccess then
                        return true,
                            string.format(
                                "Placed %s [Luck %.0f, %s, %.2f kg] via held-tool activation",
                                candidate.Name,
                                candidate.Luck or 0,
                                candidate.Rarity,
                                candidate.WeightKg
                            ),
                            candidate
                    end
                end
            else
                Runtime.DebugTeleport("EGG-AUTO", "Candidate selection failed", {
                    egg = candidate.Name,
                    reason = activateReason,
                })
            end
        end

        return false, "no eligible egg could be placed: no live Place prompt and direct click fallback did not verify", nil
    end)

    -- Never leave the temporary placement Egg Tool equipped after the action.
    Runtime.EggAutomation.UnequipActiveEggTool()
    releaseEggActionLock()

    if not ok then
        Runtime.DebugTeleport("EGG-AUTO", "PlaceBestOnce ERROR", {error = success})
        return false, tostring(success)
    end

    Runtime.DebugTeleport("EGG-AUTO", success and "PLACE SUCCESS" or "PLACE SKIP/FAIL", {
        message = message,
        egg = placedCandidate and placedCandidate.Name or "nil",
        luck = placedCandidate and placedCandidate.Luck or 0,
        rarity = placedCandidate and placedCandidate.Rarity or "nil",
        weightKg = placedCandidate and placedCandidate.WeightKg or 0,
    })
    return success, message, placedCandidate
end

-- Current Ride A Pet hatch API. The September update exposes placed eggs under
-- Plot.Eggs with EggKey attributes and hatches them through Remotes.Game.Hatch.
-- Keep this lazy/cached so Auto Hatch does not require modules every worker tick.
local currentHatchApiCache = nil

-- v3.66 HATCH TIMER FIX:
-- The Hatch RemoteEvent is the only hard requirement. Earlier builds treated
-- client timing modules (GameData.Eggs/General + GameServices.DayNight) as mandatory;
-- when the experience moved/renamed one of those modules Auto Hatch silently saw
-- zero "ready" eggs even though Plot.Eggs already contained a live EggKey.
-- Timing modules are now OPTIONAL diagnostics only. The server decides readiness.
local function getCurrentHatchApi()
    if currentHatchApiCache
        and currentHatchApiCache.HatchRemote
        and currentHatchApiCache.HatchRemote.Parent then
        return currentHatchApiCache
    end

    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local gameRemotes = remotes and remotes:FindFirstChild("Game")
    local hatchRemote = gameRemotes and gameRemotes:FindFirstChild("Hatch")
    if not hatchRemote or not hatchRemote:IsA("RemoteEvent") then
        return nil, "Remotes.Game.Hatch RemoteEvent unavailable"
    end

    local api = {
        HatchRemote = hatchRemote,
        Eggs = nil,
        General = nil,
        DayNight = nil,
        EggDataByNormalizedName = nil,
        TimingAvailable = false,
    }

    -- Optional only: useful to prioritize eggs the client can prove are ready,
    -- but never allowed to disable Auto Hatch if a module changes in a game update.
    local gameData = ReplicatedStorage:FindFirstChild("GameData")
    local gameServices = ReplicatedStorage:FindFirstChild("GameServices")
    local eggsModule = gameData and gameData:FindFirstChild("Eggs")
    local generalModule = gameData and gameData:FindFirstChild("General")
    local dayNightModule = gameServices and gameServices:FindFirstChild("DayNight")

    if eggsModule and generalModule and dayNightModule then
        local okEggs, eggsData = pcall(require, eggsModule)
        local okGeneral, generalData = pcall(require, generalModule)
        local okDayNight, dayNight = pcall(require, dayNightModule)
        if okEggs and type(eggsData) == "table"
            and okGeneral and type(generalData) == "table"
            and okDayNight and type(dayNight) == "table" then
            api.Eggs = eggsData
            api.General = generalData
            api.DayNight = dayNight
            api.TimingAvailable = type(generalData.GrowthTimeFor) == "function"
                and type(dayNight.GrowthRealRemaining) == "function"
        end
    end

    currentHatchApiCache = api
    return api, api.TimingAvailable and "Hatch remote + optional timing modules" or "Hatch remote ready; timing modules optional/unavailable"
end

Runtime.EggAutomation.PlacedEggMetaCache = Runtime.EggAutomation.PlacedEggMetaCache
    or setmetatable({}, {__mode = "k"})
Runtime.EggAutomation.HatchAttemptState = Runtime.EggAutomation.HatchAttemptState or {}

-- Compact timer text used by Auto Hatch status/debug output.
Runtime.EggAutomation.FormatHatchRemaining = Runtime.EggAutomation.FormatHatchRemaining or function(seconds)
    seconds = math.max(0, math.floor((tonumber(seconds) or 0) + 0.5))
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    if hours > 0 then
        return string.format("%dh %02dm %02ds", hours, minutes, secs)
    elseif minutes > 0 then
        return string.format("%dm %02ds", minutes, secs)
    end
    return string.format("%ds", secs)
end

local function valueObjectValue(object)
    if not object then return nil end
    if object:IsA("StringValue") or object:IsA("IntValue")
        or object:IsA("NumberValue") or object:IsA("BoolValue")
        or object:IsA("ObjectValue") then
        return object.Value
    end
    return nil
end

local function readNamedPlacedEggValue(egg, name)
    if not egg then return nil end

    local value = egg:GetAttribute(name)
    if value ~= nil then return value end

    local direct = egg:FindFirstChild(name)
    value = valueObjectValue(direct)
    if value ~= nil then return value end

    local eggData = egg:FindFirstChild("EggData")
    if eggData then
        value = eggData:GetAttribute(name)
        if value ~= nil then return value end
        value = valueObjectValue(eggData:FindFirstChild(name))
        if value ~= nil then return value end
    end

    return nil
end

local function resolvePlacedEggKey(egg)
    local cache = Runtime.EggAutomation.PlacedEggMetaCache[egg]
    if cache and cache.EggKey ~= nil then
        return cache.EggKey
    end

    local eggKey = readNamedPlacedEggValue(egg, "EggKey")

    -- One-time compatibility fallback for servers that nest EggKey deeper inside
    -- EggData. This is never repeated every worker cycle because the result is cached.
    if eggKey == nil and egg then
        local eggData = egg:FindFirstChild("EggData")
        local nested = eggData and eggData:FindFirstChild("EggKey", true)
        eggKey = valueObjectValue(nested)
        if eggKey == nil and nested then
            eggKey = nested:GetAttribute("EggKey") or nested:GetAttribute("Value")
        end
    end

    cache = cache or {}
    cache.EggKey = eggKey
    Runtime.EggAutomation.PlacedEggMetaCache[egg] = cache
    return eggKey
end

local function resolvePlacedEggName(egg)
    local cache = Runtime.EggAutomation.PlacedEggMetaCache[egg]
    if cache and cache.EggName then
        return cache.EggName
    end

    local knownNames = getAutomationKnownEggNames()
    local knownByKey = {}
    for _, knownName in ipairs(knownNames) do
        knownByKey[normalizeEggKey(knownName)] = knownName
    end

    local eggName = nil
    for _, field in ipairs({"Egg", "EggName", "EggType", "Species", "Type"}) do
        local raw = readNamedPlacedEggValue(egg, field)
        if type(raw) == "string" and raw ~= "" then
            eggName = knownByKey[normalizeEggKey(raw)] or raw
            break
        end
    end

    if not eggName and egg then
        eggName = knownByKey[normalizeEggKey(egg.Name)]
    end

    -- Last-resort one-time deep parse. It may inspect descendants, but only when a
    -- newly placed egg has no direct species metadata; cached thereafter.
    if not eggName and egg then
        eggName = extractEggName(egg, knownNames)
    end

    cache = cache or {}
    cache.EggName = eggName or (egg and egg.Name) or "Unknown Egg"
    Runtime.EggAutomation.PlacedEggMetaCache[egg] = cache
    return cache.EggName
end

local function getEggDataDefinition(api, eggName, fallbackName)
    if not api or type(api.Eggs) ~= "table" then return nil end

    local direct = api.Eggs[eggName] or api.Eggs[fallbackName]
    if direct then return direct end

    if not api.EggDataByNormalizedName then
        api.EggDataByNormalizedName = {}
        for name, data in pairs(api.Eggs) do
            if type(name) == "string" then
                api.EggDataByNormalizedName[normalizeEggKey(name)] = data
            end
        end
    end

    return api.EggDataByNormalizedName[normalizeEggKey(eggName)]
        or api.EggDataByNormalizedName[normalizeEggKey(fallbackName)]
end

local function getCurrentPlacedEggRemaining(egg, api, resolvedEggName)
    if not egg or not egg.Parent or not api or not api.TimingAvailable then
        return nil, "server-authoritative readiness"
    end

    local eggData = getEggDataDefinition(api, resolvedEggName, egg.Name)
    local placeTimeValue = readNamedPlacedEggValue(egg, "PlaceTime")
    local weightValue = readNamedPlacedEggValue(egg, "Weight")

    if not eggData or placeTimeValue == nil then
        return nil, "optional timing metadata unavailable"
    end

    local okTotal, total = pcall(function()
        return api.General.GrowthTimeFor(
            eggData.GrowthTime or 0,
            tonumber(weightValue) or 1
        )
    end)
    if not okTotal or type(total) ~= "number" then
        return nil, "optional GrowthTimeFor failed"
    end

    local okRemaining, remaining = pcall(function()
        return api.DayNight.GrowthRealRemaining(placeTimeValue, total)
    end)
    if not okRemaining or type(remaining) ~= "number" then
        return nil, "optional GrowthRealRemaining failed"
    end

    return remaining, "optional client timer"
end

-- Returns ALL placed eggs carrying an EggKey. Readiness is intentionally not a
-- prerequisite: the Hatch server validates whether the egg is actually ready.
-- This avoids the v3.63 failure where a changed client timing module produced an
-- empty list forever.
local function getReadyRemoteHatchEntries(plot)
    local api, apiReason = getCurrentHatchApi()
    local eggsFolder = plot and plot:FindFirstChild("Eggs")
    if not api or not eggsFolder then
        return {}, api, apiReason or "Plot.Eggs unavailable"
    end

    local entries = {}
    for _, egg in ipairs(eggsFolder:GetChildren()) do
        if egg:IsA("Model") or egg:IsA("BasePart") then
            local eggKey = resolvePlacedEggKey(egg)
            if eggKey ~= nil then
                local eggName = resolvePlacedEggName(egg)
                local remaining, remainingReason = getCurrentPlacedEggRemaining(egg, api, eggName)
                table.insert(entries, {
                    Egg = egg,
                    EggKey = eggKey,
                    EggName = eggName,
                    Remaining = remaining,
                    ReadyByTimer = type(remaining) == "number" and remaining <= 0,
                    Reason = remainingReason,
                })
            end
        end
    end

    return entries, api, apiReason or "server-authoritative Hatch remote scan"
end

Runtime.EggAutomation.GetReadyRemoteHatchEntries = getReadyRemoteHatchEntries

Runtime.EggAutomation.HatchReadyOnce = function(options)
    options = options or {}

    local shouldYield, yieldReason = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
    if shouldYield then
        return false, "yielded to " .. tostring(yieldReason), 0
    end

    if not acquireEggActionLock(0.4) then
        return false, "egg automation busy", 0
    end

    local ok, success, message, hatchCount = pcall(function()
        local atOwnedRanch, strictPlot, strictReason = ensureAtStrictOwnedRanchForEggAutomation()
        if not atOwnedRanch or not strictPlot then
            return false, strictReason or "STRICT OWNED RANCH: could not verify Ranch", 0
        end

        -- PRIMARY CURRENT PATH (v3.66): Plot.Eggs + EggKey + timer-aware/server-authoritative
        -- readiness. At most ONE hatch request is attempted per worker pass, and each
        -- EggKey has its own retry cooldown. This fixes Auto Hatch without bringing
        -- back the old repeated Ranch scans/freezes.
        local remoteEntries, hatchApi, remoteScanReason = getReadyRemoteHatchEntries(strictPlot)
        local root = getRootPart()
        if root then
            table.sort(remoteEntries, function(a, b)
                -- Prefer an egg the optional client timer says is ready, then nearest.
                if a.ReadyByTimer ~= b.ReadyByTimer then
                    return a.ReadyByTimer == true
                end
                local ap = getTargetPosition(a.Egg)
                local bp = getTargetPosition(b.Egg)
                local ad = ap and (root.Position - ap).Magnitude or math.huge
                local bd = bp and (root.Position - bp).Magnitude or math.huge
                return ad < bd
            end)
        end

        local enabledPlacedCount = 0
        local attemptedEntry = nil
        local nextRetryIn = nil
        local now = os.clock()

        for _, remoteEntry in ipairs(remoteEntries) do
            if not Runtime.Alive then break end
            if isEggNameFilterEnabled(EggAutoState.HatchEggFilters, remoteEntry.EggName) then
                enabledPlacedCount = enabledPlacedCount + 1
                local stateKey = tostring(remoteEntry.EggKey)
                local attemptState = Runtime.EggAutomation.HatchAttemptState[stateKey]
                if type(attemptState) ~= "table" then
                    attemptState = {Failures = 0, NextAt = 0, NextDismountAt = 0}
                    Runtime.EggAutomation.HatchAttemptState[stateKey] = attemptState
                end

                local waitLeft = math.max(0, (attemptState.NextAt or 0) - now)
                if waitLeft <= 0 and not attemptedEntry then
                    attemptedEntry = remoteEntry
                    break
                elseif waitLeft > 0 and (nextRetryIn == nil or waitLeft < nextRetryIn) then
                    nextRetryIn = waitLeft
                end
            end
        end

        if attemptedEntry and hatchApi and hatchApi.HatchRemote then
            Runtime.EggAutomation.NextHatchWakeAt = 0
            local egg = attemptedEntry.Egg
            local eggsFolder = strictPlot:FindFirstChild("Eggs")
            local stateKey = tostring(attemptedEntry.EggKey)
            local attemptState = Runtime.EggAutomation.HatchAttemptState[stateKey]

            if egg and egg.Parent == eggsFolder then
                local shouldYieldNow, yieldWhyNow = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
                if shouldYieldNow then
                    return false, "yielded to " .. tostring(yieldWhyNow), 0
                end

                -- v3.66 TIMER-AWARE HATCH FIX:
                -- If the game's optional timer is available and positively says the
                -- egg is still growing, do NOT spam the Hatch RemoteEvent. The server
                -- will reject it anyway. Recheck periodically (max 30s sleep) so a
                -- server-side speed/luck change is picked up without visible freezes.
                if type(attemptedEntry.Remaining) == "number"
                    and attemptedEntry.Remaining > 0.15 then
                    local recheckIn = math.clamp(attemptedEntry.Remaining - 0.10, 0.50, 30.0)
                    attemptState.NextAt = os.clock() + recheckIn
                    Runtime.EggAutomation.NextHatchWakeAt = attemptState.NextAt
                    attemptState.Failures = 0
                    Runtime.DebugTeleport("EGG-AUTO", "HATCH TIMER WAIT", {
                        egg = attemptedEntry.EggName,
                        key = attemptedEntry.EggKey,
                        remaining = attemptedEntry.Remaining,
                        nextCheck = recheckIn,
                    })
                    return false,
                        string.format(
                            "Auto Hatch armed — %s ready in %s",
                            tostring(attemptedEntry.EggName),
                            Runtime.EggAutomation.FormatHatchRemaining
                                and Runtime.EggAutomation.FormatHatchRemaining(attemptedEntry.Remaining)
                                or string.format("%.0fs", attemptedEntry.Remaining)
                        ),
                        0
                end

                -- Timer is ready/unknown: make one server-authoritative request.
                attemptState.NextAt = os.clock() + 1.35
                local rideState = Runtime.EggAutomation.CaptureRideResumeState(strictPlot)
                local sent, sendErr = pcall(function()
                    hatchApi.HatchRemote:FireServer({EggKey = attemptedEntry.EggKey})
                end)

                local verified = sent and Runtime.EggAutomation.WaitForHatchRemoval(
                    egg,
                    eggsFolder,
                    math.max(0.80, math.min(1.25, tonumber(Config.EggActionTimeout) or 1.0))
                )

                if verified then
                    Runtime.EggAutomation.HatchAttemptState[stateKey] = nil
                    Runtime.EggAutomation.PlacedEggMetaCache[egg] = nil
                    Runtime.EggAutomation.LastHatchedEggName = attemptedEntry.EggName
                    Runtime.EggAutomation.InvalidateRanchSnapshot()
                    Runtime.DebugTeleport("EGG-AUTO", "CURRENT HATCH SUCCESS", {
                        egg = attemptedEntry.EggName,
                        key = attemptedEntry.EggKey,
                        remaining = attemptedEntry.Remaining,
                        timerReady = attemptedEntry.ReadyByTimer,
                        wasRiding = rideState.WasRiding,
                    })
                    return true, "Hatched " .. tostring(attemptedEntry.EggName), 1
                end

                attemptState.Failures = (attemptState.Failures or 0) + 1

                -- Mounted rejection compatibility: do NOT dismount on every not-ready
                -- request. Only retry dismounted when the optional timer says ready, or
                -- after several server-authoritative attempts, and rate-limit this path.
                local shouldDismountRetry = rideState.WasRiding
                    and egg.Parent == eggsFolder
                    and (attemptedEntry.ReadyByTimer == true or attemptState.Failures >= 3)
                    and os.clock() >= (attemptState.NextDismountAt or 0)

                if sent and shouldDismountRetry then
                    attemptState.NextDismountAt = os.clock() + 8.0
                    local dismounted, dismountReason = ensureDismountedForEggHatch(0.90)
                    if dismounted then
                        task.wait(0.05)
                        local retrySent, retryErr = pcall(function()
                            hatchApi.HatchRemote:FireServer({EggKey = attemptedEntry.EggKey})
                        end)
                        local retryVerified = retrySent and Runtime.EggAutomation.WaitForHatchRemoval(
                            egg,
                            eggsFolder,
                            math.max(0.80, math.min(1.25, tonumber(Config.EggActionTimeout) or 1.0))
                        )

                        local resumed, resumeReason = Runtime.EggAutomation.ResumeCapturedRide(rideState)
                        Runtime.DebugTeleport("EGG-AUTO", retryVerified
                            and "CURRENT HATCH SUCCESS AFTER DISMOUNT FALLBACK"
                            or "CURRENT HATCH DISMOUNT FALLBACK NOT CONFIRMED", {
                            egg = attemptedEntry.EggName,
                            key = attemptedEntry.EggKey,
                            failures = attemptState.Failures,
                            retrySent = retrySent,
                            retryError = retryErr,
                            remounted = resumed,
                            remountReason = resumeReason,
                        })

                        if retryVerified then
                            Runtime.EggAutomation.HatchAttemptState[stateKey] = nil
                            Runtime.EggAutomation.PlacedEggMetaCache[egg] = nil
                            Runtime.EggAutomation.LastHatchedEggName = attemptedEntry.EggName
                            Runtime.EggAutomation.InvalidateRanchSnapshot()
                            return true, "Hatched " .. tostring(attemptedEntry.EggName) .. " (dismount fallback)", 1
                        end
                    else
                        Runtime.DebugTeleport("EGG-AUTO", "CURRENT HATCH FALLBACK DISMOUNT FAILED", {
                            egg = attemptedEntry.EggName,
                            key = attemptedEntry.EggKey,
                            reason = dismountReason,
                        })
                    end
                end

                Runtime.DebugTeleport("EGG-AUTO", sent and "HATCH REQUEST SENT; SERVER NOT READY/NOT CONFIRMED" or "CURRENT HATCH REMOTE ERROR", {
                    egg = attemptedEntry.EggName,
                    key = attemptedEntry.EggKey,
                    failures = attemptState.Failures,
                    remaining = attemptedEntry.Remaining,
                    timerReady = attemptedEntry.ReadyByTimer,
                    scan = remoteScanReason,
                    error = sent and "none" or tostring(sendErr),
                })

                return false,
                    "waiting for server hatch readiness: " .. tostring(attemptedEntry.EggName),
                    0
            end
        end

        if #remoteEntries > 0 and enabledPlacedCount > 0 and nextRetryIn ~= nil then
            Runtime.EggAutomation.NextHatchWakeAt = os.clock() + math.max(0.25, nextRetryIn)
            return false,
                string.format("Auto Hatch armed — next server check in %.1fs", nextRetryIn),
                0
        end

        -- Compatibility fallback: old/current alternate servers that still expose
        -- an individual hatch ProximityPrompt continue to work. This deep Ranch scan
        -- is intentionally RATE-LIMITED: the EggKey remote path above is authoritative
        -- on current servers, so scanning every descendant every worker tick only
        -- creates visible frame freezes while there is nothing ready to hatch.
        local fallbackNow = os.clock()
        local fallbackAt = Runtime.EggAutomation.NextHatchFallbackScanAt or 0
        if fallbackNow < fallbackAt then
            return false, #remoteEntries > 0
                and "placed EggKey detected; waiting for enabled/server-ready egg"
                or "no placed EggKey detected for Auto Hatch", 0
        end
        Runtime.EggAutomation.NextHatchFallbackScanAt = fallbackNow
            + math.max(3.0, tonumber(Config.EggHatchPromptFallbackInterval) or 8.0)

        local ranch = Runtime.EggAutomation.GetRanchSnapshot(true)
        if not ranch.Plot or ranch.Plot ~= strictPlot or not isPlotOwnedByLocalPlayer(ranch.Plot) then
            return false, "STRICT OWNED RANCH: Hatch snapshot did not match owned Plot", 0
        end
        local prompts = ranch.HatchPrompts or {}
        if #prompts == 0 then
            return false, #remoteEntries > 0
                and "placed EggKey detected; waiting for enabled/server-ready egg"
                or "no placed EggKey detected for Auto Hatch", 0
        end

        local count = 0
        root = getRootPart()
        if root then
            table.sort(prompts, function(a, b)
                local ap = getEntryPosition(a)
                local bp = getEntryPosition(b)
                local ad = ap and (root.Position - ap).Magnitude or math.huge
                local bd = bp and (root.Position - bp).Magnitude or math.huge
                return ad < bd
            end)
        end

        for _, entry in ipairs(prompts) do
            if not Runtime.Alive then break end

            local shouldYieldNow, yieldWhyNow = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
            if shouldYieldNow then
                return false, "yielded to " .. tostring(yieldWhyNow), 0
            end

            if entry.Prompt and entry.Prompt.Parent and entry.Prompt.Enabled then
                entry.Plot = entry.Plot or strictPlot
                local entryOwned, entryOwnedReason = belongsToStrictOwnedPlot(entry.Prompt, strictPlot)
                if not entryOwned then
                    Runtime.DebugTeleport("EGG-AUTO", "STRICT OWNED RANCH HATCH BLOCK", {
                        target = entry.Prompt:GetFullName(),
                        reason = entryOwnedReason,
                    })
                    continue
                end

                local hatchEggName, hatchEggObject, hatchNameReason = Runtime.EggAutomation.GetHatchEntryEggName(entry, strictPlot)
                if not hatchEggName then
                    Runtime.DebugTeleport("EGG-AUTO", "HATCH FILTER SKIP: egg name unresolved", {
                        target = entry.Prompt:GetFullName(),
                        reason = hatchNameReason,
                    })
                    continue
                end

                if not isEggNameFilterEnabled(EggAutoState.HatchEggFilters, hatchEggName) then
                    Runtime.DebugTeleport("EGG-AUTO", "HATCH FILTER SKIP: egg blocked", {
                        egg = hatchEggName,
                        target = hatchEggObject and hatchEggObject:GetFullName() or entry.Prompt:GetFullName(),
                        reason = hatchNameReason,
                    })
                    continue
                end

                local eggsFolder = strictPlot:FindFirstChild("Eggs")
                local interacted = interactPrompt(entry)
                if interacted then
                    local verifyDeadline = os.clock() + math.max(
                        2.0,
                        tonumber(Config.EggActionTimeout) or 1.35
                    )
                    while Runtime.Alive
                        and hatchEggObject
                        and hatchEggObject.Parent
                        and eggsFolder
                        and hatchEggObject:IsDescendantOf(eggsFolder)
                        and os.clock() < verifyDeadline do
                        task.wait(0.05)
                    end

                    local verified = hatchEggObject == nil
                        or hatchEggObject.Parent == nil
                        or not eggsFolder
                        or not hatchEggObject:IsDescendantOf(eggsFolder)

                    if verified then
                        count = 1
                        Runtime.EggAutomation.LastHatchedEggName = hatchEggName
                        break
                    end

                    local rideState = Runtime.EggAutomation.CaptureRideResumeState(strictPlot)
                    if rideState.WasRiding and hatchEggObject and hatchEggObject.Parent then
                        local dismounted, dismountReason = ensureDismountedForEggHatch(0.90)
                        if dismounted then
                            local retryInteracted = interactPrompt(entry)
                            if retryInteracted then
                                verified = Runtime.EggAutomation.WaitForHatchRemoval(
                                    hatchEggObject,
                                    eggsFolder,
                                    math.max(1.5, tonumber(Config.EggActionTimeout) or 1.35)
                                )
                            end
                            local resumed, resumeReason = Runtime.EggAutomation.ResumeCapturedRide(rideState)
                            Runtime.DebugTeleport("EGG-AUTO", "PROMPT HATCH DISMOUNT FALLBACK", {
                                egg = hatchEggName,
                                target = entry.Prompt:GetFullName(),
                                verified = verified,
                                remounted = resumed,
                                remountReason = resumeReason,
                            })
                            if verified then
                                count = 1
                                Runtime.EggAutomation.LastHatchedEggName = hatchEggName
                                break
                            end
                        else
                            Runtime.DebugTeleport("EGG-AUTO", "PROMPT HATCH FALLBACK DISMOUNT FAILED", {
                                egg = hatchEggName,
                                reason = dismountReason,
                            })
                        end
                    end

                    Runtime.DebugTeleport("EGG-AUTO", "PROMPT HATCH NOT CONFIRMED", {
                        egg = hatchEggName,
                        target = entry.Prompt:GetFullName(),
                    })
                end
            end
        end

        if count > 0 then
            Runtime.EggAutomation.InvalidateRanchSnapshot()
            return true, "Hatched " .. tostring(Runtime.EggAutomation.LastHatchedEggName or "enabled egg"), count
        end
        return false, "no enabled Auto Hatch egg is ready", 0
    end)

    releaseEggActionLock()

    if not ok then
        Runtime.DebugTeleport("EGG-AUTO", "HatchReadyOnce ERROR", {error = success})
        return false, tostring(success), 0
    end

    Runtime.DebugTeleport("EGG-AUTO", success and "HATCH SUCCESS" or "HATCH SKIP/FAIL", {
        message = message,
        count = hatchCount,
    })
    return success, message, hatchCount
end

Runtime.EggAutomation.RefreshButtons = function()
    if Runtime.EggAutomation.UI.AutoPlaceBtn then
        Runtime.EggAutomation.UI.AutoPlaceBtn.Text = EggAutoState.AutoPlace and "Auto Place Eggs: ON (ARMED)" or "Auto Place Eggs: OFF"
        Runtime.EggAutomation.UI.AutoPlaceBtn.BackgroundColor3 = EggAutoState.AutoPlace
            and Color3.fromRGB(0, 145, 82)
            or Color3.fromRGB(35, 45, 58)
    end
    if Runtime.EggAutomation.UI.AutoHatchBtn then
        Runtime.EggAutomation.UI.AutoHatchBtn.Text = EggAutoState.AutoHatch and "Auto Hatch Eggs: ON (ARMED)" or "Auto Hatch Eggs: OFF"
        Runtime.EggAutomation.UI.AutoHatchBtn.BackgroundColor3 = EggAutoState.AutoHatch
            and Color3.fromRGB(0, 145, 82)
            or Color3.fromRGB(35, 45, 58)
    end
    if Runtime.EggAutomation.UI.PriorityBtn then
        EggAutoState.PriorityEnabled = true
        Runtime.EggAutomation.UI.PriorityBtn.Text = "Priority: Luck > Rarity > KG (FIXED)"
        Runtime.EggAutomation.UI.PriorityBtn.BackgroundColor3 = Color3.fromRGB(0, 120, 170)
    end
end

Runtime.EggAutomation.AnyAutoPlaceEggEnabled = function()
    return anyEggNameFilterEnabled(EggAutoState.PlaceEggFilters)
end

Runtime.EggAutomation.AnyAutoHatchEggEnabled = function()
    return anyEggNameFilterEnabled(EggAutoState.HatchEggFilters)
end

Runtime.EggAutomation.StopSharedWorkerIfUnused = function()
    if EggAutoState.AutoPlace or EggAutoState.AutoHatch then
        return
    end
    if Runtime.EggAutomation.WorkerThread then
        pcall(task.cancel, Runtime.EggAutomation.WorkerThread)
        Runtime.EggAutomation.WorkerThread = nil
    end
end

Runtime.EggAutomation.EnsureSharedWorker = function()
    if Runtime.EggAutomation.WorkerThread then
        return
    end

    Runtime.EggAutomation.WorkerThread = task.spawn(function()
        local lastStatus = nil

        local function statusOnce(text, good)
            if text ~= lastStatus then
                lastStatus = text
                setEggAutomationStatus(text, good)
            end
        end

        while Runtime.Alive and (EggAutoState.AutoPlace or EggAutoState.AutoHatch) do
            local sleepTime = math.max(0.25, tonumber(Config.EggAutomationPoll) or 0.85)

            -- ON means ARMED. Auto Place / Auto Hatch are independent from the
            -- Get Egg filter/queue. They only pause while Get Egg is ACTIVELY handling
            -- an egg, or while another primary automation is using movement.
            local shouldYield, yieldReason = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
            if shouldYield then
                statusOnce("Egg Auto armed — yielding to " .. tostring(yieldReason), nil)
                sleepTime = math.max(sleepTime, tonumber(Config.EggPrimaryAutomationYieldPoll) or 0.90)
            elseif not isNearOwnedPlot(Config.EggHomeRadius) then
                statusOnce("Egg Auto armed — waiting until character is inside owned Ranch bounds", nil)
                sleepTime = math.max(sleepTime, tonumber(Config.EggUnavailablePoll) or 1.25)
            else
                -- LOW-FREEZE WORKER: do NOT build a deep Ranch snapshot just because
                -- either toggle is ON. Auto Hatch uses the cheap Plot.Eggs + EggKey
                -- path first; Auto Place scans the Ranch only when an eligible bag
                -- candidate actually exists and placement needs spatial prompt data.
                local actionTaken = false

                -- Hatch first. If the Ranch is full, hatching can free a slot while
                -- Auto Place remains idle. No Ranch GetDescendants() is needed here.
                if EggAutoState.AutoHatch and not Runtime.EggAutomation.AnyAutoHatchEggEnabled() then
                    statusOnce("Auto Hatch armed — select at least one egg in the Hatch filter", nil)
                    sleepTime = math.max(sleepTime, tonumber(Config.EggNoRarityPoll) or 2.25)
                elseif EggAutoState.AutoHatch and not Runtime.EggAutomation.Busy then
                    local hatchNow = os.clock()
                    local hatchWakeAt = Runtime.EggAutomation.NextHatchWakeAt or 0
                    if hatchWakeAt > hatchNow then
                        -- Known growing/cooldown state: skip ownership checks, Plot.Eggs
                        -- parsing, sorting and timer module calls until they are useful.
                        sleepTime = math.max(sleepTime, math.min(5.0, hatchWakeAt - hatchNow))
                    else
                        local success, message, count = Runtime.EggAutomation.HatchReadyOnce()
                        if success and count > 0 then
                            statusOnce(message, true)
                            actionTaken = true
                            task.wait(tonumber(Config.EggActionCooldown) or 0.35)
                        elseif not EggAutoState.AutoPlace then
                            statusOnce(message or "Auto Hatch armed — no ready egg", nil)
                            sleepTime = math.max(sleepTime, tonumber(Config.EggUnavailablePoll) or 2.00)
                        end
                    end
                end

                local yieldBeforePlace, yieldBeforePlaceReason = Runtime.EggAutomation.ShouldYieldToPrimaryAutomation()
                if yieldBeforePlace then
                    statusOnce("Egg Auto armed — yielding to " .. tostring(yieldBeforePlaceReason), nil)
                    sleepTime = math.max(sleepTime, tonumber(Config.EggPrimaryAutomationYieldPoll) or 1.10)
                elseif EggAutoState.AutoPlace and not Runtime.EggAutomation.Busy then
                    local nowPlace = os.clock()
                    if nowPlace < (Runtime.EggAutomation.NextPlaceAttemptAt or 0) then
                        sleepTime = math.max(sleepTime, math.min(1.0, (Runtime.EggAutomation.NextPlaceAttemptAt or 0) - nowPlace))
                    elseif not Runtime.EggAutomation.AnyAutoPlaceEggEnabled() then
                        statusOnce("Auto Place armed — select at least one egg in the Place filter", nil)
                        sleepTime = math.max(sleepTime, tonumber(Config.EggNoRarityPoll) or 2.25)
                    else
                        -- Cheap capacity guard: Plot.Eggs children are authoritative on
                        -- current servers and avoid a full Plot:GetDescendants() scan.
                        local lightPlot = getStrictOwnedPlot()
                        local lightEggsFolder = lightPlot and lightPlot:FindFirstChild("Eggs")
                        local lightEggCount = 0
                        if lightEggsFolder then
                            for _, child in ipairs(lightEggsFolder:GetChildren()) do
                                if child:IsA("Model") or child:IsA("BasePart") then
                                    lightEggCount = lightEggCount + 1
                                end
                            end
                        end

                        if lightEggsFolder and lightEggCount >= 10 then
                            statusOnce("Auto Place armed — Ranch full (" .. tostring(lightEggCount) .. "/10)", nil)
                            sleepTime = math.max(sleepTime, tonumber(Config.EggUnavailablePoll) or 2.00)
                        else
                            local candidates = Runtime.EggAutomation.GetPlaceCandidatesLight(false)
                            if #candidates > 0 then
                                local success, message = Runtime.EggAutomation.PlaceBestOnce({
                                    RequireHome = true,
                                    Candidates = candidates,
                                })
                                if success then
                                    Runtime.EggAutomation.NextPlaceAttemptAt = 0
                                    statusOnce(message, true)
                                    actionTaken = true
                                elseif message ~= "egg automation busy"
                                    and message ~= "no allowed egg found in bag/slot"
                                    and not string.find(tostring(message), "yielded to", 1, true) then
                                    Runtime.EggAutomation.LastPlaceFailureAt = os.clock()
                                    Runtime.EggAutomation.NextPlaceAttemptAt = os.clock()
                                        + math.max(1.0, tonumber(Config.EggPlaceFailureCooldown) or 1.35)
                                    statusOnce(message .. " — retry cooled down", nil)
                                    sleepTime = math.max(sleepTime, tonumber(Config.EggPlaceFailureCooldown) or 1.35)
                                end
                            else
                                local _, placeMinKg = Runtime.EggAutomation.GetPlaceFilterSummary()
                                if placeMinKg > 0 then
                                    statusOnce(
                                        "Auto Place armed — no enabled Place-filter egg with resolved slot weight ≥ "
                                            .. tostring(placeMinKg)
                                            .. " kg (change Min kg to force a fresh bag scan)",
                                        nil
                                    )
                                else
                                    statusOnce("Auto Place armed — no enabled Place-filter egg in cached bag/slot", nil)
                                end
                                sleepTime = math.max(sleepTime, tonumber(Config.EggUnavailablePoll) or 2.00)
                            end
                        end
                    end
                end

                if actionTaken then
                    -- Always yield at least one short frame window after an egg action.
                    -- This prevents Auto Place/Hatch from monopolizing the client when
                    -- Auto Feed is also running at a fast cadence.
                    sleepTime = math.max(0.10, tonumber(Config.EggActionCooldown) or 0.20)
                end
            end

            task.wait(sleepTime)
        end

        Runtime.EggAutomation.WorkerThread = nil
    end)
end

Runtime.EggAutomation.StopAutoPlace = function()
    EggAutoState.AutoPlace = false
    EggAutoState.AutoPlaceThread = nil
    Runtime.EggAutomation.NextPlaceAttemptAt = 0
    Runtime.EggAutomation.RefreshButtons()
    Runtime.EggAutomation.StopSharedWorkerIfUnused()
end

Runtime.EggAutomation.StartAutoPlace = function()
    EggAutoState.AutoPlace = true
    EggAutoState.AutoPlaceThread = nil
    Runtime.EggAutomation.NextPlaceAttemptAt = 0
    Runtime.EggAutomation.MarkBagCacheDirty("Auto Place started")
    Runtime.EggAutomation.WakeSerial = (Runtime.EggAutomation.WakeSerial or 0) + 1
    Runtime.EggAutomation.InvalidateRanchSnapshot("Auto Place started")
    Runtime.EggAutomation.RefreshButtons()
    Runtime.EggAutomation.EnsureSharedWorker()
end

Runtime.EggAutomation.StopAutoHatch = function()
    EggAutoState.AutoHatch = false
    Runtime.EggAutomation.NextHatchWakeAt = 0
    EggAutoState.AutoHatchThread = nil
    Runtime.EggAutomation.RefreshButtons()
    Runtime.EggAutomation.StopSharedWorkerIfUnused()
end

Runtime.EggAutomation.StartAutoHatch = function()
    EggAutoState.AutoHatch = true
    Runtime.EggAutomation.NextHatchWakeAt = 0
    EggAutoState.AutoHatchThread = nil
    Runtime.EggAutomation.WakeSerial = (Runtime.EggAutomation.WakeSerial or 0) + 1
    -- Current EggKey remote checks run immediately. The expensive legacy prompt
    -- fallback waits for its cooldown so toggling Auto Hatch itself cannot freeze.
    Runtime.EggAutomation.NextHatchFallbackScanAt = os.clock()
        + math.max(3.0, tonumber(Config.EggHatchPromptFallbackInterval) or 8.0)
    Runtime.EggAutomation.InvalidateRanchSnapshot("Auto Hatch started")
    Runtime.EggAutomation.RefreshButtons()
    Runtime.EggAutomation.EnsureSharedWorker()
end

-- Compatibility hook kept only so older cached code cannot error if it references it.
-- Get Egg does NOT wake, queue, select, place, or hatch anything here; Auto Place and
-- Auto Hatch are driven exclusively by their own toggles/shared worker.
Runtime.EggAutomation.OnEggConfirmed = function(_eggName)
    return false
end


    -- Export only the small public surface used by UI/config/cleanup.
    Runtime.EggAutomation.SetStatus = setEggAutomationStatus

    -- v3.39.1 SCOPE FIX:
    -- These helpers are declared inside this Egg Automation do-block. Late UI,
    -- profile restore, and F8 diagnostics live outside the block, so expose the
    -- helpers through Runtime instead of accidentally resolving nil globals.
    Runtime.EggAutomation.NormalizeEggKey = normalizeEggKey
    Runtime.EggAutomation.IsEggNameFilterEnabled = isEggNameFilterEnabled
    Runtime.EggAutomation.SetEggNameFilterEnabled = setEggNameFilterEnabled
    Runtime.EggAutomation.AnyEggNameFilterEnabled = anyEggNameFilterEnabled
    Runtime.EggAutomation.GetKnownEggNames = getAutomationKnownEggNames
end

Runtime.AutoGet.WaitPickup = function(egg, active)
    local deadline = math.max(os.clock() + Runtime.AutoGet.PickupDelay, Runtime.AutoGet.NextPickupAt)
    if StatusLabel then StatusLabel.Text = "● Waiting before pickup: " .. egg.Name end
    repeat
        if not Runtime.Alive or not active() or not egg.Parent or not Runtime.Weight.GetAllowed(egg) then return false end
        if os.clock() >= deadline then break end
        task.wait(math.min(0.05, deadline - os.clock()))
    until false
    Runtime.AutoGet.NextPickupAt = os.clock() + math.max(3, Runtime.AutoGet.PickupDelay)
    return true
end

local function findBestEgg()

    if not RenderedEggsFolder then

        return nil

    end

    for _, egg in ipairs(RenderedEggsFolder:GetChildren()) do

        if string.find(

            egg.Name:lower(),

            Config.BestEggName:lower(),

            1,

            true

        ) and Runtime.Weight.GetAllowed(egg) then

            return egg

        end

    end

    return nil

end

local function stopAutoBestEgg()

    autoBestEggActive = false

    stopMovement()

    if autoBestEggThread then

        task.cancel(autoBestEggThread)

        autoBestEggThread = nil

    end

    if Runtime.AutoGet and Runtime.AutoGet.RefreshEggModeUI then
        task.defer(Runtime.AutoGet.RefreshEggModeUI)
    end

end

local function startAutoBestEgg()

    stopAutoBestEgg()

    autoBestEggActive = true

    autoBestEggThread = task.spawn(function()

        while Runtime.Alive and autoBestEggActive do

            local egg = findBestEgg()

            if egg and egg.Parent then

                local teleported = moveToModel(egg)

                if teleported then

                    task.wait(0.3)

                    if autoBestEggActive and egg.Parent
                        and Runtime.AutoGet.WaitPickup(egg, function() return autoBestEggActive end) then

                        holdEKey(Config.AutoEggHoldTime, egg)

                    end

                    task.wait(0.2)

                    if autoBestEggActive then

                        teleportToHomePlot()

                    end

                    task.wait(Config.AutoEggDelay)

                end

            else

                -- Si no existe el Egg, esperamos y volvemos a buscar.

                task.wait(0.5)

            end

        end

    end)

end

--==================================================

--==================================================

-- AUTOFARM DE EGGS SELECCIONADOS

--==================================================

local function setAutoFarmButtonState(button, active)

    if not button then

        return

    end

    if active then

        button.Text = "AutoFarm: ON"

        button.BackgroundColor3 = Color3.fromRGB(0, 150, 70)

    else

        button.Text = "AutoFarm"

        button.BackgroundColor3 = Color3.fromRGB(45, 45, 45)

    end

end

local function isValidEgg(egg)

    return egg

        and egg.Parent == RenderedEggsFolder

        and (egg:IsA("Model") or egg:IsA("BasePart"))

end

local function getAutoFarmEggs()
    local found = {}
    local scan = {
        Selected = 0,
        Eligible = 0,
        Below = 0,
        Unknown = 0,
        EnabledFilters = 0,
        Samples = {},
    }

    for _, active in pairs(autoFarmEggs) do
        if active then scan.EnabledFilters = scan.EnabledFilters + 1 end
    end

    if not RenderedEggsFolder then
        return found, scan
    end

    for _, egg in ipairs(RenderedEggsFolder:GetChildren()) do
        if #scan.Samples < 4 then
            table.insert(scan.Samples, tostring(egg.Name) .. "=>" .. tostring(Runtime.EggIdentity.Resolve(egg)))
        end

        if isValidEgg(egg)
            and Runtime.EggIdentity.GetSelected(egg)
            and not autoFarmProcessed[egg] then

            scan.Selected = scan.Selected + 1
            local weight = Runtime.Weight.Read(egg)

            if Runtime.Weight.Allows(weight, Runtime.AutoGet.MinWeightKg) then
                scan.Eligible = scan.Eligible + 1
                table.insert(found, egg)
            elseif weight == nil then
                scan.Unknown = scan.Unknown + 1
            else
                scan.Below = scan.Below + 1
            end
        end
    end

    if Runtime.TeleportDebug.Enabled and os.clock() >= (Runtime.AutoGet.NextFilterLog or 0) then
        Runtime.AutoGet.NextFilterLog = os.clock() + 5
        Runtime.DebugTeleport("GET-EGG", "Filter scan", {
            selected = scan.Selected,
            eligible = scan.Eligible,
            enabledFilters = scan.EnabledFilters,
            rendered = #RenderedEggsFolder:GetChildren(),
            catalog = #Runtime.EggIdentity.Catalog(),
            samples = table.concat(scan.Samples, "; "),
            belowMinKg = scan.Below,
            unknownKg = scan.Unknown,
            minKg = Runtime.AutoGet.MinWeightKg,
            pickupMethod = Runtime.AutoGet.PickupMethod,
            delay = Runtime.AutoGet.PickupDelay,
            rejoinBelowMin = Runtime.AutoGet.RejoinBelowMin.Enabled,
        })
    end

    table.sort(found, function(a, b)
        local wa = Runtime.Weight.Read(a) or 0
        local wb = Runtime.Weight.Read(b) or 0
        if math.abs(wa - wb) > 0.001 then return wa > wb end
        return a.Name:lower() < b.Name:lower()
    end)

    return found, scan
end

Runtime.AutoGet.RefreshRejoinBelowMinUI = function()
    local state = Runtime.AutoGet.RejoinBelowMin
    local button = state.UI and state.UI.Toggle
    if button and button.Parent then
        if state.Busy then
            button.Text = "Rejoin Below Min: REJOINING..."
            button.BackgroundColor3 = Color3.fromRGB(120, 75, 30)
        elseif state.Enabled then
            button.Text = "Rejoin Below Min: ON"
            button.BackgroundColor3 = Color3.fromRGB(0, 130, 75)
        else
            button.Text = "Rejoin Below Min: OFF"
            button.BackgroundColor3 = Color3.fromRGB(35, 45, 58)
        end
        button.TextColor3 = Color3.fromRGB(235, 242, 250)
    end
end

Runtime.AutoGet.SetRejoinBelowMinEnabled = function(enabled, quiet)
    local state = Runtime.AutoGet.RejoinBelowMin
    enabled = enabled == true

    -- Reliable repeated rejoin requires a FRESH remote loader after teleport.
    -- Do not rejoin into a destination that has no URL from which to reload ZOLO.
    if enabled and Runtime.Transport then
        if type(Runtime.Transport.GetRemoteReleaseURL) == "function"
            and not Runtime.Transport.GetRemoteReleaseURL() then

            state.Enabled = false
            state.Busy = false
            state.BelowSince = nil
            Runtime.AutoGet.RefreshRejoinBelowMinUI()

            if not quiet and StatusLabel then
                StatusLabel.Text =
                    "● Rejoin blocked — execute PUBLIC_main.lua first"
                StatusLabel.TextColor3 = Color3.fromRGB(255, 150, 110)
            end
            return false
        end

        if type(Runtime.Transport.SetAutoExecute) == "function" then
            local ok = Runtime.Transport.SetAutoExecute(true, true)
            if ok == false then
                state.Enabled = false
                state.Busy = false
                state.BelowSince = nil
                Runtime.AutoGet.RefreshRejoinBelowMinUI()

                if not quiet and StatusLabel then
                    StatusLabel.Text =
                        "● Rejoin needs working queue_on_teleport + remote loader"
                    StatusLabel.TextColor3 = Color3.fromRGB(255, 150, 110)
                end
                return false
            end
        end
    end

    state.Enabled = enabled
    state.Busy = false
    state.BelowSince = nil

    if Runtime.Transport and type(Runtime.Transport.SetTeleportFlag) == "function" then
        Runtime.Transport.SetTeleportFlag("ZoloEggsESP_RejoinBelowMinEnabled", state.Enabled)
        if not state.Enabled then
            Runtime.Transport.SetTeleportFlag("ZoloEggsESP_RejoinBelowMinResume", false)
        end
    end

    Runtime.AutoGet.RefreshRejoinBelowMinUI()

    if not quiet and StatusLabel then
        StatusLabel.Text = state.Enabled
            and "● Rejoin Below Min ON — below-min filtered Eggs will rejoin"
            or "● Rejoin Below Min OFF"
        StatusLabel.TextColor3 = state.Enabled
            and Color3.fromRGB(0, 255, 120)
            or Color3.fromRGB(180, 180, 180)
    end

    return true
end

Runtime.AutoGet.BuildRejoinPayload = function()
    local filters = {}
    for key, enabled in pairs(autoFarmEggs) do
        if enabled == true then
            table.insert(filters, tostring(key))
        end
    end
    table.sort(filters)

    local HttpService = game:GetService("HttpService")
    local ok, encoded = pcall(function()
        return HttpService:JSONEncode({
            Version = 1,
            MinWeightKg = Runtime.AutoGet.MinWeightKg,
            Filters = filters,
        })
    end)

    return ok and encoded or nil
end

Runtime.AutoGet.TryRejoinBelowMin = function(scan)
    local state = Runtime.AutoGet.RejoinBelowMin
    if not state.Enabled or state.Busy or not autoFarmActive then
        state.BelowSince = nil
        return false
    end

    scan = scan or {}

    -- Only rejoin when at least one selected/filter-matching Egg is actually
    -- rendered, every such Egg has a readable weight, and none reaches Min kg.
    -- Unknown weights are allowed to settle instead of causing a false hop.
    local allKnownBelow = (tonumber(scan.Selected) or 0) > 0
        and (tonumber(scan.Eligible) or 0) == 0
        and (tonumber(scan.Below) or 0) > 0
        and (tonumber(scan.Unknown) or 0) == 0

    if not allKnownBelow then
        state.BelowSince = nil
        return false
    end

    state.BelowSince = state.BelowSince or os.clock()
    if os.clock() - state.BelowSince < math.max(0.35, tonumber(state.GraceSeconds) or 1.10) then
        return false
    end

    if os.clock() - (state.LastAttemptAt or 0) < math.max(2, tonumber(state.Cooldown) or 6) then
        return false
    end

    local transport = Runtime.Transport
    if not transport
        or type(transport.Rejoin) ~= "function"
        or type(transport.SetTeleportFlag) ~= "function" then
        return false
    end

    local payload = Runtime.AutoGet.BuildRejoinPayload()
    local TeleportService = game:GetService("TeleportService")

    transport.SetTeleportFlag("ZoloEggsESP_RejoinBelowMinEnabled", true)
    transport.SetTeleportFlag("ZoloEggsESP_RejoinBelowMinResume", true)
    if payload then
        pcall(function()
            TeleportService:SetTeleportSetting("ZoloEggsESP_RejoinBelowMinPayload", payload)
        end)
    end

    -- IMPORTANT: do not queue here. Rejoin() owns the single queue registration
    -- after every resume flag/payload has already been written.
    state.Busy = true
    state.LastAttemptAt = os.clock()
    Runtime.AutoGet.RefreshRejoinBelowMinUI()

    if StatusLabel then
        StatusLabel.Text = "● Selected Egg is below " .. tostring(Runtime.AutoGet.MinWeightKg)
            .. " kg — rejoining..."
        StatusLabel.TextColor3 = Color3.fromRGB(255, 200, 90)
    end

    Runtime.DebugTeleport("GET-EGG", "Rejoin Below Min triggered", {
        selected = scan.Selected,
        below = scan.Below,
        minKg = Runtime.AutoGet.MinWeightKg,
        currentJob = tostring(game.JobId or ""),
    })

    task.spawn(function()
        task.wait(0.18)

        local okRejoin, rejoinResult = false, "rejoin function unavailable"
        if Runtime.Transport and type(Runtime.Transport.Rejoin) == "function" then
            okRejoin, rejoinResult = Runtime.Transport.Rejoin("below-min")
        end

        if not okRejoin and Runtime.Alive then
            state.Busy = false
            state.BelowSince = nil
            Runtime.AutoGet.RefreshRejoinBelowMinUI()

            if StatusLabel then
                StatusLabel.Text = "● Rejoin failed: " .. tostring(rejoinResult)
                StatusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
            end
        end
    end)

    return true
end


--==================================================
-- TARGET RANCH DELIVER: INDEPENDENT MODE WORKER
--==================================================
-- This mode deliberately does NOT depend on autoFarmActive/Get Egg. It reuses the
-- user's TRUE egg filters and minimum-weight rule, but owns its pickup, carry check,
-- manual/pathfinding transport, and target-Ranch drop lifecycle.
Runtime.AutoGet.TargetRanchGetCandidates = function()
    local state = Runtime.AutoGet.TargetRanch
    local found = {}
    if not RenderedEggsFolder then return found end
    for _, egg in ipairs(RenderedEggsFolder:GetChildren()) do
        if isValidEgg(egg)
            and Runtime.EggIdentity.GetSelected(egg)
            and Runtime.Weight.GetAllowed(egg)
            and not state.Processed[egg] then
            table.insert(found, egg)
        end
    end
    table.sort(found, function(a, b)
        local da = getDistanceToTarget(a)
        local db = getDistanceToTarget(b)
        if math.abs(da - db) > 0.01 then return da < db end
        return a.Name:lower() < b.Name:lower()
    end)
    return found
end

Runtime.AutoGet.TargetRanchWaitForCarry = function(eggName, before, sourceEgg, timeout)
    local state = Runtime.AutoGet.TargetRanch
    local started = os.clock()
    local beforeCount = before and before.Count or 0
    local beforeCarry = before and before.CarrySignature or Runtime.AutoGet.GetCarrySignature()
    timeout = math.max(0.6, tonumber(timeout) or 1.7)
    local changedSince = nil
    local sourceLeftSince = nil

    while Runtime.Alive and state.Active and os.clock() - started <= timeout do
        local roots = Runtime.AutoGet.GetInventoryRoots(true)
        local count = Runtime.AutoGet.CountOwnedEgg(eggName, roots)
        if count > beforeCount then
            return true, "exact-count"
        end

        local sourceLeft = sourceEgg and sourceEgg.Parent ~= RenderedEggsFolder
        if sourceLeft then
            sourceLeftSince = sourceLeftSince or os.clock()
            if os.clock() - sourceLeftSince >= 0.16 then
                return true, "source-left"
            end
        else
            sourceLeftSince = nil
        end

        local carryNow = Runtime.AutoGet.GetCarrySignature()
        if carryNow ~= beforeCarry then
            changedSince = changedSince or os.clock()
            if os.clock() - changedSince >= 0.18 then
                return true, "carry-ui"
            end
        else
            changedSince = nil
        end
        task.wait(0.08)
    end
    return false, "carry not confirmed"
end

Runtime.AutoGet.TargetRanchDeliverCarried = function(eggName, beforeOwnership, sourceEgg)
    local state = Runtime.AutoGet.TargetRanch
    local targetPlayer = Runtime.AutoGet.GetSelectedTargetPlayer()
    if not targetPlayer then
        return false, "select a Ranch Player"
    end

    local plot = Runtime.AutoGet.GetPlotForPlayer(targetPlayer)
    if not plot then
        return false, targetPlayer.Name .. " Ranch not found"
    end

    local prompt = Runtime.AutoGet.FindTargetRanchPlacePrompt(plot)
    if StatusLabel then
        StatusLabel.Text = "● Target Ranch: walking to " .. targetPlayer.Name
        StatusLabel.TextColor3 = Color3.fromRGB(0, 200, 255)
    end

    local moved, moveReason = Runtime.AutoGet.ManualTravelToTargetRanch(
        plot,
        prompt,
        targetPlayer,
        function() return Runtime.Alive and state.Active end
    )
    if not moved or not state.Active then
        return false, "manual travel failed: " .. tostring(moveReason)
    end

    task.wait(0.08)
    if not prompt or not prompt.Parent or not prompt.Enabled then
        prompt = Runtime.AutoGet.FindTargetRanchPlacePrompt(plot)
    end
    if not prompt or not prompt.Parent then
        return false, "no empty Place Egg prompt"
    end

    local eggsFolder = plot:FindFirstChild("Eggs")
    local beforeTargetCount = eggsFolder and #eggsFolder:GetChildren() or nil
    local beforeCarry = beforeOwnership and beforeOwnership.CarrySignature or Runtime.AutoGet.GetCarrySignature()

    local okInput, inputMethod = Runtime.InputCompat.InteractProximityPromptPortable(
        prompt,
        tonumber(Config.EggPromptExtraHold) or 0.08
    )
    if not okInput then
        return false, "drop input failed: " .. tostring(inputMethod)
    end

    local started = os.clock()
    while Runtime.Alive and state.Active and os.clock() - started <= 1.8 do
        eggsFolder = plot:FindFirstChild("Eggs")
        local countRaised = eggsFolder and beforeTargetCount ~= nil
            and #eggsFolder:GetChildren() > beforeTargetCount
        local carryCleared = Runtime.AutoGet.GetCarrySignature() == beforeCarry
        local sourceReturned = sourceEgg and sourceEgg.Parent == RenderedEggsFolder

        if not sourceReturned
            and (countRaised or (os.clock() - started >= 0.25 and carryCleared)) then
            Runtime.AutoGet.UnequipConfirmedEgg()
            state.LastStatus = "Delivered " .. tostring(eggName) .. " to " .. targetPlayer.Name
            if StatusLabel then
                StatusLabel.Text = "● " .. state.LastStatus
                StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
            end
            return true, "delivered"
        end
        task.wait(0.10)
    end
    return false, "drop not confirmed"
end

Runtime.AutoGet.StopTargetRanchDelivery = function()
    local state = Runtime.AutoGet.TargetRanch
    state.Active = false
    state.Enabled = false
    stopMovement()
    if state.Thread then
        pcall(function() task.cancel(state.Thread) end)
        state.Thread = nil
    end
    state.LastStatus = "OFF"
    if Runtime.AutoGet.RefreshEggModeUI then
        task.defer(Runtime.AutoGet.RefreshEggModeUI)
    end
end

Runtime.AutoGet.StartTargetRanchDelivery = function()
    local state = Runtime.AutoGet.TargetRanch
    Runtime.AutoGet.StopTargetRanchDelivery()

    if not Runtime.AutoGet.HasFilter() then
        state.LastStatus = "Select at least one Egg Filter"
        return false, state.LastStatus
    end
    if not Runtime.AutoGet.GetSelectedTargetPlayer() then
        state.LastStatus = "Select a Ranch Player"
        return false, state.LastStatus
    end

    state.Active = true
    state.Enabled = true
    state.Processed = setmetatable({}, {__mode="k"})
    state.LastStatus = "ARMED"

    state.Thread = task.spawn(function()
        while Runtime.Alive and state.Active do
            if not Runtime.AutoGet.HasFilter() then
                state.LastStatus = "No TRUE egg filters"
                task.wait(0.45)
                continue
            end

            local candidates = Runtime.AutoGet.TargetRanchGetCandidates()
            local egg = candidates[1]
            if not egg then
                if StatusLabel then
                    StatusLabel.Text = "● Target Ranch: waiting for selected egg ≥ "
                        .. tostring(Runtime.AutoGet.MinWeightKg) .. " kg"
                    StatusLabel.TextColor3 = Color3.fromRGB(145, 158, 175)
                end
                task.wait(0.35)
                continue
            end

            local before = Runtime.AutoGet.CaptureOwnership(egg.Name)
            local moved = moveToModel(egg)
            if moved and state.Active and isValidEgg(egg) then
                task.wait(0.16)

                local pickupReady = Runtime.AutoGet.WaitPickup(
                    egg,
                    function() return Runtime.Alive and state.Active end
                )

                local interacted = false
                local method = "pickup canceled"
                if pickupReady and state.Active and isValidEgg(egg) then
                    interacted, method = holdEKey(Config.AutoFarmHoldTime, egg)
                end

                if interacted and state.Active then
                    local carried, carryReason = Runtime.AutoGet.TargetRanchWaitForCarry(
                        egg.Name, before, egg, 1.8
                    )
                    if carried and state.Active then
                        local delivered, deliverReason = Runtime.AutoGet.TargetRanchDeliverCarried(
                            egg.Name, before, egg
                        )
                        if delivered then
                            state.Processed[egg] = true
                            if Runtime.EggAutomation
                                and type(Runtime.EggAutomation.MarkBagCacheDirty) == "function" then
                                Runtime.EggAutomation.MarkBagCacheDirty(
                                    "Target Ranch delivered: " .. tostring(egg.Name)
                                )
                            end
                            task.wait(0.20)
                        else
                            state.LastStatus = tostring(deliverReason)
                            Runtime.DebugTeleport("TARGET-RANCH", "Independent delivery failed", {
                                egg=egg.Name, reason=deliverReason
                            })
                            -- Safe recovery only. This does not start/stop Get Egg.
                            teleportToHomePlot()
                            task.wait(0.40)
                        end
                    else
                        state.LastStatus = tostring(carryReason)
                        Runtime.DebugTeleport("TARGET-RANCH", "Independent carry failed", {
                            egg=egg.Name, pickup=method, reason=carryReason
                        })
                        task.wait(0.25)
                    end
                else
                    state.LastStatus = "pickup failed: " .. tostring(method)
                    task.wait(0.25)
                end
            else
                task.wait(0.20)
            end
        end

        state.Thread = nil
        state.Enabled = false
        if Runtime.AutoGet.RefreshEggModeUI then
            task.defer(Runtime.AutoGet.RefreshEggModeUI)
        end
    end)

    if Runtime.AutoGet.RefreshEggModeUI then
        task.defer(Runtime.AutoGet.RefreshEggModeUI)
    end
    return true, "Target Ranch Deliver started"
end

-- Lightweight Get Egg target signal consumed by the background Egg Automation
-- priority gate. This uses only direct RenderedEggs children and the user's TRUE
-- Get Egg filters; no GUI/inventory descendant scans are involved.
Runtime.AutoGet.HasPendingRenderedTarget = function()
    if not autoFarmActive or not RenderedEggsFolder then
        return false, nil
    end

    for _, egg in ipairs(RenderedEggsFolder:GetChildren()) do
        if isValidEgg(egg)
            and Runtime.EggIdentity.GetSelected(egg)
            and not autoFarmProcessed[egg]
            and Runtime.Weight.GetAllowed(egg) then
            return true, egg.Name
        end
    end

    return false, nil
end

local function stopAutoFarm()

    autoFarmActive = false

    Runtime.AutoGet.SetPickupNoclip(false)
    stopMovement()

    autoFarmCurrentName = nil

    if autoFarmThread then

        task.cancel(autoFarmThread)

        autoFarmThread = nil

    end

    if not Runtime.InputCompat.IsTouchPreferred() then
        pcall(function()
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
        end)
    end

    if Runtime.AutoGet.RefreshSelectedPanel then
        task.defer(Runtime.AutoGet.RefreshSelectedPanel)
    end

end

local function startAutoFarm()
    stopAutoFarm()

    autoFarmActive = true

    if StopAutoFarmBtn then
        StopAutoFarmBtn.Visible = false
    end

    autoFarmThread = task.spawn(function()
        while Runtime.Alive and autoFarmActive do
            if not Runtime.AutoGet.HasFilter() then
                autoFarmActive = false
                break
            end

            local eggs, scan = getAutoFarmEggs()

            if #eggs == 0 then
                autoFarmCurrentName = nil

                if Runtime.AutoGet.TryRejoinBelowMin(scan) then
                    task.wait(1.0)
                else
                    if StatusLabel then
                        if Runtime.AutoGet.RejoinBelowMin.Enabled
                            and scan
                            and scan.Selected > 0
                            and scan.Below > 0
                            and scan.Unknown == 0 then
                            StatusLabel.Text = "● Selected Egg below Min kg — checking before rejoin..."
                        else
                            StatusLabel.Text = "● Get Egg: waiting for selected egg ≥ " .. tostring(Runtime.AutoGet.MinWeightKg) .. " kg"
                        end
                        StatusLabel.TextColor3 = Color3.fromRGB(145, 158, 175)
                    end
                    task.wait(0.30)
                end
            else
                local didWork = false

                for _, egg in ipairs(eggs) do
                    if not autoFarmActive then
                        break
                    end

                    if isValidEgg(egg) and not autoFarmProcessed[egg] and Runtime.Weight.GetAllowed(egg) then
                        didWork = true
                        autoFarmCurrentName = egg.Name

                        if StatusLabel then
                            StatusLabel.Text = "● Get Egg: " .. egg.Name
                            StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
                        end

                        -- Snapshot bag/slot state BEFORE the pickup attempt.
                        local beforeOwnership = Runtime.AutoGet.CaptureOwnership(egg.Name)
                        local success = moveToModel(egg)

                        if success and autoFarmActive then
                            Runtime.AutoGet.SetPickupNoclip(true)
                            zeroMovementVelocity()
                            task.wait(0.20)

                            -- Target ONLY this rendered egg's own pickup prompt. This is
                            -- angle-independent and cannot be stolen by another visible E prompt.
                            local interacted = false
                            local interactReason = "Get Egg stopped before interaction"
                            if autoFarmActive and isValidEgg(egg) and Runtime.Weight.GetAllowed(egg)
                                and Runtime.AutoGet.WaitPickup(egg, function() return autoFarmActive end) then
                                interacted, interactReason = Runtime.AutoGet.ActivateTargetEggPrompt(
                                    egg,
                                    Config.AutoFarmHoldTime
                                )
                            end

                            if interacted and autoFarmActive then
                                -- Keep pickup noclip through the server-side disappearance signal.
                                -- Release it before Home travel; moveToModel() owns travel noclip itself.
                                Runtime.AutoGet.UnequipAfterPickupSignal(egg, 0.75)
                                Runtime.AutoGet.SetPickupNoclip(false)

                                local confirmed = Runtime.AutoGet.TravelAndConfirm(
                                    egg.Name,
                                    beforeOwnership,
                                    egg
                                )

                                if confirmed then
                                    Runtime.AutoGet.UnequipConfirmedEgg()

                                    -- One controlled rebuild discovers the newly inserted bag slot;
                                    -- later Auto Place cycles reuse that exact slot/location.
                                    if Runtime.EggAutomation
                                        and type(Runtime.EggAutomation.MarkBagCacheDirty) == "function" then
                                        Runtime.EggAutomation.MarkBagCacheDirty("Get Egg confirmed: " .. tostring(egg.Name))
                                    end

                                    autoFarmProcessed[egg] = true
                                else
                                    autoFarmProcessed[egg] = nil
                                end
                            else
                                Runtime.AutoGet.SetPickupNoclip(false)
                                Runtime.DebugTeleport("GET-EGG", "Target egg prompt interaction failed", {
                                    egg = egg.Name,
                                    reason = interactReason,
                                })
                                autoFarmProcessed[egg] = nil
                            end

                            Runtime.AutoGet.SetPickupNoclip(false)
                            task.wait(0.12)
                        else
                            Runtime.AutoGet.SetPickupNoclip(false)
                        end
                    end
                end

                autoFarmCurrentName = nil

                if not didWork then
                    if StatusLabel then
                        StatusLabel.Text = "● Get Egg: filtered Eggs already handled — waiting..."
                        StatusLabel.TextColor3 = Color3.fromRGB(145, 158, 175)
                    end
                    task.wait(0.30)
                else
                    task.wait(0.12)
                end
            end
        end

        if not Runtime.InputCompat.IsTouchPreferred() then
            pcall(function()
                VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
            end)
        end
        autoFarmThread = nil

        if StopAutoFarmBtn then
            StopAutoFarmBtn.Visible = false
        end

        if Runtime.AutoGet.RefreshFilterUI then
            Runtime.AutoGet.RefreshFilterUI()
        end
        if Runtime.AutoGet.RefreshSelectedPanel then
            Runtime.AutoGet.RefreshSelectedPanel()
        end
    end)
end

-- Continue a Rejoin-Below-Min hunt after the executor's teleport queue reloads ZOLO.
-- The payload carries only the active Get Egg filters + Min kg needed for this loop.
Runtime.AutoGet.ResumeRejoinBelowMinAfterTeleport = function()
    local TeleportService = game:GetService("TeleportService")
    local HttpService = game:GetService("HttpService")

    local okResume, shouldResume = pcall(function()
        return TeleportService:GetTeleportSetting("ZoloEggsESP_RejoinBelowMinResume")
    end)
    if not okResume or shouldResume ~= true then
        return false
    end

    pcall(function()
        TeleportService:SetTeleportSetting("ZoloEggsESP_RejoinBelowMinResume", false)
    end)

    local rawPayload = nil
    pcall(function()
        rawPayload = TeleportService:GetTeleportSetting("ZoloEggsESP_RejoinBelowMinPayload")
    end)

    local payload = nil
    if type(rawPayload) == "string" and rawPayload ~= "" then
        pcall(function()
            payload = HttpService:JSONDecode(rawPayload)
        end)
    end

    if type(payload) == "table" then
        local minKg = Runtime.Weight.Parse(payload.MinWeightKg, true)
        if minKg then
            Runtime.AutoGet.MinWeightKg = minKg
        end

        table.clear(autoFarmEggs)
        if type(payload.Filters) == "table" then
            for _, key in ipairs(payload.Filters) do
                key = Runtime.EggIdentity.Key(key)
                if key ~= "" then
                    autoFarmEggs[key] = true
                end
            end
        end
    end

    Runtime.AutoGet.RejoinBelowMin.Enabled = true
    Runtime.AutoGet.RejoinBelowMin.Busy = false
    Runtime.AutoGet.RejoinBelowMin.BelowSince = nil

    if Runtime.AutoGet.ModeSelector then
        Runtime.AutoGet.ModeSelector.Selected = "GetEgg"
        Runtime.AutoGet.ModeSelector.MenuOpen = false
    end

    Runtime.Weight.RefreshControls()
    if Runtime.AutoGet.RefreshFilterUI then Runtime.AutoGet.RefreshFilterUI() end
    if Runtime.AutoGet.RefreshRejoinBelowMinUI then Runtime.AutoGet.RefreshRejoinBelowMinUI() end

    if Runtime.AutoGet.HasFilter() then
        stopAutoFarm()
        startAutoFarm()
        if StatusLabel then
            StatusLabel.Text = "● Rejoin Below Min resumed — scanning selected Eggs"
            StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
        end
        if Runtime.AutoGet.RefreshEggModeUI then Runtime.AutoGet.RefreshEggModeUI() end
        return true
    end

    return false
end

--==================================================
-- HATCH LUCK UPGRADE ANNOUNCEMENT SILENCER
--==================================================
-- Event-driven only: no Heartbeat/RenderStepped scanning. It suppresses only
-- client GUI text containing BOTH "upgraded" and "luck". Other announcements
-- are untouched. Existing likely notification labels are watched when enabled;
-- newly-created labels are handled through PlayerGui.DescendantAdded.
do
    local silencer = Runtime.LuckAlertSilencer

    local function isTextObject(object)
        return object
            and (object:IsA("TextLabel") or object:IsA("TextButton") or object:IsA("TextBox"))
    end

    local function isOurMenu(object)
        return Runtime.ScreenGui
            and object
            and object:IsDescendantOf(Runtime.ScreenGui)
    end

    local function isLuckUpgradeAnnouncement(text)
        local lower = tostring(text or ""):lower()
        if lower == "" then
            return false
        end
        -- Strict condition requested by the user. Requiring both words avoids
        -- silencing normal Luck UI, hatch messages, money notices, etc.
        return string.find(lower, "upgraded", 1, true) ~= nil
            and string.find(lower, "luck", 1, true) ~= nil
    end

    local function looksLikeAnnouncementPath(object)
        if not object then return false end
        local ok, fullName = pcall(function()
            return object:GetFullName()
        end)
        local lower = ok and tostring(fullName):lower() or tostring(object.Name or ""):lower()
        return string.find(lower, "announce", 1, true) ~= nil
            or string.find(lower, "notification", 1, true) ~= nil
            or string.find(lower, "notify", 1, true) ~= nil
            or string.find(lower, "toast", 1, true) ~= nil
            or string.find(lower, "alert", 1, true) ~= nil
            or string.find(lower, "message", 1, true) ~= nil
            or string.find(lower, "upgrade", 1, true) ~= nil
    end

    local function silenceIfMatching(object)
        if not silencer.Enabled or not isTextObject(object) or isOurMenu(object) then
            return false
        end

        local text = tostring(object.Text or "")
        if not isLuckUpgradeAnnouncement(text) then
            return false
        end

        -- Blank only the matching text. We do not hide/destroy the notification
        -- container, so other game alerts using the same UI remain functional.
        pcall(function()
            object.Text = ""
        end)
        return true
    end

    local function disconnectWatch(object)
        local connection = silencer.WatchConnections[object]
        if connection then
            pcall(function() connection:Disconnect() end)
            silencer.WatchConnections[object] = nil
        end
    end

    local function watchTextObject(object, forceWatch)
        if not silencer.Enabled or not isTextObject(object) or isOurMenu(object) then
            return
        end

        local matched = silenceIfMatching(object)
        if not matched and not forceWatch and not looksLikeAnnouncementPath(object) then
            return
        end
        if silencer.WatchConnections[object] then
            return
        end

        silencer.WatchConnections[object] = object:GetPropertyChangedSignal("Text"):Connect(function()
            if not silencer.Enabled or not object.Parent then
                disconnectWatch(object)
                return
            end
            silenceIfMatching(object)
        end)
    end

    local function stopSilencer()
        silencer.Enabled = false
        if silencer.DescendantConnection then
            pcall(function() silencer.DescendantConnection:Disconnect() end)
            silencer.DescendantConnection = nil
        end
        for object, connection in pairs(silencer.WatchConnections) do
            pcall(function() connection:Disconnect() end)
            silencer.WatchConnections[object] = nil
        end
    end

    local function startSilencer()
        if silencer.Enabled and silencer.DescendantConnection then
            return
        end

        stopSilencer()
        silencer.Enabled = true

        -- One-time lightweight setup scan. Only matching/current notification-like
        -- text controls receive a Text listener; this avoids a heavy global poll.
        for _, object in ipairs(TargetParent:GetDescendants()) do
            if isTextObject(object) and not isOurMenu(object) then
                watchTextObject(object, false)
            end
        end

        silencer.DescendantConnection = TargetParent.DescendantAdded:Connect(function(object)
            if not silencer.Enabled then return end
            if isTextObject(object) and not isOurMenu(object) then
                -- New popup labels usually arrive with their final text already set.
                -- If they are created blank under an announcement container, the
                -- path heuristic watches their subsequent Text change too.
                watchTextObject(object, false)
            end
        end)
    end

    function silencer.RefreshButton()
        local button = silencer.UI.ToggleBtn
        if not button or not button.Parent then return end
        if silencer.Enabled then
            button.Text = "Silence Luck Upgrade Alert: ON"
            button.BackgroundColor3 = Color3.fromRGB(0, 130, 75)
            button.TextColor3 = Color3.fromRGB(255, 255, 255)
        else
            button.Text = "Silence Luck Upgrade Alert: OFF"
            button.BackgroundColor3 = Color3.fromRGB(45, 52, 64)
            button.TextColor3 = Color3.fromRGB(220, 228, 238)
        end
    end

    function silencer.SetEnabled(enabled)
        if enabled == true then
            startSilencer()
        else
            stopSilencer()
        end
        silencer.RefreshButton()
    end

    silencer.Start = startSilencer
    silencer.Stop = stopSilencer
    silencer.IsLuckUpgradeAnnouncement = isLuckUpgradeAnnouncement
end

-- GUI PRINCIPAL
-- Legacy fallback: old builds only destroyed their UI and had no runtime registry.

--==================================================

-- If another ZOLO copy won the startup race while this copy was initializing,
-- stop here. This is the main protection against a visible but dead duplicate UI.
if Runtime.IsSuperseded and Runtime.IsSuperseded() then
    return
end

do
local oldGui = nil

pcall(function()

    oldGui = TargetParent:FindFirstChild("RenderedEggsESP_Menu")

end)

-- Migration fallback for v2.7 and older copies that did not yet register a
-- runtime cleanup function. If the executor exposes firesignal, try to switch
-- active legacy toggles off before destroying that old UI. New v2.8+ copies
-- are stopped through Runtime.Cleanup above and do not depend on this fallback.
local function tryStopLegacyUI(gui)
    if not gui or not gui.Parent then
        return
    end

    local fireSignalFunction = firesignal
    if type(fireSignalFunction) ~= "function" then
        return
    end

    for _, object in ipairs(gui:GetDescendants()) do
        if object:IsA("TextButton") then
            local text = tostring(object.Text or "")
            local shouldClick = false

            if object.Name == "StopAutoFarm" and object.Visible then
                shouldClick = true
            elseif string.sub(text, 1, #"Auto Hatch Luck: ON") == "Auto Hatch Luck: ON" then
                shouldClick = true
            elseif string.sub(text, 1, #"Auto Place Eggs: ON") == "Auto Place Eggs: ON" then
                shouldClick = true
            elseif string.sub(text, 1, #"Auto Hatch Eggs: ON") == "Auto Hatch Eggs: ON" then
                shouldClick = true
            elseif string.sub(text, 1, #"Auto Feed Pet: ON") == "Auto Feed Pet: ON" then
                shouldClick = true
            elseif string.sub(text, 1, #"Auto Feed Pets: ON") == "Auto Feed Pets: ON" then
                shouldClick = true
            elseif text == "Silence Luck Upgrade Alert: ON" then
                shouldClick = true
            elseif text == "Auto Reconnect: ON" then
                shouldClick = true
            elseif text == "Auto Execute After Hop: ON" then
                shouldClick = true
            elseif text == "Auto Best Egg: ON" then
                shouldClick = true
            elseif text == "AutoFarm: ON" then
                shouldClick = true
            end

            if shouldClick then
                pcall(function()
                    fireSignalFunction(object.MouseButton1Click)
                end)
            end
        end
    end
end

if oldGui then

    pcall(function() tryStopLegacyUI(oldGui) end)
    task.wait()
    pcall(function() oldGui:Destroy() end)

end

end
local ScreenGui = Instance.new("ScreenGui")

ScreenGui.Name = "RenderedEggsESP_Menu"

ScreenGui.ResetOnSpawn = false

ScreenGui.Parent = TargetParent
Runtime.ScreenGui = ScreenGui

-- Stable screen-space ESP renderer. WorldToScreenPoint returns coordinates in
-- the same GUI coordinate system when IgnoreGuiInset is false (our default).
Runtime.ESPRenderBindName = "ZoloEggESP_Screen_" .. tostring(Runtime.Session or Runtime.SessionId or os.clock())
Runtime.ESPRenderInterval = 1 / math.clamp(tonumber(Config.ESPRenderHz) or 20, 5, 60)
pcall(function() RunService:UnbindFromRenderStep(Runtime.ESPRenderBindName) end)
RunService:BindToRenderStep(Runtime.ESPRenderBindName, Enum.RenderPriority.Last.Value, function(deltaTime)
    if not Runtime.Alive or not Runtime.ScreenGui or not Runtime.ScreenGui.Parent then return end

    -- FPS-friendly: project ESP labels at a bounded rate instead of every rendered
    -- frame. The callback still runs each frame, but normally exits immediately.
    Runtime.ESPRenderAccumulator = (Runtime.ESPRenderAccumulator or 0) + (tonumber(deltaTime) or 0)
    local renderInterval = Runtime.ESPRenderInterval or (1 / 20)
    if Runtime.ESPRenderAccumulator < renderInterval then return end
    Runtime.ESPRenderAccumulator = Runtime.ESPRenderAccumulator % renderInterval

    if (Runtime.ESPRequestedCount or 0) <= 0 then
        Runtime.ESPOnScreen = 0
        return
    end

    local camera = Workspace.CurrentCamera
    if not camera then return end

    Runtime.ESPOnScreen = 0
    for egg, data in pairs(eggData) do
        local holder = data and data.NameBillboard
        if holder and holder.Parent then
            local shouldRender = data.ESPShouldShow and egg and egg.Parent == RenderedEggsFolder
            if shouldRender then
                local part = data.ESPPart
                -- egg.Parent already proves this tracked egg is live. Avoid an
                -- IsDescendantOf(Workspace) traversal for every label on every ESP tick.
                if not part or not part.Parent or not part:IsA("BasePart") then
                    part = egg:IsA("BasePart") and egg
                        or egg.PrimaryPart
                        or egg:FindFirstChildWhichIsA("BasePart", true)
                    data.ESPPart = part
                end

                if part then
                    local point, onScreen = camera:WorldToScreenPoint(part.Position + Vector3.new(0, 3.5, 0))
                    if onScreen and point.Z > 0 then
                        holder.Position = UDim2.fromOffset(point.X, point.Y)
                        if not holder.Visible then holder.Visible = true end
                        Runtime.ESPOnScreen = Runtime.ESPOnScreen + 1
                    elseif holder.Visible then
                        holder.Visible = false
                    end
                elseif holder.Visible then
                    holder.Visible = false
                end
            elseif holder.Visible then
                holder.Visible = false
            end
        end
    end
end)


-- Full cleanup used by the next execution of this script.
Runtime.Cleanup = function(reason)
    if Runtime.Cleaned then
        return
    end

    Runtime.Cleaned = true
    Runtime.Alive = false

    -- Invalidate deferred/list/ESP work that may still be waiting for a frame.
    listBuildGeneration = listBuildGeneration + 1
    listRefreshGeneration = listRefreshGeneration + 1
    espRefreshGeneration = espRefreshGeneration + 1
    table.clear(pendingEggESPUpdates)
    eggESPWorkerRunning = false

    -- Stop every long-running feature before destroying the interface.
    pcall(stopAutoFarm)
    pcall(stopAutoBestEgg)
    if Runtime.AutoGet and Runtime.AutoGet.StopTargetRanchDelivery then
        pcall(Runtime.AutoGet.StopTargetRanchDelivery)
    end
    pcall(stopAutoHatchLuck)
    pcall(Runtime.EggAutomation.StopAutoPlace)
    if Runtime.LiveEggData and Runtime.LiveEggData.ClearWatchers then
        pcall(Runtime.LiveEggData.ClearWatchers)
    end
    pcall(Runtime.EggAutomation.StopAutoHatch)
    pcall(Runtime.AutoFeed.Stop)
    if Runtime.DropEggQ and Runtime.DropEggQ.Stop then
        pcall(Runtime.DropEggQ.Stop)
    end
    pcall(Runtime.LuckAlertSilencer.Stop)
    if Runtime.SpawnNotifications and Runtime.SpawnNotifications.Stop then
        pcall(Runtime.SpawnNotifications.Stop)
    end
    if Runtime.Transport and Runtime.Transport.Stop then
        pcall(Runtime.Transport.Stop)
    end
    if Runtime.AntiAFK then
        Runtime.AntiAFK.Enabled = false
        if Runtime.AntiAFK.Thread then
            pcall(function()
                task.cancel(Runtime.AntiAFK.Thread)
            end)
            Runtime.AntiAFK.Thread = nil
        end
    end
    if Runtime.AutoGet and Runtime.AutoGet.SetPickupNoclip then
        pcall(Runtime.AutoGet.SetPickupNoclip, false)
    end
    pcall(stopMovement)

    autoFarmActive = false
    autoBestEggActive = false
    autoHatchLuckActive = false
    EggAutoState.AutoPlace = false
    EggAutoState.AutoHatch = false
    Runtime.AutoFeed.Enabled = false
    Runtime.AutoFeed.Busy = false
    listeningForKey = false

    -- Never leave the interact key logically held if a task is cancelled
    -- while holdEKey() is running.
    if not Runtime.InputCompat.IsTouchPreferred() then
        pcall(function()
            VirtualInputManager:SendKeyEvent(false, Enum.KeyCode.E, false, game)
        end)
    end

    -- Remove ESP objects created by the previous execution.
    for egg, data in pairs(eggData) do
        if data then
            if data.Highlight then
                pcall(function() data.Highlight:Destroy() end)
            end
            if data.NameBillboard then
                pcall(function() data.NameBillboard:Destroy() end)
            end
        end
        eggData[egg] = nil
    end
    if Runtime.ESPHighlightFolder then
        pcall(function() Runtime.ESPHighlightFolder:Destroy() end)
        Runtime.ESPHighlightFolder = nil
    end
    if Runtime.ESPRenderBindName then
        pcall(function() RunService:UnbindFromRenderStep(Runtime.ESPRenderBindName) end)
        Runtime.ESPRenderBindName = nil
    end
    if Runtime.ESPOverlay then
        pcall(function() Runtime.ESPOverlay:Destroy() end)
        Runtime.ESPOverlay = nil
    end

    -- Disconnect global services/folder listeners owned by this execution.
    disconnectRuntimeConnections()

    if ScreenGui and ScreenGui.Parent then
        pcall(function()
            ScreenGui:Destroy()
        end)
    end

    Runtime.ScreenGui = nil

    if RuntimeEnv[RuntimeKey] == Runtime and reason ~= "reexecute" then
        RuntimeEnv[RuntimeKey] = nil
    end
end

--==================================================

-- MENÚ DE DISPOSITIVO

--==================================================

local DeviceFrame = Instance.new("Frame")

DeviceFrame.Name = "DeviceSelectionFrame"

DeviceFrame.Size = UDim2.new(0, 280, 0, 140)

DeviceFrame.Position = UDim2.new(0.5, -140, 0.5, -70)

DeviceFrame.BackgroundColor3 = Color3.fromRGB(17, 22, 30)

DeviceFrame.BackgroundTransparency = 0.08

DeviceFrame.BorderSizePixel = 0

DeviceFrame.Active = true

DeviceFrame.Parent = ScreenGui

do
local DeviceCorner = Instance.new("UICorner")

DeviceCorner.CornerRadius = UDim.new(0, 10)

DeviceCorner.Parent = DeviceFrame
end

do
local DeviceStroke = Instance.new("UIStroke")

DeviceStroke.Color = Color3.fromRGB(58, 78, 101)

DeviceStroke.Thickness = 1.5

DeviceStroke.Parent = DeviceFrame
end

do
local DeviceTitle = Instance.new("TextLabel")

DeviceTitle.Size = UDim2.new(1, 0, 0, 35)

DeviceTitle.Position = UDim2.new(0, 0, 0, 10)

DeviceTitle.BackgroundTransparency = 1

DeviceTitle.Text = UserInputService.TouchEnabled and "Choose Device (Mobile detected)" or "Choose Device"

DeviceTitle.TextColor3 = Color3.fromRGB(255, 255, 255)

DeviceTitle.TextSize = 17

DeviceTitle.Font = Enum.Font.SourceSansBold

DeviceTitle.Parent = DeviceFrame
end

local PCBtn = Instance.new("TextButton")

PCBtn.Size = UDim2.new(0, 110, 0, 45)

PCBtn.Position = UDim2.new(0, 20, 0, 65)

PCBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)

PCBtn.BackgroundTransparency = 0.1

PCBtn.Text = "PC"

PCBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

PCBtn.TextSize = 14

PCBtn.Font = Enum.Font.SourceSansBold

PCBtn.Parent = DeviceFrame

do
local PCCorner = Instance.new("UICorner")

PCCorner.CornerRadius = UDim.new(0, 7)

PCCorner.Parent = PCBtn
end

local MobileBtn = Instance.new("TextButton")

MobileBtn.Size = UDim2.new(0, 110, 0, 45)

MobileBtn.Position = UDim2.new(1, -130, 0, 65)

MobileBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)

MobileBtn.BackgroundTransparency = 0.1

MobileBtn.Text = "Mobile"

MobileBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

MobileBtn.TextSize = 14

MobileBtn.Font = Enum.Font.SourceSansBold

MobileBtn.Parent = DeviceFrame

do
local MobileCorner = Instance.new("UICorner")

MobileCorner.CornerRadius = UDim.new(0, 7)

MobileCorner.Parent = MobileBtn
end

--==================================================

-- FRAME PRINCIPAL

--==================================================

local MainFrame = Instance.new("Frame")

MainFrame.Name = "MainFrame"

MainFrame.Size = UDim2.new(0, Config.PCWidth, 0, Config.PCHeight)

MainFrame.Position = UDim2.new(0.5, -Config.PCWidth / 2, 0.4, -Config.PCHeight / 2)

MainFrame.BackgroundColor3 = Color3.fromRGB(13, 16, 21)

MainFrame.BackgroundTransparency = 0.02

MainFrame.BorderSizePixel = 0

MainFrame.Active = true

MainFrame.Visible = false

MainFrame.Parent = ScreenGui

do
local MainCorner = Instance.new("UICorner")

MainCorner.CornerRadius = UDim.new(0, 13)

MainCorner.Parent = MainFrame
end

do
local MainStroke = Instance.new("UIStroke")

MainStroke.Color = Color3.fromRGB(43, 52, 66)

MainStroke.Thickness = 1

MainStroke.Parent = MainFrame
end

--==================================================
-- FLOATING Z UI TOGGLE (SEPARATE SUBSYSTEM)
--==================================================
Runtime.FloatingToggle = {
    UI = {},
}

Runtime.FloatingToggle.Create = function()
    local float = Runtime.FloatingToggle
    if float.UI.Button and float.UI.Button.Parent then
        return float.UI.Button
    end

    local size = Runtime.InputCompat.IsTouchPreferred() and 52 or 48

    local button = Instance.new("TextButton")
    button.Name = "ZoloFloatingToggle"
    button.Size = UDim2.fromOffset(size, size)
    button.Position = UDim2.new(0, 18, 0.5, -math.floor(size / 2))
    button.BackgroundColor3 = Color3.fromRGB(18, 25, 35)
    button.BorderSizePixel = 0
    button.Text = "Z"
    button.TextColor3 = Color3.fromRGB(224, 245, 235)
    button.TextSize = 18
    button.Font = Enum.Font.GothamBold
    button.AutoButtonColor = false
    button.Active = true
    button.Visible = false
    button.ZIndex = 1200
    button.Parent = ScreenGui
    float.UI.Button = button

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, Runtime.InputCompat.IsTouchPreferred() and 15 or 14)
    corner.Parent = button

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(80, 200, 135)
    stroke.Transparency = 0.12
    stroke.Thickness = 1.5
    stroke.Parent = button

    local badge = Instance.new("TextLabel")
    badge.Name = "Badge"
    badge.Size = UDim2.fromOffset(24, 12)
    badge.Position = UDim2.new(0.5, -12, 1, -15)
    badge.BackgroundTransparency = 1
    badge.Text = "ZOLO"
    badge.TextColor3 = Color3.fromRGB(91, 210, 150)
    badge.TextSize = 7
    badge.Font = Enum.Font.GothamBold
    badge.ZIndex = 1201
    badge.Parent = button
    float.UI.Badge = badge

    local dragging = false
    local moved = false
    local dragStart = nil
    local startPosition = nil
    local activeTouch = nil

    trackRuntimeConnection(button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then

            dragging = true
            moved = false
            dragStart = input.Position
            startPosition = button.Position
            activeTouch = input.UserInputType == Enum.UserInputType.Touch and input or nil
        end
    end))

    trackRuntimeConnection(UserInputService.InputChanged:Connect(function(input)
        if not dragging or not dragStart or not startPosition then
            return
        end

        local usable = input.UserInputType == Enum.UserInputType.MouseMovement
            or (activeTouch and input == activeTouch)

        if not usable then
            return
        end

        local delta = input.Position - dragStart
        if delta.Magnitude >= 5 then
            moved = true
        end

        button.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end))

    trackRuntimeConnection(UserInputService.InputEnded:Connect(function(input)
        if not dragging then
            return
        end

        local finished = input.UserInputType == Enum.UserInputType.MouseButton1
            or (activeTouch and input == activeTouch)

        if not finished then
            return
        end

        dragging = false
        activeTouch = nil

        if not moved and MainFrame and MainFrame.Parent then
            MainFrame.Visible = not MainFrame.Visible
        end
    end))

    return button
end

Runtime.FloatingToggle.SetReady = function(ready)
    local button = Runtime.FloatingToggle.UI.Button
    if button and button.Parent then
        button.Visible = ready == true
    end
end

Runtime.FloatingToggle.Create()

--==================================================

-- TOP BAR

--==================================================

local TopBar = Instance.new("Frame")

TopBar.Name = "TopBar"

TopBar.Size = UDim2.new(1, 0, 0, 50)

TopBar.BackgroundColor3 = Color3.fromRGB(18, 21, 27)

TopBar.BackgroundTransparency = 0

TopBar.BorderSizePixel = 0

TopBar.Parent = MainFrame

local TopAccent = Instance.new("Frame")
TopAccent.Name = "TopAccent"
TopAccent.Size = UDim2.new(1, 0, 0, 2)
TopAccent.Position = UDim2.new(0, 0, 1, -2)
TopAccent.BackgroundColor3 = Color3.fromRGB(48, 126, 232)
TopAccent.BorderSizePixel = 0
TopAccent.Parent = TopBar

do
local TopCorner = Instance.new("UICorner")

TopCorner.CornerRadius = UDim.new(0, 10)

TopCorner.Parent = TopBar
end

local AuthorLabel = Instance.new("TextLabel")

AuthorLabel.Size = UDim2.new(1, -90, 0, 14)

AuthorLabel.Position = UDim2.new(0, 10, 0, 3)

AuthorLabel.BackgroundTransparency = 1

AuthorLabel.Text = "ZOLO HUB  •  Owner / Editor: Zolo"

AuthorLabel.TextColor3 = Color3.fromRGB(160, 160, 160)

AuthorLabel.TextSize = 11

AuthorLabel.Font = Enum.Font.SourceSansBold

AuthorLabel.TextXAlignment = Enum.TextXAlignment.Left

AuthorLabel.Parent = TopBar

local TitleLabel = Instance.new("TextLabel")

TitleLabel.Size = UDim2.new(1, -90, 0, 16)

TitleLabel.Position = UDim2.new(0, 10, 0, 18)

TitleLabel.BackgroundTransparency = 1

TitleLabel.Text = "Ride A Pet  •  Egg Tools"

TitleLabel.TextColor3 = Color3.fromRGB(255, 255, 255)

TitleLabel.TextSize = 14

TitleLabel.Font = Enum.Font.SourceSansBold

TitleLabel.TextXAlignment = Enum.TextXAlignment.Left

TitleLabel.Parent = TopBar

local GameLabel = Instance.new("TextLabel")

GameLabel.Size = UDim2.new(1, -90, 0, 12)

GameLabel.Position = UDim2.new(0, 10, 0, 34)

GameLabel.BackgroundTransparency = 1

GameLabel.Text = "Big Froot-inspired layout • same functions"

GameLabel.TextColor3 = Color3.fromRGB(130, 130, 130)

GameLabel.TextSize = 10

GameLabel.Font = Enum.Font.SourceSansItalic

GameLabel.TextXAlignment = Enum.TextXAlignment.Left

GameLabel.Parent = TopBar

local MinimizeBtn = Instance.new("TextButton")

MinimizeBtn.Size = UDim2.new(0, 30, 0, 30)

MinimizeBtn.Position = UDim2.new(1, -35, 0, 10)

MinimizeBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)

MinimizeBtn.BackgroundTransparency = 0.15

MinimizeBtn.Text = "-"

MinimizeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

MinimizeBtn.TextSize = 18

MinimizeBtn.Font = Enum.Font.SourceSansBold

MinimizeBtn.Parent = TopBar

do
local MinCorner = Instance.new("UICorner")

MinCorner.CornerRadius = UDim.new(0, 6)

MinCorner.Parent = MinimizeBtn
end

--==================================================

-- CONTENEDOR

--==================================================

local ContentContainer = Instance.new("Frame")

ContentContainer.Name = "ContentContainer"

ContentContainer.Size = UDim2.new(1, -20, 1, -60)

ContentContainer.Position = UDim2.new(0, 10, 0, 55)

ContentContainer.BackgroundTransparency = 1

ContentContainer.Parent = MainFrame

--==================================================

-- TEXTO DE ESTADO

--==================================================

StatusLabel = Instance.new("TextLabel")

StatusLabel.Size = UDim2.new(1, 0, 0, 20)

StatusLabel.Position = UDim2.new(0, 0, 0, 0)

StatusLabel.BackgroundTransparency = 1

StatusLabel.Text = "● System ready"

StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)

StatusLabel.TextSize = 11

StatusLabel.Font = Enum.Font.SourceSansBold

StatusLabel.TextXAlignment = Enum.TextXAlignment.Left

StatusLabel.Parent = ContentContainer

--==================================================

-- FUNCIÓN PARA CREAR BOTONES

--==================================================

local function styleButton(button)

    local corner = Instance.new("UICorner")

    corner.CornerRadius = UDim.new(0, 8)

    corner.Parent = button

    local stroke = Instance.new("UIStroke")

    stroke.Color = Color3.fromRGB(52, 62, 78)

    stroke.Transparency = 0.35

    stroke.Thickness = 1

    stroke.Parent = button

    button.AutoButtonColor = false

    button.MouseEnter:Connect(function()

        tween(button, {

            BackgroundTransparency = math.max(0, button.BackgroundTransparency - 0.08)

        }, 0.10)

    end)

    button.MouseLeave:Connect(function()

        tween(button, {

            BackgroundTransparency = math.min(0.5, button.BackgroundTransparency + 0.08)

        }, 0.10)

    end)

    button.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            tween(button, {
                Size = button.Size
            }, 0.05)
        end
    end)

end

--==================================================

--==================================================

-- BOTÓN ROJO PARA DETENER AUTOFARM

--==================================================

ModeAutoFarmBtn = Instance.new("TextButton")

ModeAutoFarmBtn.Name = "ModeAutoFarm"

ModeAutoFarmBtn.Size = UDim2.new(0.5, -3, 0, 30)

ModeAutoFarmBtn.Position = UDim2.new(0, 0, 0, 20)

ModeAutoFarmBtn.BackgroundColor3 = Color3.fromRGB(0, 150, 70)

ModeAutoFarmBtn.BackgroundTransparency = 0.10

ModeAutoFarmBtn.Text = "AutoFarm Mode"

ModeAutoFarmBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

ModeAutoFarmBtn.TextSize = 11

ModeAutoFarmBtn.Font = Enum.Font.SourceSansBold

ModeAutoFarmBtn.Parent = ContentContainer

styleButton(ModeAutoFarmBtn)

ModeTeleportBtn = Instance.new("TextButton")

ModeTeleportBtn.Name = "ModeTeleport"

ModeTeleportBtn.Size = UDim2.new(0.5, -3, 0, 30)

ModeTeleportBtn.Position = UDim2.new(0.5, 3, 0, 20)

ModeTeleportBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)

ModeTeleportBtn.BackgroundTransparency = 0.18

ModeTeleportBtn.Text = "Teleport Mode"

ModeTeleportBtn.TextColor3 = Color3.fromRGB(220, 220, 220)

ModeTeleportBtn.TextSize = 11

ModeTeleportBtn.Font = Enum.Font.SourceSansBold

ModeTeleportBtn.Parent = ContentContainer

styleButton(ModeTeleportBtn)

ModeAutoFarmBtn.Activated:Connect(function() setMovementMode("AutoFarm") end)

ModeTeleportBtn.Activated:Connect(function() setMovementMode("Teleport") end)

updateMovementModeButtons()

StopAutoFarmBtn = Instance.new("TextButton")

StopAutoFarmBtn.Name = "StopAutoFarm"

StopAutoFarmBtn.Size = UDim2.new(0, 105, 0, 20)

StopAutoFarmBtn.Position = UDim2.new(1, -105, 0, 0)

StopAutoFarmBtn.BackgroundColor3 = Color3.fromRGB(180, 45, 45)

StopAutoFarmBtn.BackgroundTransparency = 0.08

StopAutoFarmBtn.Text = "■ Stop Get Egg"

StopAutoFarmBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

StopAutoFarmBtn.TextSize = 10

StopAutoFarmBtn.Font = Enum.Font.SourceSansBold

StopAutoFarmBtn.Visible = false

StopAutoFarmBtn.Parent = ContentContainer

styleButton(StopAutoFarmBtn)

StopAutoFarmBtn.Activated:Connect(function()

    stopAutoFarm()

    StopAutoFarmBtn.Visible = false

    StatusLabel.Text = "● Get Egg stopped"

    StatusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)

end)

-- BOTÓN ESP

--==================================================

Runtime.UIRegs = Runtime.UIRegs or {}

Runtime.UIRegs.ToggleGlobalESPBtn = Instance.new("TextButton")

Runtime.UIRegs.ToggleGlobalESPBtn.Size = UDim2.new(1, 0, 0, 32)

Runtime.UIRegs.ToggleGlobalESPBtn.Position = UDim2.new(0, 0, 0, 55)

Runtime.UIRegs.ToggleGlobalESPBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)

Runtime.UIRegs.ToggleGlobalESPBtn.BackgroundTransparency = 0.18

Runtime.UIRegs.ToggleGlobalESPBtn.Text = "All Eggs ESP: OFF"

Runtime.UIRegs.ToggleGlobalESPBtn.TextColor3 = Color3.fromRGB(220, 220, 220)

Runtime.UIRegs.ToggleGlobalESPBtn.TextSize = 13

Runtime.UIRegs.ToggleGlobalESPBtn.Font = Enum.Font.SourceSansBold

Runtime.UIRegs.ToggleGlobalESPBtn.Parent = ContentContainer

styleButton(Runtime.UIRegs.ToggleGlobalESPBtn)

Runtime.UIRegs.ToggleGlobalESPBtn.Activated:Connect(function()
    local turnOn = not mainESPActive

    if turnOn then
        mainESPActive = true
        Runtime.UIRegs.ToggleGlobalESPBtn.Text = "All Eggs ESP: ON"
        Runtime.UIRegs.ToggleGlobalESPBtn.TextColor3 = Color3.fromRGB(0, 255, 120)
        StatusLabel.Text = "● ESP enabled"
        StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
    else
        -- Strict OFF: disable both global ESP and every per-egg custom ESP.
        mainESPActive = false
        for egg, data in pairs(eggData) do
            if data then
                data.CustomActive = false
            end
            if egg and egg.Parent then
                updateEggESP(egg)
            end
        end
        Runtime.UIRegs.ToggleGlobalESPBtn.Text = "All Eggs ESP: OFF"
        Runtime.UIRegs.ToggleGlobalESPBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
        StatusLabel.Text = "● ESP disabled (strict OFF)"
        StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
    end

    applyGlobalESP(mainESPActive)
end)

--==================================================

-- BOTÓN AUTO BEST EGG

--==================================================

Runtime.UIRegs.AutoBestEggBtn = Instance.new("TextButton")

Runtime.UIRegs.AutoBestEggBtn.Size = UDim2.new(1, 0, 0, 32)

Runtime.UIRegs.AutoBestEggBtn.Position = UDim2.new(0, 0, 0, 92)

Runtime.UIRegs.AutoBestEggBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)

Runtime.UIRegs.AutoBestEggBtn.BackgroundTransparency = 0.18

Runtime.UIRegs.AutoBestEggBtn.Text = "Auto Best Egg: OFF"

Runtime.UIRegs.AutoBestEggBtn.TextColor3 = Color3.fromRGB(220, 220, 220)

Runtime.UIRegs.AutoBestEggBtn.TextSize = 13

Runtime.UIRegs.AutoBestEggBtn.Font = Enum.Font.SourceSansBold

Runtime.UIRegs.AutoBestEggBtn.Parent = ContentContainer

styleButton(Runtime.UIRegs.AutoBestEggBtn)

Runtime.UIRegs.AutoBestEggBtn.Activated:Connect(function()
    if autoBestEggActive then
        stopAutoBestEgg()
        Runtime.UIRegs.AutoBestEggBtn.Text = "Auto Best Egg: OFF"
        Runtime.UIRegs.AutoBestEggBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
        Runtime.UIRegs.AutoBestEggBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)
        StatusLabel.Text = "● Auto Best Egg stopped"
        StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
    else
        startAutoBestEgg()
        Runtime.UIRegs.AutoBestEggBtn.Text = "Auto Best Egg: ON"
        Runtime.UIRegs.AutoBestEggBtn.TextColor3 = Color3.fromRGB(0, 255, 120)
        Runtime.UIRegs.AutoBestEggBtn.BackgroundColor3 = Color3.fromRGB(0, 95, 60)
        StatusLabel.Text = "● Auto Best Egg enabled"
        StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
    end
end)

--==================================================

-- BOTÓN TP INICIO

--==================================================

Runtime.UIRegs.TPHomeBtn = Instance.new("TextButton")

Runtime.UIRegs.TPHomeBtn.Size = UDim2.new(1, 0, 0, 32)

Runtime.UIRegs.TPHomeBtn.Position = UDim2.new(0, 0, 0, 129)

Runtime.UIRegs.TPHomeBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)

Runtime.UIRegs.TPHomeBtn.BackgroundTransparency = 0.18

Runtime.UIRegs.TPHomeBtn.Text = "🏠 Go Home"

Runtime.UIRegs.TPHomeBtn.TextColor3 = Color3.fromRGB(220, 220, 220)

Runtime.UIRegs.TPHomeBtn.TextSize = 13

Runtime.UIRegs.TPHomeBtn.Font = Enum.Font.SourceSansBold

Runtime.UIRegs.TPHomeBtn.Parent = ContentContainer

styleButton(Runtime.UIRegs.TPHomeBtn)

Runtime.UIRegs.TPHomeBtn.Activated:Connect(function()

    local success = teleportToHomePlot()

    if success then

        StatusLabel.Text = movementMode == "AutoFarm" and "● Moved Home (500 + noclip)" or "● Teleported Home"

        StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)

    else

        StatusLabel.Text = "● Your Ranch/plot was not found"

        StatusLabel.TextColor3 = Color3.fromRGB(255, 100, 100)

    end

end)

--==================================================

-- KEYBIND

--==================================================

Runtime.UIRegs.KeybindBtn = Instance.new("TextButton")

Runtime.UIRegs.KeybindBtn.Size = UDim2.new(1, 0, 0, 26)

Runtime.UIRegs.KeybindBtn.Position = UDim2.new(0, 0, 0, 166)

Runtime.UIRegs.KeybindBtn.BackgroundColor3 = Color3.fromRGB(25, 25, 25)

Runtime.UIRegs.KeybindBtn.BackgroundTransparency = 0.25

Runtime.UIRegs.KeybindBtn.Text = "Home TP Key: [" .. tpKeybind.Name .. "]"

Runtime.UIRegs.KeybindBtn.TextColor3 = Color3.fromRGB(180, 180, 180)

Runtime.UIRegs.KeybindBtn.TextSize = 11

Runtime.UIRegs.KeybindBtn.Font = Enum.Font.SourceSans

Runtime.UIRegs.KeybindBtn.Parent = ContentContainer

styleButton(Runtime.UIRegs.KeybindBtn)

Runtime.UIRegs.KeybindBtn.Activated:Connect(function()

    if Runtime.InputCompat.IsTouchPreferred() then
        listeningForKey = false
        local moved = teleportToHomePlot()
        Runtime.UIRegs.KeybindBtn.Text = moved and "Mobile Home TP: DONE" or "Mobile Home TP: RETRY"
        Runtime.UIRegs.KeybindBtn.TextColor3 = moved
            and Color3.fromRGB(0, 255, 120)
            or Color3.fromRGB(255, 190, 80)
        task.delay(1.0, function()
            if Runtime.UIRegs.KeybindBtn and Runtime.UIRegs.KeybindBtn.Parent then
                Runtime.UIRegs.KeybindBtn.Text = "Mobile Home TP (tap)"
                Runtime.UIRegs.KeybindBtn.TextColor3 = Color3.fromRGB(180, 180, 180)
            end
        end)
        return
    end

    listeningForKey = true

    Runtime.UIRegs.KeybindBtn.Text = "Press a key..."

    Runtime.UIRegs.KeybindBtn.TextColor3 = Color3.fromRGB(255, 200, 0)

end)

--==================================================

-- BOTÓN LISTA

--==================================================

Runtime.UIRegs.ToggleListBtn = Instance.new("TextButton")

Runtime.UIRegs.ToggleListBtn.Size = UDim2.new(1, 0, 0, 32)

Runtime.UIRegs.ToggleListBtn.Position = UDim2.new(0, 0, 0, 197)

Runtime.UIRegs.ToggleListBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)

Runtime.UIRegs.ToggleListBtn.BackgroundTransparency = 0.18

Runtime.UIRegs.ToggleListBtn.Text = "Show Egg List ▼"

Runtime.UIRegs.ToggleListBtn.TextColor3 = Color3.fromRGB(220, 220, 220)

Runtime.UIRegs.ToggleListBtn.TextSize = 13

Runtime.UIRegs.ToggleListBtn.Font = Enum.Font.SourceSansBold

Runtime.UIRegs.ToggleListBtn.Parent = ContentContainer

styleButton(Runtime.UIRegs.ToggleListBtn)

--==================================================

-- LISTA

--==================================================

Runtime.UIRegs.ListContainerFrame = Instance.new("Frame")

Runtime.UIRegs.ListContainerFrame.Size = UDim2.new(1, 0, 0, 275)

Runtime.UIRegs.ListContainerFrame.Position = UDim2.new(0, 0, 0, 234)

Runtime.UIRegs.ListContainerFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 15)

Runtime.UIRegs.ListContainerFrame.BackgroundTransparency = 0.22

Runtime.UIRegs.ListContainerFrame.Visible = false

Runtime.UIRegs.ListContainerFrame.Parent = ContentContainer

do
Runtime.UIRegs.ListCorner = Instance.new("UICorner")

Runtime.UIRegs.ListCorner.CornerRadius = UDim.new(0, 7)

Runtime.UIRegs.ListCorner.Parent = Runtime.UIRegs.ListContainerFrame
end

do
Runtime.UIRegs.ListStroke = Instance.new("UIStroke")

Runtime.UIRegs.ListStroke.Color = Color3.fromRGB(55, 55, 55)

Runtime.UIRegs.ListStroke.Transparency = 0.5

Runtime.UIRegs.ListStroke.Parent = Runtime.UIRegs.ListContainerFrame
end

--==================================================

-- CONTADOR

--==================================================

Runtime.UIRegs.EggCountLabel = Instance.new("TextLabel")

Runtime.UIRegs.EggCountLabel.Size = UDim2.new(1, -10, 0, 20)

Runtime.UIRegs.EggCountLabel.Position = UDim2.new(0, 5, 0, 5)

Runtime.UIRegs.EggCountLabel.BackgroundTransparency = 1

Runtime.UIRegs.EggCountLabel.Text = "Detected Eggs: 0"

Runtime.UIRegs.EggCountLabel.TextColor3 = Color3.fromRGB(170, 170, 170)

Runtime.UIRegs.EggCountLabel.TextSize = 11

Runtime.UIRegs.EggCountLabel.Font = Enum.Font.SourceSansBold

Runtime.UIRegs.EggCountLabel.TextXAlignment = Enum.TextXAlignment.Left

Runtime.UIRegs.EggCountLabel.Parent = Runtime.UIRegs.ListContainerFrame

--==================================================

-- REFRESH

--==================================================

Runtime.UIRegs.RefreshBtn = Instance.new("TextButton")

Runtime.UIRegs.RefreshBtn.Size = UDim2.new(0.48, -5, 0, 25)

Runtime.UIRegs.RefreshBtn.Position = UDim2.new(0, 5, 0, 27)

Runtime.UIRegs.RefreshBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 45)

Runtime.UIRegs.RefreshBtn.BackgroundTransparency = 0.15

Runtime.UIRegs.RefreshBtn.Text = "↻ Refresh"

Runtime.UIRegs.RefreshBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

Runtime.UIRegs.RefreshBtn.TextSize = 12

Runtime.UIRegs.RefreshBtn.Font = Enum.Font.SourceSansBold

Runtime.UIRegs.RefreshBtn.Parent = Runtime.UIRegs.ListContainerFrame

styleButton(Runtime.UIRegs.RefreshBtn)

--==================================================

-- ORDENAR

--==================================================

Runtime.UIRegs.SortBtn = Instance.new("TextButton")

Runtime.UIRegs.SortBtn.Size = UDim2.new(0.48, -5, 0, 25)

Runtime.UIRegs.SortBtn.Position = UDim2.new(0.52, 0, 0, 27)

Runtime.UIRegs.SortBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 45)

Runtime.UIRegs.SortBtn.BackgroundTransparency = 0.15

Runtime.UIRegs.SortBtn.Text = "Sort: Name"

Runtime.UIRegs.SortBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

Runtime.UIRegs.SortBtn.TextSize = 12

Runtime.UIRegs.SortBtn.Font = Enum.Font.SourceSansBold

Runtime.UIRegs.SortBtn.Parent = Runtime.UIRegs.ListContainerFrame

styleButton(Runtime.UIRegs.SortBtn)

--==================================================

-- BUSCADOR

--==================================================

Runtime.UIRegs.SearchBox = Instance.new("TextBox")

Runtime.UIRegs.SearchBox.Size = UDim2.new(1, -10, 0, 25)

Runtime.UIRegs.SearchBox.Position = UDim2.new(0, 5, 0, 57)

Runtime.UIRegs.SearchBox.BackgroundColor3 = Color3.fromRGB(25, 25, 25)

Runtime.UIRegs.SearchBox.BackgroundTransparency = 0.15

Runtime.UIRegs.SearchBox.PlaceholderText = "Search Eggs..."

Runtime.UIRegs.SearchBox.PlaceholderColor3 = Color3.fromRGB(130, 130, 130)

Runtime.UIRegs.SearchBox.Text = ""

Runtime.UIRegs.SearchBox.TextColor3 = Color3.fromRGB(255, 255, 255)

Runtime.UIRegs.SearchBox.TextSize = 12

Runtime.UIRegs.SearchBox.Font = Enum.Font.SourceSans

Runtime.UIRegs.SearchBox.TextXAlignment = Enum.TextXAlignment.Left

Runtime.UIRegs.SearchBox.ClearTextOnFocus = false

Runtime.UIRegs.SearchBox.Parent = Runtime.UIRegs.ListContainerFrame

do
Runtime.UIRegs.SearchCorner = Instance.new("UICorner")

Runtime.UIRegs.SearchCorner.CornerRadius = UDim.new(0, 5)

Runtime.UIRegs.SearchCorner.Parent = Runtime.UIRegs.SearchBox
end

do
Runtime.UIRegs.SearchPadding = Instance.new("UIPadding")

Runtime.UIRegs.SearchPadding.PaddingLeft = UDim.new(0, 8)

Runtime.UIRegs.SearchPadding.Parent = Runtime.UIRegs.SearchBox
end

--==================================================

-- SCROLL

--==================================================

Runtime.UIRegs.ScrollList = Instance.new("ScrollingFrame")

Runtime.UIRegs.ScrollList.Size = UDim2.new(1, -10, 1, -87)

Runtime.UIRegs.ScrollList.Position = UDim2.new(0, 5, 0, 87)

Runtime.UIRegs.ScrollList.BackgroundTransparency = 1

Runtime.UIRegs.ScrollList.BorderSizePixel = 0

Runtime.UIRegs.ScrollList.ScrollBarThickness = 4

Runtime.UIRegs.ScrollList.ScrollBarImageColor3 = Color3.fromRGB(80, 80, 80)

Runtime.UIRegs.ScrollList.CanvasSize = UDim2.new(0, 0, 0, 0)

Runtime.UIRegs.ScrollList.Parent = Runtime.UIRegs.ListContainerFrame

Runtime.UIRegs.UIListLayout = Instance.new("UIListLayout")

Runtime.UIRegs.UIListLayout.SortOrder = Enum.SortOrder.LayoutOrder

Runtime.UIRegs.UIListLayout.Padding = UDim.new(0, 4)

Runtime.UIRegs.UIListLayout.Parent = Runtime.UIRegs.ScrollList

Runtime.UIRegs.UIListLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()

    Runtime.UIRegs.ScrollList.CanvasSize = UDim2.new(

        0,

        0,

        0,

        Runtime.UIRegs.UIListLayout.AbsoluteContentSize.Y + 6

    )

end)

--==================================================

-- TABBED UI (UI ONLY - FEATURE FUNCTIONS ABOVE ARE REUSED)

--==================================================

Runtime.UIRegs.TabBar = Instance.new("Frame")

Runtime.UIRegs.TabBar.Name = "TabBar"

Runtime.UIRegs.TabBar.Size = UDim2.new(1, 0, 0, 30)

Runtime.UIRegs.TabBar.Position = UDim2.new(0, 0, 0, 24)

Runtime.UIRegs.TabBar.BackgroundColor3 = Color3.fromRGB(18, 21, 27)

Runtime.UIRegs.TabBar.BackgroundTransparency = 0

Runtime.UIRegs.TabBar.Parent = ContentContainer

do
    local sidebarCorner = Instance.new("UICorner")
    sidebarCorner.CornerRadius = UDim.new(0, 10)
    sidebarCorner.Parent = Runtime.UIRegs.TabBar
    local sidebarStroke = Instance.new("UIStroke")
    sidebarStroke.Color = Color3.fromRGB(43, 52, 66)
    sidebarStroke.Transparency = 0.35
    sidebarStroke.Thickness = 1
    sidebarStroke.Parent = Runtime.UIRegs.TabBar
end

Runtime.UIRegs.PagesContainer = Instance.new("Frame")

Runtime.UIRegs.PagesContainer.Name = "Pages"

Runtime.UIRegs.PagesContainer.Size = UDim2.new(1, 0, 1, -60)

Runtime.UIRegs.PagesContainer.Position = UDim2.new(0, 0, 0, 60)

Runtime.UIRegs.PagesContainer.BackgroundTransparency = 1

Runtime.UIRegs.PagesContainer.ClipsDescendants = true

Runtime.UIRegs.PagesContainer.Parent = ContentContainer

Runtime.UIRegs.MainPage = Instance.new("ScrollingFrame")
Runtime.UIRegs.MainPage.BorderSizePixel = 0
Runtime.UIRegs.MainPage.ScrollBarThickness = 3
Runtime.UIRegs.MainPage.CanvasSize = UDim2.new(0, 0, 0, 680)
Runtime.UIRegs.MainPage.ScrollingDirection = Enum.ScrollingDirection.Y

Runtime.UIRegs.MainPage.Name = "MiscPage"

Runtime.UIRegs.MainPage.Size = UDim2.new(1, 0, 1, 0)

Runtime.UIRegs.MainPage.BackgroundTransparency = 1

Runtime.UIRegs.MainPage.Visible = false

Runtime.UIRegs.MainPage.Parent = Runtime.UIRegs.PagesContainer

Runtime.UIRegs.EggsPage = Instance.new("Frame")

Runtime.UIRegs.EggsPage.Name = "EggsPage"

Runtime.UIRegs.EggsPage.Size = UDim2.new(1, 0, 1, 0)

Runtime.UIRegs.EggsPage.BackgroundTransparency = 1

Runtime.UIRegs.EggsPage.Visible = false

Runtime.UIRegs.EggsPage.Parent = Runtime.UIRegs.PagesContainer

Runtime.UIRegs.LuckPage = Instance.new("Frame")

Runtime.UIRegs.LuckPage.Name = "LuckPage"

Runtime.UIRegs.LuckPage.Size = UDim2.new(1, 0, 1, 0)

Runtime.UIRegs.LuckPage.BackgroundTransparency = 1

Runtime.UIRegs.LuckPage.Visible = false

Runtime.UIRegs.LuckPage.Parent = Runtime.UIRegs.PagesContainer

Runtime.UIRegs.AutomationPage = Instance.new("ScrollingFrame")

Runtime.UIRegs.AutomationPage.Name = "AutomationPage"

Runtime.UIRegs.AutomationPage.Size = UDim2.new(1, 0, 1, 0)

Runtime.UIRegs.AutomationPage.BackgroundTransparency = 1
Runtime.UIRegs.AutomationPage.BorderSizePixel = 0
Runtime.UIRegs.AutomationPage.ScrollBarThickness = 3
Runtime.UIRegs.AutomationPage.ScrollBarImageColor3 = Color3.fromRGB(75, 90, 110)
Runtime.UIRegs.AutomationPage.CanvasSize = UDim2.new(0, 0, 0, 610)
Runtime.UIRegs.AutomationPage.ScrollingDirection = Enum.ScrollingDirection.Y
Runtime.UIRegs.AutomationPage.ElasticBehavior = Enum.ElasticBehavior.Never
Runtime.UIRegs.AutomationPage.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar

Runtime.UIRegs.AutomationPage.Visible = false

Runtime.UIRegs.AutomationPage.Parent = Runtime.UIRegs.PagesContainer

Runtime.UIRegs.SettingsPage = Instance.new("ScrollingFrame")

Runtime.UIRegs.SettingsPage.Name = "SettingsPage"

Runtime.UIRegs.SettingsPage.Size = UDim2.new(1, 0, 1, 0)

Runtime.UIRegs.SettingsPage.BackgroundTransparency = 1
Runtime.UIRegs.SettingsPage.BorderSizePixel = 0
Runtime.UIRegs.SettingsPage.ScrollBarThickness = 3
Runtime.UIRegs.SettingsPage.ScrollBarImageColor3 = Color3.fromRGB(75, 90, 110)
Runtime.UIRegs.SettingsPage.CanvasSize = UDim2.new(0, 0, 0, 670)
Runtime.UIRegs.SettingsPage.ScrollingDirection = Enum.ScrollingDirection.Y
Runtime.UIRegs.SettingsPage.ElasticBehavior = Enum.ElasticBehavior.Never
Runtime.UIRegs.SettingsPage.VerticalScrollBarInset = Enum.ScrollBarInset.ScrollBar

Runtime.UIRegs.SettingsPage.Visible = false

Runtime.UIRegs.SettingsPage.Parent = Runtime.UIRegs.PagesContainer

local function createTabButton(text, index)

    local button = Instance.new("TextButton")

    button.Name = text .. "Tab"

    local tabWidth = 0.20
    button.Size = UDim2.new(tabWidth, -3, 1, 0)

    button.Position = UDim2.new((index - 1) * tabWidth, index == 1 and 0 or 1, 0, 0)

    button.BackgroundColor3 = Color3.fromRGB(23, 27, 34)

    button.BackgroundTransparency = 0.02

    button.Text = text

    button.TextColor3 = Color3.fromRGB(171, 181, 197)

    button.TextSize = 11

    button.TextWrapped = true

    button.Font = Enum.Font.GothamBold

    button.Parent = Runtime.UIRegs.TabBar

    styleButton(button)

    return button

end

Runtime.UIRegs.EggsTabBtn = createTabButton("Eggs", 1)

Runtime.UIRegs.AutomationTabBtn = createTabButton("Place/Hatch", 2)

Runtime.UIRegs.MiscTabBtn = createTabButton("Misc", 3)

Runtime.UIRegs.LuckTabBtn = createTabButton("Luck", 4)

Runtime.UIRegs.SettingsTabBtn = createTabButton("Settings", 5)

Runtime.UIRegs.tabPages = {

    Eggs = Runtime.UIRegs.EggsPage,

    Automation = Runtime.UIRegs.AutomationPage,

    Misc = Runtime.UIRegs.MainPage,

    Luck = Runtime.UIRegs.LuckPage,

    Settings = Runtime.UIRegs.SettingsPage

}

Runtime.UIRegs.tabButtons = {

    Eggs = Runtime.UIRegs.EggsTabBtn,

    Automation = Runtime.UIRegs.AutomationTabBtn,

    Misc = Runtime.UIRegs.MiscTabBtn,

    Luck = Runtime.UIRegs.LuckTabBtn,

    Settings = Runtime.UIRegs.SettingsTabBtn

}

Runtime.UIRegs.currentTab = "Eggs"

local function selectTab(name)

    Runtime.UIRegs.currentTab = name

    for tabName, page in pairs(Runtime.UIRegs.tabPages) do

        page.Visible = tabName == name

        local button = Runtime.UIRegs.tabButtons[tabName]

        if button then

            if tabName == name then

                button.BackgroundColor3 = Color3.fromRGB(48, 126, 232)

                button.TextColor3 = Color3.fromRGB(255, 255, 255)

            else

                button.BackgroundColor3 = Color3.fromRGB(23, 27, 34)

                button.TextColor3 = Color3.fromRGB(171, 181, 197)

            end

        end

    end

    -- Performance: while other tabs are open, egg-list UI rebuilds are deferred.
    -- Returning to Eggs refreshes the display immediately without changing Auto Get logic.
    if name == "Eggs" then
        task.defer(function()
            if not Runtime.Alive or not ScreenGui.Parent or Runtime.UIRegs.currentTab ~= "Eggs" then
                return
            end
            if Runtime.AutoGet.RefreshFilterUI then
                Runtime.AutoGet.RefreshFilterUI()
            end
            if populateList and Runtime.UIRegs.ListContainerFrame.Visible then
                populateList()
            end
        end)
    elseif name == "Automation" then
        -- v3.39: rebuild the two egg-name filter lists from the live game Index
        -- whenever this tab opens. This automatically picks up newly added eggs.
        task.defer(function()
            if not Runtime.Alive or not ScreenGui.Parent or Runtime.UIRegs.currentTab ~= "Automation" then
                return
            end
            if Runtime.EggAutomation.RefreshEggFilterUI then
                Runtime.EggAutomation.RefreshEggFilterUI()
            end
        end)
    end

end

Runtime.UIRegs.EggsTabBtn.Activated:Connect(function() selectTab("Eggs") end)

Runtime.UIRegs.AutomationTabBtn.Activated:Connect(function() selectTab("Automation") end)

Runtime.UIRegs.MiscTabBtn.Activated:Connect(function() selectTab("Misc") end)

Runtime.UIRegs.LuckTabBtn.Activated:Connect(function() selectTab("Luck") end)

Runtime.UIRegs.SettingsTabBtn.Activated:Connect(function() selectTab("Settings") end)

selectTab("Eggs")

-- Main tab removed. Legacy movement buttons stay hidden; Auto Get has its own
-- travel selector, Auto Best lives in Eggs, and ESP lives in Misc.
ModeAutoFarmBtn.Parent = Runtime.UIRegs.MainPage
ModeAutoFarmBtn.Visible = false
ModeTeleportBtn.Parent = Runtime.UIRegs.MainPage
ModeTeleportBtn.Visible = false
Runtime.UIRegs.TPHomeBtn.Parent = Runtime.UIRegs.MainPage
Runtime.UIRegs.TPHomeBtn.Visible = false
StopAutoFarmBtn.Parent = Runtime.UIRegs.MainPage
StopAutoFarmBtn.Visible = false

Runtime.UIRegs.ToggleGlobalESPBtn.Parent = Runtime.UIRegs.MainPage
Runtime.UIRegs.AutoBestEggBtn.Parent = Runtime.UIRegs.EggsPage

Runtime.UIRegs.KeybindBtn.Parent = Runtime.UIRegs.SettingsPage
Runtime.UIRegs.ListContainerFrame.Parent = Runtime.UIRegs.EggsPage

-- ESP colors live only in Misc. Colors are automatic per egg.
-- Blackhole Egg remains forced to black-violet.
Runtime.UIRegs.ESPColorPanel = Instance.new("Frame")
Runtime.UIRegs.ESPColorPanel.Name = "ESPColorCategory"
Runtime.UIRegs.ESPColorPanel.Size = UDim2.new(1, 0, 0, 56)
Runtime.UIRegs.ESPColorPanel.Position = UDim2.new(0, 0, 0, 0)
Runtime.UIRegs.ESPColorPanel.BackgroundColor3 = Color3.fromRGB(18, 24, 32)
Runtime.UIRegs.ESPColorPanel.BackgroundTransparency = 0.08
Runtime.UIRegs.ESPColorPanel.BorderSizePixel = 0
Runtime.UIRegs.ESPColorPanel.Parent = Runtime.UIRegs.MainPage

do
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = Runtime.UIRegs.ESPColorPanel
end

Runtime.UIRegs.ESPColorTitle = Instance.new("TextLabel")
Runtime.UIRegs.ESPColorTitle.Size = UDim2.new(1, -10, 0, 20)
Runtime.UIRegs.ESPColorTitle.Position = UDim2.new(0, 5, 0, 3)
Runtime.UIRegs.ESPColorTitle.BackgroundTransparency = 1
Runtime.UIRegs.ESPColorTitle.Text = "ESP Colors: Automatic Per Egg"
Runtime.UIRegs.ESPColorTitle.TextColor3 = Color3.fromRGB(205, 215, 228)
Runtime.UIRegs.ESPColorTitle.TextSize = 10
Runtime.UIRegs.ESPColorTitle.Font = Enum.Font.SourceSansBold
Runtime.UIRegs.ESPColorTitle.TextXAlignment = Enum.TextXAlignment.Left
Runtime.UIRegs.ESPColorTitle.Parent = Runtime.UIRegs.ESPColorPanel

do
    local hint = Instance.new("TextLabel")
    hint.Size = UDim2.new(1, -10, 0, 25)
    hint.Position = UDim2.new(0, 5, 0, 25)
    hint.BackgroundTransparency = 1
    hint.Text = "Each egg gets a stable unique color. Blackhole Egg = Black Violet."
    hint.TextWrapped = true
    hint.TextColor3 = Color3.fromRGB(145, 158, 175)
    hint.TextSize = 9
    hint.Font = Enum.Font.SourceSans
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.Parent = Runtime.UIRegs.ESPColorPanel
end

--==================================================
-- EGGS TAB: AVAILABLE + SELECTED TWO-PANEL UI
--==================================================

Runtime.UIRegs.availableEggsHidden = false

Runtime.UIRegs.AvailableEggsHeader = Instance.new("Frame")
Runtime.UIRegs.AvailableEggsHeader.Name = "AvailableEggsHeader"
Runtime.UIRegs.AvailableEggsHeader.BackgroundColor3 = Color3.fromRGB(18, 24, 32)
Runtime.UIRegs.AvailableEggsHeader.BackgroundTransparency = 0.08
Runtime.UIRegs.AvailableEggsHeader.BorderSizePixel = 0
Runtime.UIRegs.AvailableEggsHeader.Parent = Runtime.UIRegs.EggsPage

do
Runtime.UIRegs.AvailableEggsHeaderCorner = Instance.new("UICorner")
Runtime.UIRegs.AvailableEggsHeaderCorner.CornerRadius = UDim.new(0, 7)
Runtime.UIRegs.AvailableEggsHeaderCorner.Parent = Runtime.UIRegs.AvailableEggsHeader
end

do
Runtime.UIRegs.AvailableEggsTitle = Instance.new("TextLabel")
Runtime.UIRegs.AvailableEggsTitle.Size = UDim2.new(1, -92, 1, 0)
Runtime.UIRegs.AvailableEggsTitle.Position = UDim2.new(0, 8, 0, 0)
Runtime.UIRegs.AvailableEggsTitle.BackgroundTransparency = 1
Runtime.UIRegs.AvailableEggsTitle.Text = "Available Eggs"
Runtime.UIRegs.AvailableEggsTitle.TextColor3 = Color3.fromRGB(225, 232, 242)
Runtime.UIRegs.AvailableEggsTitle.TextSize = 11
Runtime.UIRegs.AvailableEggsTitle.Font = Enum.Font.SourceSansBold
Runtime.UIRegs.AvailableEggsTitle.TextXAlignment = Enum.TextXAlignment.Left
Runtime.UIRegs.AvailableEggsTitle.Parent = Runtime.UIRegs.AvailableEggsHeader
end

Runtime.UIRegs.AvailableEggsToggleBtn = Instance.new("TextButton")
Runtime.UIRegs.AvailableEggsToggleBtn.Size = UDim2.new(0, 78, 0, 22)
Runtime.UIRegs.AvailableEggsToggleBtn.Position = UDim2.new(1, -84, 0.5, -11)
Runtime.UIRegs.AvailableEggsToggleBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 58)
Runtime.UIRegs.AvailableEggsToggleBtn.BackgroundTransparency = 0.08
Runtime.UIRegs.AvailableEggsToggleBtn.Text = "Hide"
Runtime.UIRegs.AvailableEggsToggleBtn.TextColor3 = Color3.fromRGB(220, 228, 238)
Runtime.UIRegs.AvailableEggsToggleBtn.TextSize = 10
Runtime.UIRegs.AvailableEggsToggleBtn.Font = Enum.Font.SourceSansBold
Runtime.UIRegs.AvailableEggsToggleBtn.Parent = Runtime.UIRegs.AvailableEggsHeader
styleButton(Runtime.UIRegs.AvailableEggsToggleBtn)

Runtime.UIRegs.SelectedEggPanel = Instance.new("ScrollingFrame")
Runtime.UIRegs.SelectedEggPanel.Name = "SelectedEggPanel"
Runtime.UIRegs.SelectedEggPanel.BackgroundColor3 = Color3.fromRGB(18, 24, 32)
Runtime.UIRegs.SelectedEggPanel.BackgroundTransparency = 0.08
Runtime.UIRegs.SelectedEggPanel.BorderSizePixel = 0
Runtime.UIRegs.SelectedEggPanel.ScrollBarThickness = 4
Runtime.UIRegs.SelectedEggPanel.ScrollBarImageColor3 = Color3.fromRGB(75, 90, 110)
Runtime.UIRegs.SelectedEggPanel.CanvasSize = UDim2.new(0, 0, 0, 430)
Runtime.UIRegs.SelectedEggPanel.ScrollingDirection = Enum.ScrollingDirection.Y
Runtime.UIRegs.SelectedEggPanel.Parent = Runtime.UIRegs.EggsPage

do
Runtime.UIRegs.SelectedEggCorner = Instance.new("UICorner")
Runtime.UIRegs.SelectedEggCorner.CornerRadius = UDim.new(0, 8)
Runtime.UIRegs.SelectedEggCorner.Parent = Runtime.UIRegs.SelectedEggPanel
end

do
Runtime.UIRegs.SelectedEggStroke = Instance.new("UIStroke")
Runtime.UIRegs.SelectedEggStroke.Color = Color3.fromRGB(55, 70, 90)
Runtime.UIRegs.SelectedEggStroke.Transparency = 0.35
Runtime.UIRegs.SelectedEggStroke.Thickness = 1
Runtime.UIRegs.SelectedEggStroke.Parent = Runtime.UIRegs.SelectedEggPanel
end

do
Runtime.UIRegs.SelectedEggTitle = Instance.new("TextLabel")
Runtime.UIRegs.SelectedEggTitle.Size = UDim2.new(1, -16, 0, 24)
Runtime.UIRegs.SelectedEggTitle.Position = UDim2.new(0, 8, 0, 6)
Runtime.UIRegs.SelectedEggTitle.BackgroundTransparency = 1
Runtime.UIRegs.SelectedEggTitle.Text = "Egg Automation"
Runtime.UIRegs.SelectedEggTitle.TextColor3 = Color3.fromRGB(225, 232, 242)
Runtime.UIRegs.SelectedEggTitle.TextSize = 12
Runtime.UIRegs.SelectedEggTitle.Font = Enum.Font.SourceSansBold
Runtime.UIRegs.SelectedEggTitle.TextXAlignment = Enum.TextXAlignment.Left
Runtime.UIRegs.SelectedEggTitle.Parent = Runtime.UIRegs.SelectedEggPanel
end

Runtime.UIRegs.SelectedGetEggBtn = Instance.new("TextButton")
Runtime.UIRegs.SelectedGetEggBtn.Name = "SelectedGetEgg"
Runtime.UIRegs.SelectedGetEggBtn.BackgroundColor3 = Color3.fromRGB(45, 45, 45)
Runtime.UIRegs.SelectedGetEggBtn.BackgroundTransparency = 0.12
Runtime.UIRegs.SelectedGetEggBtn.Text = "Get Egg: OFF"
Runtime.UIRegs.SelectedGetEggBtn.TextColor3 = Color3.fromRGB(235, 240, 248)
Runtime.UIRegs.SelectedGetEggBtn.TextSize = 10
Runtime.UIRegs.SelectedGetEggBtn.Font = Enum.Font.SourceSansBold
Runtime.UIRegs.SelectedGetEggBtn.Parent = Runtime.UIRegs.SelectedEggPanel
styleButton(Runtime.UIRegs.SelectedGetEggBtn)

Runtime.UIRegs.AutoBestEggBtn.Parent = Runtime.UIRegs.SelectedEggPanel

Runtime.Weight.Controls = {}
Runtime.Weight.RefreshControls = function()
    if Runtime.AutoGet.UI.PickupMethodBtn then
        Runtime.AutoGet.UI.PickupMethodBtn.Text = "Pickup: " .. Runtime.AutoGet.PickupMethod
    end
    for _, control in ipairs(Runtime.Weight.Controls) do
        control.Box.Text = tostring(control.Read())
    end
end
Runtime.Weight.AddControl = function(parent, title, y, read, write, delay)
    local row = Instance.new("Frame")
    row.BackgroundTransparency = 1
    row.Position = UDim2.new(0, 8, 0, y)
    row.Size = UDim2.new(1, -16, 0, 26)
    row.Parent = parent
    local label = Instance.new("TextLabel")
    label.BackgroundTransparency = 1
    label.Size = UDim2.new(0.43, 0, 1, 0)
    label.Text = title
    label.TextSize = 10
    label.Font = Enum.Font.SourceSans
    label.TextColor3 = Color3.fromRGB(170, 184, 202)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Parent = row
    local box = Instance.new("TextBox")
    box.Position = UDim2.new(0.43, 4, 0, 0)
    box.Size = UDim2.new(0.57, -4, 1, 0)
    box.BackgroundColor3 = Color3.fromRGB(24, 32, 43)
    box.BorderSizePixel = 0
    box.TextColor3 = Color3.fromRGB(235, 242, 250)
    box.TextSize = 11
    box.ClearTextOnFocus = false
    box.Text = tostring(read())
    box.PlaceholderText = delay and "seconds" or "0 = all"
    box.Parent = row
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 4)
    corner.Parent = box
    trackRuntimeConnection(box.FocusLost:Connect(function()
        local value = Runtime.Weight.Parse(box.Text, true)
        if value and (not delay or (value >= 0.25 and value <= 30)) then write(value) end
        box.Text = tostring(read())
    end))
    local control = {Box=box, Read=read, Row=row, Label=label}
    table.insert(Runtime.Weight.Controls, control)
    return control
end
Runtime.AutoGet.UI.WeightControl = Runtime.Weight.AddControl(Runtime.UIRegs.SelectedEggPanel, "Min kg", 70,
    function() return Runtime.AutoGet.MinWeightKg end,
    function(value)
        Runtime.AutoGet.MinWeightKg = value
        Runtime.AutoGet.RejoinBelowMin.BelowSince = nil
    end)

do
    local state = Runtime.AutoGet.RejoinBelowMin
    local button = Instance.new("TextButton")
    button.Name = "RejoinBelowMinToggle"
    button.Size = UDim2.new(1, -16, 0, 27)
    button.Position = UDim2.new(0, 8, 0, 102)
    button.BackgroundColor3 = Color3.fromRGB(35, 45, 58)
    button.BackgroundTransparency = 0.08
    button.BorderSizePixel = 0
    button.Text = "Rejoin Below Min: OFF"
    button.TextColor3 = Color3.fromRGB(235, 242, 250)
    button.TextSize = 9
    button.Font = Enum.Font.SourceSansBold
    button.Parent = Runtime.UIRegs.SelectedEggPanel
    styleButton(button)
    state.UI.Toggle = button

    trackRuntimeConnection(button.Activated:Connect(function()
        Runtime.AutoGet.SetRejoinBelowMinEnabled(not state.Enabled, false)
    end))

    Runtime.AutoGet.RefreshRejoinBelowMinUI()
end

Runtime.AutoGet.UI.DelayControl = Runtime.Weight.AddControl(Runtime.UIRegs.SelectedEggPanel, "Delay (s)", 480,
    function() return Runtime.AutoGet.PickupDelay end,
    function(value) Runtime.AutoGet.PickupDelay = value end, true)

do
    local button = Instance.new("TextButton")
    button.Position = UDim2.new(0, 8, 0, 560)
    button.Size = UDim2.new(1, -16, 0, 29)
    button.BackgroundColor3 = Color3.fromRGB(35, 45, 58)
    button.TextColor3 = Color3.fromRGB(240, 240, 240)
    button.TextSize = 11
    button.Text = "Pickup: " .. Runtime.AutoGet.PickupMethod
    button.Parent = Runtime.UIRegs.SelectedEggPanel
    Runtime.AutoGet.UI.PickupMethodBtn = button
    styleButton(button)
    trackRuntimeConnection(button.Activated:Connect(function()
        Runtime.AutoGet.PickupMethod = Runtime.AutoGet.PickupMethod == "PromptHold" and "Compatibility" or "PromptHold"
        Runtime.Weight.RefreshControls()
    end))
end

-- Auto Get return method: independent of the hidden legacy movement mode.
do
    local ui = Runtime.AutoGet.UI

    ui.TravelLabel = Instance.new("TextLabel")
    ui.TravelLabel.BackgroundTransparency = 1
    ui.TravelLabel.Text = "Auto Get Travel"
    ui.TravelLabel.TextColor3 = Color3.fromRGB(170, 184, 202)
    ui.TravelLabel.TextSize = 9
    ui.TravelLabel.Font = Enum.Font.SourceSansBold
    ui.TravelLabel.TextXAlignment = Enum.TextXAlignment.Left
    ui.TravelLabel.Parent = Runtime.UIRegs.SelectedEggPanel

    ui.TweenHomeBtn = Instance.new("TextButton")
    ui.TweenHomeBtn.BackgroundTransparency = 0.10
    ui.TweenHomeBtn.Text = "Tween Home"
    ui.TweenHomeBtn.TextSize = 9
    ui.TweenHomeBtn.Font = Enum.Font.SourceSansBold
    ui.TweenHomeBtn.Parent = Runtime.UIRegs.SelectedEggPanel
    styleButton(ui.TweenHomeBtn)

    ui.FilterLabel = Instance.new("TextLabel")
    ui.FilterLabel.BackgroundTransparency = 1
    ui.FilterLabel.Text = "Egg Filter — multi-select (green = TRUE)"
    ui.FilterLabel.TextColor3 = Color3.fromRGB(170, 184, 202)
    ui.FilterLabel.TextSize = 9
    ui.FilterLabel.Font = Enum.Font.SourceSansBold
    ui.FilterLabel.TextXAlignment = Enum.TextXAlignment.Left
    ui.FilterLabel.Parent = Runtime.UIRegs.SelectedEggPanel
    ui.FilterCollapsed = false
    ui.FilterCollapseBtn = Instance.new("TextButton")
    ui.FilterCollapseBtn.BackgroundColor3 = Color3.fromRGB(27,35,46)
    ui.FilterCollapseBtn.BorderSizePixel = 0
    ui.FilterCollapseBtn.TextColor3 = Color3.fromRGB(205,218,235)
    ui.FilterCollapseBtn.TextSize = 9
    ui.FilterCollapseBtn.Font = Enum.Font.SourceSansBold
    ui.FilterCollapseBtn.Text = "Hide"
    ui.FilterCollapseBtn.Parent = Runtime.UIRegs.SelectedEggPanel
    styleButton(ui.FilterCollapseBtn)

    ui.FilterScroll = Instance.new("ScrollingFrame")
    ui.FilterScroll.BackgroundColor3 = Color3.fromRGB(12, 17, 23)
    ui.FilterScroll.BackgroundTransparency = 0.10
    ui.FilterScroll.BorderSizePixel = 0
    ui.FilterScroll.ScrollBarThickness = 3
    ui.FilterScroll.ScrollBarImageColor3 = Color3.fromRGB(75, 90, 110)
    ui.FilterScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    ui.FilterScroll.Parent = Runtime.UIRegs.SelectedEggPanel

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 6)
    corner.Parent = ui.FilterScroll

    ui.FilterLayout = Instance.new("UIListLayout")
    ui.FilterLayout.SortOrder = Enum.SortOrder.LayoutOrder
    ui.FilterLayout.Padding = UDim.new(0, 3)
    ui.FilterLayout.Parent = ui.FilterScroll

    ui.FilterLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        if ui.FilterScroll and ui.FilterScroll.Parent then
            ui.FilterScroll.CanvasSize = UDim2.new(0, 0, 0, ui.FilterLayout.AbsoluteContentSize.Y + 4)
        end
    end)
end

Runtime.UIRegs.SelectedEggHint = Instance.new("TextLabel")
Runtime.UIRegs.SelectedEggHint.BackgroundTransparency = 1
Runtime.UIRegs.SelectedEggHint.Text = "Only green TRUE filters are Auto Get targets. Available Eggs are display + manual TP only."
Runtime.UIRegs.SelectedEggHint.TextWrapped = true
Runtime.UIRegs.SelectedEggHint.TextColor3 = Color3.fromRGB(125, 139, 158)
Runtime.UIRegs.SelectedEggHint.TextSize = 9
Runtime.UIRegs.SelectedEggHint.Font = Enum.Font.SourceSans
Runtime.UIRegs.SelectedEggHint.TextXAlignment = Enum.TextXAlignment.Left
Runtime.UIRegs.SelectedEggHint.TextYAlignment = Enum.TextYAlignment.Top
Runtime.UIRegs.SelectedEggHint.Parent = Runtime.UIRegs.SelectedEggPanel


-- Available Egg rows are display + manual TP only; Auto Get targeting happens only in the filter.

local function updateSelectedEggPanel()
    -- Auto Get is filter-only. Available Egg clicks never change target filters.
    Runtime.UIRegs.SelectedGetEggBtn.Text = autoFarmActive and "Get Egg: ON" or "Get Egg: OFF"
    Runtime.UIRegs.SelectedGetEggBtn.BackgroundColor3 = autoFarmActive
        and Color3.fromRGB(0, 150, 70)
        or Color3.fromRGB(45, 45, 45)
    if Runtime.AutoGet.RefreshEggModeUI then
        Runtime.AutoGet.RefreshEggModeUI()
    end
end

Runtime.AutoGet.RefreshSelectedPanel = updateSelectedEggPanel

local function layoutEggsPage()
    local ui = Runtime.AutoGet.UI
    Runtime.UIRegs.SelectedEggPanel.CanvasSize = UDim2.new(0, 0, 0, 605)

    if isMobileMode then
        Runtime.UIRegs.AvailableEggsHeader.Position = UDim2.new(0, 0, 0, 0)
        Runtime.UIRegs.AvailableEggsHeader.Size = UDim2.new(1, 0, 0, 28)

        if Runtime.UIRegs.availableEggsHidden then
            Runtime.UIRegs.ListContainerFrame.Visible = false
            Runtime.UIRegs.SelectedEggPanel.Position = UDim2.new(0, 0, 0, 34)
            Runtime.UIRegs.SelectedEggPanel.Size = UDim2.new(1, 0, 1, -34)
        else
            Runtime.UIRegs.ListContainerFrame.Visible = true
            Runtime.UIRegs.ListContainerFrame.Position = UDim2.new(0, 0, 0, 32)
            Runtime.UIRegs.ListContainerFrame.Size = UDim2.new(1, 0, 0, 150)
            Runtime.UIRegs.SelectedEggPanel.Position = UDim2.new(0, 0, 0, 188)
            Runtime.UIRegs.SelectedEggPanel.Size = UDim2.new(1, 0, 1, -188)
        end

        Runtime.UIRegs.SelectedGetEggBtn.Size = UDim2.new(1, -16, 0, 29)
        Runtime.UIRegs.SelectedGetEggBtn.Position = UDim2.new(0, 8, 0, 36)
        Runtime.UIRegs.AutoBestEggBtn.Size = UDim2.new(1, -16, 0, 29)
        Runtime.UIRegs.AutoBestEggBtn.Position = UDim2.new(0, 8, 0, 70)
        ui.FilterLabel.Size = UDim2.new(1, -16, 0, 16)
        ui.FilterLabel.Position = UDim2.new(0, 8, 0, 106)
        ui.FilterScroll.Size = UDim2.new(1, -16, 0, 200)
        ui.FilterScroll.Position = UDim2.new(0, 8, 0, 124)
        ui.TravelLabel.Size = UDim2.new(1, -16, 0, 16)
        ui.TravelLabel.Position = UDim2.new(0, 8, 0, 332)
        ui.TweenHomeBtn.Size = UDim2.new(1, -16, 0, 27)
        ui.TweenHomeBtn.Position = UDim2.new(0, 8, 0, 350)
        Runtime.UIRegs.SelectedEggHint.Size = UDim2.new(1, -16, 0, 42)
        Runtime.UIRegs.SelectedEggHint.Position = UDim2.new(0, 8, 0, 385)
    else
        Runtime.UIRegs.AvailableEggsHeader.Position = UDim2.new(0, 0, 0, 0)
        Runtime.UIRegs.AvailableEggsHeader.Size = UDim2.new(0.58, -4, 0, 28)

        if Runtime.UIRegs.availableEggsHidden then
            Runtime.UIRegs.ListContainerFrame.Visible = false
            Runtime.UIRegs.SelectedEggPanel.Position = UDim2.new(0, 0, 0, 0)
            Runtime.UIRegs.SelectedEggPanel.Size = UDim2.new(1, 0, 1, 0)
        else
            Runtime.UIRegs.ListContainerFrame.Visible = true
            Runtime.UIRegs.ListContainerFrame.Position = UDim2.new(0, 0, 0, 34)
            Runtime.UIRegs.ListContainerFrame.Size = UDim2.new(0.58, -4, 1, -34)
            Runtime.UIRegs.SelectedEggPanel.Position = UDim2.new(0.59, 4, 0, 0)
            Runtime.UIRegs.SelectedEggPanel.Size = UDim2.new(0.41, -4, 1, 0)
        end

        Runtime.UIRegs.SelectedGetEggBtn.Size = UDim2.new(1, -20, 0, 30)
        Runtime.UIRegs.SelectedGetEggBtn.Position = UDim2.new(0, 10, 0, 38)
        Runtime.UIRegs.AutoBestEggBtn.Size = UDim2.new(1, -20, 0, 30)
        Runtime.UIRegs.AutoBestEggBtn.Position = UDim2.new(0, 10, 0, 73)
        ui.FilterLabel.Size = UDim2.new(1, -20, 0, 16)
        ui.FilterLabel.Position = UDim2.new(0, 10, 0, 111)
        ui.FilterScroll.Size = UDim2.new(1, -20, 0, 215)
        ui.FilterScroll.Position = UDim2.new(0, 10, 0, 129)
        ui.TravelLabel.Size = UDim2.new(1, -20, 0, 16)
        ui.TravelLabel.Position = UDim2.new(0, 10, 0, 352)
        ui.TweenHomeBtn.Size = UDim2.new(1, -20, 0, 29)
        ui.TweenHomeBtn.Position = UDim2.new(0, 10, 0, 370)
        Runtime.UIRegs.SelectedEggHint.Size = UDim2.new(1, -20, 0, 42)
        Runtime.UIRegs.SelectedEggHint.Position = UDim2.new(0, 10, 0, 407)
    end

    -- Get Egg -> minimum kg -> Auto Best -> egg-name list.
    ui.WeightControl.Row.Position = UDim2.new(0, isMobileMode and 8 or 10, 0, isMobileMode and 70 or 73)
    ui.WeightControl.Row.Size = UDim2.new(1, isMobileMode and -16 or -20, 0, 26)
    if Runtime.AutoGet.RejoinBelowMin.UI.Toggle then
        Runtime.AutoGet.RejoinBelowMin.UI.Toggle.Position = UDim2.new(0, isMobileMode and 8 or 10, 0, isMobileMode and 100 or 103)
        Runtime.AutoGet.RejoinBelowMin.UI.Toggle.Size = UDim2.new(1, isMobileMode and -16 or -20, 0, 27)
    end
    for _, control in ipairs({Runtime.UIRegs.AutoBestEggBtn, ui.FilterLabel, ui.FilterScroll,
        ui.TravelLabel, ui.TweenHomeBtn, Runtime.UIRegs.SelectedEggHint}) do
        control.Position = control.Position + UDim2.new(0, 0, 0, 32)
    end
    local targetUI = Runtime.AutoGet.TargetRanch and Runtime.AutoGet.TargetRanch.UI or nil
    if targetUI and targetUI.Toggle and targetUI.Selector then
        local x = isMobileMode and 8 or 10
        local w = isMobileMode and -16 or -20
        targetUI.Toggle.Size = UDim2.new(1, w, 0, isMobileMode and 28 or 29)
        targetUI.Toggle.Position = UDim2.new(0, x, 0, isMobileMode and 137 or 140)
        targetUI.Selector.Size = UDim2.new(1, w, 0, isMobileMode and 27 or 28)
        targetUI.Selector.Position = UDim2.new(0, x, 0, isMobileMode and 169 or 173)
    end
    for _, control in ipairs({ui.FilterLabel, ui.FilterScroll, ui.FilterCollapseBtn,
        ui.TravelLabel, ui.TweenHomeBtn, Runtime.UIRegs.SelectedEggHint}) do
        if control then control.Position = control.Position + UDim2.new(0,0,0,68) end
    end
    ui.FilterCollapseBtn.Size = UDim2.new(0,54,0,16)
    ui.FilterCollapseBtn.Position = UDim2.new(1, isMobileMode and -62 or -64, 0, ui.FilterLabel.Position.Y.Offset)
    ui.FilterLabel.Size = UDim2.new(1,-76,0,16)
    ui.FilterCollapseBtn.Text = ui.FilterCollapsed and "Show" or "Hide"
    ui.FilterScroll.Visible = not ui.FilterCollapsed
    local reclaim = ui.FilterCollapsed and (isMobileMode and 200 or 215) or 0
    if reclaim > 0 then
        for _, control in ipairs({ui.TravelLabel, ui.TweenHomeBtn, Runtime.UIRegs.SelectedEggHint}) do
            control.Position = control.Position - UDim2.new(0,0,0,reclaim)
        end
    end
    ui.DelayControl.Row.Position = UDim2.new(0,8,0,(isMobileMode and 533 or 555)-reclaim)
    ui.PickupMethodBtn.Position = UDim2.new(0,8,0,(isMobileMode and 565 or 587)-reclaim)
    Runtime.UIRegs.SelectedEggPanel.CanvasSize = UDim2.new(0,0,0,(isMobileMode and 603 or 625)-reclaim)
    Runtime.UIRegs.AvailableEggsToggleBtn.Text = Runtime.UIRegs.availableEggsHidden and "Show" or "Hide"

    -- v3.71 Big Froot mode layout. Legacy Get Egg / Auto Best buttons remain
    -- instantiated for compatibility but are hidden; one compact selector controls
    -- Get Egg, Best Egg, and Target Ranch Deliver.
    local modeState = Runtime.AutoGet.ModeSelector
    local modeUI = modeState and modeState.UI or nil
    if modeUI and modeUI.ModeButton and modeUI.RunButton then
        Runtime.UIRegs.SelectedGetEggBtn.Visible = false
        Runtime.UIRegs.AutoBestEggBtn.Visible = false

        local x = isMobileMode and 8 or 10
        local w = isMobileMode and -16 or -20
        local selectedMode = modeState.Selected or "GetEgg"
        local targetMode = selectedMode == "TargetRanch"

        modeUI.ModeButton.Size = UDim2.new(1,w,0,29)
        modeUI.ModeButton.Position = UDim2.new(0,x,0,36)
        modeUI.RunButton.Size = UDim2.new(1,w,0,29)
        modeUI.RunButton.Position = UDim2.new(0,x,0,69)

        if modeUI.Menu then
            modeUI.Menu.Size = UDim2.new(1,w,0,94)
            modeUI.Menu.Position = UDim2.new(0,x,0,66)
        end

        ui.WeightControl.Row.Position = UDim2.new(0,x,0,103)
        ui.WeightControl.Row.Size = UDim2.new(1,w,0,26)

        local rejoinBtn = Runtime.AutoGet.RejoinBelowMin.UI.Toggle
        local showRejoin = selectedMode == "GetEgg"
        if rejoinBtn then
            rejoinBtn.Visible = showRejoin
            rejoinBtn.Position = UDim2.new(0,x,0,133)
            rejoinBtn.Size = UDim2.new(1,w,0,28)
        end

        local y = showRejoin and 167 or 135
        if modeUI.RanchSelector then
            modeUI.RanchSelector.Visible = targetMode
            modeUI.RanchSelector.Size = UDim2.new(1,w,0,28)
            modeUI.RanchSelector.Position = UDim2.new(0,x,0,y)
            if targetMode then y = y + 34 end
        end

        ui.FilterLabel.Position = UDim2.new(0,x,0,y)
        ui.FilterLabel.Size = UDim2.new(1,-76,0,16)
        ui.FilterCollapseBtn.Size = UDim2.new(0,54,0,16)
        ui.FilterCollapseBtn.Position = UDim2.new(1,isMobileMode and -62 or -64,0,y)

        local filterHeight = isMobileMode and 200 or 215
        ui.FilterScroll.Position = UDim2.new(0,x,0,y+18)
        ui.FilterScroll.Size = UDim2.new(1,w,0,filterHeight)
        ui.FilterScroll.Visible = not ui.FilterCollapsed

        local afterFilter = y + 18 + (ui.FilterCollapsed and 0 or filterHeight) + 8

        -- Return selector is a Get Egg-only detail; Best Egg and Target Ranch own
        -- their transportation independently.
        local showReturn = selectedMode == "GetEgg"
        ui.TravelLabel.Visible = showReturn
        ui.TweenHomeBtn.Visible = showReturn
        if showReturn then
            ui.TravelLabel.Position = UDim2.new(0,x,0,afterFilter)
            ui.TravelLabel.Size = UDim2.new(1,w,0,16)
            ui.TweenHomeBtn.Position = UDim2.new(0,x,0,afterFilter+18)
            ui.TweenHomeBtn.Size = UDim2.new(1,w,0,28)
            afterFilter = afterFilter + 52
        end

        Runtime.UIRegs.SelectedEggHint.Position = UDim2.new(0,x,0,afterFilter)
        Runtime.UIRegs.SelectedEggHint.Size = UDim2.new(1,w,0,42)
        if selectedMode == "TargetRanch" then
            Runtime.UIRegs.SelectedEggHint.Text =
                "Target Ranch Deliver is independent. TRUE egg filters choose pickups; manual pathfinding carries and drops them at the selected player's Ranch."
        elseif selectedMode == "BestEgg" then
            Runtime.UIRegs.SelectedEggHint.Text =
                "Best Egg runs the original Auto Best behavior with its own travel. Egg filters are kept but do not change Best Egg selection."
        else
            Runtime.UIRegs.SelectedEggHint.Text =
                "Only green TRUE filters are Get Egg targets. Available Eggs are display + manual TP only."
        end

        ui.DelayControl.Row.Position = UDim2.new(0,x,0,afterFilter+46)
        ui.DelayControl.Row.Size = UDim2.new(1,w,0,26)
        ui.PickupMethodBtn.Position = UDim2.new(0,x,0,afterFilter+76)
        ui.PickupMethodBtn.Size = UDim2.new(1,w,0,27)

        Runtime.UIRegs.SelectedEggPanel.CanvasSize =
            UDim2.new(0,0,0,afterFilter+112)
    end
end

if Runtime.AutoGet.UI.FilterCollapseBtn then
    Runtime.AutoGet.UI.FilterCollapseBtn.Activated:Connect(function()
        Runtime.AutoGet.UI.FilterCollapsed = not Runtime.AutoGet.UI.FilterCollapsed
        layoutEggsPage()
    end)
end

-- Travel mode buttons and persistent TRUE/FALSE filter list.
Runtime.AutoGet.RefreshTravelButtons = function()
    Runtime.AutoGet.TravelMode = "TweenHome"
    local button = Runtime.AutoGet.UI.TweenHomeBtn
    button.Text = "Return: Tween Home"
    button.BackgroundColor3 = Color3.fromRGB(0, 120, 170)
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.AutoButtonColor = false
end

Runtime.AutoGet.RefreshFilterUI = function()
    local ui = Runtime.AutoGet.UI
    if not ui.FilterScroll or not ui.FilterScroll.Parent then
        return
    end

    for _, child in ipairs(ui.FilterScroll:GetChildren()) do
        if child ~= ui.FilterLayout then
            child:Destroy()
        end
    end

    -- Show the complete game Egg Index, not only currently spawned eggs.
    -- This lets filters stay armed while AFK and automatically act when a
    -- matching egg appears later in Workspace.RenderedEggs.
    local names = Runtime.AutoGet.GetKnownEggNames()

    for _, name in ipairs(names) do
        local row = Instance.new("Frame")
        row.Size = UDim2.new(1, -4, 0, 31)
        row.BackgroundColor3 = autoFarmEggs[Runtime.EggIdentity.Key(name)]
            and Color3.fromRGB(0, 135, 70)
            or Color3.fromRGB(30, 37, 47)
        row.BackgroundTransparency = 0.08
        row.BorderSizePixel = 0
        row.Parent = ui.FilterScroll

        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 5)
        corner.Parent = row

        local icon = Instance.new("ImageLabel")
        icon.Size = UDim2.new(0, 25, 0, 25)
        icon.Position = UDim2.new(0, 4, 0.5, -12)
        icon.BackgroundTransparency = 1
        icon.Image = getEggImage(name)
        icon.ScaleType = Enum.ScaleType.Fit
        icon.Parent = row

        local label = Instance.new("TextLabel")
        label.Size = UDim2.new(1, -66, 1, 0)
        label.Position = UDim2.new(0, 34, 0, 0)
        label.BackgroundTransparency = 1
        label.Text = name
        label.TextColor3 = Color3.fromRGB(235, 240, 248)
        label.TextSize = 9
        label.Font = Enum.Font.SourceSansBold
        label.TextXAlignment = Enum.TextXAlignment.Left
        label.TextTruncate = Enum.TextTruncate.AtEnd
        label.Parent = row

        local stateLabel = Instance.new("TextLabel")
        stateLabel.Size = UDim2.new(0, 28, 1, 0)
        stateLabel.Position = UDim2.new(1, -32, 0, 0)
        stateLabel.BackgroundTransparency = 1
        stateLabel.Text = autoFarmEggs[Runtime.EggIdentity.Key(name)] and "ON" or "OFF"
        stateLabel.TextColor3 = autoFarmEggs[Runtime.EggIdentity.Key(name)]
            and Color3.fromRGB(180, 255, 205)
            or Color3.fromRGB(150, 160, 175)
        stateLabel.TextSize = 8
        stateLabel.Font = Enum.Font.SourceSansBold
        stateLabel.Parent = row

        local hit = Instance.new("TextButton")
        hit.Size = UDim2.new(1, 0, 1, 0)
        hit.BackgroundTransparency = 1
        hit.Text = ""
        hit.Parent = row

        hit.Activated:Connect(function()
            local enable = autoFarmEggs[Runtime.EggIdentity.Key(name)] ~= true
            if enable then
                autoFarmEggs[Runtime.EggIdentity.Key(name)] = true
                for processedEgg in pairs(autoFarmProcessed) do
                    if processedEgg and Runtime.EggIdentity.Resolve(processedEgg) == Runtime.EggIdentity.Key(name) then
                        autoFarmProcessed[processedEgg] = nil
                    end
                end
            else
                autoFarmEggs[Runtime.EggIdentity.Key(name)] = nil
            end

            Runtime.AutoGet.RefreshFilterUI()
            updateSelectedEggPanel()

            if enable then
                StatusLabel.Text = "● Egg Filter TRUE: " .. name
                StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
            else
                StatusLabel.Text = "● Egg Filter FALSE: " .. name
                StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
            end

            if autoFarmActive then
                local anyFilter = false
                for _, enabled in pairs(autoFarmEggs) do
                    if enabled == true then
                        anyFilter = true
                        break
                    end
                end
                if not anyFilter then
                    stopAutoFarm()
                    if StopAutoFarmBtn then
                        StopAutoFarmBtn.Visible = false
                    end
                end
            end
        end)
    end
end

Runtime.AutoGet.RefreshTravelButtons()
Runtime.AutoGet.RefreshFilterUI()

Runtime.UIRegs.AvailableEggsToggleBtn.Activated:Connect(function()
    Runtime.UIRegs.availableEggsHidden = not Runtime.UIRegs.availableEggsHidden
    layoutEggsPage()

    if not Runtime.UIRegs.availableEggsHidden and populateList then
        populateList()
    end
end)

Runtime.UIRegs.SelectedGetEggBtn.Activated:Connect(function()
    if autoFarmActive then
        stopAutoFarm()
        autoFarmActive = false
        if StopAutoFarmBtn then
            StopAutoFarmBtn.Visible = false
        end
        StatusLabel.Text = "● Get Egg stopped — filters kept"
        StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
    else
        local anyFilter = false
        for _, enabled in pairs(autoFarmEggs) do
            if enabled == true then
                anyFilter = true
                break
            end
        end

        if not anyFilter then
            StatusLabel.Text = "● Select at least one Egg Filter first"
            StatusLabel.TextColor3 = Color3.fromRGB(255, 170, 90)
            return
        end

        -- A fresh ON cycle may retry currently rendered eggs that match TRUE filters.
        for processedEgg in pairs(autoFarmProcessed) do
            if processedEgg and autoFarmEggs[processedEgg.Name] then
                autoFarmProcessed[processedEgg] = nil
            end
        end

        startAutoFarm()
        StatusLabel.Text = "● Get Egg started — filter-only multi-select"
        StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
    end

    updateSelectedEggPanel()
    if Runtime.AutoGet.RefreshFilterUI then
        Runtime.AutoGet.RefreshFilterUI()
    end
end)

Runtime.UIRegs.EggsTabBtn.Activated:Connect(function()
    updateSelectedEggPanel()
    if Runtime.AutoGet.RefreshFilterUI then
        Runtime.AutoGet.RefreshFilterUI()
    end
    if not Runtime.UIRegs.availableEggsHidden and populateList then
        populateList()
    end
end)

Runtime.UIRegs.ToggleListBtn.Visible = false

Runtime.UIRegs.ListContainerFrame.Visible = true

-- Misc page: ESP + Auto Feed Pet.
Runtime.UIRegs.ToggleGlobalESPBtn.Position = UDim2.new(0, 0, 0, 0)
Runtime.UIRegs.ESPColorPanel.Position = UDim2.new(0, 0, 0, 40)
Runtime.UIRegs.ESPColorPanel.Size = UDim2.new(1, 0, 0, 56)

--==================================================
-- LATE UI / BOOTSTRAP REGISTER-SAFE SCOPE
-- Luau has a 200-local-register limit per function. The main runtime is already
-- close to that ceiling, so all late UI/bootstrap locals live in this nested
-- function instead of the root chunk. This prevents compile-time register
-- exhaustion without changing runtime behavior.
--==================================================
Runtime.LateBootstrap = function()
    if Runtime.IsSuperseded and Runtime.IsSuperseded() then
        return
    end

do
    local state = Runtime.AutoGet.TargetRanch
    state.UI = state.UI or {}

    Runtime.AutoGet.ModeSelector = Runtime.AutoGet.ModeSelector or {
        Selected = "GetEgg",
        MenuOpen = false,
        UI = {},
    }
    local modeState = Runtime.AutoGet.ModeSelector
    local modeUI = modeState.UI

    local modeButton = Instance.new("TextButton")
    modeButton.Name = "EggModeSelector"
    modeButton.BackgroundColor3 = Color3.fromRGB(27,35,46)
    modeButton.BackgroundTransparency = 0.05
    modeButton.TextColor3 = Color3.fromRGB(225,233,244)
    modeButton.TextSize = 10
    modeButton.Font = Enum.Font.SourceSansBold
    modeButton.TextXAlignment = Enum.TextXAlignment.Left
    modeButton.Parent = Runtime.UIRegs.SelectedEggPanel
    modeButton.ZIndex = 30
    styleButton(modeButton)
    modeUI.ModeButton = modeButton

    local runButton = Instance.new("TextButton")
    runButton.Name = "EggModeRun"
    runButton.BackgroundColor3 = Color3.fromRGB(35,45,58)
    runButton.BackgroundTransparency = 0.08
    runButton.TextColor3 = Color3.fromRGB(220,228,238)
    runButton.TextSize = 10
    runButton.Font = Enum.Font.SourceSansBold
    runButton.Parent = Runtime.UIRegs.SelectedEggPanel
    runButton.ZIndex = 20
    styleButton(runButton)
    modeUI.RunButton = runButton

    local menu = Instance.new("Frame")
    menu.Name = "EggModeMenu"
    menu.BackgroundColor3 = Color3.fromRGB(13,18,25)
    menu.BackgroundTransparency = 0.02
    menu.BorderSizePixel = 0
    menu.Visible = false
    menu.Parent = Runtime.UIRegs.SelectedEggPanel
    menu.ZIndex = 80
    modeUI.Menu = menu
    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0,6)
        c.Parent = menu
        local s = Instance.new("UIStroke")
        s.Color = Color3.fromRGB(65,82,105)
        s.Transparency = 0.18
        s.Thickness = 1
        s.Parent = menu
    end

    local modeNames = {
        GetEgg = "Get Egg",
        BestEgg = "Best Egg",
        TargetRanch = "Target Ranch Deliver",
    }
    local modeOrder = {"GetEgg","BestEgg","TargetRanch"}
    modeUI.OptionButtons = {}

    for index, key in ipairs(modeOrder) do
        local option = Instance.new("TextButton")
        option.Name = "Mode_" .. key
        option.Size = UDim2.new(1,-8,0,27)
        option.Position = UDim2.new(0,4,0,4 + (index-1)*30)
        option.BackgroundTransparency = 0.06
        option.BorderSizePixel = 0
        option.Text = modeNames[key]
        option.TextColor3 = Color3.fromRGB(230,237,247)
        option.TextSize = 10
        option.Font = Enum.Font.SourceSansBold
        option.TextXAlignment = Enum.TextXAlignment.Left
        option.ZIndex = 82
        option.Parent = menu
        styleButton(option)
        modeUI.OptionButtons[key] = option
    end

    local selector = Instance.new("TextButton")
    selector.Name = "TargetRanchPlayer"
    selector.BackgroundColor3 = Color3.fromRGB(27,35,46)
    selector.BackgroundTransparency = 0.05
    selector.TextColor3 = Color3.fromRGB(205,218,235)
    selector.TextSize = 10
    selector.Font = Enum.Font.SourceSansBold
    selector.Text = "Ranch Player: tap to select"
    selector.Parent = Runtime.UIRegs.SelectedEggPanel
    selector.Visible = false
    selector.ZIndex = 20
    styleButton(selector)
    state.UI.Selector = selector
    modeUI.RanchSelector = selector

    local function eligiblePlayers()
        local list = {}
        for _, player in ipairs(Players:GetPlayers()) do
            if player ~= LocalPlayer then table.insert(list, player) end
        end
        table.sort(list, function(a,b) return a.Name:lower() < b.Name:lower() end)
        return list
    end

    Runtime.AutoGet.StopAllEggModes = function(exceptMode)
        if exceptMode ~= "GetEgg" and autoFarmActive then
            stopAutoFarm()
        end
        if exceptMode ~= "BestEgg" and autoBestEggActive then
            stopAutoBestEgg()
        end
        if exceptMode ~= "TargetRanch"
            and Runtime.AutoGet.TargetRanch
            and Runtime.AutoGet.TargetRanch.Active then
            Runtime.AutoGet.StopTargetRanchDelivery()
        end
    end

    Runtime.AutoGet.RefreshEggModeUI = function()
        local selected = modeState.Selected or "GetEgg"
        local selectedPlayer = Runtime.AutoGet.GetSelectedTargetPlayer
            and Runtime.AutoGet.GetSelectedTargetPlayer() or nil
        local active = selected == "GetEgg" and autoFarmActive
            or selected == "BestEgg" and autoBestEggActive
            or selected == "TargetRanch" and state.Active

        modeButton.Text = "  Automation: " .. (modeNames[selected] or selected) .. "   ▾"
        menu.Visible = modeState.MenuOpen == true

        for key, option in pairs(modeUI.OptionButtons) do
            local chosen = key == selected
            option.BackgroundColor3 = chosen
                and Color3.fromRGB(0,120,72)
                or Color3.fromRGB(30,38,49)
            option.TextColor3 = chosen
                and Color3.fromRGB(210,255,225)
                or Color3.fromRGB(225,233,244)
        end

        runButton.Text = (active and "Stop " or "Start ") .. (modeNames[selected] or selected)
        runButton.BackgroundColor3 = active
            and Color3.fromRGB(0,125,76)
            or Color3.fromRGB(35,45,58)
        runButton.TextColor3 = active
            and Color3.fromRGB(255,255,255)
            or Color3.fromRGB(220,228,238)

        selector.Visible = selected == "TargetRanch"
        selector.Text = "Ranch Player: " .. (selectedPlayer and selectedPlayer.Name or "tap to select")
        if Runtime.AutoGet.RefreshRejoinBelowMinUI then
            Runtime.AutoGet.RefreshRejoinBelowMinUI()
        end

        -- Legacy controls stay hidden; the single mode runner owns their start/stop actions.
        Runtime.UIRegs.SelectedGetEggBtn.Visible = false
        Runtime.UIRegs.AutoBestEggBtn.Visible = false

        if layoutEggsPage then
            task.defer(layoutEggsPage)
        end
    end

    Runtime.AutoGet.SelectEggMode = function(mode)
        if not modeNames[mode] then return end
        if modeState.Selected ~= mode then
            Runtime.AutoGet.StopAllEggModes(nil)
        end
        modeState.Selected = mode
        modeState.MenuOpen = false
        Runtime.AutoGet.RefreshEggModeUI()
    end

    modeButton.Activated:Connect(function()
        modeState.MenuOpen = not modeState.MenuOpen
        Runtime.AutoGet.RefreshEggModeUI()
    end)

    for key, option in pairs(modeUI.OptionButtons) do
        local modeKey = key
        option.Activated:Connect(function()
            Runtime.AutoGet.SelectEggMode(modeKey)
        end)
    end

    selector.Activated:Connect(function()
        local list = eligiblePlayers()
        if #list == 0 then
            state.TargetUserId = nil
            state.LastStatus = "No other players available"
            Runtime.AutoGet.RefreshEggModeUI()
            return
        end
        local currentIndex = 0
        for index, player in ipairs(list) do
            if player.UserId == tonumber(state.TargetUserId) then
                currentIndex = index
                break
            end
        end
        local nextPlayer = list[(currentIndex % #list) + 1]
        state.TargetUserId = nextPlayer.UserId
        state.LastStatus = "Selected " .. nextPlayer.Name
        Runtime.AutoGet.RefreshEggModeUI()
    end)

    runButton.Activated:Connect(function()
        local selected = modeState.Selected or "GetEgg"

        if selected == "GetEgg" then
            if autoFarmActive then
                stopAutoFarm()
                StatusLabel.Text = "● Get Egg stopped — filters kept"
                StatusLabel.TextColor3 = Color3.fromRGB(180,180,180)
            else
                if not Runtime.AutoGet.HasFilter() then
                    StatusLabel.Text = "● Select at least one Egg Filter first"
                    StatusLabel.TextColor3 = Color3.fromRGB(255,170,90)
                else
                    Runtime.AutoGet.StopAllEggModes("GetEgg")
                    for processedEgg in pairs(autoFarmProcessed) do
                        autoFarmProcessed[processedEgg] = nil
                    end
                    startAutoFarm()
                    StatusLabel.Text = "● Get Egg started"
                    StatusLabel.TextColor3 = Color3.fromRGB(0,255,120)
                end
            end

        elseif selected == "BestEgg" then
            if autoBestEggActive then
                stopAutoBestEgg()
                StatusLabel.Text = "● Best Egg stopped"
                StatusLabel.TextColor3 = Color3.fromRGB(180,180,180)
            else
                Runtime.AutoGet.StopAllEggModes("BestEgg")
                startAutoBestEgg()
                StatusLabel.Text = "● Best Egg enabled"
                StatusLabel.TextColor3 = Color3.fromRGB(0,255,120)
            end

        elseif selected == "TargetRanch" then
            if state.Active then
                Runtime.AutoGet.StopTargetRanchDelivery()
                StatusLabel.Text = "● Target Ranch Deliver stopped"
                StatusLabel.TextColor3 = Color3.fromRGB(180,180,180)
            else
                if not Runtime.AutoGet.GetSelectedTargetPlayer() then
                    local list = eligiblePlayers()
                    if #list > 0 then
                        state.TargetUserId = list[1].UserId
                    end
                end
                Runtime.AutoGet.StopAllEggModes("TargetRanch")
                local ok, why = Runtime.AutoGet.StartTargetRanchDelivery()
                StatusLabel.Text = ok
                    and "● Target Ranch Deliver enabled"
                    or ("● " .. tostring(why))
                StatusLabel.TextColor3 = ok
                    and Color3.fromRGB(0,255,120)
                    or Color3.fromRGB(255,170,90)
            end
        end

        Runtime.AutoGet.RefreshEggModeUI()
        updateSelectedEggPanel()
    end)

    trackRuntimeConnection(Players.PlayerRemoving:Connect(function(player)
        if player.UserId == tonumber(state.TargetUserId) then
            state.TargetUserId = nil
            if state.Active then
                Runtime.AutoGet.StopTargetRanchDelivery()
            end
            task.defer(Runtime.AutoGet.RefreshEggModeUI)
        end
    end))
    trackRuntimeConnection(Players.PlayerAdded:Connect(function()
        task.defer(Runtime.AutoGet.RefreshEggModeUI)
    end))

    Runtime.AutoGet.RefreshEggModeUI()
end

Runtime.Weight.LayoutPlace = function()
    local ui = Runtime.EggAutomation.UI
    if not ui.WeightControl or not ui.PlaceFilterTitle then return end
    local y = ui.PlaceFilterTitle.Position.Y.Offset
    ui.PlaceFilterTitle.Size = UDim2.new(1, -144, 0, 18)
    ui.WeightControl.Row.Position = UDim2.new(1, -140, 0, y)
    ui.WeightControl.Row.Size = UDim2.new(0, 134, 0, 18)
end

do
    -- v3.39.1 defensive scope bridge. The normal path exports these helpers from
    -- Egg Automation before LateBootstrap is called. These fallbacks prevent a
    -- nil-call UI crash on executors that reuse/transform scoped chunks unusually.
    if type(Runtime.EggAutomation.NormalizeEggKey) ~= "function" then
        Runtime.EggAutomation.NormalizeEggKey = function(value)
            return tostring(value or ""):lower():gsub("[^%w]", "")
        end
    end
    if type(Runtime.EggAutomation.IsEggNameFilterEnabled) ~= "function" then
        Runtime.EggAutomation.IsEggNameFilterEnabled = function(filterTable, eggName)
            if type(filterTable) ~= "table" then return false end
            local key = Runtime.EggAutomation.NormalizeEggKey(eggName)
            return key ~= "" and filterTable[key] == true
        end
    end
    if type(Runtime.EggAutomation.SetEggNameFilterEnabled) ~= "function" then
        Runtime.EggAutomation.SetEggNameFilterEnabled = function(filterTable, eggName, enabled)
            if type(filterTable) ~= "table" then return end
            local key = Runtime.EggAutomation.NormalizeEggKey(eggName)
            if key ~= "" then filterTable[key] = enabled == true end
        end
    end
    if type(Runtime.EggAutomation.AnyEggNameFilterEnabled) ~= "function" then
        Runtime.EggAutomation.AnyEggNameFilterEnabled = function(filterTable)
            if type(filterTable) ~= "table" then return false end
            for _, enabled in pairs(filterTable) do
                if enabled == true then return true end
            end
            return false
        end
    end
    if type(Runtime.EggAutomation.GetKnownEggNames) ~= "function" then
        Runtime.EggAutomation.GetKnownEggNames = function()
            local names, seen = {}, {}
            local function add(name)
                name = tostring(name or "")
                local key = Runtime.EggAutomation.NormalizeEggKey(name)
                if name ~= "" and key ~= "" and not seen[key] then
                    seen[key] = true
                    table.insert(names, name)
                end
            end
            if type(Runtime.AutoGet.GetKnownEggNames) == "function" then
                for _, name in ipairs(Runtime.AutoGet.GetKnownEggNames()) do add(name) end
            end
            for _, name in ipairs(Runtime.EggAutomation.KnownEggFallbackNames or {}) do add(name) end
            table.sort(names, function(a, b) return a:lower() < b:lower() end)
            return names
        end
    end
    -- Egg Actions is independent from ESP and Pet Feeding.
    Runtime.DropEggQ.CreateMiscUI = function(parent)
        local drop = Runtime.DropEggQ
        if drop.UI.Toggle and drop.UI.Toggle.Parent then
            return drop.UI.Toggle
        end

        local title = Instance.new("TextLabel")
        title.Name = "DropEggQTitle"
        title.Size = UDim2.new(1, 0, 0, 18)
        title.Position = UDim2.new(0, 0, 0, 104)
        title.BackgroundTransparency = 1
        title.Text = "Egg Actions"
        title.TextColor3 = Color3.fromRGB(235, 240, 248)
        title.TextSize = 11
        title.Font = Enum.Font.SourceSansBold
        title.TextXAlignment = Enum.TextXAlignment.Left
        title.Parent = parent
        drop.UI.Title = title

        local button = Instance.new("TextButton")
        button.Name = "DropEggQToggle"
        button.Size = UDim2.new(1, 0, 0, 32)
        button.Position = UDim2.new(0, 0, 0, 126)
        button.BackgroundColor3 = Color3.fromRGB(35, 45, 58)
        button.BackgroundTransparency = 0.08
        button.TextColor3 = Color3.fromRGB(220, 228, 238)
        button.TextSize = 11
        button.Font = Enum.Font.SourceSansBold
        button.Text = "Drop Egg [Q]  •  OFF"
        button.Parent = parent
        styleButton(button)

        drop.UI.Toggle = button

        trackRuntimeConnection(button.Activated:Connect(function()
            drop.SetEnabled(not drop.Enabled)
        end))

        drop.RefreshUI()
        return button
    end

    Runtime.DropEggQ.CreateMiscUI(Runtime.UIRegs.MainPage)

    local feedTitle = Instance.new("TextLabel")
    feedTitle.Name = "AutoFeedTitle"
    feedTitle.Size = UDim2.new(1, 0, 0, 20)
    feedTitle.Position = UDim2.new(0, 0, 0, 174)
    feedTitle.BackgroundTransparency = 1
    feedTitle.Text = "Pet Feeding"
    feedTitle.TextColor3 = Color3.fromRGB(235, 240, 248)
    feedTitle.TextSize = 12
    feedTitle.Font = Enum.Font.SourceSansBold
    feedTitle.TextXAlignment = Enum.TextXAlignment.Left
    feedTitle.Parent = Runtime.UIRegs.MainPage
    Runtime.AutoFeed.UI.Title = feedTitle

    local feedToggle = Instance.new("TextButton")
    feedToggle.Name = "AutoFeedPet"
    feedToggle.Size = UDim2.new(1, 0, 0, 32)
    feedToggle.Position = UDim2.new(0, 0, 0, 198)
    feedToggle.BackgroundColor3 = Color3.fromRGB(35, 45, 58)
    feedToggle.BackgroundTransparency = 0.08
    feedToggle.TextColor3 = Color3.fromRGB(220, 228, 238)
    feedToggle.TextSize = 11
    feedToggle.Font = Enum.Font.SourceSansBold
    feedToggle.Text = "Auto Feed Pet: OFF"
    feedToggle.Parent = Runtime.UIRegs.MainPage
    styleButton(feedToggle)
    Runtime.AutoFeed.UI.Toggle = feedToggle

    -- Whole-number 0..99 threshold directly below Auto Feed.
    local ageLabel = Instance.new("TextLabel")
    ageLabel.Name = "AutoFeedAgeLabel"
    ageLabel.Size = UDim2.new(1, 0, 0, 16)
    ageLabel.Position = UDim2.new(0, 0, 0, 235)
    ageLabel.BackgroundTransparency = 1
    ageLabel.TextColor3 = Color3.fromRGB(185, 202, 220)
    ageLabel.TextSize = 9
    ageLabel.Font = Enum.Font.SourceSansBold
    ageLabel.TextXAlignment = Enum.TextXAlignment.Left
    ageLabel.Parent = Runtime.UIRegs.MainPage
    Runtime.AutoFeed.UI.AgeLabel = ageLabel

    local ageControl = Instance.new("Frame")
    ageControl.Name = "AutoFeedAgeControl"
    ageControl.Size = UDim2.new(1, 0, 0, 28)
    ageControl.Position = UDim2.new(0, 0, 0, 254)
    ageControl.BackgroundColor3 = Color3.fromRGB(18, 24, 33)
    ageControl.BackgroundTransparency = 0.10
    ageControl.BorderSizePixel = 0
    ageControl.Active = true
    ageControl.Parent = Runtime.UIRegs.MainPage
    Runtime.AutoFeed.UI.AgeControl = ageControl
    do
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 6)
        corner.Parent = ageControl
    end

    local ageBar = Instance.new("Frame")
    ageBar.Name = "Bar"
    ageBar.Size = UDim2.new(1, -58, 0, 8)
    ageBar.Position = UDim2.new(0, 8, 0.5, -4)
    ageBar.BackgroundColor3 = Color3.fromRGB(45, 52, 64)
    ageBar.BorderSizePixel = 0
    ageBar.Active = true
    ageBar.Parent = ageControl
    Runtime.AutoFeed.UI.AgeBar = ageBar
    do
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = ageBar
    end

    local ageFill = Instance.new("Frame")
    ageFill.Name = "Fill"
    ageFill.Size = UDim2.new(0, 0, 1, 0)
    ageFill.BackgroundColor3 = Color3.fromRGB(0, 145, 85)
    ageFill.BorderSizePixel = 0
    ageFill.Parent = ageBar
    Runtime.AutoFeed.UI.AgeFill = ageFill
    do
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = ageFill
    end

    local ageKnob = Instance.new("Frame")
    ageKnob.Name = "Knob"
    ageKnob.Size = UDim2.new(0, 10, 0, 10)
    ageKnob.AnchorPoint = Vector2.new(0, 0)
    ageKnob.BackgroundColor3 = Color3.fromRGB(235, 240, 248)
    ageKnob.BorderSizePixel = 0
    ageKnob.Parent = ageBar
    Runtime.AutoFeed.UI.AgeKnob = ageKnob
    do
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(1, 0)
        corner.Parent = ageKnob
    end

    local ageValue = Instance.new("TextBox")
    ageValue.Name = "AgeValue"
    ageValue.Size = UDim2.new(0, 42, 0, 20)
    ageValue.Position = UDim2.new(1, -48, 0.5, -10)
    ageValue.BackgroundColor3 = Color3.fromRGB(35, 45, 58)
    ageValue.BackgroundTransparency = 0.05
    ageValue.BorderSizePixel = 0
    ageValue.ClearTextOnFocus = false
    ageValue.TextColor3 = Color3.fromRGB(235, 240, 248)
    ageValue.TextSize = 10
    ageValue.Font = Enum.Font.SourceSansBold
    ageValue.Text = tostring(Runtime.AutoFeed.MinAge)
    ageValue.Parent = ageControl
    Runtime.AutoFeed.UI.AgeValue = ageValue
    do
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 5)
        corner.Parent = ageValue
    end

    local feedHint = Instance.new("TextLabel")
    feedHint.Name = "AutoFeedHint"
    feedHint.Size = UDim2.new(1, 0, 0, 36)
    feedHint.Position = UDim2.new(0, 0, 0, 288)
    feedHint.BackgroundTransparency = 1
    feedHint.Text = "Age must be STRICTLY above the selected whole number. Scroll/drag 0–99. Feeds best income pet -> next -> lowest; unknown Age is skipped."
    feedHint.TextWrapped = true
    feedHint.TextColor3 = Color3.fromRGB(150, 165, 185)
    feedHint.TextSize = 9
    feedHint.Font = Enum.Font.SourceSans
    feedHint.TextXAlignment = Enum.TextXAlignment.Left
    feedHint.TextYAlignment = Enum.TextYAlignment.Top
    feedHint.Parent = Runtime.UIRegs.MainPage
    Runtime.AutoFeed.UI.Hint = feedHint

    local feedStatus = Instance.new("TextLabel")
    feedStatus.Name = "AutoFeedStatus"
    feedStatus.Size = UDim2.new(1, 0, 0, 52)
    feedStatus.Position = UDim2.new(0, 0, 0, 328)
    feedStatus.BackgroundColor3 = Color3.fromRGB(18, 24, 33)
    feedStatus.BackgroundTransparency = 0.18
    feedStatus.TextColor3 = Color3.fromRGB(170, 215, 195)
    feedStatus.TextSize = 9
    feedStatus.Font = Enum.Font.SourceSans
    feedStatus.TextWrapped = true
    feedStatus.TextXAlignment = Enum.TextXAlignment.Left
    feedStatus.TextYAlignment = Enum.TextYAlignment.Center
    feedStatus.Text = "Auto Feed Pet: OFF"
    feedStatus.Parent = Runtime.UIRegs.MainPage
    do
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 6)
        corner.Parent = feedStatus
        local stroke = Instance.new("UIStroke")
        stroke.Color = Color3.fromRGB(60, 60, 60)
        stroke.Transparency = 0.65
        stroke.Thickness = 1
        stroke.Parent = feedStatus
    end
    Runtime.AutoFeed.UI.Status = feedStatus

    local ageDragging = false
    local ageHover = false

    local function setAgeFromScreenX(screenX)
        local width = ageBar.AbsoluteSize.X
        if width <= 0 then return end
        local ratio = math.clamp(
            (screenX - ageBar.AbsolutePosition.X) / width,
            0,
            1
        )
        Runtime.AutoFeed.SetMinAge(math.floor(ratio * 99 + 0.5))
    end

    ageControl.MouseEnter:Connect(function()
        ageHover = true
    end)
    ageControl.MouseLeave:Connect(function()
        ageHover = false
    end)

    ageBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            ageDragging = true
            setAgeFromScreenX(input.Position.X)
        end
    end)

    trackRuntimeConnection(UserInputService.InputChanged:Connect(function(input)
        if ageDragging
            and (input.UserInputType == Enum.UserInputType.MouseMovement
                or input.UserInputType == Enum.UserInputType.Touch) then
            setAgeFromScreenX(input.Position.X)
        elseif ageHover and input.UserInputType == Enum.UserInputType.MouseWheel then
            local delta = input.Position.Z > 0 and 1 or -1
            Runtime.AutoFeed.SetMinAge(Runtime.AutoFeed.MinAge + delta)
        end
    end))

    trackRuntimeConnection(UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            ageDragging = false
        end
    end))

    ageValue.FocusLost:Connect(function()
        -- Strict whole-number sanitizer: decimals are quantized; non-numeric text
        -- is rejected and the previous valid 0..99 integer is restored.
        local typed = tonumber(ageValue.Text)
        if typed ~= nil then
            Runtime.AutoFeed.SetMinAge(typed)
        else
            refreshAutoFeedAgeUI()
        end
        ageValue.Text = tostring(Runtime.AutoFeed.MinAge)
    end)

    feedToggle.Activated:Connect(function()
        if Runtime.AutoFeed.Enabled then
            Runtime.AutoFeed.Stop()
        else
            Runtime.AutoFeed.Start()
        end
    end)

    refreshAutoFeedButton()
    refreshAutoFeedAgeUI()
end

-- Legacy Main controls are intentionally hidden.
ModeAutoFarmBtn.Visible = false
ModeTeleportBtn.Visible = false
Runtime.UIRegs.TPHomeBtn.Visible = false
StopAutoFarmBtn.Visible = false

-- Independent ESP visibility filters. Unknown mutation is never treated as Normal.
Runtime.ESPFilter = {AllEggs=true, Eggs={},
    Cache=setmetatable({}, {__mode="k"}), UI={}, NextRefresh=0}
Runtime.ESPFilter.Key = function(value)
    return tostring(value or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
end
Runtime.ESPFilter.MutationKey = function(value)
    local key=Runtime.ESPFilter.Key(value):gsub("[^%w]", "")
    return ({golden="gold",thunder="shocked",volt="volted",raging="rage",normal="none",nomutation="none"})[key] or key
end
Runtime.ESPFilter.WeatherMutations = {shocked="Shocked", volted="Volted", rage="Rage", void="Void", eternal="Eternal"}
Runtime.ESPFilter.ReadMutations = function(egg)
    local values, sources = {}, {}
    local liveInfo = Runtime.LiveEggData and Runtime.LiveEggData.FindForRendered
        and Runtime.LiveEggData.FindForRendered(egg) or nil
    local function fullName(item)
        local ok, value = pcall(function() return item:GetFullName() end)
        return ok and value or tostring(item)
    end
    local function add(value, source)
        if value == nil then return end
        if type(value) ~= "string" then value = tostring(value) end
        value = value:gsub("<[^>]*>", "")
        if value:match("^%s*$") then
            values.none = "None"
            sources.none = source or "empty-value"
            return
        end
        for part in value:gmatch("[^,;+|]+") do
            local key = Runtime.ESPFilter.MutationKey(part)
            if key == "normal" or key == "none" or key == "no mutation" then key = "none"; part = "None" end
            if key ~= "" then
                values[key] = part:match("^%s*(.-)%s*$")
                sources[key] = source or "unknown-source"
            end
        end
    end
    if liveInfo and liveInfo.Object then
        if liveInfo.Mutation ~= nil and tostring(liveInfo.Mutation) ~= "" then
            add(liveInfo.Mutation, "ActiveEggs:" .. tostring(liveInfo.ID) .. ".Mutation")
        end
        if liveInfo.SpawnMutation ~= nil and tostring(liveInfo.SpawnMutation) ~= "" then
            add(liveInfo.SpawnMutation, "ActiveEggs:" .. tostring(liveInfo.ID) .. ".SpawnMutation")
        end
        if next(values) == nil then
            values.none = "None"
            sources.none = "ActiveEggs:" .. tostring(liveInfo.ID) .. " (no mutation attributes)"
        end
        -- ActiveEggs is authoritative for live world eggs. Do not descend through
        -- every rendered mesh/UI/tag once a matching replicated record exists.
        return values, sources
    end
    local function inspect(item)
        for name, value in pairs(item:GetAttributes()) do
            local key = name:lower():gsub("[^%a]", "")
            if key == "mutation" or key == "mutations" or key == "variant" or key == "weathermutation" or key == "eggmutation" then
                add(value, "attribute:" .. fullName(item) .. "." .. tostring(name))
            end
            if value == true and Runtime.ESPFilter.WeatherMutations[Runtime.ESPFilter.MutationKey(name)] then
                add(name, "bool-attribute:" .. fullName(item) .. "." .. tostring(name))
            end
        end
        local key = item.Name:lower():gsub("[^%a]", "")
        if key == "mutation" or key == "mutations" or key == "variant" or key == "weathermutation" or key == "eggmutation" then
            if item:IsA("StringValue") then add(item.Value, "string-value:" .. fullName(item)) end
            if item:IsA("TextLabel") or item:IsA("TextButton") then add(item.Text, "text:" .. fullName(item)) end
            if item:IsA("Folder") then
                for _, child in ipairs(item:GetChildren()) do
                    if child:IsA("BoolValue") and child.Value then add(child.Name, "bool-value:" .. fullName(child))
                    elseif child:IsA("StringValue") then add(child.Value, "string-value:" .. fullName(child)) end
                end
            end
        elseif item:IsA("TextLabel") then
            local parsed = item.Text:match("^[Mm]utations?%s*:%s*(.+)$")
            if parsed then add(parsed, "mutation-text:" .. fullName(item)) end
        end
    end
    local function isOwnedESPUI(item)
        local parent = item
        while parent and parent ~= egg do
            if parent.Name == "EggESP_Info" then return true end
            parent = parent.Parent
        end
        return false
    end

    inspect(egg)
    for _, item in ipairs(egg:GetDescendants()) do
        if not isOwnedESPUI(item) then inspect(item) end
    end
    -- Match named weather mutations in live egg names/labels, never infer from color.
    local function inspectText(text, source)
        text=tostring(text or ""):gsub("<[^>]*>", ""):lower()
        for key, label in pairs(Runtime.ESPFilter.WeatherMutations) do
            if text:match("%f[%a]"..key.."%f[%A]") then
                values[key]=label
                sources[key]=source or "visible-text"
            end
        end
    end
    inspectText(egg.Name, "egg-name:" .. fullName(egg))
    for _, item in ipairs(egg:GetDescendants()) do
        if not isOwnedESPUI(item) then
            inspectText(item.Name, "instance-name:" .. fullName(item))
            if item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
                inspectText(item.Text, "visible-text:" .. fullName(item))
            elseif item:IsA("ProximityPrompt") then
                inspectText(item.ObjectText, "prompt-object:" .. fullName(item))
                inspectText(item.ActionText, "prompt-action:" .. fullName(item))
            end
            local okTags, tags = pcall(function()
                return game:GetService("CollectionService"):GetTags(item)
            end)
            if okTags and type(tags) == "table" then
                for _, tag in ipairs(tags) do
                    inspectText(tag, "tag:" .. fullName(item))
                end
            end
        end
    end
    if next(values) == nil then
        values.unknown = "Unknown"
        sources.unknown = "not-found"
    end
    return values, sources
end
Runtime.ESPFilter.Metadata = function(egg)
    local f = Runtime.ESPFilter
    local cached = f.Cache[egg]
    if cached and os.clock() - cached.At < 0.70 then return cached end

    local liveInfo = Runtime.LiveEggData and Runtime.LiveEggData.FindForRendered
        and Runtime.LiveEggData.FindForRendered(egg) or nil

    if liveInfo and liveInfo.Object then
        local mutations, mutationSources = {}, {}
        local function addLive(value, source)
            value = tostring(value or ""):match("^%s*(.-)%s*$")
            if value == "" or value:lower() == "none" then return end
            local key = f.MutationKey(value)
            if key ~= "" then
                mutations[key] = value
                mutationSources[key] = source
            end
        end
        addLive(liveInfo.Mutation, "ActiveEggs:" .. tostring(liveInfo.ID) .. ".Mutation")
        addLive(liveInfo.SpawnMutation, "ActiveEggs:" .. tostring(liveInfo.ID) .. ".SpawnMutation")
        if next(mutations) == nil then
            mutations.none = "None"
            mutationSources.none = "ActiveEggs:" .. tostring(liveInfo.ID) .. " (no mutation attributes)"
        end
        cached = {
            At=os.clock(), Weight=liveInfo.KG,
            WeightSource="ActiveEggs:" .. tostring(liveInfo.ID) .. ".Weight(raw=" .. tostring(liveInfo.RawWeight) .. ")",
            Mutations=mutations, MutationSources=mutationSources, LiveInfo=liveInfo,
        }
        f.Cache[egg] = cached
        return cached
    end

    -- Compatibility fallback only if ActiveEggs is unavailable/unmatched.
    local weight, weightSource = Runtime.Weight.Read(egg)
    local mutations, mutationSources = f.ReadMutations(egg)
    cached = {
        At=os.clock(), Weight=weight, WeightSource=weightSource,
        Mutations=mutations, MutationSources=mutationSources, LiveInfo=liveInfo,
    }
    f.Cache[egg] = cached
    return cached
end

Runtime.ESPFilter.MatchSelectedEgg = function(egg)
    local f = Runtime.ESPFilter
    local resolvedKey, resolvedName = Runtime.EggIdentity.Resolve(egg)
    local liveInfo = Runtime.LiveEggData and Runtime.LiveEggData.FindForRendered
        and Runtime.LiveEggData.FindForRendered(egg) or nil
    if liveInfo and type(liveInfo.Egg) == "string" and liveInfo.Egg ~= "" then
        resolvedName = liveInfo.Egg
        resolvedKey = Runtime.EggIdentity.Key(liveInfo.Egg)
    end
    local displayKey = Runtime.EggIdentity.Key(resolvedName)
    local rawKey = Runtime.EggIdentity.Key(egg and egg.Name or "")
    if f.AllEggs then
        return true, "all-eggs", resolvedKey or rawKey, resolvedName or (egg and egg.Name or ""), rawKey
    end

    if resolvedKey and f.Eggs[resolvedKey] == true then
        return true, resolvedKey, resolvedKey, resolvedName or "", rawKey
    end
    if displayKey ~= "" and f.Eggs[displayKey] == true then
        return true, displayKey, resolvedKey or "", resolvedName or "", rawKey
    end
    if rawKey ~= "" and f.Eggs[rawKey] == true then
        return true, rawKey, resolvedKey or "", resolvedName or "", rawKey
    end
    return false, "", resolvedKey or "", resolvedName or "", rawKey
end
Runtime.ESPFilter.Allows = function(egg)
    -- v3.62: ESP filtering is egg-type only. Weight remains display metadata and
    -- is intentionally NOT an ESP visibility gate. Auto Get / Auto Place retain
    -- their own independent Min kg thresholds elsewhere.
    return Runtime.ESPFilter.MatchSelectedEgg(egg) == true
end


--==================================================
-- SELECTED ESP SPAWN NOTIFICATIONS (v3.58 SAFE/ISOLATED)
--==================================================
-- Completely independent observer subsystem:
-- * reads a SNAPSHOT of the ESP egg-type selection when ChildAdded fires
-- * reads ActiveEggs metadata without calling ESPFilter.Metadata/Allows
-- * owns separate ChildAdded/ChildRemoved/UI connections
-- * never changes ESP, movement, Auto Get, AutoFarm, Auto Place/Hatch, or Busy flags
-- * one right-side card per exact rendered egg; card lives until that egg disappears
Runtime.SpawnNotifications = {
    Alive = false,
    Generation = 0,
    Connections = {},
    Cards = setmetatable({}, {__mode="k"}),
    Pending = setmetatable({}, {__mode="k"}),
    Count = 0,
    NextOrder = 0,
    Collapsed = false,
    UI = {},
    LastError = nil,
}

Runtime.SpawnNotifications.Safe = function(label, callback, ...)
    local n = Runtime.SpawnNotifications
    local args = table.pack(...)
    local ok, result = pcall(function()
        return callback(table.unpack(args, 1, args.n))
    end)
    if not ok then
        n.LastError = tostring(label or "notification") .. ": " .. tostring(result)
        warn("[SpawnNotifications] " .. n.LastError)
        return false, result
    end
    return true, result
end

Runtime.SpawnNotifications.Own = function(connection)
    local n = Runtime.SpawnNotifications
    if connection then table.insert(n.Connections, connection) end
    return connection
end

Runtime.SpawnNotifications.FormatKg = function(value)
    if type(value) ~= "number" then return "?" end
    return string.format("%.2f", value):gsub("0+$", ""):gsub("%.$", "")
end

Runtime.SpawnNotifications.NowText = function()
    local ok, value = pcall(function() return os.date("%I:%M:%S %p") end)
    return ok and tostring(value) or "Now"
end

Runtime.SpawnNotifications.CaptureFilter = function()
    local f = Runtime.ESPFilter or {}
    local selected = {}
    for key, enabled in pairs(f.Eggs or {}) do
        if enabled == true then selected[key] = true end
    end
    return {
        AllEggs = f.AllEggs == true,
        Eggs = selected,
    }
end

Runtime.SpawnNotifications.ReadLive = function(egg)
    if not egg or not egg.Parent then return nil end
    local serverData = ReplicatedStorage:FindFirstChild("ServerData")
    local folder = serverData and serverData:FindFirstChild("ActiveEggs")
    if not folder then return nil end

    local targetPosition = getTargetPosition(egg)
    local resolvedKey, resolvedName = Runtime.EggIdentity.Resolve(egg)
    local rawKey = Runtime.EggIdentity.Key(egg.Name)
    local best = nil
    local bestDelta = math.huge

    for _, object in ipairs(folder:GetChildren()) do
        local eggName = object:GetAttribute("Egg")
        local position = object:GetAttribute("Position")
        if type(eggName) == "string" and eggName ~= "" and typeof(position) == "Vector3" then
            local recordKey = Runtime.EggIdentity.Key(eggName)
            local identityCompatible = (resolvedKey and resolvedKey ~= "" and recordKey == resolvedKey)
                or (rawKey ~= "" and recordKey == rawKey)

            -- If RenderedEggs has a generic/internal name, position can still identify
            -- its authoritative ActiveEggs record. A strict 14-stud ceiling matches
            -- the existing metadata resolver but this table/cache is NOT shared with it.
            local delta = targetPosition and (position - targetPosition).Magnitude or math.huge
            if (identityCompatible or resolvedKey == nil or resolvedKey == "" or rawKey == "")
                and delta < bestDelta then
                bestDelta = delta
                best = object
            elseif delta < bestDelta and delta <= 2 then
                bestDelta = delta
                best = object
            end
        end
    end

    if not best or bestDelta > 14 then return nil end

    local rawWeight = best:GetAttribute("Weight")
    local kg = nil
    if Runtime.LiveEggData and Runtime.LiveEggData.ShownKG then
        kg = Runtime.LiveEggData.ShownKG(rawWeight)
    else
        kg = tonumber(rawWeight)
    end

    return {
        Object = best,
        ID = best.Name,
        Egg = best:GetAttribute("Egg") or resolvedName or egg.Name,
        Key = Runtime.EggIdentity.Key(best:GetAttribute("Egg") or resolvedName or egg.Name),
        KG = kg,
        RawWeight = rawWeight,
        Delta = bestDelta,
    }
end

Runtime.SpawnNotifications.MatchesSnapshot = function(egg, live, snapshot)
    if type(snapshot) ~= "table" then return false, "" end

    local _, resolvedName = Runtime.EggIdentity.Resolve(egg)
    local liveName = live and live.Egg
    local displayName = (type(liveName) == "string" and liveName ~= "" and liveName)
        or resolvedName or (egg and egg.Name) or "Egg"

    if not snapshot.AllEggs then
        local keys = {
            Runtime.EggIdentity.Key(displayName),
            Runtime.EggIdentity.Key(resolvedName or ""),
            Runtime.EggIdentity.Key(egg and egg.Name or ""),
        }
        local selected = false
        for _, key in ipairs(keys) do
            if key ~= "" and snapshot.Eggs[key] == true then
                selected = true
                break
            end
        end
        if not selected then return false, displayName end
    end

    -- Weight is informational only for ESP/spawn cards in v3.62.
    return true, displayName
end

Runtime.SpawnNotifications.RefreshUI = function()
    local n = Runtime.SpawnNotifications
    local ui = n.UI
    if ui.Badge and ui.Badge.Parent then
        ui.Badge.Visible = n.Count > 0
        ui.Badge.Text = n.Count > 99 and "99+" or tostring(n.Count)
    end
    if ui.HeaderCount and ui.HeaderCount.Parent then
        ui.HeaderCount.Text = tostring(n.Count) .. (n.Count == 1 and " active" or " active")
    end
    if ui.Panel and ui.Panel.Parent then
        ui.Panel.Visible = n.Count > 0 and not n.Collapsed
    end
end

Runtime.SpawnNotifications.CreateUI = function()
    local n = Runtime.SpawnNotifications
    if not ScreenGui or not ScreenGui.Parent then return end
    if n.UI.Bell and n.UI.Bell.Parent then return end

    local bell = Instance.new("TextButton")
    bell.Name = "SpawnNotificationBell"
    bell.Size = UDim2.fromOffset(28, 28)
    bell.Position = UDim2.new(1, -46, 0, 12)
    bell.BackgroundColor3 = Color3.fromRGB(28, 38, 52)
    bell.BackgroundTransparency = 0.05
    bell.BorderSizePixel = 0
    bell.Text = "🔔"
    bell.TextColor3 = Color3.fromRGB(245, 248, 252)
    bell.TextSize = 15
    bell.Font = Enum.Font.SourceSansBold
    bell.AutoButtonColor = true
    bell.ZIndex = 80
    bell.Parent = ScreenGui
    n.UI.Bell = bell

    local bellCorner = Instance.new("UICorner")
    bellCorner.CornerRadius = UDim.new(0, 6)
    bellCorner.Parent = bell

    local bellStroke = Instance.new("UIStroke")
    bellStroke.Color = Color3.fromRGB(66, 87, 112)
    bellStroke.Thickness = 1
    bellStroke.Transparency = 0.2
    bellStroke.Parent = bell

    local badge = Instance.new("TextLabel")
    badge.Name = "CountBadge"
    badge.AnchorPoint = Vector2.new(1, 0)
    badge.Position = UDim2.new(1, 5, 0, -6)
    badge.Size = UDim2.fromOffset(18, 18)
    badge.BackgroundColor3 = Color3.fromRGB(220, 65, 75)
    badge.BorderSizePixel = 0
    badge.TextColor3 = Color3.fromRGB(255, 255, 255)
    badge.TextSize = 9
    badge.Font = Enum.Font.SourceSansBold
    badge.Visible = false
    badge.ZIndex = 82
    badge.Parent = bell
    n.UI.Badge = badge

    local badgeCorner = Instance.new("UICorner")
    badgeCorner.CornerRadius = UDim.new(1, 0)
    badgeCorner.Parent = badge

    local panel = Instance.new("Frame")
    panel.Name = "SelectedEggSpawnNotifications"
    panel.AnchorPoint = Vector2.new(1, 0)
    panel.Position = UDim2.new(1, -12, 0, 62)
    panel.Size = UDim2.fromOffset(UserInputService.TouchEnabled and 276 or 310, 350)
    panel.BackgroundColor3 = Color3.fromRGB(12, 17, 25)
    panel.BackgroundTransparency = 0.06
    panel.BorderSizePixel = 0
    panel.Visible = false
    panel.ZIndex = 1000
    panel.Parent = ScreenGui
    n.UI.Panel = panel

    local panelCorner = Instance.new("UICorner")
    panelCorner.CornerRadius = UDim.new(0, 10)
    panelCorner.Parent = panel

    local panelStroke = Instance.new("UIStroke")
    panelStroke.Color = Color3.fromRGB(60, 80, 105)
    panelStroke.Thickness = 1
    panelStroke.Transparency = 0.15
    panelStroke.Parent = panel

    local title = Instance.new("TextLabel")
    title.Name = "Header"
    title.Position = UDim2.fromOffset(12, 7)
    title.Size = UDim2.new(1, -92, 0, 22)
    title.BackgroundTransparency = 1
    title.Text = "🔔 Selected Egg Spawns"
    title.TextColor3 = Color3.fromRGB(245, 248, 252)
    title.TextSize = 13
    title.Font = Enum.Font.SourceSansBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.ZIndex = 1002
    title.Parent = panel

    local headerCount = Instance.new("TextLabel")
    headerCount.Name = "HeaderCount"
    headerCount.AnchorPoint = Vector2.new(1, 0)
    headerCount.Position = UDim2.new(1, -10, 0, 8)
    headerCount.Size = UDim2.fromOffset(72, 20)
    headerCount.BackgroundTransparency = 1
    headerCount.Text = "0 active"
    headerCount.TextColor3 = Color3.fromRGB(150, 165, 184)
    headerCount.TextSize = 10
    headerCount.Font = Enum.Font.SourceSans
    headerCount.TextXAlignment = Enum.TextXAlignment.Right
    headerCount.ZIndex = 1002
    headerCount.Parent = panel
    n.UI.HeaderCount = headerCount

    local separator = Instance.new("Frame")
    separator.Position = UDim2.new(0, 10, 0, 34)
    separator.Size = UDim2.new(1, -20, 0, 1)
    separator.BackgroundColor3 = Color3.fromRGB(54, 69, 88)
    separator.BackgroundTransparency = 0.25
    separator.BorderSizePixel = 0
    separator.ZIndex = 1001
    separator.Parent = panel

    local list = Instance.new("ScrollingFrame")
    list.Name = "NotificationList"
    list.Position = UDim2.new(0, 8, 0, 42)
    list.Size = UDim2.new(1, -16, 1, -50)
    list.BackgroundTransparency = 1
    list.BorderSizePixel = 0
    list.CanvasSize = UDim2.new()
    list.ScrollBarThickness = 3
    list.ScrollBarImageTransparency = 0.2
    list.ScrollingDirection = Enum.ScrollingDirection.Y
    list.ZIndex = 1001
    list.Parent = panel
    n.UI.List = list

    local layout = Instance.new("UIListLayout")
    layout.Padding = UDim.new(0, 8)
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
    layout.Parent = list
    n.UI.Layout = layout

    n.Own(layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
        if list and list.Parent then
            list.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y + 8)
        end
    end))

    n.Own(bell.Activated:Connect(function()
        if n.Count <= 0 then return end
        n.Collapsed = not n.Collapsed
        n.RefreshUI()
    end))

    n.RefreshUI()
end

Runtime.SpawnNotifications.AddCard = function(egg, displayName, kg, detectedAt)
    local n = Runtime.SpawnNotifications
    if not n.Alive or not egg or egg.Parent ~= RenderedEggsFolder then return end
    if n.Cards[egg] and n.Cards[egg].Parent then return end

    -- v3.69: notification cards follow the CURRENT ESP egg filter, not only the
    -- selection that existed when ChildAdded first fired. This prevents a card
    -- from appearing/staying after that specific egg toggle has been switched OFF.
    local cardKey = Runtime.EggIdentity.Key(displayName or egg.Name)
    local currentFilter = n.CaptureFilter()
    if not currentFilter.AllEggs
        and (cardKey == "" or currentFilter.Eggs[cardKey] ~= true) then
        return
    end

    if not n.UI.List or not n.UI.List.Parent then n.CreateUI() end
    if not n.UI.List or not n.UI.List.Parent then return end

    n.NextOrder = n.NextOrder + 1

    local card = Instance.new("Frame")
    card.Name = "EggSpawn_" .. tostring(displayName or egg.Name)
    card.Size = UDim2.new(1, -6, 0, 88)
    card.BackgroundColor3 = Color3.fromRGB(20, 28, 39)
    card.BackgroundTransparency = 0.02
    card.BorderSizePixel = 0
    card.LayoutOrder = n.NextOrder
    card.ZIndex = 1003
    card.Parent = n.UI.List
    -- Stored once so filter changes can remove stale cards without rescanning
    -- ActiveEggs/RenderedEggs or doing any Ranch work.
    pcall(function() card:SetAttribute("EggFilterKey", cardKey) end)

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = card

    local stroke = Instance.new("UIStroke")
    stroke.Color = Color3.fromRGB(68, 91, 118)
    stroke.Thickness = 1
    stroke.Transparency = 0.18
    stroke.Parent = card

    local accent = Instance.new("Frame")
    accent.Size = UDim2.new(0, 3, 1, -12)
    accent.Position = UDim2.fromOffset(5, 6)
    accent.BackgroundColor3 = Color3.fromRGB(80, 200, 135)
    accent.BorderSizePixel = 0
    accent.ZIndex = 1004
    accent.Parent = card

    local accentCorner = Instance.new("UICorner")
    accentCorner.CornerRadius = UDim.new(1, 0)
    accentCorner.Parent = accent

    local status = Instance.new("TextLabel")
    status.Position = UDim2.fromOffset(16, 7)
    status.Size = UDim2.new(1, -24, 0, 16)
    status.BackgroundTransparency = 1
    status.Text = "SELECTED ESP SPAWN DETECTED"
    status.TextColor3 = Color3.fromRGB(92, 220, 150)
    status.TextSize = 9
    status.Font = Enum.Font.SourceSansBold
    status.TextXAlignment = Enum.TextXAlignment.Left
    status.ZIndex = 1004
    status.Parent = card

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Position = UDim2.fromOffset(16, 23)
    nameLabel.Size = UDim2.new(1, -24, 0, 22)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = tostring(displayName or egg.Name)
    nameLabel.TextColor3 = Color3.fromRGB(248, 250, 253)
    nameLabel.TextSize = 14
    nameLabel.Font = Enum.Font.SourceSansBold
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
    nameLabel.ZIndex = 1004
    nameLabel.Parent = card

    local weightLabel = Instance.new("TextLabel")
    weightLabel.Position = UDim2.fromOffset(16, 48)
    weightLabel.Size = UDim2.new(0.55, -16, 0, 18)
    weightLabel.BackgroundTransparency = 1
    weightLabel.Text = "Weight: " .. n.FormatKg(kg) .. " kg"
    weightLabel.TextColor3 = Color3.fromRGB(206, 218, 232)
    weightLabel.TextSize = 11
    weightLabel.Font = Enum.Font.SourceSans
    weightLabel.TextXAlignment = Enum.TextXAlignment.Left
    weightLabel.ZIndex = 1004
    weightLabel.Parent = card

    local timeLabel = Instance.new("TextLabel")
    timeLabel.AnchorPoint = Vector2.new(1, 0)
    timeLabel.Position = UDim2.new(1, -9, 0, 48)
    timeLabel.Size = UDim2.new(0.45, -4, 0, 18)
    timeLabel.BackgroundTransparency = 1
    timeLabel.Text = "Detected: " .. tostring(detectedAt or n.NowText())
    timeLabel.TextColor3 = Color3.fromRGB(160, 178, 199)
    timeLabel.TextSize = 10
    timeLabel.Font = Enum.Font.SourceSans
    timeLabel.TextXAlignment = Enum.TextXAlignment.Right
    timeLabel.ZIndex = 1004
    timeLabel.Parent = card

    local lifeLabel = Instance.new("TextLabel")
    lifeLabel.Position = UDim2.fromOffset(16, 68)
    lifeLabel.Size = UDim2.new(1, -24, 0, 13)
    lifeLabel.BackgroundTransparency = 1
    lifeLabel.Text = "Stays until egg disappears or its ESP filter is turned OFF"
    lifeLabel.TextColor3 = Color3.fromRGB(122, 139, 159)
    lifeLabel.TextSize = 9
    lifeLabel.Font = Enum.Font.SourceSansItalic
    lifeLabel.TextXAlignment = Enum.TextXAlignment.Left
    lifeLabel.ZIndex = 1004
    lifeLabel.Parent = card

    n.Cards[egg] = card
    n.Count = n.Count + 1
    n.Collapsed = false
    n.RefreshUI()
end

Runtime.SpawnNotifications.Remove = function(egg)
    local n = Runtime.SpawnNotifications
    n.Pending[egg] = nil
    local card = n.Cards[egg]
    if card then
        n.Cards[egg] = nil
        if card.Parent then pcall(function() card:Destroy() end) end
        n.Count = math.max(0, n.Count - 1)
        if n.Count == 0 then n.Collapsed = false end
        n.RefreshUI()
    end
end

-- v3.69: synchronize existing cards with the live ESP egg selection.
-- This is USER-EVENT driven only (filter clicks/restores), so it adds no idle
-- polling and does not touch the Ranch/Auto Place/Auto Hatch performance path.
Runtime.SpawnNotifications.ReconcileCurrentFilter = function()
    local n = Runtime.SpawnNotifications
    if not n or not n.Alive then return end

    local currentFilter = n.CaptureFilter()
    local removeEggs = {}

    for egg, card in pairs(n.Cards or {}) do
        local remove = false
        if not egg or not egg.Parent or egg.Parent ~= RenderedEggsFolder
            or not card or not card.Parent then
            remove = true
        elseif not currentFilter.AllEggs then
            local cardKey = ""
            pcall(function() cardKey = tostring(card:GetAttribute("EggFilterKey") or "") end)
            if cardKey == "" then
                local resolvedKey = Runtime.EggIdentity.Resolve(egg)
                cardKey = resolvedKey or Runtime.EggIdentity.Key(egg.Name)
            end
            remove = cardKey == "" or currentFilter.Eggs[cardKey] ~= true
        end

        if remove then
            table.insert(removeEggs, egg)
        end
    end

    for _, egg in ipairs(removeEggs) do
        n.Remove(egg)
    end

    -- Pending spawn tasks are safe: AddCard revalidates the CURRENT filter just
    -- before creating a card, so an egg toggled OFF cannot reappear afterward.
    n.RefreshUI()
end

Runtime.SpawnNotifications.HandleSpawn = function(egg)
    local n = Runtime.SpawnNotifications
    if not n.Alive or not egg or (not egg:IsA("Model") and not egg:IsA("BasePart")) then return end

    local snapshot = n.CaptureFilter()
    local detectedAt = n.NowText()
    local generation = n.Generation
    local token = {}
    n.Pending[egg] = token

    task.spawn(function()
        local started = os.clock()
        local live = nil
        local allowed = false
        local displayName = egg.Name

        while n.Alive
            and Runtime.Alive
            and generation == n.Generation
            and n.Pending[egg] == token
            and egg.Parent == RenderedEggsFolder
            and os.clock() - started < 2.25 do

            local okRead, readValue = n.Safe("ReadLive", n.ReadLive, egg)
            live = okRead and readValue or nil
            local okMatch, matchAllowed, matchName = pcall(n.MatchesSnapshot, egg, live, snapshot)
            if okMatch then
                allowed = matchAllowed
                displayName = matchName
            else
                n.LastError = "MatchesSnapshot: " .. tostring(matchAllowed)
                allowed = false
            end

            -- Wait briefly for authoritative weight so the notification card
            -- can display kg when the game exposes it. Weight no longer filters ESP.
            if live and type(live.KG) == "number" then
                break
            end

            task.wait(0.10)
        end

        if not n.Alive
            or not Runtime.Alive
            or generation ~= n.Generation
            or n.Pending[egg] ~= token
            or egg.Parent ~= RenderedEggsFolder then
            return
        end

        n.Pending[egg] = nil
        if not live then
            local okRead, readValue = n.Safe("ReadLive-final", n.ReadLive, egg)
            live = okRead and readValue or nil
        end
        local okMatch, matchAllowed, matchName = pcall(n.MatchesSnapshot, egg, live, snapshot)
        if okMatch then
            allowed = matchAllowed
            displayName = matchName
        else
            n.LastError = "MatchesSnapshot-final: " .. tostring(matchAllowed)
            allowed = false
        end

        if allowed then
            n.Safe("AddCard", n.AddCard, egg, displayName, live and live.KG or nil, detectedAt)
        end
    end)
end

Runtime.SpawnNotifications.Start = function()
    local n = Runtime.SpawnNotifications
    if n.Alive then return true end

    n.Alive = true
    n.Generation = n.Generation + 1

    -- UI creation is isolated. If it ever fails, the rest of the script keeps running.
    local uiOk = n.Safe("CreateUI", n.CreateUI)
    if not uiOk then
        n.Alive = false
        return false
    end

    if not RenderedEggsFolder then
        n.Alive = false
        n.LastError = "RenderedEggs folder unavailable"
        return false
    end

    -- Deliberately separate listeners: no callbacks are injected into ESP/AutoFarm.
    n.Own(RenderedEggsFolder.ChildAdded:Connect(function(egg)
        if n.Alive and Runtime.Alive then
            n.Safe("ChildAdded", n.HandleSpawn, egg)
        end
    end))

    n.Own(RenderedEggsFolder.ChildRemoved:Connect(function(egg)
        n.Safe("ChildRemoved", n.Remove, egg)
    end))

    return true
end

Runtime.SpawnNotifications.Stop = function()
    local n = Runtime.SpawnNotifications
    if not n then return end
    n.Alive = false
    n.Generation = (n.Generation or 0) + 1

    for _, connection in ipairs(n.Connections or {}) do
        pcall(function() connection:Disconnect() end)
    end
    table.clear(n.Connections)
    table.clear(n.Pending)

    for egg, card in pairs(n.Cards or {}) do
        if card and card.Parent then pcall(function() card:Destroy() end) end
        n.Cards[egg] = nil
    end
    n.Count = 0

    if n.UI.Panel and n.UI.Panel.Parent then pcall(function() n.UI.Panel:Destroy() end) end
    if n.UI.Bell and n.UI.Bell.Parent then pcall(function() n.UI.Bell:Destroy() end) end
    n.UI = {}
end

-- Startup is deferred until the END of LateBootstrap so notification errors
-- cannot interrupt construction of the main UI or any automation system.
Runtime.ESPFilter.FormatMutationDebug = function(data)
    if not data or type(data.Mutations) ~= "table" then return "Unknown", "not-read" end
    local labels, sourceLabels = {}, {}
    for key, value in pairs(data.Mutations) do
        table.insert(labels, tostring(value))
        local source = data.MutationSources and data.MutationSources[key] or "unknown-source"
        table.insert(sourceLabels, tostring(key) .. "@" .. tostring(source))
    end
    table.sort(labels)
    table.sort(sourceLabels)
    return #labels > 0 and table.concat(labels, ",") or "Unknown",
        #sourceLabels > 0 and table.concat(sourceLabels, ";") or "not-found"
end
Runtime.ESPFilter.RawMetadataHints = function(egg, maxHints)
    local hints = {}
    local seen = {}
    maxHints = math.max(1, math.floor(tonumber(maxHints) or 8))
    local function push(text)
        text = tostring(text or "")
        if text ~= "" and not seen[text] and #hints < maxHints then
            seen[text] = true
            table.insert(hints, text)
        end
    end
    local function inspect(item)
        for name, value in pairs(item:GetAttributes()) do
            local lower = tostring(name):lower()
            if lower:find("weight",1,true) or lower == "kg" or lower:find("mutation",1,true) or lower:find("variant",1,true) then
                push("attr:" .. tostring(item.Name) .. "." .. tostring(name) .. "=" .. tostring(value))
            end
        end
        local lowerName = tostring(item.Name):lower()
        if item:IsA("ValueBase") and (lowerName:find("weight",1,true) or lowerName == "kg" or lowerName:find("mutation",1,true) or lowerName:find("variant",1,true)) then
            push("value:" .. tostring(item.Name) .. "=" .. tostring(item.Value))
        elseif item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
            local text = tostring(item.Text or "")
            local lowerText = text:lower()
            if lowerText:find("kg",1,true) or lowerText:find("mutation",1,true)
                or lowerText:find("shocked",1,true) or lowerText:find("volted",1,true)
                or lowerText:find("rage",1,true) or lowerText:find("void",1,true)
                or lowerText:find("eternal",1,true) then
                push("text:" .. tostring(item.Name) .. "=" .. text)
            end
        elseif item:IsA("ProximityPrompt") then
            push("prompt:" .. tostring(item.Name) .. "|Object=" .. tostring(item.ObjectText) .. "|Action=" .. tostring(item.ActionText))
        end
        local okTags, tags = pcall(function()
            return game:GetService("CollectionService"):GetTags(item)
        end)
        if okTags and type(tags) == "table" and #tags > 0 then
            push("tags:" .. tostring(item.Name) .. "=" .. table.concat(tags, ","))
        end
    end
    inspect(egg)
    for _, item in ipairs(egg:GetDescendants()) do
        if #hints >= maxHints then break end
        inspect(item)
    end
    return table.concat(hints, ";")
end
Runtime.ESPFilter.DeepInspect = function(eggLimit, itemLimit)
    if not RenderedEggsFolder then
        print("[F8 DEBUG][ESP-DEEP] RenderedEggsFolder=nil")
        return
    end
    eggLimit = math.max(1, math.floor(tonumber(eggLimit) or 3))
    itemLimit = math.max(10, math.floor(tonumber(itemLimit) or 80))
    local collectionService = game:GetService("CollectionService")
    local candidates = {}
    local seenNames = {}

    -- Prefer eggs matching the active filter. Otherwise inspect distinct live types.
    for _, egg in ipairs(RenderedEggsFolder:GetChildren()) do
        if egg:IsA("Model") or egg:IsA("BasePart") then
            local matched = Runtime.ESPFilter.MatchSelectedEgg(egg)
            local _, resolvedName = Runtime.EggIdentity.Resolve(egg)
            local nameKey = Runtime.EggIdentity.Key(resolvedName or egg.Name)
            if (not Runtime.ESPFilter.AllEggs and matched) or Runtime.ESPFilter.AllEggs then
                if not seenNames[nameKey] then
                    seenNames[nameKey] = true
                    table.insert(candidates, egg)
                    if #candidates >= eggLimit then break end
                end
            end
        end
    end

    local function safeFullName(item)
        local ok, value = pcall(function() return item:GetFullName() end)
        return ok and value or tostring(item)
    end
    local function tagsOf(item)
        local ok, tags = pcall(function() return collectionService:GetTags(item) end)
        return ok and type(tags) == "table" and tags or {}
    end
    local function attrsOf(item)
        local out = {}
        for key, value in pairs(item:GetAttributes()) do
            table.insert(out, tostring(key) .. "=" .. tostring(value))
        end
        table.sort(out)
        return table.concat(out, ",")
    end
    local function describe(item)
        local extras = {}
        local attrs = attrsOf(item)
        if attrs ~= "" then table.insert(extras, "attrs{" .. attrs .. "}") end
        local tags = tagsOf(item)
        if #tags > 0 then table.insert(extras, "tags{" .. table.concat(tags, ",") .. "}") end
        if item:IsA("ValueBase") then
            local ok, value = pcall(function() return item.Value end)
            if ok then table.insert(extras, "value=" .. tostring(value)) end
        end
        if item:IsA("ProximityPrompt") then
            table.insert(extras, "ObjectText=" .. tostring(item.ObjectText))
            table.insert(extras, "ActionText=" .. tostring(item.ActionText))
        elseif item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
            local text = tostring(item.Text or "")
            if text ~= "" then table.insert(extras, "text=" .. text) end
        elseif item:IsA("ObjectValue") then
            table.insert(extras, "object=" .. tostring(item.Value and safeFullName(item.Value) or "nil"))
        end
        return table.concat(extras, " | ")
    end

    print("[F8 DEBUG][ESP-DEEP] inspecting=" .. tostring(#candidates)
        .. " | eggLimit=" .. tostring(eggLimit) .. " | itemLimit=" .. tostring(itemLimit))

    for index, egg in ipairs(candidates) do
        local resolvedKey, resolvedName = Runtime.EggIdentity.Resolve(egg)
        local liveInfo = Runtime.LiveEggData and Runtime.LiveEggData.FindForRendered
            and Runtime.LiveEggData.FindForRendered(egg, true) or nil
        local weight, weightSource = Runtime.Weight.Read(egg)
        local data = Runtime.ESPFilter.Metadata(egg)
        local mutationText, mutationSource = Runtime.ESPFilter.FormatMutationDebug(data)
        print("[F8 DEBUG][ESP-DEEP][" .. tostring(index) .. "] egg=" .. tostring(resolvedName or egg.Name)
            .. " | key=" .. tostring(resolvedKey)
            .. " | raw=" .. tostring(egg.Name)
            .. " | path=" .. safeFullName(egg)
            .. " | kg=" .. tostring(weight or "Unknown")
            .. " | kgSource=" .. tostring(weightSource)
            .. " | mutation=" .. tostring(mutationText)
            .. " | mutationSource=" .. tostring(mutationSource)
            .. " | activeID=" .. tostring(liveInfo and liveInfo.ID or "")
            .. " | activeEgg=" .. tostring(liveInfo and liveInfo.Egg or "")
            .. " | activeDelta=" .. tostring(liveInfo and liveInfo.Delta and string.format("%.2f", liveInfo.Delta) or "?")
            .. " | rawWeight=" .. tostring(liveInfo and liveInfo.RawWeight or "?")
            .. " | shownKG=" .. tostring(liveInfo and liveInfo.KG or "?")
            .. " | activeMutation=" .. tostring(liveInfo and liveInfo.Mutation or "")
            .. " | spawnMutation=" .. tostring(liveInfo and liveInfo.SpawnMutation or ""))

        local rootDesc = describe(egg)
        if rootDesc ~= "" then
            print("[F8 DEBUG][ESP-DEEP][" .. tostring(index) .. "][ROOT] " .. rootDesc)
        end

        local printed = 0
        for _, item in ipairs(egg:GetDescendants()) do
            local desc = describe(item)
            if desc ~= "" or item:IsA("ProximityPrompt") then
                printed = printed + 1
                print("[F8 DEBUG][ESP-DEEP][" .. tostring(index) .. "][" .. tostring(printed) .. "] "
                    .. tostring(item.ClassName) .. " " .. safeFullName(item)
                    .. (desc ~= "" and (" | " .. desc) or ""))
                if printed >= itemLimit then break end
            end
        end

        -- Parent-level metadata can belong to a centralized rendered-egg container.
        local parent = egg.Parent
        if parent then
            local parentDesc = describe(parent)
            print("[F8 DEBUG][ESP-DEEP][" .. tostring(index) .. "][PARENT] "
                .. safeFullName(parent) .. (parentDesc ~= "" and (" | " .. parentDesc) or ""))
        end

        -- Look for client UI text that mentions this exact live egg name or kg/mutation.
        local gui = LocalPlayer:FindFirstChild("PlayerGui")
        if gui then
            local needle = tostring(resolvedName or egg.Name):lower()
            local uiHits = 0
            for _, item in ipairs(gui:GetDescendants()) do
                if item:IsA("TextLabel") or item:IsA("TextButton") or item:IsA("TextBox") then
                    local textValue = tostring(item.Text or "")
                    local low = textValue:lower()
                    if textValue ~= "" and (low:find(needle, 1, true)
                        or low:find("kg",1,true) or low:find("mutation",1,true)
                        or low:find("shocked",1,true) or low:find("volted",1,true)
                        or low:find("rage",1,true) or low:find("void",1,true)
                        or low:find("eternal",1,true)) then
                        uiHits = uiHits + 1
                        print("[F8 DEBUG][ESP-DEEP][" .. tostring(index) .. "][GUI" .. tostring(uiHits) .. "] "
                            .. safeFullName(item) .. " | text=" .. textValue)
                        if uiHits >= 12 then break end
                    end
                end
            end
        end
    end
end

Runtime.ESPFilter.DebugDump = function(limit)
    if not RenderedEggsFolder then
        print("[F8 DEBUG][ESP-META] RenderedEggsFolder=nil")
        return
    end
    limit = math.max(1, math.floor(tonumber(limit) or 24))
    Runtime.ESPFilter.Cache = setmetatable({}, {__mode="k"})

    local rows = {}
    for _, egg in ipairs(RenderedEggsFolder:GetChildren()) do
        if egg:IsA("Model") or egg:IsA("BasePart") then
            local matched, matchedKey, resolvedKey, resolvedName, rawKey = Runtime.ESPFilter.MatchSelectedEgg(egg)
            local data = Runtime.ESPFilter.Metadata(egg)
            local mutationText, mutationSource = Runtime.ESPFilter.FormatMutationDebug(data)
            local liveInfo = Runtime.LiveEggData and Runtime.LiveEggData.FindForRendered
                and Runtime.LiveEggData.FindForRendered(egg, true) or nil
            table.insert(rows, {
                egg=egg, matched=matched, matchedKey=matchedKey, resolvedKey=resolvedKey,
                resolvedName=resolvedName, rawKey=rawKey, weight=data.Weight,
                weightSource=data.WeightSource or "not-found", mutationText=mutationText,
                mutationSource=mutationSource, rawHints=Runtime.ESPFilter.RawMetadataHints(egg, 8),
                activeID=liveInfo and liveInfo.ID or "", activeEgg=liveInfo and liveInfo.Egg or "",
                activeDelta=liveInfo and liveInfo.Delta or nil, rawWeight=liveInfo and liveInfo.RawWeight or nil,
                activeMutation=liveInfo and liveInfo.Mutation or nil,
                spawnMutation=liveInfo and liveInfo.SpawnMutation or nil,
                activeSource=liveInfo and liveInfo.Source or "not-found"
            })
        end
    end
    table.sort(rows, function(a,b)
        if a.matched ~= b.matched then return a.matched end
        return tostring(a.resolvedName):lower() < tostring(b.resolvedName):lower()
    end)

    local selected = {}
    for key,on in pairs(Runtime.ESPFilter.Eggs) do if on then table.insert(selected,key) end end
    table.sort(selected)
    print("[F8 DEBUG][ESP-META] rendered=" .. tostring(#rows)
        .. " | allEggs=" .. tostring(Runtime.ESPFilter.AllEggs)
        .. " | selected=" .. table.concat(selected, ","))

    for index, row in ipairs(rows) do
        if index > limit then break end
        print("[F8 DEBUG][ESP-META][" .. tostring(index) .. "] "
            .. "name=" .. tostring(row.resolvedName)
            .. " | resolvedKey=" .. tostring(row.resolvedKey)
            .. " | raw=" .. tostring(row.egg.Name)
            .. " | rawKey=" .. tostring(row.rawKey)
            .. " | filterMatch=" .. tostring(row.matched)
            .. " | matchedKey=" .. tostring(row.matchedKey)
            .. " | kg=" .. tostring(row.weight or "Unknown")
            .. " | kgSource=" .. tostring(row.weightSource)
            .. " | mutation=" .. tostring(row.mutationText)
            .. " | mutationSource=" .. tostring(row.mutationSource)
            .. " | activeID=" .. tostring(row.activeID)
            .. " | activeEgg=" .. tostring(row.activeEgg)
            .. " | activeDelta=" .. tostring(row.activeDelta and string.format("%.2f", row.activeDelta) or "?")
            .. " | rawWeight=" .. tostring(row.rawWeight or "?")
            .. " | activeMutation=" .. tostring(row.activeMutation or "")
            .. " | spawnMutation=" .. tostring(row.spawnMutation or "")
            .. " | activeSource=" .. tostring(row.activeSource)
            .. " | rawHints=" .. tostring(row.rawHints))
    end
end
Runtime.ESPFilter.Restore = function(state)
    local f = Runtime.ESPFilter
    state = type(state) == "table" and state or {}
    f.AllEggs = state.AllEggs ~= false
    f.Eggs = {}
    if type(state.Eggs) == "table" then
        for key, value in pairs(state.Eggs) do
            if type(key) == "string" and value == true then
                f.Eggs[Runtime.EggIdentity.Key(key)] = true
            end
        end
    end
    if f.RefreshChoices then f.RefreshChoices(true) end
    updateAllESP()
    if Runtime.SpawnNotifications
        and type(Runtime.SpawnNotifications.ReconcileCurrentFilter) == "function" then
        Runtime.SpawnNotifications.ReconcileCurrentFilter()
    end
end

-- Small paired lists keep egg type and mutation selections visible together.
do
    local f = Runtime.ESPFilter
    local panel = Instance.new("Frame")
    panel.Name = "EggESPFilters"
    panel.BackgroundTransparency = 1
    panel.Size = UDim2.new(1, -6, 0, 230)
    panel.Position = UDim2.new(0, 0, 0, 104)
    panel.Parent = Runtime.UIRegs.MainPage
    f.UI.Panel = panel
    local function label(text, x, y, width)
        local v = Instance.new("TextLabel")
        v.BackgroundTransparency = 1
        v.Position = UDim2.new(x, 0, 0, y)
        v.Size = UDim2.new(width, -4, 0, 18)
        v.Text = text
        v.TextSize = 10
        v.Font = Enum.Font.SourceSansBold
        v.TextColor3 = Color3.fromRGB(185, 205, 225)
        v.TextXAlignment = Enum.TextXAlignment.Left
        v.Parent = panel
        return v
    end
    label("Egg ESP filters  •  egg type only", 0, 0, 1)
    label("Egg type", 0, 25, 1)

    local search = Instance.new("TextBox")
    search.Position = UDim2.new(0, 0, 0, 45)
    search.Size = UDim2.new(1, -5, 0, 24)
    search.BackgroundColor3 = Color3.fromRGB(24,32,43)
    search.BorderSizePixel = 0
    search.TextColor3 = Color3.fromRGB(235,242,250)
    search.TextSize = 10
    search.Text = ""
    search.PlaceholderText = "Search egg..."
    search.ClearTextOnFocus = false
    search.Parent = panel

    local list = Instance.new("ScrollingFrame")
    list.Position = UDim2.new(0, 0, 0, 74)
    list.Size = UDim2.new(1, -5, 0, 122)
    list.BackgroundColor3 = Color3.fromRGB(18,24,32)
    list.BorderSizePixel = 0
    list.ScrollBarThickness = 3
    list.CanvasSize = UDim2.new()
    list.Parent = panel
    f.UI.Eggs = {Search=search, List=list, Signature=nil}

    trackRuntimeConnection(search:GetPropertyChangedSignal("Text"):Connect(function() f.RefreshChoices(true) end))

    local hint = label("Weight stays display-only. ESP label = Egg Name / Weight kg / Mutation.", 0, 202, 1)
    hint.Size = UDim2.new(1, -94, 0, 28)
    hint.TextWrapped = true
    hint.Font = Enum.Font.SourceSans
    hint.TextSize = 9

    local reset = Instance.new("TextButton")
    reset.Position=UDim2.new(1,-88,0,202)
    reset.Size=UDim2.new(0,82,0,28)
    reset.Text="Reset filter"
    reset.TextSize=10
    reset.BorderSizePixel=0
    reset.BackgroundColor3=Color3.fromRGB(27,35,46)
    reset.TextColor3=Color3.fromRGB(230,238,246)
    reset.Parent=panel
    reset.Activated:Connect(function()
        f.AllEggs=true; f.Eggs={}
        f.SelectionChanged()
    end)

    f.SelectionChanged = function()
        -- Choosing an ESP filter means ESP should actually be active.
        -- Clear cached metadata/identity before the direct refresh so the filter
        -- and F8 diagnostics inspect the same current replicated egg state.
        f.Cache = setmetatable({}, {__mode="k"})
        Runtime.EggIdentity.Cache = setmetatable({}, {__mode="k"})
        if Runtime.LiveEggData then Runtime.LiveEggData.Cache = setmetatable({}, {__mode="k"}) end
        applyGlobalESP(true)
        -- Keep the notification bar/cards in lockstep with the current egg toggles.
        if Runtime.SpawnNotifications
            and type(Runtime.SpawnNotifications.ReconcileCurrentFilter) == "function" then
            Runtime.SpawnNotifications.ReconcileCurrentFilter()
        end
        Runtime.UIRegs.ToggleGlobalESPBtn.Text="All Eggs ESP: ON"
        Runtime.UIRegs.ToggleGlobalESPBtn.TextColor3=Color3.fromRGB(0,255,120)
        if Runtime.TeleportDebug.Enabled and type(f.DebugDump) == "function" then
            task.defer(function() if Runtime.Alive then f.DebugDump(16) end end)
        end
        task.defer(function() if Runtime.Alive then f.RefreshChoices(false) end end)
    end

    f.RefreshChoices = function(force)
        -- Show the COMPLETE egg catalog, not only currently spawned eggs.
        -- Sources are merged in this order: built-in fallback -> live Index UI ->
        -- ActiveEggs. This automatically picks up future/new eggs exposed by the game.
        local names, spawned = {}, {}
        for _, name in ipairs(Runtime.EggIdentity.Catalog()) do
            local key = Runtime.EggIdentity.Key(name)
            if key ~= "" then names[key] = name end
        end
        for _, name in ipairs(Runtime.EggAutomation.KnownEggFallbackNames or {}) do
            local key = Runtime.EggIdentity.Key(name)
            if key ~= "" and not names[key] then names[key] = name end
        end

        if Runtime.LiveEggData and Runtime.LiveEggData.RefreshIndex then
            Runtime.LiveEggData.RefreshIndex(false)
            for _, record in ipairs(Runtime.LiveEggData.Records or {}) do
                local name = record.Egg
                local key = Runtime.EggIdentity.Key(name)
                if key ~= "" then
                    names[key] = name
                    spawned[key] = true
                end
            end
        end

        if RenderedEggsFolder then
            for _, egg in ipairs(RenderedEggsFolder:GetChildren()) do
                if egg:IsA("Model") or egg:IsA("BasePart") then
                    local key, name = Runtime.EggIdentity.Resolve(egg)
                    if not key or key == "" then key = Runtime.EggIdentity.Key(egg.Name) end
                    if key ~= "" then
                        names[key] = name or egg.Name
                        spawned[key] = true
                    end
                end
            end
        end

        local ui = f.UI.Eggs
        for key in pairs(f.Eggs) do
            if not names[key] then names[key] = key end
        end
        local keys = {}
        local queryText = f.Key(ui.Search.Text)
        local queryKey = Runtime.EggIdentity.Key(ui.Search.Text)
        for key, name in pairs(names) do
            if f.Key(name):find(queryText, 1, true) or key:find(queryKey, 1, true) then
                table.insert(keys, key)
            end
        end
        table.sort(keys, function(a,b) return tostring(names[a]):lower() < tostring(names[b]):lower() end)

        local signature = table.concat(keys, "|") .. tostring(f.AllEggs)
        for _, key in ipairs(keys) do signature = signature .. tostring(f.Eggs[key] == true) end
        if force or signature ~= ui.Signature then
            ui.Signature = signature
            for _, child in ipairs(ui.List:GetChildren()) do child:Destroy() end

            local function button(text, row, selected, callback)
                local b = Instance.new("TextButton")
                b.Position = UDim2.new(0, 2, 0, row*25+2)
                b.Size = UDim2.new(1, -8, 0, 23)
                b.BorderSizePixel = 0
                b.BackgroundColor3 = selected and Color3.fromRGB(25,95,65) or Color3.fromRGB(27,35,46)
                b.TextColor3 = Color3.fromRGB(230,238,246)
                b.TextSize = 10
                b.TextTruncate = Enum.TextTruncate.AtEnd
                b.Text = (selected and "✓ " or "") .. text
                b.Parent = ui.List
                b.Activated:Connect(callback)
            end

            button("All Eggs", 0, f.AllEggs, function()
                f.AllEggs = true
                f.Eggs = {}
                f.SelectionChanged()
            end)

            for row, key in ipairs(keys) do
                local rowKey = key
                local rowName = names[rowKey] .. (spawned[rowKey] and "" or "  • not spawned")
                button(rowName, row, not f.AllEggs and f.Eggs[rowKey] == true, function()
                    if f.AllEggs then f.AllEggs=false; f.Eggs={} end
                    f.Eggs[rowKey] = not f.Eggs[rowKey] or nil
                    f.SelectionChanged()
                end)
            end
            ui.List.CanvasSize = UDim2.new(0,0,0,(#keys+1)*25+4)
        end
    end
    f.RefreshChoices(true)
end
-- Minimal Player ESP: name only, event-driven, no render-step loop.
Runtime.PlayerESP = Runtime.PlayerESP or {Enabled=false, Tags=setmetatable({}, {__mode="k"}), UI={}}
Runtime.PlayerESP.Remove = function(player)
    local tag = Runtime.PlayerESP.Tags[player]
    if tag then pcall(function() tag:Destroy() end) end
    Runtime.PlayerESP.Tags[player] = nil
end
Runtime.PlayerESP.Attach = function(player, character)
    Runtime.PlayerESP.Remove(player)
    if not Runtime.PlayerESP.Enabled or player == LocalPlayer then return end
    character = character or player.Character
    local head = character and (character:FindFirstChild("Head") or character:FindFirstChild("HumanoidRootPart"))
    if not head or not head:IsA("BasePart") then return end
    local gui = Instance.new("BillboardGui")
    gui.Name = "ZOLO_PlayerNameESP"
    gui.Adornee = head
    gui.Size = UDim2.fromOffset(160,22)
    gui.StudsOffset = Vector3.new(0,2.6,0)
    gui.AlwaysOnTop = true
    gui.LightInfluence = 0
    gui.MaxDistance = 1000
    local label = Instance.new("TextLabel")
    label.Size = UDim2.fromScale(1,1)
    label.BackgroundTransparency = 1
    label.Text = player.DisplayName ~= "" and player.DisplayName or player.Name
    label.TextColor3 = Color3.fromRGB(245,245,245)
    label.TextStrokeColor3 = Color3.fromRGB(0,0,0)
    label.TextStrokeTransparency = 0.25
    label.TextSize = 12
    label.Font = Enum.Font.GothamMedium
    label.Parent = gui
    gui.Parent = Runtime.ScreenGui or TargetParent
    Runtime.PlayerESP.Tags[player] = gui
end
Runtime.PlayerESP.Refresh = function()
    for player in pairs(Runtime.PlayerESP.Tags) do Runtime.PlayerESP.Remove(player) end
    if Runtime.PlayerESP.Enabled then
        for _, player in ipairs(Players:GetPlayers()) do Runtime.PlayerESP.Attach(player, player.Character) end
    end
end
for _, player in ipairs(Players:GetPlayers()) do
    if player ~= LocalPlayer then
        trackRuntimeConnection(player.CharacterAdded:Connect(function(character)
            task.defer(function() if Runtime.Alive then Runtime.PlayerESP.Attach(player, character) end end)
        end))
    end
end
trackRuntimeConnection(Players.PlayerAdded:Connect(function(player)
    if player == LocalPlayer then return end
    trackRuntimeConnection(player.CharacterAdded:Connect(function(character)
        task.defer(function() if Runtime.Alive then Runtime.PlayerESP.Attach(player, character) end end)
    end))
    task.defer(function() if Runtime.Alive then Runtime.PlayerESP.Attach(player, player.Character) end end)
end))
trackRuntimeConnection(Players.PlayerRemoving:Connect(function(player) Runtime.PlayerESP.Remove(player) end))

Runtime.PlayerESP.UI.Toggle = Instance.new("TextButton")
Runtime.PlayerESP.UI.Toggle.Name = "PlayerESPNameOnlyToggle"
Runtime.PlayerESP.UI.Toggle.Size = UDim2.new(1,-6,0,30)
Runtime.PlayerESP.UI.Toggle.BackgroundColor3 = Color3.fromRGB(27,35,46)
Runtime.PlayerESP.UI.Toggle.BorderSizePixel = 0
Runtime.PlayerESP.UI.Toggle.TextColor3 = Color3.fromRGB(220,230,240)
Runtime.PlayerESP.UI.Toggle.TextSize = 10
Runtime.PlayerESP.UI.Toggle.Font = Enum.Font.GothamMedium
Runtime.PlayerESP.UI.Toggle.Text = "Player ESP (Name Only): OFF"
Runtime.PlayerESP.UI.Toggle.Parent = Runtime.UIRegs.MainPage
styleButton(Runtime.PlayerESP.UI.Toggle)
Runtime.PlayerESP.UI.Toggle.Activated:Connect(function()
    Runtime.PlayerESP.Enabled = not Runtime.PlayerESP.Enabled
    Runtime.PlayerESP.UI.Toggle.Text = Runtime.PlayerESP.Enabled and "Player ESP (Name Only): ON" or "Player ESP (Name Only): OFF"
    Runtime.PlayerESP.UI.Toggle.BackgroundColor3 = Runtime.PlayerESP.Enabled and Color3.fromRGB(0,105,75) or Color3.fromRGB(27,35,46)
    Runtime.PlayerESP.Refresh()
end)

Runtime.ESPFilter.UI.Collapsed = false
Runtime.ESPFilter.UI.CollapseBtn = Instance.new("TextButton")
Runtime.ESPFilter.UI.CollapseBtn.Size = UDim2.new(0,56,0,20)
Runtime.ESPFilter.UI.CollapseBtn.Position = UDim2.new(1,-62,0,0)
Runtime.ESPFilter.UI.CollapseBtn.BackgroundColor3 = Color3.fromRGB(27,35,46)
Runtime.ESPFilter.UI.CollapseBtn.BorderSizePixel = 0
Runtime.ESPFilter.UI.CollapseBtn.TextColor3 = Color3.fromRGB(205,218,235)
Runtime.ESPFilter.UI.CollapseBtn.TextSize = 9
Runtime.ESPFilter.UI.CollapseBtn.Font = Enum.Font.GothamMedium
Runtime.ESPFilter.UI.CollapseBtn.Text = "Hide"
Runtime.ESPFilter.UI.CollapseBtn.Parent = Runtime.ESPFilter.UI.Panel
styleButton(Runtime.ESPFilter.UI.CollapseBtn)
Runtime.ESPFilter.UI.CollapseBtn.Activated:Connect(function()
    Runtime.ESPFilter.UI.Collapsed = not Runtime.ESPFilter.UI.Collapsed
    Runtime.ESPFilter.Layout()
end)

Runtime.ESPFilter.Layout = function()
    local f = Runtime.ESPFilter
    local panelTop = isMobileMode and 94 or 104
    local collapsed = f.UI.Collapsed == true
    local panelHeight = collapsed and 28 or 230
    f.UI.Panel.Position = UDim2.new(0,0,0,panelTop)
    f.UI.Panel.Size = UDim2.new(1,-6,0,panelHeight)
    if f.UI.CollapseBtn then
        f.UI.CollapseBtn.Text = collapsed and "Show" or "Hide"
        f.UI.CollapseBtn.Visible = true
    end
    for _, child in ipairs(f.UI.Panel:GetChildren()) do
        if child ~= f.UI.CollapseBtn and child:IsA("GuiObject") then
            local keepTitle = child:IsA("TextLabel") and child.Position.Y.Offset == 0
            child.Visible = (not collapsed) or keepTitle
        end
    end
    if Runtime.PlayerESP and Runtime.PlayerESP.UI.Toggle then
        Runtime.PlayerESP.UI.Toggle.Position = UDim2.new(0,0,0,panelTop+panelHeight+6)
        Runtime.PlayerESP.UI.Toggle.Size = UDim2.new(1,-6,0,isMobileMode and 28 or 30)
        Runtime.PlayerESP.UI.Toggle.TextSize = isMobileMode and 9 or 10
    end
    local baseTitle = isMobileMode and 96 or 108
    local desiredTitle = panelTop + panelHeight + (isMobileMode and 42 or 44)
    local offset = desiredTitle - baseTitle
    for _, key in ipairs({"Title", "Toggle", "AgeLabel", "AgeControl", "Hint", "Status"}) do
        local control = Runtime.AutoFeed.UI[key]
        if control then control.Position = control.Position + UDim2.new(0,0,0,offset) end
    end
    Runtime.UIRegs.MainPage.CanvasSize = UDim2.new(0,0,0,collapsed and (isMobileMode and 390 or 420) or (isMobileMode and 630 or 660))
end
-- Bounded metadata refresh catches replicated weight/mutation changes without
-- adding a descendant watcher to every object. Cleanup is gated by Runtime.Alive.
task.spawn(function()
    while Runtime.Alive and ScreenGui.Parent do
        -- Global ESP is refreshed by state changes/new eggs and the lightweight
        -- metadata updater below. Avoid rebuilding every egg every 2 seconds.
        if not mainESPActive then
            for egg,data in pairs(eggData) do
                if data.CustomActive and egg.Parent then queueEggESPUpdate(egg) end
            end
        end
        if Runtime.UIRegs.MainPage.Visible and os.clock() >= (Runtime.NextESPChoiceRefreshAt or 0) then
            Runtime.NextESPChoiceRefreshAt = os.clock() + 8.0
            local ok,err=pcall(Runtime.ESPFilter.RefreshChoices,false)
            if not ok then Runtime.LastESPError=tostring(err) end
        end
        if Runtime.TeleportDebug.Enabled and os.clock()>=(Runtime.NextESPDebug or 0) then
            Runtime.NextESPDebug=os.clock()+5
            local counts,visible,matched={},0,0
            local highlights,billboards,adorned,liveAdornees=0,0,0,0
            local activeMatched = 0
            local metadataSamples = {}
            local debugProcessed = 0
            for egg,data in pairs(eggData) do
                debugProcessed = debugProcessed + 1
                if debugProcessed % 24 == 0 then RunService.Heartbeat:Wait() end
                if egg.Parent then
                    local identityKey, identityName = Runtime.EggIdentity.Resolve(egg)
                    local key=identityKey or "unknown"
                    counts[key]=(counts[key] or 0)+1
                    local liveInfo = Runtime.LiveEggData and Runtime.LiveEggData.FindForRendered
                        and Runtime.LiveEggData.FindForRendered(egg) or nil
                    if liveInfo and liveInfo.Object then activeMatched=activeMatched+1 end
                    local filterMatched = Runtime.ESPFilter.MatchSelectedEgg(egg)
                    if filterMatched then matched=matched+1 end
                    if #metadataSamples < 4 and (Runtime.ESPFilter.AllEggs or filterMatched) then
                        local meta = Runtime.ESPFilter.Metadata(egg)
                        local mutationText = Runtime.ESPFilter.FormatMutationDebug(meta)
                        table.insert(metadataSamples, tostring(identityName or egg.Name)
                            .. "|kg=" .. tostring(meta.Weight or "?")
                            .. "|mut=" .. tostring(mutationText))
                    end
                    if data.Highlight and data.Highlight.Parent and data.Highlight.Enabled then highlights=highlights+1 end
                    if data.NameBillboard and data.NameBillboard.Parent then
                        billboards=billboards+1
                        local adornee=data.ESPPart
                        if adornee then adorned=adorned+1 end
                        if adornee and adornee:IsA("BasePart") and adornee:IsDescendantOf(Workspace) then liveAdornees=liveAdornees+1 end
                        if data.NameBillboard.Visible then visible=visible+1 end
                    end
                end
            end
            local list={}
            for key,count in pairs(counts) do table.insert(list,key..":"..count) end
            table.sort(list)
            local selected={}
            for key,on in pairs(Runtime.ESPFilter.Eggs) do if on then table.insert(selected,key) end end
            Runtime.DebugTeleport("ESP","Visibility",{types=table.concat(list,", "),labels=visible,
                billboards=billboards,adorned=adorned,liveAdornees=liveAdornees,highlights=highlights,
                billboardRepairs=Runtime.ESPBillboardRepairs or 0,highlightRepairs=Runtime.ESPHighlightRepairs or 0,
                onScreen=Runtime.ESPOnScreen or 0,
                noAdornee=Runtime.ESPNoAdornee or 0,globalActive=mainESPActive,
                allEggs=Runtime.ESPFilter.AllEggs,selected=table.concat(selected,","),matchedEggs=matched,
                activeMatched=activeMatched,metadataSamples=table.concat(metadataSamples,"; "),
                activeIndexBuilds=Runtime.LiveEggData and Runtime.LiveEggData.IndexBuilds or 0,
                mutationFilter="removed/display-only",renderer="screen-space-" .. tostring(Config.ESPRenderHz or 20) .. "hz",
                errors=Runtime.ESPErrors or 0,lastError=Runtime.LastESPError or "none"})
        end
        task.wait(2)
    end
end)

Runtime.EggAutomation.UI.WeightControl = Runtime.Weight.AddControl(Runtime.UIRegs.AutomationPage, "Place Min kg", 176,
    function()
        return Runtime.EggAutomation.GetPlaceMinWeight()
    end,
    function(value)
        Runtime.EggAutomation.SetPlaceMinWeight(value)
    end)

-- Apply valid Place Min kg values immediately while editing. FocusLost still
-- normalizes the final textbox text through the common Weight control handler.
do
    local control = Runtime.EggAutomation.UI.WeightControl
    if control and control.Box then
        local serial = 0
        trackRuntimeConnection(control.Box:GetPropertyChangedSignal("Text"):Connect(function()
            if not control.Box:IsFocused() then return end

            serial = serial + 1
            local mine = serial
            task.delay(0.12, function()
                if not Runtime.Alive or mine ~= serial then return end
                local parsed = Runtime.Weight.Parse(control.Box.Text, true)
                if type(parsed) == "number" then
                    Runtime.EggAutomation.SetPlaceMinWeight(parsed)
                end
            end)
        end))
    end
end

-- Egg Automation page: bag/slot-aware placement + hatch automation.
do
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 0, 22)
    title.BackgroundTransparency = 1
    title.Text = "Egg Place / Hatch Manager"
    title.TextColor3 = Color3.fromRGB(235, 240, 248)
    title.TextSize = 14
    title.Font = Enum.Font.SourceSansBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = Runtime.UIRegs.AutomationPage
    Runtime.EggAutomation.UI.PageTitle = title

    local hint = Instance.new("TextLabel")
    hint.Size = UDim2.new(1, 0, 0, 42)
    hint.Position = UDim2.new(0, 0, 0, 26)
    hint.BackgroundTransparency = 1
    hint.Text = "Independent armed modes with TWO separate egg-name filters. Auto Place uses only its Place list and still prioritizes highest Luck > rarity > KG. Auto Hatch uses only its Hatch list and resolves the ready placed egg before interacting."
    hint.TextWrapped = true
    hint.TextColor3 = Color3.fromRGB(155, 170, 188)
    hint.TextSize = 10
    hint.Font = Enum.Font.SourceSans
    hint.TextXAlignment = Enum.TextXAlignment.Left
    hint.TextYAlignment = Enum.TextYAlignment.Top
    hint.Parent = Runtime.UIRegs.AutomationPage
    Runtime.EggAutomation.UI.PageHint = hint

    Runtime.EggAutomation.UI.AutoPlaceBtn = Instance.new("TextButton")
    Runtime.EggAutomation.UI.AutoPlaceBtn.Size = UDim2.new(0.5, -4, 0, 32)
    Runtime.EggAutomation.UI.AutoPlaceBtn.Position = UDim2.new(0, 0, 0, 74)
    Runtime.EggAutomation.UI.AutoPlaceBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 58)
    Runtime.EggAutomation.UI.AutoPlaceBtn.BackgroundTransparency = 0.08
    Runtime.EggAutomation.UI.AutoPlaceBtn.TextColor3 = Color3.fromRGB(235, 240, 248)
    Runtime.EggAutomation.UI.AutoPlaceBtn.TextSize = 11
    Runtime.EggAutomation.UI.AutoPlaceBtn.Font = Enum.Font.SourceSansBold
    Runtime.EggAutomation.UI.AutoPlaceBtn.Parent = Runtime.UIRegs.AutomationPage
    styleButton(Runtime.EggAutomation.UI.AutoPlaceBtn)

    Runtime.EggAutomation.UI.AutoHatchBtn = Instance.new("TextButton")
    Runtime.EggAutomation.UI.AutoHatchBtn.Size = UDim2.new(0.5, -4, 0, 32)
    Runtime.EggAutomation.UI.AutoHatchBtn.Position = UDim2.new(0.5, 4, 0, 74)
    Runtime.EggAutomation.UI.AutoHatchBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 58)
    Runtime.EggAutomation.UI.AutoHatchBtn.BackgroundTransparency = 0.08
    Runtime.EggAutomation.UI.AutoHatchBtn.TextColor3 = Color3.fromRGB(235, 240, 248)
    Runtime.EggAutomation.UI.AutoHatchBtn.TextSize = 11
    Runtime.EggAutomation.UI.AutoHatchBtn.Font = Enum.Font.SourceSansBold
    Runtime.EggAutomation.UI.AutoHatchBtn.Parent = Runtime.UIRegs.AutomationPage
    styleButton(Runtime.EggAutomation.UI.AutoHatchBtn)

    Runtime.EggAutomation.UI.PriorityBtn = Instance.new("TextButton")
    Runtime.EggAutomation.UI.PriorityBtn.Size = UDim2.new(1, 0, 0, 30)
    Runtime.EggAutomation.UI.PriorityBtn.Position = UDim2.new(0, 0, 0, 112)
    Runtime.EggAutomation.UI.PriorityBtn.BackgroundColor3 = Color3.fromRGB(0, 120, 170)
    Runtime.EggAutomation.UI.PriorityBtn.BackgroundTransparency = 0.08
    Runtime.EggAutomation.UI.PriorityBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    Runtime.EggAutomation.UI.PriorityBtn.TextSize = 10
    Runtime.EggAutomation.UI.PriorityBtn.Font = Enum.Font.SourceSansBold
    Runtime.EggAutomation.UI.PriorityBtn.Parent = Runtime.UIRegs.AutomationPage
    styleButton(Runtime.EggAutomation.UI.PriorityBtn)

    local sameNest = Instance.new("TextLabel")
    sameNest.Size = UDim2.new(1, 0, 0, 22)
    sameNest.Position = UDim2.new(0, 0, 0, 147)
    sameNest.BackgroundColor3 = Color3.fromRGB(16, 45, 31)
    sameNest.BackgroundTransparency = 0.08
    sameNest.Text = "Strict Same Egg Area: ON — beside only, NEVER stacked above"
    sameNest.TextColor3 = Color3.fromRGB(145, 255, 190)
    sameNest.TextSize = 10
    sameNest.Font = Enum.Font.SourceSansBold
    sameNest.Parent = Runtime.UIRegs.AutomationPage
    sameNest.TextWrapped = true
    Runtime.EggAutomation.UI.SameNestLabel = sameNest
    local sameCorner = Instance.new("UICorner")
    sameCorner.CornerRadius = UDim.new(0, 6)
    sameCorner.Parent = sameNest

    local placeFilterTitle = Instance.new("TextLabel")
    placeFilterTitle.Size = UDim2.new(1, 0, 0, 18)
    placeFilterTitle.Position = UDim2.new(0, 0, 0, 176)
    placeFilterTitle.BackgroundTransparency = 1
    placeFilterTitle.Text = "Auto Place eggs"
    placeFilterTitle.TextColor3 = Color3.fromRGB(185, 215, 255)
    placeFilterTitle.TextSize = 10
    placeFilterTitle.Font = Enum.Font.SourceSansBold
    placeFilterTitle.TextXAlignment = Enum.TextXAlignment.Left
    placeFilterTitle.Parent = Runtime.UIRegs.AutomationPage
    Runtime.EggAutomation.UI.PlaceFilterTitle = placeFilterTitle

    local placeSearchBox = Instance.new("TextBox")
    placeSearchBox.Name = "AutoPlaceEggSearch"
    placeSearchBox.Size = UDim2.new(1, 0, 0, 26)
    placeSearchBox.Position = UDim2.new(0, 0, 0, 198)
    placeSearchBox.BackgroundColor3 = Color3.fromRGB(24, 32, 43)
    placeSearchBox.BackgroundTransparency = 0.04
    placeSearchBox.BorderSizePixel = 0
    placeSearchBox.ClearTextOnFocus = false
    placeSearchBox.PlaceholderText = "Search Auto Place egg... e.g. Solaris"
    placeSearchBox.PlaceholderColor3 = Color3.fromRGB(120, 135, 155)
    placeSearchBox.Text = ""
    placeSearchBox.TextColor3 = Color3.fromRGB(235, 242, 250)
    placeSearchBox.TextSize = 10
    placeSearchBox.Font = Enum.Font.SourceSans
    placeSearchBox.TextXAlignment = Enum.TextXAlignment.Left
    placeSearchBox.Parent = Runtime.UIRegs.AutomationPage
    Runtime.EggAutomation.UI.PlaceFilterSearch = placeSearchBox
    local placeSearchCorner = Instance.new("UICorner")
    placeSearchCorner.CornerRadius = UDim.new(0, 7)
    placeSearchCorner.Parent = placeSearchBox
    local placeSearchPadding = Instance.new("UIPadding")
    placeSearchPadding.PaddingLeft = UDim.new(0, 9)
    placeSearchPadding.PaddingRight = UDim.new(0, 9)
    placeSearchPadding.Parent = placeSearchBox

    local placeFilterFrame = Instance.new("ScrollingFrame")
    placeFilterFrame.Name = "AutoPlaceEggFilterScroll"
    placeFilterFrame.Size = UDim2.new(1, 0, 0, 105)
    placeFilterFrame.Position = UDim2.new(0, 0, 0, 229)
    placeFilterFrame.BackgroundColor3 = Color3.fromRGB(18, 24, 32)
    placeFilterFrame.BackgroundTransparency = 0.08
    placeFilterFrame.BorderSizePixel = 0
    placeFilterFrame.ScrollBarThickness = 4
    placeFilterFrame.ScrollingDirection = Enum.ScrollingDirection.Y
    placeFilterFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    placeFilterFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
    placeFilterFrame.Parent = Runtime.UIRegs.AutomationPage
    Runtime.EggAutomation.UI.PlaceFilterScroll = placeFilterFrame
    local placeFilterCorner = Instance.new("UICorner")
    placeFilterCorner.CornerRadius = UDim.new(0, 7)
    placeFilterCorner.Parent = placeFilterFrame

    local hatchFilterTitle = Instance.new("TextLabel")
    hatchFilterTitle.Size = UDim2.new(1, 0, 0, 18)
    hatchFilterTitle.Position = UDim2.new(0, 0, 0, 342)
    hatchFilterTitle.BackgroundTransparency = 1
    hatchFilterTitle.Text = "AUTO HATCH EGG FILTER — independent / searchable"
    hatchFilterTitle.TextColor3 = Color3.fromRGB(190, 255, 205)
    hatchFilterTitle.TextSize = 10
    hatchFilterTitle.Font = Enum.Font.SourceSansBold
    hatchFilterTitle.TextXAlignment = Enum.TextXAlignment.Left
    hatchFilterTitle.Parent = Runtime.UIRegs.AutomationPage
    Runtime.EggAutomation.UI.HatchFilterTitle = hatchFilterTitle

    local hatchSearchBox = Instance.new("TextBox")
    hatchSearchBox.Name = "AutoHatchEggSearch"
    hatchSearchBox.Size = UDim2.new(1, 0, 0, 26)
    hatchSearchBox.Position = UDim2.new(0, 0, 0, 364)
    hatchSearchBox.BackgroundColor3 = Color3.fromRGB(24, 32, 43)
    hatchSearchBox.BackgroundTransparency = 0.04
    hatchSearchBox.BorderSizePixel = 0
    hatchSearchBox.ClearTextOnFocus = false
    hatchSearchBox.PlaceholderText = "Search Auto Hatch egg... e.g. Blackhole"
    hatchSearchBox.PlaceholderColor3 = Color3.fromRGB(120, 135, 155)
    hatchSearchBox.Text = ""
    hatchSearchBox.TextColor3 = Color3.fromRGB(235, 242, 250)
    hatchSearchBox.TextSize = 10
    hatchSearchBox.Font = Enum.Font.SourceSans
    hatchSearchBox.TextXAlignment = Enum.TextXAlignment.Left
    hatchSearchBox.Parent = Runtime.UIRegs.AutomationPage
    Runtime.EggAutomation.UI.HatchFilterSearch = hatchSearchBox
    local hatchSearchCorner = Instance.new("UICorner")
    hatchSearchCorner.CornerRadius = UDim.new(0, 7)
    hatchSearchCorner.Parent = hatchSearchBox
    local hatchSearchPadding = Instance.new("UIPadding")
    hatchSearchPadding.PaddingLeft = UDim.new(0, 9)
    hatchSearchPadding.PaddingRight = UDim.new(0, 9)
    hatchSearchPadding.Parent = hatchSearchBox

    local hatchFilterFrame = Instance.new("ScrollingFrame")
    hatchFilterFrame.Name = "AutoHatchEggFilterScroll"
    hatchFilterFrame.Size = UDim2.new(1, 0, 0, 105)
    hatchFilterFrame.Position = UDim2.new(0, 0, 0, 395)
    hatchFilterFrame.BackgroundColor3 = Color3.fromRGB(18, 24, 32)
    hatchFilterFrame.BackgroundTransparency = 0.08
    hatchFilterFrame.BorderSizePixel = 0
    hatchFilterFrame.ScrollBarThickness = 4
    hatchFilterFrame.ScrollingDirection = Enum.ScrollingDirection.Y
    hatchFilterFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
    hatchFilterFrame.AutomaticCanvasSize = Enum.AutomaticSize.None
    hatchFilterFrame.Parent = Runtime.UIRegs.AutomationPage
    Runtime.EggAutomation.UI.HatchFilterScroll = hatchFilterFrame
    local hatchFilterCorner = Instance.new("UICorner")
    hatchFilterCorner.CornerRadius = UDim.new(0, 7)
    hatchFilterCorner.Parent = hatchFilterFrame

    Runtime.EggAutomation.UI.PlaceFilterCollapsed = false
    Runtime.EggAutomation.UI.HatchFilterCollapsed = false
    Runtime.EggAutomation.UI.PlaceFilterHide = Instance.new("TextButton")
    Runtime.EggAutomation.UI.PlaceFilterHide.Size = UDim2.new(0,58,0,18)
    Runtime.EggAutomation.UI.PlaceFilterHide.BackgroundColor3 = Color3.fromRGB(27,35,46)
    Runtime.EggAutomation.UI.PlaceFilterHide.BorderSizePixel = 0
    Runtime.EggAutomation.UI.PlaceFilterHide.Text = "Hide"
    Runtime.EggAutomation.UI.PlaceFilterHide.TextColor3 = Color3.fromRGB(205,218,235)
    Runtime.EggAutomation.UI.PlaceFilterHide.TextSize = 9
    Runtime.EggAutomation.UI.PlaceFilterHide.Parent = Runtime.UIRegs.AutomationPage
    styleButton(Runtime.EggAutomation.UI.PlaceFilterHide)
    Runtime.EggAutomation.UI.HatchFilterHide = Instance.new("TextButton")
    Runtime.EggAutomation.UI.HatchFilterHide.Size = UDim2.new(0,58,0,18)
    Runtime.EggAutomation.UI.HatchFilterHide.BackgroundColor3 = Color3.fromRGB(27,35,46)
    Runtime.EggAutomation.UI.HatchFilterHide.BorderSizePixel = 0
    Runtime.EggAutomation.UI.HatchFilterHide.Text = "Hide"
    Runtime.EggAutomation.UI.HatchFilterHide.TextColor3 = Color3.fromRGB(205,218,235)
    Runtime.EggAutomation.UI.HatchFilterHide.TextSize = 9
    Runtime.EggAutomation.UI.HatchFilterHide.Parent = Runtime.UIRegs.AutomationPage
    styleButton(Runtime.EggAutomation.UI.HatchFilterHide)

    Runtime.EggAutomation.UI.PlaceFilterButtons = {}
    Runtime.EggAutomation.UI.HatchFilterButtons = {}

    local function clearEggFilterButtons(frame, buttonTable)
        for _, child in ipairs(frame:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end
        table.clear(buttonTable)
    end

    local function normalizeEggSearch(value)
        local textValue = tostring(value or ""):lower()
        textValue = textValue:gsub("^%s+", ""):gsub("%s+$", "")
        return textValue
    end

    local function eggNameMatchesSearch(eggName, query)
        local search = normalizeEggSearch(query)
        if search == "" then
            return true
        end

        local lowerName = tostring(eggName or ""):lower()
        if string.find(lowerName, search, 1, true) then
            return true
        end

        local normalizedName = Runtime.EggAutomation.NormalizeEggKey(eggName)
        local normalizedSearch = Runtime.EggAutomation.NormalizeEggKey(search)
        return normalizedSearch ~= ""
            and string.find(normalizedName, normalizedSearch, 1, true) ~= nil
    end

    local function rebuildEggFilterList(frame, buttonTable, filterTable, modeLabel, searchQuery)
        clearEggFilterButtons(frame, buttonTable)

        local knownNames = Runtime.EggAutomation.GetKnownEggNames()
        local names = {}
        for _, eggName in ipairs(knownNames) do
            if eggNameMatchesSearch(eggName, searchQuery) then
                table.insert(names, eggName)
            end
        end

        for index, eggName in ipairs(names) do
            local col = (index - 1) % 2
            local row = math.floor((index - 1) / 2)
            local button = Instance.new("TextButton")
            button.Size = UDim2.new(0.5, -8, 0, 25)
            button.Position = UDim2.new(col * 0.5, 5 + col * 2, 0, 5 + row * 28)
            button.BackgroundTransparency = 0.08
            button.TextColor3 = Color3.fromRGB(255, 255, 255)
            button.TextSize = 9
            button.Font = Enum.Font.SourceSansBold
            button.TextWrapped = true
            button.Parent = frame
            styleButton(button)

            local key = Runtime.EggAutomation.NormalizeEggKey(eggName)
            buttonTable[key] = button

            local function refreshOne()
                local enabled = Runtime.EggAutomation.IsEggNameFilterEnabled(filterTable, eggName)
                button.BackgroundColor3 = enabled
                    and Color3.fromRGB(0, 135, 70)
                    or Color3.fromRGB(45, 52, 64)
                button.Text = eggName .. (enabled and " ✓" or " ✕")
            end

            button.Activated:Connect(function()
                local enabled = not Runtime.EggAutomation.IsEggNameFilterEnabled(filterTable, eggName)
                Runtime.EggAutomation.SetEggNameFilterEnabled(filterTable, eggName, enabled)
                if filterTable == EggAutoState.PlaceEggFilters then
                    Runtime.EggAutomation.MarkBagCacheDirty("Auto Place filter UI changed")
                end
                Runtime.EggAutomation.WakeSerial = (Runtime.EggAutomation.WakeSerial or 0) + 1
                refreshOne()
                Runtime.EggAutomation.SetStatus(
                    modeLabel .. " " .. eggName .. ": " .. (enabled and "ENABLED" or "BLOCKED"),
                    true
                )
            end)
            refreshOne()
        end

        local rows = math.ceil(#names / 2)
        frame.CanvasPosition = Vector2.new(0, 0)
        frame.CanvasSize = UDim2.new(0, 0, 0, math.max(frame.AbsoluteSize.Y, 10 + rows * 28))
    end

    Runtime.EggAutomation.RefreshEggFilterUI = function()
        if not placeFilterFrame.Parent or not hatchFilterFrame.Parent then
            return
        end

        rebuildEggFilterList(
            placeFilterFrame,
            Runtime.EggAutomation.UI.PlaceFilterButtons,
            EggAutoState.PlaceEggFilters,
            "Auto Place",
            placeSearchBox.Text
        )
        rebuildEggFilterList(
            hatchFilterFrame,
            Runtime.EggAutomation.UI.HatchFilterButtons,
            EggAutoState.HatchEggFilters,
            "Auto Hatch",
            hatchSearchBox.Text
        )
    end

    placeSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
        rebuildEggFilterList(
            placeFilterFrame,
            Runtime.EggAutomation.UI.PlaceFilterButtons,
            EggAutoState.PlaceEggFilters,
            "Auto Place",
            placeSearchBox.Text
        )
    end)

    hatchSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
        rebuildEggFilterList(
            hatchFilterFrame,
            Runtime.EggAutomation.UI.HatchFilterButtons,
            EggAutoState.HatchEggFilters,
            "Auto Hatch",
            hatchSearchBox.Text
        )
    end)

    Runtime.EggAutomation.RefreshEggFilterUI()

    local PlaceNowBtn = Instance.new("TextButton")
    PlaceNowBtn.Size = UDim2.new(0.5, -4, 0, 29)
    PlaceNowBtn.Position = UDim2.new(0, 0, 0, 508)
    PlaceNowBtn.BackgroundColor3 = Color3.fromRGB(45, 72, 100)
    PlaceNowBtn.BackgroundTransparency = 0.08
    PlaceNowBtn.Text = "Place Best Now"
    PlaceNowBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    PlaceNowBtn.TextSize = 10
    PlaceNowBtn.Font = Enum.Font.SourceSansBold
    PlaceNowBtn.Parent = Runtime.UIRegs.AutomationPage
    styleButton(PlaceNowBtn)
    Runtime.EggAutomation.UI.PlaceNowBtn = PlaceNowBtn

    local HatchNowBtn = Instance.new("TextButton")
    HatchNowBtn.Size = UDim2.new(0.5, -4, 0, 29)
    HatchNowBtn.Position = UDim2.new(0.5, 4, 0, 508)
    HatchNowBtn.BackgroundColor3 = Color3.fromRGB(45, 72, 100)
    HatchNowBtn.BackgroundTransparency = 0.08
    HatchNowBtn.Text = "Hatch Ready Now"
    HatchNowBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    HatchNowBtn.TextSize = 10
    HatchNowBtn.Font = Enum.Font.SourceSansBold
    HatchNowBtn.Parent = Runtime.UIRegs.AutomationPage
    styleButton(HatchNowBtn)
    Runtime.EggAutomation.UI.HatchNowBtn = HatchNowBtn

    Runtime.EggAutomation.UI.StatusLabel = Instance.new("TextLabel")
    Runtime.EggAutomation.UI.StatusLabel.Size = UDim2.new(1, 0, 0, 78)
    Runtime.EggAutomation.UI.StatusLabel.Position = UDim2.new(0, 0, 0, 544)
    Runtime.EggAutomation.UI.StatusLabel.BackgroundColor3 = Color3.fromRGB(22, 29, 39)
    Runtime.EggAutomation.UI.StatusLabel.BackgroundTransparency = 0.10
    Runtime.EggAutomation.UI.StatusLabel.BorderSizePixel = 0
    Runtime.EggAutomation.UI.StatusLabel.Text = "Ready. Place and Hatch use separate searchable egg-name filters. Type part of an egg name to find it quickly. Both lists are ALL OFF by default."
    Runtime.EggAutomation.UI.StatusLabel.TextWrapped = true
    Runtime.EggAutomation.UI.StatusLabel.TextColor3 = Color3.fromRGB(170, 215, 195)
    Runtime.EggAutomation.UI.StatusLabel.TextSize = 10
    Runtime.EggAutomation.UI.StatusLabel.Font = Enum.Font.SourceSans
    Runtime.EggAutomation.UI.StatusLabel.TextXAlignment = Enum.TextXAlignment.Left
    Runtime.EggAutomation.UI.StatusLabel.TextYAlignment = Enum.TextYAlignment.Top
    Runtime.EggAutomation.UI.StatusLabel.Parent = Runtime.UIRegs.AutomationPage
    local statusCorner = Instance.new("UICorner")
    statusCorner.CornerRadius = UDim.new(0, 7)
    statusCorner.Parent = Runtime.EggAutomation.UI.StatusLabel
    local statusPadding = Instance.new("UIPadding")
    statusPadding.PaddingLeft = UDim.new(0, 8)
    statusPadding.PaddingRight = UDim.new(0, 8)
    statusPadding.PaddingTop = UDim.new(0, 6)
    statusPadding.Parent = Runtime.EggAutomation.UI.StatusLabel

    Runtime.EggAutomation.UI.AutoPlaceBtn.Activated:Connect(function()
        if EggAutoState.AutoPlace then
            Runtime.EggAutomation.StopAutoPlace()
            Runtime.EggAutomation.SetStatus("Auto Place stopped.", true)
        else
            Runtime.EggAutomation.StartAutoPlace()
            Runtime.EggAutomation.SetStatus("Auto Place armed. Only eggs enabled in the separate Auto Place filter can be selected; priority remains Luck > Rarity > KG.", true)
        end
    end)

    Runtime.EggAutomation.UI.AutoHatchBtn.Activated:Connect(function()
        if EggAutoState.AutoHatch then
            Runtime.EggAutomation.StopAutoHatch()
            Runtime.EggAutomation.SetStatus("Auto Hatch stopped.", true)
        else
            Runtime.EggAutomation.StartAutoHatch()
            Runtime.EggAutomation.SetStatus("Auto Hatch armed. It will hatch only ready placed eggs enabled in the separate Auto Hatch filter.", true)
        end
    end)

    Runtime.EggAutomation.UI.PriorityBtn.Activated:Connect(function()
        EggAutoState.PriorityEnabled = true
        Runtime.EggAutomation.RefreshButtons()
        Runtime.EggAutomation.SetStatus("Priority is fixed: highest Luck first, then rarity, then highest KG.", true)
    end)

    PlaceNowBtn.Activated:Connect(function()
        task.spawn(function()
            if not Runtime.EggAutomation.AnyEggNameFilterEnabled(EggAutoState.PlaceEggFilters) then
                Runtime.EggAutomation.SetStatus("Select at least one egg in the Auto Place filter.", false)
                return
            end
            local success, message = Runtime.EggAutomation.PlaceBestOnce({RequireHome = true, RanchSnapshot = Runtime.EggAutomation.GetRanchSnapshot(true), ForceBagScan = true})
            Runtime.EggAutomation.SetStatus(message, success ~= false)
        end)
    end)

    HatchNowBtn.Activated:Connect(function()
        task.spawn(function()
            if not Runtime.EggAutomation.AnyEggNameFilterEnabled(EggAutoState.HatchEggFilters) then
                Runtime.EggAutomation.SetStatus("Select at least one egg in the Auto Hatch filter.", false)
                return
            end
            local success, message = Runtime.EggAutomation.HatchReadyOnce({RanchSnapshot = Runtime.EggAutomation.GetRanchSnapshot(true)})
            Runtime.EggAutomation.SetStatus(message, success ~= false)
        end)
    end)

    Runtime.EggAutomation.ApplyFilterCollapseLayout = function()
        local ui = Runtime.EggAutomation.UI
        local mobile = isMobileMode
        local placeY = mobile and 225 or 178
        local searchH = mobile and 25 or 26
        local expandedH = mobile and 160 or 161
        local collapsedH = 28
        ui.PlaceFilterTitle.Position = UDim2.new(0,0,0,placeY)
        ui.PlaceFilterTitle.Size = UDim2.new(1,-214,0,18)
        ui.PlaceFilterHide.Position = UDim2.new(1,-210,0,placeY)
        ui.PlaceFilterHide.Text = ui.PlaceFilterCollapsed and "Show" or "Hide"
        ui.PlaceFilterSearch.Visible = not ui.PlaceFilterCollapsed
        ui.PlaceFilterScroll.Visible = not ui.PlaceFilterCollapsed
        ui.PlaceFilterSearch.Position = UDim2.new(0,0,0,placeY+21)
        ui.PlaceFilterSearch.Size = UDim2.new(1,mobile and -6 or -2,0,searchH)
        ui.PlaceFilterScroll.Position = UDim2.new(0,0,0,placeY+52)
        ui.PlaceFilterScroll.Size = UDim2.new(1,mobile and -6 or -2,0,100)
        local hatchY = placeY + (ui.PlaceFilterCollapsed and collapsedH or expandedH)
        ui.HatchFilterTitle.Position = UDim2.new(0,0,0,hatchY)
        ui.HatchFilterTitle.Size = UDim2.new(1,-72,0,18)
        ui.HatchFilterHide.Position = UDim2.new(1,-64,0,hatchY)
        ui.HatchFilterHide.Text = ui.HatchFilterCollapsed and "Show" or "Hide"
        ui.HatchFilterSearch.Visible = not ui.HatchFilterCollapsed
        ui.HatchFilterScroll.Visible = not ui.HatchFilterCollapsed
        ui.HatchFilterSearch.Position = UDim2.new(0,0,0,hatchY+21)
        ui.HatchFilterSearch.Size = UDim2.new(1,mobile and -6 or -2,0,searchH)
        ui.HatchFilterScroll.Position = UDim2.new(0,0,0,hatchY+52)
        ui.HatchFilterScroll.Size = UDim2.new(1,mobile and -6 or -2,0,100)
        local afterFilters = hatchY + (ui.HatchFilterCollapsed and collapsedH or expandedH) + 8
        if mobile then
            ui.PlaceNowBtn.Position = UDim2.new(0,0,0,afterFilters)
            ui.HatchNowBtn.Position = UDim2.new(0,0,0,afterFilters+34)
            ui.StatusLabel.Position = UDim2.new(0,0,0,afterFilters+70)
            Runtime.UIRegs.AutomationPage.CanvasSize = UDim2.new(0,0,0,afterFilters+180)
        else
            ui.PlaceNowBtn.Position = UDim2.new(0,0,0,afterFilters)
            ui.HatchNowBtn.Position = UDim2.new(0.5,5,0,afterFilters)
            ui.StatusLabel.Position = UDim2.new(0,0,0,afterFilters+36)
            Runtime.UIRegs.AutomationPage.CanvasSize = UDim2.new(0,0,0,afterFilters+125)
        end
        Runtime.Weight.LayoutPlace()
    end
    Runtime.EggAutomation.UI.PlaceFilterHide.Activated:Connect(function()
        Runtime.EggAutomation.UI.PlaceFilterCollapsed = not Runtime.EggAutomation.UI.PlaceFilterCollapsed
        Runtime.EggAutomation.ApplyFilterCollapseLayout()
    end)
    Runtime.EggAutomation.UI.HatchFilterHide.Activated:Connect(function()
        Runtime.EggAutomation.UI.HatchFilterCollapsed = not Runtime.EggAutomation.UI.HatchFilterCollapsed
        Runtime.EggAutomation.ApplyFilterCollapseLayout()
    end)

    Runtime.EggAutomation.RefreshButtons()
    Runtime.EggAutomation.ApplyFilterCollapseLayout()
end

--==================================================
-- SETTINGS: AUTO RECONNECT + AUTO EXECUTE AFTER TELEPORT/HOP
-- Event-driven: no polling while connected. Auto Execute uses the executor's
-- teleport queue only when supported and loads the cached local autorun file.
--==================================================
do
    local transport = Runtime.Transport
    local TeleportService = game:GetService("TeleportService")

    local function getExecutorEnv()
        return (getgenv and getgenv()) or _G
    end

    function transport.GetQueueFunction()
        local env = getExecutorEnv()

        local candidates = {
            rawget(env, "queue_on_teleport"),
            rawget(env, "queueonteleport"),
            rawget(env, "queueteleport"),
            rawget(_G, "queue_on_teleport"),
            rawget(_G, "queueonteleport"),
            rawget(_G, "queueteleport"),
        }

        for _, candidate in ipairs(candidates) do
            if type(candidate) == "function" then
                return candidate
            end
        end

        for _, namespace in ipairs({
            rawget(env, "syn"),
            rawget(_G, "syn"),
            rawget(env, "fluxus"),
            rawget(_G, "fluxus"),
        }) do
            if type(namespace) == "table" then
                local fn = namespace.queue_on_teleport
                    or namespace.queueonteleport
                    or namespace.queueteleport
                if type(fn) == "function" then
                    return fn
                end
            end
        end

        return nil
    end

    function transport.GetClearQueueFunction()
        local env = getExecutorEnv()

        local candidates = {
            rawget(env, "clearqueueonteleport"),
            rawget(env, "clearteleportqueue"),
            rawget(env, "clear_teleport_queue"),
            rawget(env, "clear_tp_queue"),
            rawget(env, "cleartpqueue"),
            rawget(_G, "clearqueueonteleport"),
            rawget(_G, "clearteleportqueue"),
            rawget(_G, "clear_teleport_queue"),
            rawget(_G, "clear_tp_queue"),
            rawget(_G, "cleartpqueue"),
        }

        for _, candidate in ipairs(candidates) do
            if type(candidate) == "function" then
                return candidate
            end
        end

        for _, namespace in ipairs({
            rawget(env, "syn"),
            rawget(_G, "syn"),
            rawget(env, "fluxus"),
            rawget(_G, "fluxus"),
        }) do
            if type(namespace) == "table" then
                local fn = namespace.clearqueueonteleport
                    or namespace.clearteleportqueue
                    or namespace.clear_teleport_queue
                    or namespace.clear_tp_queue
                    or namespace.cleartpqueue
                if type(fn) == "function" then
                    return fn
                end
            end
        end

        return nil
    end

    function transport.ClearTeleportQueue()
        local clearFunction = transport.GetClearQueueFunction()
        if not clearFunction then
            transport.LastQueueClearSupported = false
            return false, "clear queue unsupported"
        end

        local ok, err = pcall(clearFunction)
        transport.LastQueueClearSupported = true
        transport.LastQueueClearOk = ok == true
        transport.LastQueueClearError = ok and nil or tostring(err)

        if ok then
            transport.QueueArmed = false
            return true, "cleared"
        end

        return false, tostring(err)
    end

    function transport.SetTeleportFlag(key, value)
        pcall(function()
            TeleportService:SetTeleportSetting(key, value == true)
        end)
    end

    function transport.ReadTeleportFlag(key)
        local ok, value = pcall(function()
            return TeleportService:GetTeleportSetting(key)
        end)
        if not ok or type(value) ~= "boolean" then return nil end
        return value
    end

    Runtime.F8DebugEnabled =
        transport.ReadTeleportFlag("ZoloEggsESP_DebugEnabled") == true

    function transport.NewRejoinNonce()
        local nonce = nil
        pcall(function()
            nonce = game:GetService("HttpService"):GenerateGUID(false)
        end)

        if type(nonce) ~= "string" or nonce == "" then
            nonce = tostring(os.clock())
                .. ":"
                .. tostring(math.random(100000, 999999))
                .. ":"
                .. tostring(Runtime.BootGeneration or 0)
        end

        pcall(function()
            TeleportService:SetTeleportSetting(
                "ZoloEggsESP_RejoinNonce",
                nonce
            )
        end)

        transport.ActiveRejoinNonce = nonce
        return nonce
    end

    function transport.DisconnectTeleportWatch()
        if transport.TeleportWatch then
            pcall(function()
                transport.TeleportWatch:Disconnect()
            end)
            transport.TeleportWatch = nil
        end
    end

    function transport.FinishRejoin(reason)
        if Runtime.F8DebugEnabled and reason then
            print("[ZOLO REJOIN MACHINE] finish | " .. tostring(reason))
        end

        transport.DisconnectTeleportWatch()
        transport.ActiveRejoin = nil
        transport.ReconnectBusy = false
        transport.QueueArmed = false
    end

    function transport.GetRetryDelay(teleportResult)
        if teleportResult == Enum.TeleportResult.Flooded then
            return 15
        end
        if teleportResult == Enum.TeleportResult.Failure then
            return 1
        end
        return nil
    end

    function transport.InstallJITQueue()
        local active = transport.ActiveRejoin
        if not active then
            return false, "no active rejoin"
        end
        if active.QueueInstalled then
            return true, "already installed"
        end

        -- Installs one fresh loader after clearing any executor teleport queue
        -- entries. On executors with a clear-queue API this may run immediately
        -- before Teleport(); otherwise OnTeleport.Started/InProgress can call it
        -- as a fallback.
        local armed, armReason = transport.ArmQueue(true)
        if not armed then
            active.QueueError = tostring(armReason)
            RuntimeEnv.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
                "teleport queue install failed: " .. tostring(armReason)
            return false, armReason
        end

        active.QueueInstalled = true
        active.QueueInstalledAt = os.clock()

        if Runtime.F8DebugEnabled then
            print(
                "[ZOLO REJOIN MACHINE] loader installed"
                .. " | attempt=" .. tostring(active.Attempts)
                .. " | nonce=" .. tostring(active.Nonce)
                .. " | mode=" .. tostring(armReason)
            )
        end

        return true, armReason
    end

    function transport.RequestRejoinAttempt()
        local active = transport.ActiveRejoin
        if not active then
            return false, "no active rejoin"
        end

        if active.Attempts >= active.MaxAttempts then
            local reason = "retry limit reached (" .. tostring(active.MaxAttempts) .. ")"
            RuntimeEnv.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR = "Rejoin: " .. reason
            transport.FinishRejoin(reason)
            return false, reason
        end

        active.Attempts = active.Attempts + 1
        active.QueueInstalled = false
        active.QueueError = nil

        if Runtime.F8DebugEnabled then
            print(
                "[ZOLO REJOIN MACHINE] request teleport"
                .. " | attempt=" .. tostring(active.Attempts)
                .. "/" .. tostring(active.MaxAttempts)
                .. " | nonce=" .. tostring(active.Nonce)
            )
        end

        -- HYBRID PREQUEUE.
        -- Your executor exposes a teleport-queue clear API, so we can safely
        -- clear accumulated entries and install exactly ONE fresh loader before
        -- Teleport(). This does not depend on Player.OnTeleport.Started firing.
        if transport.State.AutoExecute
            and transport.GetClearQueueFunction() ~= nil
            and not active.QueueInstalled then

            local armed, armReason = transport.InstallJITQueue()
            if not armed then
                RuntimeEnv.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
                    "pre-teleport loader install failed: " .. tostring(armReason)

                if Runtime.F8DebugEnabled then
                    print(
                        "[ZOLO REJOIN MACHINE] prequeue failed | "
                        .. tostring(armReason)
                    )
                end

                transport.FinishRejoin("prequeue failed")
                return false, tostring(armReason)
            end

            if Runtime.F8DebugEnabled then
                print(
                    "[ZOLO REJOIN MACHINE] prequeue ready"
                    .. " | attempt=" .. tostring(active.Attempts)
                )
            end
        end

        local ok, teleportError = pcall(function()
            -- Client executor context cannot use server-only TeleportAsync().
            -- Teleport() is the available client-side same-place rejoin.
            TeleportService:Teleport(game.PlaceId, LocalPlayer)
        end)

        if ok then
            return true, "teleport requested"
        end

        active.QueueInstalled = false
        transport.QueueArmed = false

        local err = tostring(teleportError)
        RuntimeEnv.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
            "Teleport call failed: " .. err

        if Runtime.F8DebugEnabled then
            print("[ZOLO REJOIN MACHINE] synchronous teleport failure | " .. err)
        end

        if active.Attempts < active.MaxAttempts then
            task.delay(1, function()
                if Runtime.Alive and transport.ActiveRejoin == active then
                    transport.RequestRejoinAttempt()
                end
            end)
            return true, "retry scheduled"
        end

        transport.FinishRejoin("synchronous teleport failure")
        return false, err
    end

    function transport.Rejoin(reason)
        if transport.ActiveRejoin then
            return false, "rejoin already active"
        end

        if transport.State.AutoExecute then
            local supported, supportReason = transport.CanAutoExecute()
            if not supported then
                return false, "auto-execute unavailable: " .. tostring(supportReason)
            end
        end

        local nonce = transport.NewRejoinNonce()

        transport.ActiveRejoin = {
            Nonce = nonce,
            Reason = tostring(reason or "manual"),
            Attempts = 0,
            MaxAttempts = 5,
            QueueInstalled = false,
            StartedAt = os.clock(),
        }

        transport.ReconnectBusy = true
        transport.DisconnectTeleportWatch()

        -- JIT QUEUE: wait until Roblox confirms the teleport lifecycle started.
        -- This avoids leaving loaders queued when a Teleport() call never starts.
        transport.TeleportWatch = LocalPlayer.OnTeleport:Connect(function(state)
            local active = transport.ActiveRejoin
            if not active then
                return
            end

            if Runtime.F8DebugEnabled then
                print(
                    "[ZOLO REJOIN STATE] " .. tostring(state)
                    .. " | attempt=" .. tostring(active.Attempts)
                )
            end

            if state == Enum.TeleportState.Started then
                local armed, armReason = transport.InstallJITQueue()
                if not armed and Runtime.F8DebugEnabled then
                    print(
                        "[ZOLO REJOIN MACHINE] fallback queue failed | "
                        .. tostring(armReason)
                    )
                end

            elseif state == Enum.TeleportState.InProgress then
                -- Fallback for executors/experiences that skipped our Started
                -- callback. Public open-source loaders also successfully queue
                -- at InProgress.
                if not active.QueueInstalled then
                    transport.InstallJITQueue()
                end

                RuntimeEnv[RuntimeKey] = nil

            elseif state == Enum.TeleportState.Failed then
                active.QueueInstalled = false
                transport.QueueArmed = false
            end
        end)

        Runtime.DebugTeleport("REJOIN", "Rejoining current place", {
            reason = transport.ActiveRejoin.Reason,
            placeId = game.PlaceId,
            fromJob = tostring(game.JobId or ""),
            build = tostring(Runtime.BuildID or "unknown"),
            nonce = tostring(nonce),
            policy = "hybrid prequeue + clear + nonce + bounded retry",
        })

        return transport.RequestRejoinAttempt()
    end

    -- Roblox documents TeleportInitFailed for a teleport that started but left
    -- the player in the current server. Retry only transient Failure/Flooded
    -- results, with a bounded attempt count. Crucially: do NOT queue here.
    -- The next OnTeleport.Started event clears/replaces the queue just-in-time.
    trackRuntimeConnection(TeleportService.TeleportInitFailed:Connect(function(
        player,
        teleportResult,
        errorMessage,
        placeId,
        teleportOptions
    )
        if player ~= LocalPlayer then
            return
        end

        local active = transport.ActiveRejoin
        if not active then
            transport.ReconnectBusy = false
            return
        end

        active.QueueInstalled = false
        transport.QueueArmed = false

        RuntimeEnv.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
            "TeleportInitFailed ["
            .. tostring(teleportResult)
            .. "]: "
            .. tostring(errorMessage)

        local retryDelay = transport.GetRetryDelay(teleportResult)

        if Runtime.F8DebugEnabled then
            print(
                "[ZOLO REJOIN MACHINE] TeleportInitFailed"
                .. " | result=" .. tostring(teleportResult)
                .. " | attempt=" .. tostring(active.Attempts)
                .. " | retryIn=" .. tostring(retryDelay)
                .. " | message=" .. tostring(errorMessage)
            )
        end

        if retryDelay and active.Attempts < active.MaxAttempts then
            task.delay(retryDelay, function()
                if Runtime.Alive and transport.ActiveRejoin == active then
                    transport.RequestRejoinAttempt()
                end
            end)
            return
        end

        if StatusLabel then
            StatusLabel.Text =
                "● Rejoin failed: "
                .. tostring(teleportResult)
                .. " — "
                .. tostring(errorMessage)
            StatusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
        end

        transport.FinishRejoin(
            "TeleportInitFailed: " .. tostring(teleportResult)
        )
    end))

    function transport.GetRemoteReleaseURL()
        local env = getExecutorEnv()

        local url = tostring(
            transport.RemoteReleaseURL
            or rawget(env, "__ZOLO_REMOTE_RELEASE_URL")
            or ""
        )

        if url ~= "" and not url:find("PASTE_", 1, true) then
            transport.RemoteReleaseURL = url
            env.__ZOLO_REMOTE_RELEASE_URL = url
            return url
        end

        local okSetting, saved = pcall(function()
            return TeleportService:GetTeleportSetting(
                "ZoloEggsESP_RemoteReleaseURL"
            )
        end)

        if okSetting and type(saved) == "string"
            and saved ~= ""
            and not saved:find("PASTE_", 1, true) then
            transport.RemoteReleaseURL = saved
            env.__ZOLO_REMOTE_RELEASE_URL = saved
            return saved
        end

        return nil
    end

    function transport.CanAutoExecute()
        if not transport.GetQueueFunction() then
            return false, "queue_on_teleport unsupported"
        end

        local url = transport.GetRemoteReleaseURL()
        if not url then
            return false, "remote release URL not configured"
        end

        return true, "ready:remote"
    end

    function transport.ArmQueue(force)
        if not transport.State.AutoExecute then
            return false, "Auto Execute is OFF"
        end
        if transport.QueueArmed and force ~= true then
            return true, "already armed"
        end

        local queueFunction = transport.GetQueueFunction()
        if not queueFunction then
            return false, "queue_on_teleport unsupported"
        end

        local url = transport.GetRemoteReleaseURL()
        if not url then
            return false,
                "remote release URL missing; use the provided main.lua loader"
        end

        -- Roblox TeleportSettings are explicitly designed to persist client-side
        -- values across teleports in the same game. Store the tiny loader's URL
        -- there instead of embedding the ~700 KB ZOLO source in queue_on_teleport.
        local settingOk = pcall(function()
            TeleportService:SetTeleportSetting(
                "ZoloEggsESP_RemoteReleaseURL",
                url
            )
        end)

        if not settingOk then
            return false, "failed to save remote release URL"
        end

        -- Prefer clearing the executor's teleport queue before adding the new
        -- loader. Some executors append queue_on_teleport entries indefinitely;
        -- without this, repeated auto-rejoins can accumulate old loaders.
        local cleared, clearReason = transport.ClearTeleportQueue()
        if Runtime.F8DebugEnabled then
            if cleared then
                print("[ZOLO QUEUE] cleared old teleport queue")
            else
                print("[ZOLO QUEUE] clear unavailable/failed: " .. tostring(clearReason))
                print("[ZOLO QUEUE] nonce duplicate suppression remains active")
            end
        end

        -- Keep this payload intentionally small. Public executor queue APIs are
        -- designed to queue source strings after teleport; a tiny remote loader
        -- is far less fragile than carrying the entire ZOLO source.
        local payload = [=[
local env = (getgenv and getgenv()) or _G
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local debugEnabled = false
pcall(function()
    debugEnabled =
        TeleportService:GetTeleportSetting("ZoloEggsESP_DebugEnabled") == true
end)

local function dlog(message)
    if debugEnabled then
        print("[ZOLO REJOIN DEBUG] " .. tostring(message))
    end
end

-- DUPLICATE-QUEUE KILL SWITCH.
-- queue_on_teleport is append-only on some executors. Every retained copy reads
-- the same per-rejoin nonce. getgenv is shared by those copies, so only the
-- first loader claims the nonce; all later copies exit before touching UI/state.
local rejoinNonce = nil
pcall(function()
    rejoinNonce =
        TeleportService:GetTeleportSetting("ZoloEggsESP_RejoinNonce")
end)

if type(rejoinNonce) ~= "string" or rejoinNonce == "" then
    rejoinNonce = "legacy:" .. tostring(game.JobId)
end

if env.__ZOLO_EGGS_ESP_CLAIMED_REJOIN_NONCE == rejoinNonce then
    dlog("duplicate queued loader suppressed | nonce=" .. tostring(rejoinNonce))
    return
end

env.__ZOLO_EGGS_ESP_CLAIMED_REJOIN_NONCE = rejoinNonce
dlog(
    "queued loader claimed"
    .. " | job=" .. tostring(game.JobId)
    .. " | nonce=" .. tostring(rejoinNonce)
)

local allow = true
pcall(function()
    if TeleportService:GetTeleportSetting("ZoloEggsESP_AutoExecute") == false then
        allow = false
    end
end)
if not allow then
    return
end

if not game:IsLoaded() then
    pcall(function()
        game.Loaded:Wait()
    end)
end
dlog("game loaded")

-- Wait for the destination client to be genuinely usable.
local readyDeadline = os.clock() + 90
local stable = 0
local player = nil

while os.clock() < readyDeadline do
    player = Players.LocalPlayer

    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    local mainGui = playerGui and playerGui:FindFirstChild("Main")
    local character = player and player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local remotes = ReplicatedStorage:FindFirstChild("Remotes")
    local camera = Workspace.CurrentCamera

    local ready = game:IsLoaded()
        and player ~= nil
        and playerGui ~= nil
        and mainGui ~= nil
        and character ~= nil
        and humanoid ~= nil
        and humanoid.Health > 0
        and root ~= nil
        and root:IsDescendantOf(Workspace)
        and remotes ~= nil
        and camera ~= nil

    if ready then
        stable = stable + 1
        if stable >= 10 then
            break
        end
    else
        stable = 0
    end

    task.wait(0.10)
end

if stable < 10 then
    env.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
        "queued boot: destination client never became stable"
    dlog("FAILED: destination client never became stable")
    warn("[ZOLO queued boot] destination client never became stable")
    return
end

dlog("client ready | player/gui/character/remotes/camera stable")

local url = nil
pcall(function()
    url = TeleportService:GetTeleportSetting(
        "ZoloEggsESP_RemoteReleaseURL"
    )
end)

if type(url) ~= "string" or url == "" then
    env.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
        "queued boot: remote release URL missing"
    warn("[ZOLO queued boot] remote release URL missing")
    return
end

env.__ZOLO_REMOTE_RELEASE_URL = url
dlog("release URL restored")

-- HARD-FRESH REJOIN RESET.
-- Some executors preserve getgenv() across teleport. Never trust a Runtime/UI
-- object from the previous DataModel. Clean it if possible, then remove the
-- registry and stale ZOLO ScreenGuis before loading the fresh release.
do
    local existing = env.__ZOLO_EGGS_ESP_RUNTIME

    if type(existing) == "table" then
        existing.Alive = false
        if type(existing.Cleanup) == "function" then
            pcall(existing.Cleanup, "post-rejoin-hard-reset")
        end
    end

    env.__ZOLO_EGGS_ESP_RUNTIME = nil
    env.__ZOLO_EGGS_ESP_QUEUED_BOOT = nil

    local playerGui = player and player:FindFirstChildOfClass("PlayerGui")
    if playerGui then
        for _, guiName in ipairs({
            "RenderedEggsESP_Menu",
            "Zolo_ESP_LocalPlayer_Notifications",
            "Zolo_BFroot_ESP_GetDrop",
            "Zolo_BFroot_ESP_F8DropDebug",
            "Zolo_BFroot_ESP_AutoDrop",
            "Zolo_BFroot_ESP_DropEggQ",
            "Zolo_BFroot_ESP_DropEgg",
            "Zolo_BFroot_ESP_DropEgg_Button",
        }) do
            local stale = playerGui:FindFirstChild(guiName)
            if stale then
                pcall(function()
                    stale:Destroy()
                end)
            end
        end
    end
end

dlog("stale runtime/UI cleared")

-- Give the executor/new DataModel a little extra settle time after the hard reset.
task.wait(1.00)

-- Retry the network fetch because Roblox/executor HTTP can become available a
-- little later than PlayerGui/character after a reconnect.
local source = nil
local fetchError = nil
local fetchDeadline = os.clock() + 30

while os.clock() < fetchDeadline do
    local okFetch, body = pcall(function()
        return game:HttpGet(url)
    end)

    if okFetch and type(body) == "string" and body ~= "" then
        source = body
        dlog("release downloaded")
        break
    end

    fetchError = body
    task.wait(0.50)
end

if not source then
    env.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
        "queued HttpGet failed: " .. tostring(fetchError)
    warn("[ZOLO queued boot] HttpGet failed: " .. tostring(fetchError))
    return
end

if type(loadstring) ~= "function" then
    env.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
        "queued boot: loadstring unavailable"
    warn("[ZOLO queued boot] loadstring unavailable")
    return
end

local chunk, compileError = loadstring(source)
if not chunk then
    env.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
        "queued compile: " .. tostring(compileError)
    warn("[ZOLO queued boot] compile failed: " .. tostring(compileError))
    return
end

dlog("release compiled")
env.__ZOLO_EGGS_ESP_QUEUED_BOOT = true
dlog("starting fresh ZOLO runtime")

local okRun, runError = xpcall(chunk, function(err)
    local okTrace, trace = pcall(function()
        return debug.traceback(tostring(err), 2)
    end)
    return okTrace and trace or tostring(err)
end)

if not okRun then
    env.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR = tostring(runError)
    env.__ZOLO_EGGS_ESP_QUEUED_BOOT = nil
    dlog("FAILED: runtime error | " .. tostring(runError))
    warn("[ZOLO queued boot] " .. tostring(runError))
else
    dlog("runtime returned without queue error")
end
]=]

        local ok, queueError = pcall(queueFunction, payload)
        transport.QueueArmed = ok == true

        if not transport.QueueArmed then
            RuntimeEnv.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
                "queue_on_teleport failed: " .. tostring(queueError)
            return false, tostring(queueError)
        end

        return true, cleared and "queued:remote:cleared" or "queued:remote:nonce-fallback"
    end

    function transport.RefreshButtons()
        local reconnectBtn = transport.UI.AutoReconnect
        if reconnectBtn then
            reconnectBtn.Text = "Auto Reconnect: " .. (transport.State.AutoReconnect and "ON" or "OFF")
            reconnectBtn.BackgroundColor3 = transport.State.AutoReconnect
                and Color3.fromRGB(0, 130, 75)
                or Color3.fromRGB(45, 52, 64)
        end

        local executeBtn = transport.UI.AutoExecute
        if executeBtn then
            local supported = transport.CanAutoExecute()
            if transport.State.AutoExecute and supported then
                executeBtn.Text = "Auto Execute After Rejoin: ON"
                executeBtn.BackgroundColor3 = Color3.fromRGB(0, 120, 170)
            elseif transport.State.AutoExecute then
                executeBtn.Text = "Auto Execute After Rejoin: UNSUPPORTED"
                executeBtn.BackgroundColor3 = Color3.fromRGB(120, 70, 30)
            else
                executeBtn.Text = "Auto Execute After Rejoin: OFF"
                executeBtn.BackgroundColor3 = Color3.fromRGB(45, 52, 64)
            end
        end
    end

    function transport.DisconnectPromptListener()
        if transport.PromptConnection then
            pcall(function()
                transport.PromptConnection:Disconnect()
            end)
            transport.PromptConnection = nil
        end
    end

    function transport.TryReconnect(prompt)
        if transport.ReconnectBusy
            or transport.ActiveRejoin
            or not transport.State.AutoReconnect then
            return
        end

        transport.ReconnectBusy = true
        task.spawn(function()
            task.wait(0.65)

            if not Runtime.Alive or not transport.State.AutoReconnect then
                transport.ReconnectBusy = false
                return
            end

            if prompt and not prompt.Parent then
                transport.ReconnectBusy = false
                return
            end

            local ok, reason = transport.Rejoin("disconnect-error-prompt")
            if not ok then
                transport.ReconnectBusy = false
                Runtime.DebugTeleport("RECONNECT", "Rejoin machine rejected", {
                    reason = tostring(reason),
                })
            end
        end)
    end

    function transport.HandlePrompt(prompt)
        if not transport.State.AutoReconnect or not prompt then
            return
        end
        if prompt.Name == "ErrorPrompt" then
            transport.TryReconnect(prompt)
        end
    end

    function transport.StartPromptListener()
        transport.DisconnectPromptListener()
        if not transport.State.AutoReconnect then
            return
        end

        task.spawn(function()
            local promptGui = CoreGui:FindFirstChild("RobloxPromptGui")
                or CoreGui:WaitForChild("RobloxPromptGui", 12)
            if not Runtime.Alive or not transport.State.AutoReconnect or not promptGui then
                return
            end

            local overlay = promptGui:FindFirstChild("promptOverlay")
                or promptGui:WaitForChild("promptOverlay", 6)
            if not Runtime.Alive or not transport.State.AutoReconnect or not overlay then
                return
            end

            transport.PromptConnection = overlay.ChildAdded:Connect(function(child)
                transport.HandlePrompt(child)
            end)

            for _, child in ipairs(overlay:GetChildren()) do
                if child.Name == "ErrorPrompt" then
                    transport.HandlePrompt(child)
                    break
                end
            end
        end)
    end

    function transport.SetAutoReconnect(enabled, quiet)
        transport.State.AutoReconnect = enabled == true
        transport.SetTeleportFlag("ZoloEggsESP_AutoReconnect", transport.State.AutoReconnect)

        if transport.State.AutoReconnect then
            transport.StartPromptListener()
        else
            transport.DisconnectPromptListener()
            transport.ReconnectBusy = false
        end

        transport.RefreshButtons()
        if not quiet and StatusLabel then
            StatusLabel.Text = transport.State.AutoReconnect
                and "● Auto Reconnect armed — runs only on a disconnect ErrorPrompt"
                or "● Auto Reconnect: OFF"
            StatusLabel.TextColor3 = transport.State.AutoReconnect
                and Color3.fromRGB(0, 255, 120)
                or Color3.fromRGB(180, 180, 180)
        end
    end

    function transport.SetAutoExecute(enabled, quiet)
        enabled = enabled == true
        if enabled then
            local supported, reason = transport.CanAutoExecute()
            if not supported then
                transport.State.AutoExecute = false
                transport.SetTeleportFlag("ZoloEggsESP_AutoExecute", false)
                transport.RefreshButtons()
                if not quiet and StatusLabel then
                    StatusLabel.Text = "● Auto Execute unavailable: " .. tostring(reason)
                    StatusLabel.TextColor3 = Color3.fromRGB(255, 150, 110)
                end
                return false
            end
        end

        transport.State.AutoExecute = enabled
        transport.SetTeleportFlag("ZoloEggsESP_AutoExecute", enabled)

        -- DO NOT queue merely because the toggle/config was loaded.
        -- The queue is registered exactly once by Rejoin() immediately before
        -- the actual teleport, after all resume state has been saved.
        transport.QueueArmed = false

        transport.RefreshButtons()
        if not quiet and StatusLabel then
            if enabled then
                StatusLabel.Text =
                    "● Auto Execute ready — loader queues only when rejoin starts"
                StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
            else
                StatusLabel.Text = "● Auto Execute After Rejoin: OFF"
                StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
            end
        end
        return true
    end

    function transport.Stop()
        transport.DisconnectPromptListener()
        transport.DisconnectTeleportWatch()
        transport.ActiveRejoin = nil
        transport.ReconnectBusy = false
        transport.QueueArmed = false
    end

    -- Preserve explicit teleport-carried switches. On a fresh/manual execution,
    -- Auto Reconnect and Auto Execute default ON as requested. Auto Execute falls
    -- back to OFF only when the executor does not provide a supported queue API.
    transport.CarriedReconnect = transport.ReadTeleportFlag("ZoloEggsESP_AutoReconnect")
    transport.CarriedExecute = transport.ReadTeleportFlag("ZoloEggsESP_AutoExecute")
    transport.State.AutoReconnect = transport.CarriedReconnect == nil and true or transport.CarriedReconnect
    transport.State.AutoExecute = transport.CarriedExecute == nil and true or transport.CarriedExecute

    transport.SetAutoReconnect(transport.State.AutoReconnect, true)
    transport.SetAutoExecute(transport.State.AutoExecute, true)
    transport.CarriedReconnect = nil
    transport.CarriedExecute = nil
end

-- Settings page.
do
local SettingsTitle = Instance.new("TextLabel")

SettingsTitle.Size = UDim2.new(1, 0, 0, 22)

SettingsTitle.BackgroundTransparency = 1

SettingsTitle.Text = "Controls"

SettingsTitle.TextColor3 = Color3.fromRGB(235, 240, 248)

SettingsTitle.TextSize = 14

SettingsTitle.Font = Enum.Font.SourceSansBold

SettingsTitle.TextXAlignment = Enum.TextXAlignment.Left

SettingsTitle.Parent = Runtime.UIRegs.SettingsPage
end

Runtime.UIRegs.KeybindBtn.Position = UDim2.new(0, 0, 0, 30)

local SettingsHint = Instance.new("TextLabel")

SettingsHint.Size = UDim2.new(1, 0, 0, 72)

SettingsHint.Position = UDim2.new(0, 0, 0, 214)

SettingsHint.BackgroundTransparency = 1

SettingsHint.Text = "Movement safety: upright assembly pivots, velocity clamp, serialized movement and noclip restore.\nAuto Get targets ONLY green TRUE filters. Place/Hatch ranks Luck > rarity > KG, uses strict same-level placement, and supports live Place prompts plus a verified held-tool activation fallback.\nTeleport debugger: use the Debug Logs button on mobile, or press F8 on PC, to toggle detailed Void/Tween/Egg-Auto console logs."

SettingsHint.TextWrapped = true

SettingsHint.TextColor3 = Color3.fromRGB(145, 158, 175)

SettingsHint.TextSize = 11

SettingsHint.Font = Enum.Font.SourceSans

SettingsHint.TextXAlignment = Enum.TextXAlignment.Left

SettingsHint.TextYAlignment = Enum.TextYAlignment.Top

SettingsHint.Parent = Runtime.UIRegs.SettingsPage

-- v3.47 RELIABLE ANTI-AFK + MOBILE-SAFE FALLBACK
-- Main source of truth: Roblox Player.Idled. Primary pulse uses VirtualUser's
-- camera-independent ClickButton2 form. A low-frequency watchdog repeats the
-- pulse before the normal idle threshold, and VirtualInputManager is only used
-- as a pcall-protected executor fallback when available.
do
    local anti = Runtime.AntiAFK

    anti.UI.Status = Instance.new("TextLabel")
    anti.UI.Status.Size = UDim2.new(1, 0, 0, 30)
    anti.UI.Status.Position = UDim2.new(0, 0, 0, 65)
    anti.UI.Status.BackgroundColor3 = Color3.fromRGB(16, 45, 31)
    anti.UI.Status.BackgroundTransparency = 0.08
    anti.UI.Status.BorderSizePixel = 0
    anti.UI.Status.TextColor3 = Color3.fromRGB(145, 255, 190)
    anti.UI.Status.TextSize = 10
    anti.UI.Status.Font = Enum.Font.SourceSansBold
    anti.UI.Status.Parent = Runtime.UIRegs.SettingsPage

    local AntiAFKCorner = Instance.new("UICorner")
    AntiAFKCorner.CornerRadius = UDim.new(0, 6)
    AntiAFKCorner.Parent = anti.UI.Status

    local virtualUser = nil
    local virtualInputManager = nil

    pcall(function()
        virtualUser = game:GetService("VirtualUser")
    end)

    pcall(function()
        virtualInputManager = game:GetService("VirtualInputManager")
    end)

    function anti.RefreshStatus()
        local label = anti.UI and anti.UI.Status
        if not label or not label.Parent then
            return
        end

        if not anti.Enabled then
            label.Text = "Anti-AFK: OFF"
            label.TextColor3 = Color3.fromRGB(255, 145, 120)
            return
        end

        label.Text = string.format(
            "Anti-AFK: ON | 90s Guard | Pulses %d | %s",
            tonumber(anti.TriggerCount) or 0,
            tostring(anti.LastMethod or "waiting")
        )
        label.TextColor3 = Color3.fromRGB(145, 255, 190)
    end

    function anti.Pulse(reason)
        if not Runtime.Alive or not anti.Enabled then
            return false, "disabled"
        end

        local methods = {}
        local success = false

        -- Preferred/common anti-idle path. ClickButton2 has a default camera value,
        -- so it cannot fail just because CurrentCamera is temporarily nil.
        if virtualUser then
            local ok = pcall(function()
                virtualUser:CaptureController()
                virtualUser:ClickButton2(Vector2.new(0, 0))
            end)
            if ok then
                success = true
                table.insert(methods, "VirtualUser")
            end
        end

        -- Executor fallback follows the active device. Mobile receives a tiny
        -- touch pulse in a quiet top-left gameplay point; desktop uses mouse delta.
        if virtualInputManager then
            local ok = false
            if Runtime.InputCompat.IsTouchPreferred() then
                local touchId = 99001 + ((anti.TriggerCount or 0) % 500)
                ok = pcall(function()
                    virtualInputManager:SendTouchEvent(
                        touchId, Enum.UserInputState.Begin.Value, 2, 2
                    )
                    task.wait(0.02)
                    virtualInputManager:SendTouchEvent(
                        touchId, Enum.UserInputState.End.Value, 2, 2
                    )
                end)
            else
                ok = pcall(function()
                    virtualInputManager:SendMouseMoveDeltaEvent(1, 0, game)
                    task.wait(0.02)
                    virtualInputManager:SendMouseMoveDeltaEvent(-1, 0, game)
                end)
            end
            if ok then
                success = true
                table.insert(methods, Runtime.InputCompat.IsTouchPreferred() and "VIM-Touch" or "VIM-Mouse")
            end
        end

        if success then
            anti.TriggerCount = (anti.TriggerCount or 0) + 1
            anti.LastPulseAt = os.clock()
            anti.LastReason = tostring(reason or "watchdog")
            anti.LastMethod = #methods > 0 and table.concat(methods, "+") or "pulse"
        else
            anti.LastReason = tostring(reason or "watchdog")
            anti.LastMethod = "UNSUPPORTED"
        end

        anti.RefreshStatus()
        Runtime.DebugTeleport("ANTI-AFK", success and "pulse sent" or "pulse failed", {
            reason = anti.LastReason,
            method = anti.LastMethod,
            count = anti.TriggerCount,
        })

        return success, anti.LastMethod
    end

    trackRuntimeConnection(LocalPlayer.Idled:Connect(function(idleSeconds)
        anti.Pulse("Player.Idled " .. tostring(math.floor(tonumber(idleSeconds) or 0)) .. "s")
    end))

    anti.Thread = task.spawn(function()
        while Runtime.Alive and anti.Enabled do
            task.wait(math.max(30, tonumber(anti.WatchdogInterval) or 90))
            if Runtime.Alive and anti.Enabled then
                anti.Pulse("90s watchdog")
            end
        end
        anti.Thread = nil
    end)

    -- One startup pulse verifies that at least one executor input path is usable.
    task.defer(function()
        if Runtime.Alive and anti.Enabled then
            anti.Pulse("startup test")
        end
    end)

    anti.RefreshStatus()
end

-- Auto Reconnect and Auto Execute are separate, saved switches.
do
    Runtime.Transport.UI.AutoReconnect = Instance.new("TextButton")
    Runtime.Transport.UI.AutoReconnect.Size = UDim2.new(1, 0, 0, 30)
    Runtime.Transport.UI.AutoReconnect.Position = UDim2.new(0, 0, 0, 102)
    Runtime.Transport.UI.AutoReconnect.BackgroundColor3 = Color3.fromRGB(45, 52, 64)
    Runtime.Transport.UI.AutoReconnect.BackgroundTransparency = 0.08
    Runtime.Transport.UI.AutoReconnect.BorderSizePixel = 0
    Runtime.Transport.UI.AutoReconnect.Text = "Auto Reconnect: ON"
    Runtime.Transport.UI.AutoReconnect.TextColor3 = Color3.fromRGB(225, 232, 242)
    Runtime.Transport.UI.AutoReconnect.TextSize = 10
    Runtime.Transport.UI.AutoReconnect.Font = Enum.Font.SourceSansBold
    Runtime.Transport.UI.AutoReconnect.Parent = Runtime.UIRegs.SettingsPage
    styleButton(Runtime.Transport.UI.AutoReconnect)

    Runtime.Transport.UI.AutoExecute = Instance.new("TextButton")
    Runtime.Transport.UI.AutoExecute.Size = UDim2.new(1, 0, 0, 30)
    Runtime.Transport.UI.AutoExecute.Position = UDim2.new(0, 0, 0, 139)
    Runtime.Transport.UI.AutoExecute.BackgroundColor3 = Color3.fromRGB(45, 52, 64)
    Runtime.Transport.UI.AutoExecute.BackgroundTransparency = 0.08
    Runtime.Transport.UI.AutoExecute.BorderSizePixel = 0
    Runtime.Transport.UI.AutoExecute.Text = "Auto Execute After Rejoin: ON"
    Runtime.Transport.UI.AutoExecute.TextColor3 = Color3.fromRGB(225, 232, 242)
    Runtime.Transport.UI.AutoExecute.TextSize = 10
    Runtime.Transport.UI.AutoExecute.Font = Enum.Font.SourceSansBold
    Runtime.Transport.UI.AutoExecute.Parent = Runtime.UIRegs.SettingsPage
    styleButton(Runtime.Transport.UI.AutoExecute)

    Runtime.Transport.UI.AutoReconnect.Activated:Connect(function()
        Runtime.Transport.SetAutoReconnect(not Runtime.Transport.State.AutoReconnect, false)
    end)

    Runtime.Transport.UI.AutoExecute.Activated:Connect(function()
        Runtime.Transport.SetAutoExecute(not Runtime.Transport.State.AutoExecute, false)
    end)

    Runtime.Transport.RefreshButtons()
end

-- Cross-platform debugger toggle. F8 remains available on desktop, but mobile
-- gets the same persistent debug-log state through a normal touch button.
do
    Runtime.TeleportDebug.UI = Runtime.TeleportDebug.UI or {}
    local debugBtn = Instance.new("TextButton")
    debugBtn.Name = "DebugLogsToggle"
    debugBtn.Size = UDim2.new(1, 0, 0, 30)
    debugBtn.Position = UDim2.new(0, 0, 0, 176)
    debugBtn.BackgroundColor3 = Color3.fromRGB(45, 52, 64)
    debugBtn.BackgroundTransparency = 0.08
    debugBtn.BorderSizePixel = 0
    debugBtn.TextColor3 = Color3.fromRGB(225, 232, 242)
    debugBtn.TextSize = 10
    debugBtn.Font = Enum.Font.SourceSansBold
    debugBtn.Parent = Runtime.UIRegs.SettingsPage
    styleButton(debugBtn)
    Runtime.TeleportDebug.UI.ToggleBtn = debugBtn

    local function refreshDebugButton()
        if not debugBtn or not debugBtn.Parent then return end
        debugBtn.Text = Runtime.TeleportDebug.Enabled and "Debug Logs: ON" or "Debug Logs: OFF"
        debugBtn.BackgroundColor3 = Runtime.TeleportDebug.Enabled
            and Color3.fromRGB(105, 75, 150)
            or Color3.fromRGB(45, 52, 64)
    end

    debugBtn.Activated:Connect(function()
        Runtime.TeleportDebug.Enabled = not Runtime.TeleportDebug.Enabled
        Runtime.TeleportDebug.Session = (Runtime.TeleportDebug.Session or 0) + 1
        refreshDebugButton()
        print(Runtime.TeleportDebug.Enabled
            and "========== AUTO GET + EGG AUTOMATION DEBUGGER: ON (UI) =========="
            or "========== AUTO GET + EGG AUTOMATION DEBUGGER: OFF (UI) ==========")
        if StatusLabel then
            StatusLabel.Text = Runtime.TeleportDebug.Enabled
                and "● Debug Logs: ON — reproduce the issue and check console"
                or "● Debug Logs: OFF"
            StatusLabel.TextColor3 = Runtime.TeleportDebug.Enabled
                and Color3.fromRGB(205, 170, 255)
                or Color3.fromRGB(180, 180, 180)
        end
    end)

    refreshDebugButton()
end

--==================================================
-- SETTINGS: CONFIG SAVE / LOAD / AUTO SAVE / AUTO LOAD
-- Inspired by the common JSON + autoload-marker pattern used by open-source
-- Roblox UI SaveManagers, but implemented locally for this script.
--==================================================
do
    local cm = {
        Folder = "ZoloEggsESP",
        ConfigFolder = "ZoloEggsESP/configs",
        MetaPath = "ZoloEggsESP/meta.json",
        IndexPath = "ZoloEggsESP/config_index.json",
        Profile = "default",
        Profiles = {},
        Meta = { AutoSave = false, AutoLoad = false },
        LastSerialized = nil,
        Available = type(writefile) == "function"
            and type(readfile) == "function"
            and type(isfile) == "function"
            and type(makefolder) == "function",
        DeleteFile = type(delfile) == "function" and delfile
            or (type(deletefile) == "function" and deletefile or nil),
        UI = {},
    }
    Runtime.ConfigManager = cm
    cm.HttpService = game:GetService("HttpService")

    -- Safe wrappers are important directly after teleport. Some executors expose
    -- their filesystem functions before those functions are actually ready.
    function cm:IsFile(path)
        if not self.Available or type(isfile) ~= "function" then
            return false
        end
        local ok, result = pcall(isfile, path)
        return ok and result == true
    end

    function cm:IsFolder(path)
        if type(isfolder) ~= "function" then
            return false
        end
        local ok, result = pcall(isfolder, path)
        return ok and result == true
    end

    function cm:SanitizeName(name)
        name = tostring(name or "default")
        name = name:gsub("[^%w_%-%s]", "")
        name = name:gsub("%s+", "_")
        if name == "" then
            name = "default"
        end
        return name:sub(1, 40)
    end

    function cm:EnsureFolders()
        if not self.Available then
            return false
        end
        pcall(function()
            if type(isfolder) == "function" and not self:IsFolder(self.Folder) then
                makefolder(self.Folder)
            elseif type(isfolder) ~= "function" then
                makefolder(self.Folder)
            end
        end)
        pcall(function()
            if type(isfolder) == "function" and not self:IsFolder(self.ConfigFolder) then
                makefolder(self.ConfigFolder)
            elseif type(isfolder) ~= "function" then
                makefolder(self.ConfigFolder)
            end
        end)
        return true
    end

    function cm:GetState()
        local filters = {}
        for name, enabled in pairs(autoFarmEggs) do
            if enabled == true then
                table.insert(filters, name)
            end
        end
        table.sort(filters)

        return {
            Version = 16,
            ESPFilter = {AllEggs=Runtime.ESPFilter.AllEggs, Eggs=Runtime.ESPFilter.Eggs},
            GetMinWeightKg = Runtime.AutoGet.MinWeightKg,
            RejoinBelowMin = Runtime.AutoGet.RejoinBelowMin.Enabled == true,
            PlaceMinWeightKg = EggAutoState.PlaceMinWeightKg,
            PickupDelay = Runtime.AutoGet.PickupDelay,
            PickupMethod = Runtime.AutoGet.PickupMethod,
            TravelMode = Runtime.AutoGet.TravelMode,
            Filters = filters,
            AvailableEggsHidden = Runtime.UIRegs.availableEggsHidden == true,
            ESPEnabled = mainESPActive == true,
            AutoBestEgg = autoBestEggActive == true,
            AutoHatchLuck = autoHatchLuckActive == true,
            SilenceLuckUpgradeAlert = Runtime.LuckAlertSilencer.Enabled == true,
            AutoReconnect = Runtime.Transport.State.AutoReconnect == true,
            AutoExecuteAfterTeleport = Runtime.Transport.State.AutoExecute == true,
            AutoPlaceEggs = EggAutoState.AutoPlace == true,
            AutoHatchEggs = EggAutoState.AutoHatch == true,
            AutoFeedPets = Runtime.AutoFeed.Enabled == true,
            AutoFeedMinAge = clampWholeAutoFeedAge(Runtime.AutoFeed.MinAge),
            EggPriority = true,
            EggNameFilterVersion = 1,
            EggPlaceFilters = EggAutoState.PlaceEggFilters,
            EggHatchFilters = EggAutoState.HatchEggFilters,
            -- Legacy fields retained so downgrading to an older build does not crash.
            EggRarityFilterVersion = 2,
            EggRarityFilters = EggAutoState.RarityFilters,
            EggPlacementMemory = Runtime.EggAutomation.PlacementMemory,
            EggNestOwners = Runtime.EggAutomation.NestOwners,
            GetEgg = autoFarmActive == true,
            EggMode = Runtime.AutoGet.ModeSelector and Runtime.AutoGet.ModeSelector.Selected or "GetEgg",
            TargetRanchActive = Runtime.AutoGet.TargetRanch and Runtime.AutoGet.TargetRanch.Active == true,
            TargetRanchUserId = Runtime.AutoGet.TargetRanch and Runtime.AutoGet.TargetRanch.TargetUserId or nil,
            SortMode = sortMode,
            TPKeybind = tpKeybind and tpKeybind.Name or "T",
            CurrentTab = Runtime.UIRegs.currentTab,
        }
    end

    function cm:Encode(value)
        local ok, encoded = pcall(function()
            return self.HttpService:JSONEncode(value)
        end)
        if ok then
            return encoded
        end
        return nil
    end

    function cm:Decode(raw)
        local ok, decoded = pcall(function()
            return self.HttpService:JSONDecode(raw)
        end)
        if ok and type(decoded) == "table" then
            return decoded
        end
        return nil
    end

    function cm:SetStatus(text, good)
        if self.UI.Status and self.UI.Status.Parent then
            self.UI.Status.Text = tostring(text)
            self.UI.Status.TextColor3 = good == false
                and Color3.fromRGB(255, 145, 120)
                or Color3.fromRGB(160, 220, 190)
        end
    end

    function cm:ProfileExists(name)
        name = self:SanitizeName(name)
        for _, existing in ipairs(self.Profiles) do
            if existing == name then
                return true
            end
        end
        return false
    end

    function cm:SaveIndex()
        if not self.Available or not self:EnsureFolders() then
            return false
        end
        table.sort(self.Profiles, function(a, b)
            return a:lower() < b:lower()
        end)
        local encoded = self:Encode({Profiles = self.Profiles})
        if not encoded then return false end
        return pcall(function()
            writefile(self.IndexPath, encoded)
        end)
    end

    function cm:RegisterProfile(name)
        name = self:SanitizeName(name)
        if not self:ProfileExists(name) then
            table.insert(self.Profiles, name)
            self:SaveIndex()
        end
        return name
    end

    function cm:RemoveProfile(name)
        name = self:SanitizeName(name)
        for index = #self.Profiles, 1, -1 do
            if self.Profiles[index] == name then
                table.remove(self.Profiles, index)
            end
        end
        self:SaveIndex()
    end

    function cm:LoadIndex()
        table.clear(self.Profiles)
        if not self.Available then return false end
        self:EnsureFolders()

        if self:IsFile(self.IndexPath) then
            local ok, raw = pcall(readfile, self.IndexPath)
            local decoded = ok and self:Decode(raw) or nil
            if decoded and type(decoded.Profiles) == "table" then
                for _, name in ipairs(decoded.Profiles) do
                    local clean = self:SanitizeName(name)
                    local path = self.ConfigFolder .. "/" .. clean .. ".json"
                    if self:IsFile(path) and not self:ProfileExists(clean) then
                        table.insert(self.Profiles, clean)
                    end
                end
            end
        end

        -- Discover pre-existing config files too when the executor supports listfiles.
        if type(listfiles) == "function" then
            local ok, files = pcall(listfiles, self.ConfigFolder)
            if ok and type(files) == "table" then
                for _, path in ipairs(files) do
                    local normalized = tostring(path):gsub("\\", "/")
                    local filename = normalized:match("([^/]+)%.json$")
                    if filename then
                        local clean = self:SanitizeName(filename)
                        if clean ~= "" and not self:ProfileExists(clean) then
                            table.insert(self.Profiles, clean)
                        end
                    end
                end
            end
        end

        table.sort(self.Profiles, function(a, b)
            return a:lower() < b:lower()
        end)
        self:SaveIndex()
        return true
    end

    function cm:SaveMeta()
        if not self.Available or not self:EnsureFolders() then
            return false
        end
        local encoded = self:Encode({
            AutoSave = self.Meta.AutoSave == true,
            AutoLoad = self.Meta.AutoLoad == true,
            Profile = self.Profile,
        })
        if not encoded then
            return false
        end
        return pcall(function()
            writefile(self.MetaPath, encoded)
        end)
    end

    function cm:LoadMeta()
        if not self.Available or not self:IsFile(self.MetaPath) then
            return false
        end
        local ok, raw = pcall(readfile, self.MetaPath)
        if not ok then
            return false
        end
        local decoded = self:Decode(raw)
        if not decoded then
            return false
        end
        self.Meta.AutoSave = decoded.AutoSave == true
        self.Meta.AutoLoad = decoded.AutoLoad == true
        self.Profile = self:SanitizeName(decoded.Profile or self.Profile)
        return true
    end

    function cm:Save(profile, silent, overwrite)
        if not self.Available then
            self:SetStatus("Config storage unavailable: executor file APIs missing.", false)
            return false
        end

        self:EnsureFolders()
        self.Profile = self:SanitizeName(profile or self.Profile)

        local state = self:GetState()
        local encoded = self:Encode(state)
        if not encoded then
            self:SetStatus("Config encode failed.", false)
            return false
        end

        local path = self.ConfigFolder .. "/" .. self.Profile .. ".json"

        -- "Save" creates a new profile only. Existing profiles require the
        -- explicit Overwrite button so an accidental click cannot destroy a
        -- known-good configuration.
        if self:IsFile(path) and overwrite ~= true then
            if not silent then
                self:SetStatus("Config already exists. Use Overwrite: " .. self.Profile, false)
            end
            return false
        end

        local ok = pcall(function()
            writefile(path, encoded)
        end)

        if ok then
            self.LastSerialized = encoded
            self:RegisterProfile(self.Profile)
            self:SaveMeta()
            if not silent then
                self:SetStatus(
                    overwrite == true and ("Overwritten config: " .. self.Profile)
                        or ("Saved config: " .. self.Profile),
                    true
                )
            end
            return true
        end

        self:SetStatus("Failed to write config: " .. self.Profile, false)
        return false
    end

    function cm:Delete(profile)
        if not self.Available then
            self:SetStatus("Config storage unavailable: executor file APIs missing.", false)
            return false
        end

        if type(self.DeleteFile) ~= "function" then
            self:SetStatus("Delete is not supported by this executor (delfile/deletefile missing).", false)
            return false
        end

        self:EnsureFolders()
        local deletingProfile = self:SanitizeName(profile or self.Profile)
        local path = self.ConfigFolder .. "/" .. deletingProfile .. ".json"

        if not self:IsFile(path) then
            self:SetStatus("Config not found: " .. deletingProfile, false)
            return false
        end

        -- Prevent Auto Save from immediately recreating a config that the user
        -- explicitly deleted, and prevent Auto Load from pointing at a file
        -- that no longer exists.
        if self.Profile == deletingProfile then
            self.Meta.AutoSave = false
            self.Meta.AutoLoad = false
        end

        local ok = pcall(function()
            self.DeleteFile(path)
        end)

        if not ok then
            self:SetStatus("Failed to delete config: " .. deletingProfile, false)
            return false
        end

        self.LastSerialized = nil
        self:RemoveProfile(deletingProfile)
        if self.Profile == deletingProfile then
            self.Profile = self.Profiles[1] or "default"
        end
        self:SaveMeta()
        self:SetStatus("Deleted config completely: " .. deletingProfile, true)
        return true
    end

    function cm:ApplyState(state)
        if type(state) ~= "table" then
            return false
        end

        -- Stop active loops first so applying a config is deterministic.
        stopAutoFarm()
        stopAutoBestEgg()
        if Runtime.AutoGet.StopTargetRanchDelivery then
            Runtime.AutoGet.StopTargetRanchDelivery()
        end
        stopAutoHatchLuck()
        Runtime.EggAutomation.StopAutoPlace()
        Runtime.EggAutomation.StopAutoHatch()
        Runtime.AutoFeed.Stop()

        Runtime.AutoGet.TravelMode = "TweenHome"
        Runtime.AutoGet.MinWeightKg = Runtime.Weight.Parse(state.GetMinWeightKg, true) or 100000
        Runtime.EggAutomation.SetPlaceMinWeight(
            Runtime.Weight.Parse(state.PlaceMinWeightKg, true) or 0
        )
        Runtime.AutoGet.PickupDelay = math.clamp(tonumber(state.PickupDelay) or 1.5, 0.25, 30)
        Runtime.AutoGet.PickupMethod = state.PickupMethod == "Compatibility" and "Compatibility" or "PromptHold"
        Runtime.AutoGet.RejoinBelowMin.Enabled = false
        Runtime.AutoGet.RejoinBelowMin.Busy = false
        Runtime.AutoGet.RejoinBelowMin.BelowSince = nil
        Runtime.ESPFilter.Restore(state.ESPFilter)
        Runtime.Weight.RefreshControls()
        Runtime.AutoGet.RefreshRejoinBelowMinUI()

        table.clear(autoFarmEggs)
        if type(state.Filters) == "table" then
            for _, name in ipairs(state.Filters) do
                if type(name) == "string" and name ~= "" then
                    autoFarmEggs[Runtime.EggIdentity.Key(name)] = true
                end
            end
        end

        Runtime.UIRegs.availableEggsHidden = state.AvailableEggsHidden == true
        sortMode = state.SortMode == "Distance" and "Distance" or "Name"
        Runtime.UIRegs.SortBtn.Text = "Sort: " .. sortMode

        if type(state.TPKeybind) == "string" and Enum.KeyCode[state.TPKeybind] then
            tpKeybind = Enum.KeyCode[state.TPKeybind]
            Runtime.UIRegs.KeybindBtn.Text = "Home TP Key: [" .. tpKeybind.Name .. "]"
        end

        -- Strict ESP restore.
        mainESPActive = state.ESPEnabled == true
        if not mainESPActive then
            for egg, data in pairs(eggData) do
                if data then
                    data.CustomActive = false
                end
                if egg and egg.Parent then
                    updateEggESP(egg)
                end
            end
        end
        applyGlobalESP(mainESPActive)
        Runtime.UIRegs.ToggleGlobalESPBtn.Text = mainESPActive and "All Eggs ESP: ON" or "All Eggs ESP: OFF"
        Runtime.UIRegs.ToggleGlobalESPBtn.TextColor3 = mainESPActive
            and Color3.fromRGB(0, 255, 120)
            or Color3.fromRGB(220, 220, 220)

        -- v3.71: automation startup is restored once through the exclusive mode
        -- selector below; never start legacy Get Egg/Auto Best loops independently.
        stopAutoBestEgg()
        Runtime.UIRegs.AutoBestEggBtn.Text = "Auto Best Egg: OFF"
        Runtime.UIRegs.AutoBestEggBtn.TextColor3 = Color3.fromRGB(220, 220, 220)
        Runtime.UIRegs.AutoBestEggBtn.BackgroundColor3 = Color3.fromRGB(35, 35, 35)

        if state.AutoHatchLuck == true then
            startAutoHatchLuck()
        else
            stopAutoHatchLuck()
        end

        -- Independent and OFF by default for old/missing config values.
        Runtime.LuckAlertSilencer.SetEnabled(state.SilenceLuckUpgradeAlert == true)

        -- v3.56 migration: profiles saved before v14 used OFF as the historical
        -- default. Migrate them once to the new requested ON defaults; v14+ profiles
        -- preserve an explicit user choice to turn either switch off.
        local profileVersion = tonumber(state.Version) or 0
        if profileVersion >= 14 then
            Runtime.Transport.SetAutoReconnect(state.AutoReconnect == true, true)
            Runtime.Transport.SetAutoExecute(state.AutoExecuteAfterTeleport == true, true)
        else
            Runtime.Transport.SetAutoReconnect(true, true)
            Runtime.Transport.SetAutoExecute(true, true)
        end

        -- Rejoin Below Min is applied after transport settings so an enabled
        -- hunt can reliably arm Auto Execute for repeated server rejoins.
        Runtime.AutoGet.SetRejoinBelowMinEnabled(state.RejoinBelowMin == true, true)

        EggAutoState.PriorityEnabled = true

        -- v3.39 deterministic restore: Place and Hatch selections are completely
        -- separate. Old profiles have no egg-name filters, so both start ALL OFF.
        table.clear(EggAutoState.PlaceEggFilters)
        table.clear(EggAutoState.HatchEggFilters)
        if tonumber(state.EggNameFilterVersion) == 1 then
            if type(state.EggPlaceFilters) == "table" then
                for key, enabled in pairs(state.EggPlaceFilters) do
                    local normalized = Runtime.EggAutomation.NormalizeEggKey(key)
                    if normalized ~= "" then
                        EggAutoState.PlaceEggFilters[normalized] = enabled == true
                    end
                end
            end
            if type(state.EggHatchFilters) == "table" then
                for key, enabled in pairs(state.EggHatchFilters) do
                    local normalized = Runtime.EggAutomation.NormalizeEggKey(key)
                    if normalized ~= "" then
                        EggAutoState.HatchEggFilters[normalized] = enabled == true
                    end
                end
            end
        end

        -- Legacy rarity state is still restored only for compatibility; it no longer
        -- controls Place/Hatch in v3.39.
        for rarity in pairs(EggAutoState.RarityFilters) do
            EggAutoState.RarityFilters[rarity] = false
        end
        if tonumber(state.EggRarityFilterVersion) == 2 and type(state.EggRarityFilters) == "table" then
            for rarity in pairs(EggAutoState.RarityFilters) do
                EggAutoState.RarityFilters[rarity] = state.EggRarityFilters[rarity] == true
            end
        end
        if type(Runtime.EggAutomation.MarkBagCacheDirty) == "function" then
            Runtime.EggAutomation.MarkBagCacheDirty("profile/filter state restored")
        else
            Runtime.EggAutomation.LastBagScanAt = 0
        end
        Runtime.EggAutomation.InvalidateRanchSnapshot()

        table.clear(Runtime.EggAutomation.PlacementMemory)
        table.clear(Runtime.EggAutomation.NestOwners)
        if type(state.EggPlacementMemory) == "table" then
            for eggKey, memory in pairs(state.EggPlacementMemory) do
                if type(eggKey) == "string" and type(memory) == "table" then
                    local x, y, z = tonumber(memory.X), tonumber(memory.Y), tonumber(memory.Z)
                    if x and y and z then
                        Runtime.EggAutomation.PlacementMemory[eggKey] = {
                            Key = tostring(memory.Key or ""),
                            X = x, Y = y, Z = z,
                        }
                    end
                end
            end
        end
        if type(state.EggNestOwners) == "table" then
            for nestKey, eggKey in pairs(state.EggNestOwners) do
                if type(nestKey) == "string" and type(eggKey) == "string" then
                    Runtime.EggAutomation.NestOwners[nestKey] = eggKey
                end
            end
        else
            -- Backward-compatible reconstruction from cluster origins.
            for eggKey, memory in pairs(Runtime.EggAutomation.PlacementMemory) do
                if memory.Key and memory.Key ~= "" then
                    Runtime.EggAutomation.NestOwners[memory.Key] = eggKey
                end
            end
        end
        if state.AutoPlaceEggs == true then
            Runtime.EggAutomation.StartAutoPlace()
        else
            Runtime.EggAutomation.StopAutoPlace()
        end
        if state.AutoHatchEggs == true then
            Runtime.EggAutomation.StartAutoHatch()
        else
            Runtime.EggAutomation.StopAutoHatch()
        end
        Runtime.EggAutomation.RefreshButtons()

        Runtime.AutoFeed.SetMinAge(state.AutoFeedMinAge or 0)
        if state.AutoFeedPets == true then
            Runtime.AutoFeed.Start()
        else
            Runtime.AutoFeed.Stop()
        end

        if Runtime.EggAutomation.RefreshEggFilterUI then
            Runtime.EggAutomation.RefreshEggFilterUI()
        end

        if Runtime.AutoGet.RefreshTravelButtons then
            Runtime.AutoGet.RefreshTravelButtons()
        end
        if Runtime.AutoGet.RefreshFilterUI then
            Runtime.AutoGet.RefreshFilterUI()
        end
        layoutEggsPage()
        updateSelectedEggPanel()

        -- Restore exactly one Eggs automation mode.
        local savedMode = type(state.EggMode) == "string" and state.EggMode or nil
        if savedMode ~= "GetEgg" and savedMode ~= "BestEgg" and savedMode ~= "TargetRanch" then
            savedMode = state.AutoBestEgg == true and "BestEgg" or "GetEgg"
        end
        if Runtime.AutoGet.ModeSelector then
            Runtime.AutoGet.ModeSelector.Selected = savedMode
            Runtime.AutoGet.ModeSelector.MenuOpen = false
        end
        if Runtime.AutoGet.TargetRanch then
            Runtime.AutoGet.TargetRanch.TargetUserId = tonumber(state.TargetRanchUserId)
        end

        local anyFilter = Runtime.AutoGet.HasFilter()
        if savedMode == "BestEgg" and state.AutoBestEgg == true then
            startAutoBestEgg()
        elseif savedMode == "TargetRanch" and state.TargetRanchActive == true and anyFilter then
            Runtime.AutoGet.StartTargetRanchDelivery()
        elseif savedMode == "GetEgg" and state.GetEgg == true and anyFilter then
            startAutoFarm()
        end

        if Runtime.AutoGet.RefreshEggModeUI then
            Runtime.AutoGet.RefreshEggModeUI()
        end

        if not Runtime.UIRegs.availableEggsHidden and populateList then
            populateList()
        end

        if type(state.CurrentTab) == "string" and Runtime.UIRegs.tabPages[state.CurrentTab] then
            selectTab(state.CurrentTab)
        end

        return true
    end

    function cm:Load(profile, silent)
        if not self.Available then
            self:SetStatus("Config storage unavailable: executor file APIs missing.", false)
            return false
        end
        self:EnsureFolders()
        self.Profile = self:SanitizeName(profile or self.Profile)
        local path = self.ConfigFolder .. "/" .. self.Profile .. ".json"
        if not self:IsFile(path) then
            self:SetStatus("Config not found: " .. self.Profile, false)
            return false
        end
        local ok, raw = pcall(readfile, path)
        if not ok then
            self:SetStatus("Failed to read config: " .. self.Profile, false)
            return false
        end
        local decoded = self:Decode(raw)
        if not decoded then
            self:SetStatus("Config JSON is invalid.", false)
            return false
        end
        if not self:ApplyState(decoded) then
            self:SetStatus("Config apply failed.", false)
            return false
        end
        self.LastSerialized = self:Encode(self:GetState())
        self:SaveMeta()
        if not silent then
            self:SetStatus("Loaded config: " .. self.Profile, true)
        end
        return true
    end

    local panel = Instance.new("Frame")
    panel.Name = "ConfigPanel"
    panel.Size = UDim2.new(1, 0, 0, 332)
    panel.Position = UDim2.new(0, 0, 0, 294)
    panel.BackgroundColor3 = Color3.fromRGB(18, 24, 32)
    panel.BackgroundTransparency = 0.08
    panel.BorderSizePixel = 0
    panel.Parent = Runtime.UIRegs.SettingsPage

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 7)
    corner.Parent = panel

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, -12, 0, 20)
    title.Position = UDim2.new(0, 6, 0, 4)
    title.BackgroundTransparency = 1
    title.Text = "Configuration"
    title.TextColor3 = Color3.fromRGB(225, 232, 242)
    title.TextSize = 11
    title.Font = Enum.Font.SourceSansBold
    title.TextXAlignment = Enum.TextXAlignment.Left
    title.Parent = panel

    cm.UI.Name = Instance.new("TextBox")
    cm.UI.Name.Size = UDim2.new(1, -12, 0, 27)
    cm.UI.Name.Position = UDim2.new(0, 6, 0, 27)
    cm.UI.Name.BackgroundColor3 = Color3.fromRGB(27, 34, 44)
    cm.UI.Name.BackgroundTransparency = 0.05
    cm.UI.Name.Text = cm.Profile
    cm.UI.Name.PlaceholderText = "Config name"
    cm.UI.Name.TextColor3 = Color3.fromRGB(235, 240, 248)
    cm.UI.Name.PlaceholderColor3 = Color3.fromRGB(125, 140, 158)
    cm.UI.Name.TextSize = 10
    cm.UI.Name.Font = Enum.Font.SourceSans
    cm.UI.Name.ClearTextOnFocus = false
    cm.UI.Name.Parent = panel
    local nameCorner = Instance.new("UICorner")
    nameCorner.CornerRadius = UDim.new(0, 5)
    nameCorner.Parent = cm.UI.Name

    cm.UI.Save = Instance.new("TextButton")
    cm.UI.Save.Size = UDim2.new(0.5, -9, 0, 27)
    cm.UI.Save.Position = UDim2.new(0, 6, 0, 59)
    cm.UI.Save.BackgroundColor3 = Color3.fromRGB(0, 115, 75)
    cm.UI.Save.Text = "Save New"
    cm.UI.Save.TextColor3 = Color3.fromRGB(255, 255, 255)
    cm.UI.Save.TextSize = 10
    cm.UI.Save.Font = Enum.Font.SourceSansBold
    cm.UI.Save.Parent = panel
    styleButton(cm.UI.Save)

    cm.UI.Load = Instance.new("TextButton")
    cm.UI.Load.Size = UDim2.new(0.5, -9, 0, 27)
    cm.UI.Load.Position = UDim2.new(0.5, 3, 0, 59)
    cm.UI.Load.BackgroundColor3 = Color3.fromRGB(35, 80, 125)
    cm.UI.Load.Text = "Load Config"
    cm.UI.Load.TextColor3 = Color3.fromRGB(255, 255, 255)
    cm.UI.Load.TextSize = 10
    cm.UI.Load.Font = Enum.Font.SourceSansBold
    cm.UI.Load.Parent = panel
    styleButton(cm.UI.Load)

    cm.UI.Overwrite = Instance.new("TextButton")
    cm.UI.Overwrite.Size = UDim2.new(0.5, -9, 0, 27)
    cm.UI.Overwrite.Position = UDim2.new(0, 6, 0, 91)
    cm.UI.Overwrite.BackgroundColor3 = Color3.fromRGB(145, 95, 20)
    cm.UI.Overwrite.Text = "Overwrite"
    cm.UI.Overwrite.TextColor3 = Color3.fromRGB(255, 255, 255)
    cm.UI.Overwrite.TextSize = 10
    cm.UI.Overwrite.Font = Enum.Font.SourceSansBold
    cm.UI.Overwrite.Parent = panel
    styleButton(cm.UI.Overwrite)

    cm.UI.Delete = Instance.new("TextButton")
    cm.UI.Delete.Size = UDim2.new(0.5, -9, 0, 27)
    cm.UI.Delete.Position = UDim2.new(0.5, 3, 0, 91)
    cm.UI.Delete.BackgroundColor3 = Color3.fromRGB(135, 45, 50)
    cm.UI.Delete.Text = "Delete Config"
    cm.UI.Delete.TextColor3 = Color3.fromRGB(255, 255, 255)
    cm.UI.Delete.TextSize = 10
    cm.UI.Delete.Font = Enum.Font.SourceSansBold
    cm.UI.Delete.Parent = panel
    styleButton(cm.UI.Delete)

    cm.UI.AutoSave = Instance.new("TextButton")
    cm.UI.AutoSave.Size = UDim2.new(0.5, -9, 0, 27)
    cm.UI.AutoSave.Position = UDim2.new(0, 6, 0, 123)
    cm.UI.AutoSave.TextSize = 10
    cm.UI.AutoSave.Font = Enum.Font.SourceSansBold
    cm.UI.AutoSave.Parent = panel
    styleButton(cm.UI.AutoSave)

    cm.UI.AutoLoad = Instance.new("TextButton")
    cm.UI.AutoLoad.Size = UDim2.new(0.5, -9, 0, 27)
    cm.UI.AutoLoad.Position = UDim2.new(0.5, 3, 0, 123)
    cm.UI.AutoLoad.TextSize = 10
    cm.UI.AutoLoad.Font = Enum.Font.SourceSansBold
    cm.UI.AutoLoad.Parent = panel
    styleButton(cm.UI.AutoLoad)

    cm.UI.ProfileCount = Instance.new("TextLabel")
    cm.UI.ProfileCount.Size = UDim2.new(1, -12, 0, 18)
    cm.UI.ProfileCount.Position = UDim2.new(0, 6, 0, 154)
    cm.UI.ProfileCount.BackgroundTransparency = 1
    cm.UI.ProfileCount.Text = "Saved Configs (0) — click one to select"
    cm.UI.ProfileCount.TextColor3 = Color3.fromRGB(185, 197, 214)
    cm.UI.ProfileCount.TextSize = 9
    cm.UI.ProfileCount.Font = Enum.Font.SourceSansBold
    cm.UI.ProfileCount.TextXAlignment = Enum.TextXAlignment.Left
    cm.UI.ProfileCount.Parent = panel

    cm.UI.ProfileList = Instance.new("ScrollingFrame")
    cm.UI.ProfileList.Size = UDim2.new(1, -12, 0, 88)
    cm.UI.ProfileList.Position = UDim2.new(0, 6, 0, 174)
    cm.UI.ProfileList.BackgroundColor3 = Color3.fromRGB(22, 29, 39)
    cm.UI.ProfileList.BackgroundTransparency = 0.08
    cm.UI.ProfileList.BorderSizePixel = 0
    cm.UI.ProfileList.ScrollBarThickness = 4
    cm.UI.ProfileList.CanvasSize = UDim2.new(0, 0, 0, 0)
    cm.UI.ProfileList.Parent = panel
    local profileListCorner = Instance.new("UICorner")
    profileListCorner.CornerRadius = UDim.new(0, 5)
    profileListCorner.Parent = cm.UI.ProfileList

    cm.UI.ProfileLayout = Instance.new("UIListLayout")
    cm.UI.ProfileLayout.Padding = UDim.new(0, 3)
    cm.UI.ProfileLayout.SortOrder = Enum.SortOrder.LayoutOrder
    cm.UI.ProfileLayout.Parent = cm.UI.ProfileList

    cm.UI.ProfilePadding = Instance.new("UIPadding")
    cm.UI.ProfilePadding.PaddingTop = UDim.new(0, 4)
    cm.UI.ProfilePadding.PaddingBottom = UDim.new(0, 4)
    cm.UI.ProfilePadding.PaddingLeft = UDim.new(0, 4)
    cm.UI.ProfilePadding.PaddingRight = UDim.new(0, 4)
    cm.UI.ProfilePadding.Parent = cm.UI.ProfileList

    cm.UI.Status = Instance.new("TextLabel")
    cm.UI.Status.Size = UDim2.new(1, -12, 0, 58)
    cm.UI.Status.Position = UDim2.new(0, 6, 0, 268)
    cm.UI.Status.BackgroundTransparency = 1
    cm.UI.Status.TextWrapped = true
    cm.UI.Status.TextColor3 = Color3.fromRGB(150, 165, 184)
    cm.UI.Status.TextSize = 9
    cm.UI.Status.Font = Enum.Font.SourceSans
    cm.UI.Status.TextXAlignment = Enum.TextXAlignment.Left
    cm.UI.Status.TextYAlignment = Enum.TextYAlignment.Top
    cm.UI.Status.Parent = panel

    function cm:RefreshProfileList()
        if not self.UI.ProfileList then return end

        for _, child in ipairs(self.UI.ProfileList:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end

        table.sort(self.Profiles, function(a, b)
            return a:lower() < b:lower()
        end)

        if self.UI.ProfileCount then
            self.UI.ProfileCount.Text = "Saved Configs (" .. tostring(#self.Profiles) .. ") — click one to select"
        end

        for index, name in ipairs(self.Profiles) do
            local button = Instance.new("TextButton")
            button.Name = "Profile_" .. name
            button.Size = UDim2.new(1, -2, 0, 24)
            button.BackgroundColor3 = name == self.Profile
                and Color3.fromRGB(0, 105, 145)
                or Color3.fromRGB(39, 48, 61)
            button.BackgroundTransparency = 0.06
            button.Text = tostring(index) .. ". " .. name
            button.TextColor3 = Color3.fromRGB(235, 240, 248)
            button.TextSize = 9
            button.Font = Enum.Font.SourceSansBold
            button.TextXAlignment = Enum.TextXAlignment.Left
            button.LayoutOrder = index
            button.Parent = self.UI.ProfileList
            styleButton(button)
            local padding = Instance.new("UIPadding")
            padding.PaddingLeft = UDim.new(0, 7)
            padding.Parent = button

            button.Activated:Connect(function()
                self.Profile = name
                if self.UI.Name then
                    self.UI.Name.Text = name
                end
                self:SaveMeta()
                self:RefreshProfileList()
                self:SetStatus("Selected config: " .. name .. " (press Load Config to apply)", true)
            end)
        end

        local height = 8 + (#self.Profiles * 27)
        self.UI.ProfileList.CanvasSize = UDim2.new(0, 0, 0, math.max(0, height))
    end

    function cm:RefreshButtons()
        if self.UI.AutoSave then
            self.UI.AutoSave.Text = "Auto Save: " .. (self.Meta.AutoSave and "ON" or "OFF")
            self.UI.AutoSave.BackgroundColor3 = self.Meta.AutoSave
                and Color3.fromRGB(0, 130, 75)
                or Color3.fromRGB(45, 52, 64)
        end
        if self.UI.AutoLoad then
            self.UI.AutoLoad.Text = "Auto Load: " .. (self.Meta.AutoLoad and "ON" or "OFF")
            self.UI.AutoLoad.BackgroundColor3 = self.Meta.AutoLoad
                and Color3.fromRGB(0, 120, 170)
                or Color3.fromRGB(45, 52, 64)
        end
        if self.UI.Name then
            self.UI.Name.Text = self.Profile
        end
        self:RefreshProfileList()
    end

    cm:LoadIndex()
    cm:LoadMeta()
    cm:RefreshButtons()
    if cm.Available then
        cm:SetStatus("Ready. Multiple named configs supported. Save New creates another profile; click any saved profile to select it.", true)
    else
        cm:SetStatus("File save/load is not supported by this executor.", false)
    end

    cm.UI.Name.FocusLost:Connect(function()
        cm.Profile = cm:SanitizeName(cm.UI.Name.Text)
        cm.UI.Name.Text = cm.Profile
        cm:SaveMeta()
    end)

    cm.UI.Save.Activated:Connect(function()
        cm.Profile = cm:SanitizeName(cm.UI.Name.Text)
        cm:Save(cm.Profile, false, false)
        cm:RefreshButtons()
    end)

    cm.UI.Load.Activated:Connect(function()
        cm.Profile = cm:SanitizeName(cm.UI.Name.Text)
        cm:Load(cm.Profile, false)
        cm:RefreshButtons()
    end)

    cm.UI.Overwrite.Activated:Connect(function()
        cm.Profile = cm:SanitizeName(cm.UI.Name.Text)
        cm:Save(cm.Profile, false, true)
        cm:RefreshButtons()
    end)

    cm.UI.Delete.Activated:Connect(function()
        cm.Profile = cm:SanitizeName(cm.UI.Name.Text)
        cm:Delete(cm.Profile)
        cm:RefreshButtons()
    end)

    cm.UI.AutoSave.Activated:Connect(function()
        cm.Meta.AutoSave = not cm.Meta.AutoSave
        cm:SaveMeta()
        if cm.Meta.AutoSave then
            cm:Save(cm.Profile, true, true)
            cm:SetStatus("Auto Save enabled for: " .. cm.Profile, true)
        else
            cm:SetStatus("Auto Save disabled.", true)
        end
        cm:RefreshButtons()
    end)

    cm.UI.AutoLoad.Activated:Connect(function()
        cm.Meta.AutoLoad = not cm.Meta.AutoLoad
        cm:SaveMeta()
        cm:SetStatus(
            cm.Meta.AutoLoad and ("Auto Load enabled for: " .. cm.Profile) or "Auto Load disabled.",
            true
        )
        cm:RefreshButtons()
    end)

    task.spawn(function()
        task.wait(0.35)
        if Runtime.Alive and cm.Meta.AutoLoad then
            cm:Load(cm.Profile, true)
            cm:SetStatus("Auto loaded: " .. cm.Profile, true)
            cm:RefreshButtons()
        end

        while Runtime.Alive do
            task.wait(5.0)
            if cm.Meta.AutoSave and cm.Available then
                local encoded = cm:Encode(cm:GetState())
                if encoded and encoded ~= cm.LastSerialized then
                    cm:Save(cm.Profile, true, true)
                    cm:SetStatus("Auto saved: " .. cm.Profile, true)
                end
            end
        end
    end)
end

-- Hatch Luck page: read the game's own display and discover client-visible sources.
local LuckTitle = Instance.new("TextLabel")

LuckTitle.Size = UDim2.new(1, 0, 0, 22)

LuckTitle.BackgroundTransparency = 1

LuckTitle.Text = "Hatch Luck"

LuckTitle.TextColor3 = Color3.fromRGB(235, 240, 248)

LuckTitle.TextSize = 14

LuckTitle.Font = Enum.Font.SourceSansBold

LuckTitle.TextXAlignment = Enum.TextXAlignment.Left

LuckTitle.Parent = Runtime.UIRegs.LuckPage

local LuckValueLabel = Instance.new("TextLabel")

LuckValueLabel.Size = UDim2.new(1, 0, 0, 30)

LuckValueLabel.Position = UDim2.new(0, 0, 0, 28)

LuckValueLabel.BackgroundColor3 = Color3.fromRGB(16, 40, 31)

LuckValueLabel.BackgroundTransparency = 0.08

LuckValueLabel.Text = "Displayed Hatch Luck: waiting for game UI..."

LuckValueLabel.TextColor3 = Color3.fromRGB(145, 255, 190)

LuckValueLabel.TextSize = 12

LuckValueLabel.Font = Enum.Font.SourceSansBold

LuckValueLabel.TextXAlignment = Enum.TextXAlignment.Left

LuckValueLabel.Parent = Runtime.UIRegs.LuckPage

do
local LuckValueCorner = Instance.new("UICorner")

LuckValueCorner.CornerRadius = UDim.new(0, 7)

LuckValueCorner.Parent = LuckValueLabel
end

do
local LuckValuePadding = Instance.new("UIPadding")

LuckValuePadding.PaddingLeft = UDim.new(0, 8)

LuckValuePadding.PaddingRight = UDim.new(0, 8)

LuckValuePadding.Parent = LuckValueLabel
end

LuckStatusLabel = Instance.new("TextLabel")

LuckStatusLabel.Size = UDim2.new(1, 0, 0, 64)

LuckStatusLabel.Position = UDim2.new(0, 0, 0, 66)

LuckStatusLabel.BackgroundColor3 = Color3.fromRGB(22, 29, 39)

LuckStatusLabel.BackgroundTransparency = 0.12

LuckStatusLabel.Text = "Auto Hatch Luck uses the verified MAX upgrade call:\nPlot.Upgrades:FireServer(\"Max\")"

LuckStatusLabel.TextWrapped = true

LuckStatusLabel.TextColor3 = Color3.fromRGB(180, 191, 207)

LuckStatusLabel.TextSize = 11

LuckStatusLabel.Font = Enum.Font.SourceSans

LuckStatusLabel.TextXAlignment = Enum.TextXAlignment.Left

LuckStatusLabel.TextYAlignment = Enum.TextYAlignment.Top

LuckStatusLabel.Parent = Runtime.UIRegs.LuckPage

do
local LuckStatusCorner = Instance.new("UICorner")

LuckStatusCorner.CornerRadius = UDim.new(0, 7)

LuckStatusCorner.Parent = LuckStatusLabel
end

AutoHatchLuckBtn = Instance.new("TextButton")

AutoHatchLuckBtn.Size = UDim2.new(1, 0, 0, 32)

AutoHatchLuckBtn.Position = UDim2.new(0, 0, 0, 140)

AutoHatchLuckBtn.BackgroundColor3 = Color3.fromRGB(35, 45, 58)

AutoHatchLuckBtn.BackgroundTransparency = 0.08

AutoHatchLuckBtn.Text = "Auto Hatch Luck: OFF"

AutoHatchLuckBtn.TextColor3 = Color3.fromRGB(220, 228, 238)

AutoHatchLuckBtn.TextSize = 12

AutoHatchLuckBtn.Font = Enum.Font.SourceSansBold

AutoHatchLuckBtn.Parent = Runtime.UIRegs.LuckPage

styleButton(AutoHatchLuckBtn)

Runtime.LuckAlertSilencer.UI.ToggleBtn = Instance.new("TextButton")
Runtime.LuckAlertSilencer.UI.ToggleBtn.Size = UDim2.new(1, 0, 0, 32)
Runtime.LuckAlertSilencer.UI.ToggleBtn.Position = UDim2.new(0, 0, 0, 180)
Runtime.LuckAlertSilencer.UI.ToggleBtn.BackgroundColor3 = Color3.fromRGB(45, 52, 64)
Runtime.LuckAlertSilencer.UI.ToggleBtn.BackgroundTransparency = 0.08
Runtime.LuckAlertSilencer.UI.ToggleBtn.Text = "Silence Luck Upgrade Alert: OFF"
Runtime.LuckAlertSilencer.UI.ToggleBtn.TextColor3 = Color3.fromRGB(220, 228, 238)
Runtime.LuckAlertSilencer.UI.ToggleBtn.TextSize = 11
Runtime.LuckAlertSilencer.UI.ToggleBtn.Font = Enum.Font.SourceSansBold
Runtime.LuckAlertSilencer.UI.ToggleBtn.Parent = Runtime.UIRegs.LuckPage
styleButton(Runtime.LuckAlertSilencer.UI.ToggleBtn)
Runtime.LuckAlertSilencer.RefreshButton()

local FindLuckBoardBtn = Instance.new("TextButton")

FindLuckBoardBtn.Size = UDim2.new(1, 0, 0, 32)

FindLuckBoardBtn.Position = UDim2.new(0, 0, 0, 220)

FindLuckBoardBtn.BackgroundColor3 = Color3.fromRGB(0, 135, 80)

FindLuckBoardBtn.BackgroundTransparency = 0.08

FindLuckBoardBtn.Text = "Find / Open Hatch Luck Board"

FindLuckBoardBtn.TextColor3 = Color3.fromRGB(255, 255, 255)

FindLuckBoardBtn.TextSize = 12

FindLuckBoardBtn.Font = Enum.Font.SourceSansBold

FindLuckBoardBtn.Parent = Runtime.UIRegs.LuckPage

styleButton(FindLuckBoardBtn)

local function refreshDisplayedLuck()

    local displayedLuck = getDisplayedHatchLuck()

    if displayedLuck then
        LuckValueLabel.Text = "Displayed Hatch Luck: " .. displayedLuck
    else
        LuckValueLabel.Text = "Displayed Hatch Luck: UI not available"
    end

end

-- UI-only polling: do not wake on every Heartbeat. Refresh Hatch Luck only
-- while its tab is visible; this preserves the displayed value with much less UI overhead.
task.spawn(function()
    while Runtime.Alive and ScreenGui.Parent do
        if Runtime.UIRegs.LuckPage.Visible and MainFrame.Visible and not isMinimized then
            refreshDisplayedLuck()
            task.wait(0.75)
        else
            task.wait(1.25)
        end
    end
end)

Runtime.LuckAlertSilencer.UI.ToggleBtn.Activated:Connect(function()
    Runtime.LuckAlertSilencer.SetEnabled(not Runtime.LuckAlertSilencer.Enabled)

    if Runtime.LuckAlertSilencer.Enabled then
        LuckStatusLabel.Text = "Luck upgrade announcement silenced. Only text containing both 'upgraded' and 'luck' is suppressed."
        StatusLabel.Text = "● Luck upgrade alert silencer: ON"
        StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
    else
        LuckStatusLabel.Text = "Luck upgrade announcement silencer disabled."
        StatusLabel.Text = "● Luck upgrade alert silencer: OFF"
        StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
    end
end)

AutoHatchLuckBtn.Activated:Connect(function()
    if autoHatchLuckActive then
        stopAutoHatchLuck()

        LuckStatusLabel.Text = "Auto Hatch Luck stopped."

        StatusLabel.Text = "● Auto Hatch Luck stopped"
        StatusLabel.TextColor3 = Color3.fromRGB(180, 180, 180)
    else
        startAutoHatchLuck()

        LuckStatusLabel.Text = "Auto Hatch Luck started. Using Plot.Upgrades:FireServer(\"Max\")."

        StatusLabel.Text = "● Auto Hatch Luck started"
        StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
    end
end)

FindLuckBoardBtn.Activated:Connect(function()

    local success, message = openHatchLuckBoard()

    LuckStatusLabel.Text = message

    StatusLabel.Text = success and "● Hatch Luck board action completed" or "● " .. message

    StatusLabel.TextColor3 = success and Color3.fromRGB(0, 255, 120) or Color3.fromRGB(255, 120, 100)

end)

refreshDisplayedLuck()

selectTab("Eggs")

--==================================================

-- ORDENAR LOS EGGS

--==================================================

local function getEggsForList()

    local eggs = {}

    if not RenderedEggsFolder then

        return eggs

    end

    for _, egg in ipairs(RenderedEggsFolder:GetChildren()) do

        if egg:IsA("Model") or egg:IsA("BasePart") then

            table.insert(eggs, egg)

        end

    end

    table.sort(eggs, function(a, b)

        if sortMode == "Distance" then

            return getDistanceToTarget(a) < getDistanceToTarget(b)

        end

        return a.Name:lower() < b.Name:lower()

    end)

    return eggs

end

--==================================================

-- CREAR ITEM DE LA LISTA

--==================================================

local function createEggListItem(egg, itemHeight, textSize)
    local ItemFrame = Instance.new("Frame")
    ItemFrame.Size = UDim2.new(1, -6, 0, itemHeight)
    ItemFrame.BackgroundColor3 = Color3.fromRGB(25, 25, 25)
    ItemFrame.BackgroundTransparency = 0.2
    ItemFrame.Parent = Runtime.UIRegs.ScrollList

    local eggIcon = Instance.new("ImageLabel")
    eggIcon.Name = "EggIcon"
    eggIcon.Size = UDim2.new(0, itemHeight - 8, 0, itemHeight - 8)
    eggIcon.Position = UDim2.new(0, 5, 0.5, -(itemHeight - 8) / 2)
    eggIcon.BackgroundTransparency = 1
    eggIcon.Image = getEggImage(egg.Name)
    eggIcon.ScaleType = Enum.ScaleType.Fit
    eggIcon.Parent = ItemFrame

    do
        local corner = Instance.new("UICorner")
        corner.CornerRadius = UDim.new(0, 5)
        corner.Parent = ItemFrame
    end

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Size = UDim2.new(1, -158, 1, 0)
    nameLabel.Position = UDim2.new(0, itemHeight + 7, 0, 0)
    nameLabel.BackgroundTransparency = 1
    nameLabel.Text = (Runtime.EggIdentity and select(2, Runtime.EggIdentity.Resolve(egg))) or egg.Name
    nameLabel.TextColor3 = Color3.fromRGB(220, 220, 220)
    nameLabel.TextSize = textSize
    nameLabel.Font = Enum.Font.SourceSans
    nameLabel.TextXAlignment = Enum.TextXAlignment.Left
    nameLabel.TextTruncate = Enum.TextTruncate.AtEnd
    nameLabel.Parent = ItemFrame

    local distanceLabel = Instance.new("TextLabel")
    distanceLabel.Size = UDim2.new(0, 64, 1, 0)
    distanceLabel.Position = UDim2.new(1, -108, 0, 0)
    distanceLabel.BackgroundTransparency = 1
    distanceLabel.TextColor3 = Color3.fromRGB(145, 145, 145)
    distanceLabel.TextSize = textSize - 1
    distanceLabel.Font = Enum.Font.SourceSans
    distanceLabel.TextXAlignment = Enum.TextXAlignment.Right
    distanceLabel.Text = "--"
    distanceLabel.Parent = ItemFrame

    local distance = getDistanceToTarget(egg)
    if distance ~= math.huge then
        distanceLabel.Text = string.format("%dm", math.floor(distance + 0.5))
    end

    local TPBtn = Instance.new("TextButton")
    TPBtn.Size = UDim2.new(0, 38, 0, itemHeight - 8)
    TPBtn.Position = UDim2.new(1, -42, 0.5, -(itemHeight - 8) / 2)
    TPBtn.BackgroundColor3 = Color3.fromRGB(40, 78, 110)
    TPBtn.BackgroundTransparency = 0.10
    TPBtn.Text = "TP"
    TPBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    TPBtn.TextSize = math.max(9, textSize - 1)
    TPBtn.Font = Enum.Font.SourceSansBold
    TPBtn.Parent = ItemFrame
    styleButton(TPBtn)

    TPBtn.Activated:Connect(function()
        if not Runtime.Alive or not egg.Parent then
            return
        end

        local success = teleportToModel(egg)
        StatusLabel.Text = success
            and ("● TP: " .. egg.Name)
            or ("● TP failed: " .. egg.Name)
        StatusLabel.TextColor3 = success
            and Color3.fromRGB(0, 255, 120)
            or Color3.fromRGB(255, 120, 100)
    end)
end

--==================================================

-- POBLAR LISTA

--==================================================

local function clearEggList()

    -- Borra TODOS los elementos creados por la lista.

    -- Antes solo se borraban Frames y los mensajes de "No se encontraron"

    -- se quedaban acumulados cada vez que la lista se actualizaba.

    for _, child in ipairs(Runtime.UIRegs.ScrollList:GetChildren()) do

        if child ~= Runtime.UIRegs.UIListLayout then

            child:Destroy()

        end

    end

end

populateList = function()

    listBuildGeneration = listBuildGeneration + 1
    local buildId = listBuildGeneration

    task.spawn(function()
        if not Runtime.Alive or not ScreenGui.Parent then
            return
        end

        clearEggList()

        if not RenderedEggsFolder then
            Runtime.UIRegs.EggCountLabel.Text = "Eggs: 0  |  Results: 0"
            return
        end

        local query = currentSearchQuery:lower()
        local eggs = getEggsForList()
        local visibleCount = 0
        local createdSinceYield = 0
        local itemHeight = isMobileMode and 38 or 42
        local textSize = isMobileMode and 10 or 12

        for _, egg in ipairs(eggs) do
            if not Runtime.Alive or buildId ~= listBuildGeneration or not ScreenGui.Parent then
                return
            end

            local matches = query == ""
                or string.find(egg.Name:lower(), query, 1, true)

            if matches then
                visibleCount = visibleCount + 1
                createdSinceYield = createdSinceYield + 1
                createEggListItem(egg, itemHeight, textSize)

                if createdSinceYield >= Config.ListBuildBatch then
                    createdSinceYield = 0
                    RunService.Heartbeat:Wait()
                end
            end
        end

        if not Runtime.Alive or buildId ~= listBuildGeneration then
            return
        end

        Runtime.UIRegs.EggCountLabel.Text = "Eggs: "
            .. tostring(#eggs)
            .. "  |  Results: "
            .. tostring(visibleCount)

        if visibleCount == 0 then
            local emptyLabel = Instance.new("TextLabel")
            emptyLabel.Name = "NoResultsLabel"
            emptyLabel.Size = UDim2.new(1, -10, 0, 35)
            emptyLabel.BackgroundTransparency = 1
            emptyLabel.Text = "No Eggs found"
            emptyLabel.TextColor3 = Color3.fromRGB(130, 130, 130)
            emptyLabel.TextSize = 12
            emptyLabel.Font = Enum.Font.SourceSansItalic
            emptyLabel.Parent = Runtime.UIRegs.ScrollList
        end
    end)

end


local function scheduleEggListRefresh()
    listRefreshGeneration = listRefreshGeneration + 1
    local refreshId = listRefreshGeneration

    task.delay(Config.ListRefreshDebounce, function()
        if not Runtime.Alive or refreshId ~= listRefreshGeneration then
            return
        end

        -- Do not rebuild hidden Egg-tab UI on every workspace egg change.
        -- It is refreshed immediately when the user returns to the Eggs tab.
        if not ScreenGui.Parent or not Runtime.UIRegs.EggsPage.Visible or not Runtime.UIRegs.ListContainerFrame.Visible then
            return
        end

        if Runtime.AutoGet.RefreshFilterUI then
            Runtime.AutoGet.RefreshFilterUI()
        end

        populateList()
    end)
end

--==================================================

-- SEARCH

--==================================================

Runtime.UIRegs.SearchBox:GetPropertyChangedSignal("Text"):Connect(function()

    local newQuery = Runtime.UIRegs.SearchBox.Text

    if newQuery == currentSearchQuery then

        return

    end

    currentSearchQuery = newQuery

    populateList()

end)

--==================================================

-- REFRESH

--==================================================

Runtime.UIRegs.RefreshBtn.Activated:Connect(function()

    populateList()

    if Runtime.AutoGet.RefreshFilterUI then
        Runtime.AutoGet.RefreshFilterUI()
    end

    updateAllESP()

    StatusLabel.Text = "● Egg list refreshed"

    StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)

end)

--==================================================

-- CAMBIAR ORDEN

--==================================================

Runtime.UIRegs.SortBtn.Activated:Connect(function()

    if sortMode == "Name" then

        sortMode = "Distance"

        Runtime.UIRegs.SortBtn.Text = "Sort: Distance"

    else

        sortMode = "Name"

        Runtime.UIRegs.SortBtn.Text = "Sort: Name"

    end

    populateList()

end)

--==================================================

-- MOSTRAR / OCULTAR LISTA

--==================================================

Runtime.UIRegs.ToggleListBtn.Activated:Connect(function()

    Runtime.UIRegs.ListContainerFrame.Visible = not Runtime.UIRegs.ListContainerFrame.Visible

    if Runtime.UIRegs.ListContainerFrame.Visible then

        Runtime.UIRegs.ToggleListBtn.Text = "Hide Egg List ▲"

        populateList()

    else

        Runtime.UIRegs.ToggleListBtn.Text = "Show Egg List ▼"

    end

end)

--==================================================

-- MINIMIZAR

--==================================================

local currentExpandedWidth = Config.PCWidth

local currentExpandedHeight = Config.PCHeight

MinimizeBtn.Activated:Connect(function()

    isMinimized = not isMinimized

    if isMinimized then

        ContentContainer.Visible = false

        tween(MainFrame, {

            Size = UDim2.new(

                0,

                currentExpandedWidth,

                0,

                TopBar.Size.Y.Offset

            )

        }, 0.20)

        MinimizeBtn.Text = "+"

    else

        tween(MainFrame, {

            Size = UDim2.new(

                0,

                currentExpandedWidth,

                0,

                currentExpandedHeight

            )

        }, 0.20)

        task.delay(0.12, function()

            if not isMinimized then

                ContentContainer.Visible = true

            end

        end)

        MinimizeBtn.Text = "-"

    end

end)

--==================================================

-- DRAG / MOVER MENÚ

--==================================================

local dragging = false

local dragInput = nil

local dragStart = nil

local startPosition = nil

-- Frames need to actively receive touch input on mobile. The previous drag code
-- waited for TopBar.InputChanged to assign dragInput, which is unreliable for a
-- finger touch because the original Touch InputObject is the object that moves.
TopBar.Active = true

local function updateMainFrameDrag(input)

    if not dragging or not dragStart or not startPosition or not input then
        return
    end

    local delta = input.Position - dragStart

    MainFrame.Position = UDim2.new(

        startPosition.X.Scale,

        startPosition.X.Offset + delta.X,

        startPosition.Y.Scale,

        startPosition.Y.Offset + delta.Y

    )

end

TopBar.InputBegan:Connect(function(input)

    if

        input.UserInputType == Enum.UserInputType.MouseButton1

        or input.UserInputType == Enum.UserInputType.Touch

    then

        dragging = true

        dragInput = input

        dragStart = input.Position

        startPosition = MainFrame.Position

        input.Changed:Connect(function()

            if dragging and input.UserInputType == Enum.UserInputType.Touch then

                updateMainFrameDrag(input)

            end

            if input.UserInputState == Enum.UserInputState.End then

                dragging = false

                if dragInput == input then
                    dragInput = nil
                end

            end

        end)

    end

end)

TopBar.InputChanged:Connect(function(input)

    if input.UserInputType == Enum.UserInputType.MouseMovement then

        dragInput = input

    elseif input.UserInputType == Enum.UserInputType.Touch and dragging then

        dragInput = input

        updateMainFrameDrag(input)

    end

end)

trackRuntimeConnection(UserInputService.InputChanged:Connect(function(input)

    if not Runtime.Alive then
        return
    end

    if dragging and input == dragInput then

        updateMainFrameDrag(input)

    end

end))

--==================================================

-- KEYBIND TP

--==================================================

trackRuntimeConnection(UserInputService.InputBegan:Connect(function(input, gameProcessed)

    if not Runtime.Alive then
        return
    end

    -- F8: MINIMAL ZOLO DEBUGGER.
    -- Only logs the states needed for the current Auto Place / rejoin problems.
    if input.UserInputType == Enum.UserInputType.Keyboard
        and input.KeyCode == Enum.KeyCode.F8 then

        Runtime.F8DebugEnabled = not (Runtime.F8DebugEnabled == true)

        if Runtime.Transport and Runtime.Transport.SetTeleportFlag then
            Runtime.Transport.SetTeleportFlag(
                "ZoloEggsESP_DebugEnabled",
                Runtime.F8DebugEnabled
            )
        end

        print("")
        print("========== ZOLO F8 DEBUG: "
            .. (Runtime.F8DebugEnabled and "ON" or "OFF")
            .. " ==========")
        print("[BUILD] " .. tostring(Runtime.BuildID or "unknown"))

        if not Runtime.F8DebugEnabled then
            print("Rejoin-stage logging disabled.")
            print("========================================")
            return
        end

        local env = (getgenv and getgenv()) or _G

        -- 1) BOOT / UI
        local gui = Runtime.ScreenGui
        local guiAlive = typeof(gui) == "Instance" and gui.Parent ~= nil

        print("[BOOT]"
            .. " job=" .. tostring(game.JobId)
            .. " origin=" .. tostring(Runtime.BootOrigin)
            .. " alive=" .. tostring(Runtime.Alive)
            .. " starting=" .. tostring(Runtime.Starting)
            .. " ready=" .. tostring(Runtime.Ready)
            .. " cleaned=" .. tostring(Runtime.Cleaned))

        print("[UI]"
            .. " ScreenGui=" .. tostring(guiAlive)
            .. " MainFrame=" .. tostring(MainFrame and MainFrame.Parent ~= nil)
            .. " visible=" .. tostring(MainFrame and MainFrame.Visible))

        print("[ERROR] "
            .. tostring(env.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR or "none"))

        -- 2) REJOIN / AUTO EXECUTE
        local transport = Runtime.Transport or {}
        local urlConfigured = type(transport.RemoteReleaseURL) == "string"
            and transport.RemoteReleaseURL ~= ""

        local autoExecuteFlag = nil
        local resumeFlag = nil
        pcall(function()
            autoExecuteFlag =
                game:GetService("TeleportService"):GetTeleportSetting(
                    "ZoloEggsESP_AutoExecute"
                )
            resumeFlag =
                game:GetService("TeleportService"):GetTeleportSetting(
                    "ZoloEggsESP_RejoinBelowMinResume"
                )
        end)

        print("[REJOIN]"
            .. " autoExecute=" .. tostring(
                transport.State and transport.State.AutoExecute
            )
            .. " queueSupported=" .. tostring(
                type(transport.GetQueueFunction) == "function"
                and transport.GetQueueFunction() ~= nil
            )
            .. " queueArmed=" .. tostring(transport.QueueArmed)
            .. " clearQueueSupported=" .. tostring(
                type(transport.GetClearQueueFunction) == "function"
                and transport.GetClearQueueFunction() ~= nil
            )
            .. " lastClearOk=" .. tostring(transport.LastQueueClearOk)
            .. " urlConfigured=" .. tostring(urlConfigured)
            .. " teleportAutoExecute=" .. tostring(autoExecuteFlag)
            .. " resume=" .. tostring(resumeFlag)
            .. " nonce=" .. tostring(
                Runtime.Transport and Runtime.Transport.ActiveRejoinNonce
            )
            .. " claimedNonce=" .. tostring(
                env.__ZOLO_EGGS_ESP_CLAIMED_REJOIN_NONCE
            )
            .. " machineActive=" .. tostring(
                transport.ActiveRejoin ~= nil
            )
            .. " attempt=" .. tostring(
                transport.ActiveRejoin
                and transport.ActiveRejoin.Attempts
                or 0
            )
            .. " loaderQueued=" .. tostring(
                transport.ActiveRejoin
                and transport.ActiveRejoin.QueueInstalled
                or false
            ))

        -- 3) AUTO PLACE / KG
        local placeState =
            Runtime.EggAutomation
            and Runtime.EggAutomation.State
            or {}

        local placeMin = tonumber(placeState.PlaceMinWeightKg) or 0
        local candidates = {}

        if Runtime.EggAutomation
            and type(Runtime.EggAutomation.GetPlaceCandidatesLight) == "function" then
            local ok, result = pcall(
                Runtime.EggAutomation.GetPlaceCandidatesLight,
                true
            )
            if ok and type(result) == "table" then
                candidates = result
            else
                print("[AUTOPLACE] candidate scan ERROR: " .. tostring(result))
            end
        end

        local top = candidates[1]
        local enabledFilters = 0
        for _, enabled in pairs(placeState.PlaceEggFilters or {}) do
            if enabled == true then
                enabledFilters = enabledFilters + 1
            end
        end

        print("[AUTOPLACE]"
            .. " enabled=" .. tostring(placeState.AutoPlace == true)
            .. " minKg=" .. tostring(placeMin)
            .. " filters=" .. tostring(enabledFilters)
            .. " bagDirty=" .. tostring(
                Runtime.EggAutomation
                and Runtime.EggAutomation.BagCacheDirty
            )
            .. " dirtyReason=" .. tostring(
                Runtime.EggAutomation
                and Runtime.EggAutomation.BagCacheDirtyReason
            )
            .. " candidates=" .. tostring(#candidates))

        if top then
            print("[AUTOPLACE TOP]"
                .. " egg=" .. tostring(top.Name)
                .. " kg=" .. tostring(top.WeightKg)
                .. " kgSource=" .. tostring(top.WeightSource)
                .. " rarity=" .. tostring(top.Rarity)
                .. " luck=" .. tostring(top.Luck))
        else
            print("[AUTOPLACE TOP] none")
        end

        print("Keep F8 debug ON before testing Rejoin.")
        print("After rejoin, check F9/console for [ZOLO REJOIN DEBUG] lines.")
        print("========================================")
        return
    end

    if listeningForKey then

        if input.UserInputType == Enum.UserInputType.Keyboard then

            tpKeybind = input.KeyCode

            listeningForKey = false

            Runtime.UIRegs.KeybindBtn.Text =

                "Home TP Key: [" .. tpKeybind.Name .. "]"

            Runtime.UIRegs.KeybindBtn.TextColor3 =

                Color3.fromRGB(180, 180, 180)

        end

        return

    end

    if gameProcessed then

        return

    end

    if input.UserInputType == Enum.UserInputType.Keyboard then

        if input.KeyCode == tpKeybind then

            teleportToHomePlot()

        end

    end

end))

--==================================================

-- ACTUALIZACIÓN AUTOMÁTICA DEL ESP

--==================================================

task.spawn(function()

    while Runtime.Alive and ScreenGui.Parent do

        if mainESPActive then
            -- Filter/show state changes are event-driven. This loop only refreshes
            -- text metadata for labels that are already active.
            local refreshed = 0
            if Runtime.LiveEggData and Runtime.LiveEggData.RefreshIndex then
                Runtime.LiveEggData.RefreshIndex(false)
            end
            for egg, data in pairs(eggData) do
                if egg and egg.Parent == RenderedEggsFolder
                    and data.ESPShouldShow and data.NameBillboard and data.NameBillboard.Parent then
                    local ok, err = pcall(updateEggLabel, egg)
                    if not ok then
                        Runtime.ESPErrors = (Runtime.ESPErrors or 0) + 1
                        Runtime.LastESPError = tostring(err)
                    end
                    refreshed = refreshed + 1
                    if refreshed % 16 == 0 then task.wait() end
                end
            end
            task.wait(math.max(0.50, tonumber(Config.ESPMetadataRefresh) or 1.00))
        else
            task.wait(1.00)
        end

    end

end)

--==================================================

-- DETECTAR EGGS NUEVOS / ELIMINADOS

--==================================================

if RenderedEggsFolder then

    trackRuntimeConnection(RenderedEggsFolder.ChildAdded:Connect(function(egg)
        if not Runtime.Alive then
            return
        end

        autoFarmProcessed[egg] = nil

        -- Queue ESP work so a reset burst is spread across frames.
        queueEggESPUpdate(egg)
        scheduleEggListRefresh()
    end))

    trackRuntimeConnection(RenderedEggsFolder.ChildRemoved:Connect(function(egg)
        if not Runtime.Alive then
            return
        end

        autoFarmProcessed[egg] = nil
        pendingEggESPUpdates[egg] = nil
        removeEggData(egg)

        scheduleEggListRefresh()
    end))

    -- Cargar los Eggs que ya existen.

    for _, egg in ipairs(RenderedEggsFolder:GetChildren()) do
        queueEggESPUpdate(egg)
    end

end

--==================================================
-- BIG FROOT-INSPIRED VISUAL POLISH (UI ONLY)
--==================================================
local function applyBigFrootInspiredTheme()
    -- One startup pass only: no render-loop work, no feature-state changes.
    for _, object in ipairs(MainFrame:GetDescendants()) do
        if object:IsA("TextButton") then
            object.BorderSizePixel = 0
            if object.Font == Enum.Font.SourceSans or object.Font == Enum.Font.SourceSansBold then
                object.Font = Enum.Font.GothamMedium
            end
        elseif object:IsA("TextBox") then
            object.BorderSizePixel = 0
            object.Font = Enum.Font.Gotham
            object.PlaceholderColor3 = Color3.fromRGB(112, 123, 141)
        elseif object:IsA("TextLabel") then
            if object.Font == Enum.Font.SourceSans then
                object.Font = Enum.Font.Gotham
            elseif object.Font == Enum.Font.SourceSansBold then
                object.Font = Enum.Font.GothamBold
            end
        elseif object:IsA("ScrollingFrame") then
            object.ScrollBarImageColor3 = Color3.fromRGB(73, 91, 117)
            object.ScrollBarImageTransparency = 0.15
        end
    end

    StatusLabel.TextColor3 = Color3.fromRGB(96, 214, 161)
    if Runtime.UIRegs.ESPColorPanel and Runtime.UIRegs.ESPColorPanel.Parent then
        Runtime.UIRegs.ESPColorPanel.BackgroundColor3 = Color3.fromRGB(20, 24, 31)
        Runtime.UIRegs.ESPColorPanel.BackgroundTransparency = 0
    end
end

applyBigFrootInspiredTheme()

--==================================================

-- MODO PC

--==================================================

local function setPCMode()

    isMobileMode = false

    currentExpandedWidth = Config.PCWidth

    currentExpandedHeight = Config.PCHeight

    MainFrame.Size = UDim2.new(0, Config.PCWidth, 0, Config.PCHeight)

    MainFrame.Position = UDim2.new(0.5, -Config.PCWidth / 2, 0.4, -Config.PCHeight / 2)

    TopBar.Size = UDim2.new(1, 0, 0, 50)

    AuthorLabel.TextSize = 11

    AuthorLabel.Position = UDim2.new(0, 10, 0, 3)

    TitleLabel.TextSize = 14

    TitleLabel.Position = UDim2.new(0, 10, 0, 18)

    GameLabel.TextSize = 10

    GameLabel.Position = UDim2.new(0, 10, 0, 34)

    MinimizeBtn.Size = UDim2.new(0, 30, 0, 30)

    MinimizeBtn.Position = UDim2.new(1, -35, 0, 10)

    if Runtime.SpawnNotifications and Runtime.SpawnNotifications.UI.Bell then
        Runtime.SpawnNotifications.UI.Bell.Size = UDim2.fromOffset(28, 28)
        Runtime.SpawnNotifications.UI.Bell.Position = UDim2.new(1, -68, 0, 11)
    end

    ContentContainer.Size = UDim2.new(1, -20, 1, -60)

    ContentContainer.Position = UDim2.new(0, 10, 0, 55)

    StatusLabel.TextSize = 11

    -- Big Froot-inspired desktop layout: compact left navigation + content canvas.
    Runtime.UIRegs.TabBar.Size = UDim2.new(0, 124, 1, -30)
    Runtime.UIRegs.TabBar.Position = UDim2.new(0, 0, 0, 24)

    Runtime.UIRegs.PagesContainer.Size = UDim2.new(1, -136, 1, -30)
    Runtime.UIRegs.PagesContainer.Position = UDim2.new(0, 136, 0, 24)

    local desktopTabs = {Runtime.UIRegs.EggsTabBtn, Runtime.UIRegs.AutomationTabBtn, Runtime.UIRegs.MiscTabBtn, Runtime.UIRegs.LuckTabBtn, Runtime.UIRegs.SettingsTabBtn}
    for index, button in ipairs(desktopTabs) do
        button.Size = UDim2.new(1, -12, 0, 38)
        button.Position = UDim2.new(0, 6, 0, 8 + (index - 1) * 44)
        button.TextSize = 10
        button.TextXAlignment = Enum.TextXAlignment.Left
        button.Text = ({"  Eggs", "  Place / Hatch", "  Misc", "  Luck", "  Settings"})[index]
    end

    -- PC polish: keep Place/Hatch controls comfortably readable and fully reachable.
    Runtime.UIRegs.AutomationPage.ScrollBarThickness = 3
    Runtime.UIRegs.AutomationPage.CanvasSize = UDim2.new(0, 0, 0, 440)
    Runtime.UIRegs.SettingsPage.ScrollBarThickness = 3
    Runtime.UIRegs.SettingsPage.CanvasSize = UDim2.new(0, 0, 0, 670)

    do
        local ui = Runtime.EggAutomation.UI
        if ui.PageTitle then
            ui.PageTitle.Size = UDim2.new(1, -6, 0, 22)
            ui.PageTitle.Position = UDim2.new(0, 0, 0, 0)
            ui.PageTitle.TextSize = 14
        end
        if ui.PageHint then
            ui.PageHint.Size = UDim2.new(1, -8, 0, 42)
            ui.PageHint.Position = UDim2.new(0, 0, 0, 26)
            ui.PageHint.TextSize = 10
        end
        if ui.AutoPlaceBtn then
            ui.AutoPlaceBtn.Size = UDim2.new(0.5, -5, 0, 32)
            ui.AutoPlaceBtn.Position = UDim2.new(0, 0, 0, 74)
            ui.AutoPlaceBtn.TextSize = 11
        end
        if ui.AutoHatchBtn then
            ui.AutoHatchBtn.Size = UDim2.new(0.5, -5, 0, 32)
            ui.AutoHatchBtn.Position = UDim2.new(0.5, 5, 0, 74)
            ui.AutoHatchBtn.TextSize = 11
        end
        if ui.PriorityBtn then
            ui.PriorityBtn.Size = UDim2.new(1, -2, 0, 30)
            ui.PriorityBtn.Position = UDim2.new(0, 0, 0, 112)
            ui.PriorityBtn.TextSize = 10
        end
        if ui.SameNestLabel then
            ui.SameNestLabel.Size = UDim2.new(1, -2, 0, 24)
            ui.SameNestLabel.Position = UDim2.new(0, 0, 0, 147)
            ui.SameNestLabel.TextSize = 10
        end
        if ui.PlaceFilterTitle then
            ui.PlaceFilterTitle.Position = UDim2.new(0, 0, 0, 178)
            ui.PlaceFilterTitle.TextSize = 10
        end
        if ui.PlaceFilterSearch then
            ui.PlaceFilterSearch.Size = UDim2.new(1, -2, 0, 26)
            ui.PlaceFilterSearch.Position = UDim2.new(0, 0, 0, 199)
            ui.PlaceFilterSearch.TextSize = 10
        end
        if ui.PlaceFilterScroll then
            ui.PlaceFilterScroll.Size = UDim2.new(1, -2, 0, 100)
            ui.PlaceFilterScroll.Position = UDim2.new(0, 0, 0, 231)
            ui.PlaceFilterScroll.ScrollBarThickness = 4
        end
        if ui.HatchFilterTitle then
            ui.HatchFilterTitle.Position = UDim2.new(0, 0, 0, 339)
            ui.HatchFilterTitle.TextSize = 10
        end
        if ui.HatchFilterSearch then
            ui.HatchFilterSearch.Size = UDim2.new(1, -2, 0, 26)
            ui.HatchFilterSearch.Position = UDim2.new(0, 0, 0, 360)
            ui.HatchFilterSearch.TextSize = 10
        end
        if ui.HatchFilterScroll then
            ui.HatchFilterScroll.Size = UDim2.new(1, -2, 0, 100)
            ui.HatchFilterScroll.Position = UDim2.new(0, 0, 0, 392)
            ui.HatchFilterScroll.ScrollBarThickness = 4
        end
        if ui.PlaceNowBtn then
            ui.PlaceNowBtn.Size = UDim2.new(0.5, -5, 0, 29)
            ui.PlaceNowBtn.Position = UDim2.new(0, 0, 0, 500)
            ui.PlaceNowBtn.TextSize = 10
        end
        if ui.HatchNowBtn then
            ui.HatchNowBtn.Size = UDim2.new(0.5, -5, 0, 29)
            ui.HatchNowBtn.Position = UDim2.new(0.5, 5, 0, 500)
            ui.HatchNowBtn.TextSize = 10
        end
        if ui.StatusLabel then
            ui.StatusLabel.Size = UDim2.new(1, -2, 0, 78)
            ui.StatusLabel.Position = UDim2.new(0, 0, 0, 536)
            ui.StatusLabel.TextSize = 10
        end
        if ui.PlaceFilterButtons then
            for _, eggButton in pairs(ui.PlaceFilterButtons) do
                eggButton.TextSize = 9
            end
        end
        if ui.HatchFilterButtons then
            for _, eggButton in pairs(ui.HatchFilterButtons) do
                eggButton.TextSize = 9
            end
        end
        Runtime.UIRegs.AutomationPage.CanvasSize = UDim2.new(0, 0, 0, 635)
        Runtime.Weight.LayoutPlace()
        if Runtime.EggAutomation.ApplyFilterCollapseLayout then Runtime.EggAutomation.ApplyFilterCollapseLayout() end
    end

    ModeAutoFarmBtn.Size = UDim2.new(0.5, -3, 0, 30)

    ModeTeleportBtn.Size = UDim2.new(0.5, -3, 0, 30)

    Runtime.UIRegs.ToggleGlobalESPBtn.Size = UDim2.new(1, 0, 0, 32)

    Runtime.UIRegs.AutoBestEggBtn.Size = UDim2.new(1, 0, 0, 32)

    Runtime.UIRegs.TPHomeBtn.Size = UDim2.new(1, 0, 0, 32)

    StopAutoFarmBtn.Size = UDim2.new(1, 0, 0, 28)

    Runtime.UIRegs.KeybindBtn.Size = UDim2.new(1, 0, 0, 28)
    Runtime.UIRegs.KeybindBtn.Text = "Home TP Key: [" .. tpKeybind.Name .. "]"
    Runtime.UIRegs.KeybindBtn.TextColor3 = Color3.fromRGB(180, 180, 180)

    if Runtime.Transport.UI.AutoReconnect then
        Runtime.Transport.UI.AutoReconnect.TextSize = 10
    end
    if Runtime.Transport.UI.AutoExecute then
        Runtime.Transport.UI.AutoExecute.TextSize = 10
    end

    Runtime.UIRegs.ToggleGlobalESPBtn.Position = UDim2.new(0, 0, 0, 0)
    Runtime.UIRegs.ESPColorPanel.Position = UDim2.new(0, 0, 0, 40)
    Runtime.UIRegs.ESPColorPanel.Size = UDim2.new(1, 0, 0, 56)
    Runtime.UIRegs.ESPColorTitle.TextSize = 10
    if Runtime.DropEggQ and Runtime.DropEggQ.UI.Title then
        Runtime.DropEggQ.UI.Title.Position = UDim2.new(0, 0, 0, 104)
        Runtime.DropEggQ.UI.Title.TextSize = 11
    end
    if Runtime.DropEggQ and Runtime.DropEggQ.UI.Toggle then
        Runtime.DropEggQ.UI.Toggle.Position = UDim2.new(0, 0, 0, 126)
        Runtime.DropEggQ.UI.Toggle.Size = UDim2.new(1, 0, 0, 32)
        Runtime.DropEggQ.UI.Toggle.TextSize = 11
    end
    if Runtime.AutoFeed.UI.Title then
        Runtime.AutoFeed.UI.Title.Position = UDim2.new(0, 0, 0, 174)
        Runtime.AutoFeed.UI.Title.TextSize = 12
    end
    if Runtime.AutoFeed.UI.Toggle then
        Runtime.AutoFeed.UI.Toggle.Position = UDim2.new(0, 0, 0, 198)
        Runtime.AutoFeed.UI.Toggle.Size = UDim2.new(1, 0, 0, 32)
        Runtime.AutoFeed.UI.Toggle.TextSize = 11
    end
    if Runtime.AutoFeed.UI.AgeLabel then
        Runtime.AutoFeed.UI.AgeLabel.Position = UDim2.new(0, 0, 0, 235)
        Runtime.AutoFeed.UI.AgeLabel.Size = UDim2.new(1, 0, 0, 16)
        Runtime.AutoFeed.UI.AgeLabel.TextSize = 9
    end
    if Runtime.AutoFeed.UI.AgeControl then
        Runtime.AutoFeed.UI.AgeControl.Position = UDim2.new(0, 0, 0, 254)
        Runtime.AutoFeed.UI.AgeControl.Size = UDim2.new(1, 0, 0, 28)
    end
    if Runtime.AutoFeed.UI.Hint then
        Runtime.AutoFeed.UI.Hint.Position = UDim2.new(0, 0, 0, 288)
        Runtime.AutoFeed.UI.Hint.Size = UDim2.new(1, 0, 0, 36)
        Runtime.AutoFeed.UI.Hint.TextSize = 9
    end
    if Runtime.AutoFeed.UI.Status then
        Runtime.AutoFeed.UI.Status.Position = UDim2.new(0, 0, 0, 328)
        Runtime.AutoFeed.UI.Status.Size = UDim2.new(1, 0, 0, 52)
        Runtime.AutoFeed.UI.Status.TextSize = 9
    end
    Runtime.UIRegs.ListContainerFrame.Position = UDim2.new(0, 0, 0, 62)
    Runtime.UIRegs.ListContainerFrame.Size = UDim2.new(1, 0, 1, -62)

    Runtime.UIRegs.EggCountLabel.TextSize = 11

    Runtime.UIRegs.RefreshBtn.Size = UDim2.new(0.48, -5, 0, 25)

    Runtime.UIRegs.RefreshBtn.Position = UDim2.new(0, 5, 0, 27)

    Runtime.UIRegs.RefreshBtn.TextSize = 12

    Runtime.UIRegs.SortBtn.Size = UDim2.new(0.48, -5, 0, 25)

    Runtime.UIRegs.SortBtn.Position = UDim2.new(0.52, 0, 0, 27)

    Runtime.UIRegs.SortBtn.TextSize = 12

    Runtime.UIRegs.SearchBox.Size = UDim2.new(1, -10, 0, 25)

    Runtime.UIRegs.SearchBox.Position = UDim2.new(0, 5, 0, 57)

    Runtime.UIRegs.SearchBox.TextSize = 12

    Runtime.UIRegs.ScrollList.Size = UDim2.new(1, -10, 1, -87)

    Runtime.UIRegs.ScrollList.Position = UDim2.new(0, 5, 0, 87)

    layoutEggsPage()
    updateSelectedEggPanel()

    LuckValueLabel.Size = UDim2.new(1, 0, 0, 30)
    LuckValueLabel.Position = UDim2.new(0, 0, 0, 28)
    LuckValueLabel.TextSize = 12

    LuckStatusLabel.Size = UDim2.new(1, 0, 0, 64)
    LuckStatusLabel.Position = UDim2.new(0, 0, 0, 66)
    LuckStatusLabel.TextSize = 11

    AutoHatchLuckBtn.Position = UDim2.new(0, 0, 0, 140)
    AutoHatchLuckBtn.Size = UDim2.new(1, 0, 0, 32)
    AutoHatchLuckBtn.TextSize = 12

    if Runtime.LuckAlertSilencer.UI.ToggleBtn then
        Runtime.LuckAlertSilencer.UI.ToggleBtn.Position = UDim2.new(0, 0, 0, 180)
        Runtime.LuckAlertSilencer.UI.ToggleBtn.Size = UDim2.new(1, 0, 0, 32)
        Runtime.LuckAlertSilencer.UI.ToggleBtn.TextSize = 11
    end

    FindLuckBoardBtn.Position = UDim2.new(0, 0, 0, 220)
    FindLuckBoardBtn.Size = UDim2.new(1, 0, 0, 32)
    FindLuckBoardBtn.TextSize = 12

    Runtime.ESPFilter.Layout()
    Runtime.Weight.LayoutPlace()

    if DeviceFrame and DeviceFrame.Parent then

        DeviceFrame:Destroy()

    end

    MainFrame.Visible = true

    if Runtime.FloatingToggle and Runtime.FloatingToggle.SetReady then
        Runtime.FloatingToggle.SetReady(true)
    end

    selectTab("Eggs")

    populateList()

end

-- MOBILE MODE

--==================================================

local function setMobileMode()

    isMobileMode = true

    currentExpandedWidth = Config.MobileWidth

    currentExpandedHeight = Config.MobileHeight

    MainFrame.Size = UDim2.new(0, Config.MobileWidth, 0, Config.MobileHeight)

    MainFrame.Position = UDim2.new(0.5, -Config.MobileWidth / 2, 0.5, -Config.MobileHeight / 2)

    TopBar.Size = UDim2.new(1, 0, 0, 44)

    AuthorLabel.TextSize = 10

    AuthorLabel.Position = UDim2.new(0, 10, 0, 3)

    TitleLabel.TextSize = 13

    TitleLabel.Position = UDim2.new(0, 10, 0, 15)

    GameLabel.TextSize = 9

    GameLabel.Position = UDim2.new(0, 10, 0, 29)

    MinimizeBtn.Size = UDim2.new(0, 28, 0, 28)

    MinimizeBtn.Position = UDim2.new(1, -32, 0, 8)

    if Runtime.SpawnNotifications and Runtime.SpawnNotifications.UI.Bell then
        Runtime.SpawnNotifications.UI.Bell.Size = UDim2.fromOffset(26, 26)
        Runtime.SpawnNotifications.UI.Bell.Position = UDim2.new(1, -62, 0, 9)
    end

    MinimizeBtn.TextSize = 16

    ContentContainer.Size = UDim2.new(1, -16, 1, -52)

    ContentContainer.Position = UDim2.new(0, 8, 0, 48)

    StatusLabel.TextSize = 10

    Runtime.UIRegs.TabBar.Size = UDim2.new(1, 0, 0, 30)
    Runtime.UIRegs.TabBar.Position = UDim2.new(0, 0, 0, 21)

    Runtime.UIRegs.PagesContainer.Size = UDim2.new(1, 0, 1, -56)
    Runtime.UIRegs.PagesContainer.Position = UDim2.new(0, 0, 0, 56)

    local mobileTabs = {Runtime.UIRegs.EggsTabBtn, Runtime.UIRegs.AutomationTabBtn, Runtime.UIRegs.MiscTabBtn, Runtime.UIRegs.LuckTabBtn, Runtime.UIRegs.SettingsTabBtn}
    local mobileNames = {"Eggs", "Place/Hatch", "Misc", "Luck", "Settings"}
    for index, button in ipairs(mobileTabs) do
        button.Size = UDim2.new(0.20, -3, 1, -4)
        button.Position = UDim2.new((index - 1) * 0.20, index == 1 and 0 or 1, 0, 2)
        button.TextSize = 8
        button.TextXAlignment = Enum.TextXAlignment.Center
        button.Text = mobileNames[index]
    end

    -- Mobile polish: long controls use full-width rows instead of being squeezed.
    Runtime.UIRegs.AutomationPage.ScrollBarThickness = 4
    Runtime.UIRegs.AutomationPage.CanvasSize = UDim2.new(0, 0, 0, 565)
    Runtime.UIRegs.SettingsPage.ScrollBarThickness = 4
    Runtime.UIRegs.SettingsPage.CanvasSize = UDim2.new(0, 0, 0, 690)

    do
        local ui = Runtime.EggAutomation.UI
        if ui.PageTitle then
            ui.PageTitle.Size = UDim2.new(1, -8, 0, 20)
            ui.PageTitle.Position = UDim2.new(0, 0, 0, 0)
            ui.PageTitle.TextSize = 12
        end
        if ui.PageHint then
            ui.PageHint.Size = UDim2.new(1, -10, 0, 50)
            ui.PageHint.Position = UDim2.new(0, 0, 0, 24)
            ui.PageHint.TextSize = 9
        end
        if ui.AutoPlaceBtn then
            ui.AutoPlaceBtn.Size = UDim2.new(1, -6, 0, 29)
            ui.AutoPlaceBtn.Position = UDim2.new(0, 0, 0, 80)
            ui.AutoPlaceBtn.TextSize = 9
        end
        if ui.AutoHatchBtn then
            ui.AutoHatchBtn.Size = UDim2.new(1, -6, 0, 29)
            ui.AutoHatchBtn.Position = UDim2.new(0, 0, 0, 115)
            ui.AutoHatchBtn.TextSize = 9
        end
        if ui.PriorityBtn then
            ui.PriorityBtn.Size = UDim2.new(1, -6, 0, 28)
            ui.PriorityBtn.Position = UDim2.new(0, 0, 0, 150)
            ui.PriorityBtn.TextSize = 9
        end
        if ui.SameNestLabel then
            ui.SameNestLabel.Size = UDim2.new(1, -6, 0, 34)
            ui.SameNestLabel.Position = UDim2.new(0, 0, 0, 184)
            ui.SameNestLabel.TextSize = 8
        end
        if ui.PlaceFilterTitle then
            ui.PlaceFilterTitle.Size = UDim2.new(1, -6, 0, 18)
            ui.PlaceFilterTitle.Position = UDim2.new(0, 0, 0, 225)
            ui.PlaceFilterTitle.TextSize = 9
        end
        if ui.PlaceFilterSearch then
            ui.PlaceFilterSearch.Size = UDim2.new(1, -6, 0, 25)
            ui.PlaceFilterSearch.Position = UDim2.new(0, 0, 0, 246)
            ui.PlaceFilterSearch.TextSize = 9
        end
        if ui.PlaceFilterScroll then
            ui.PlaceFilterScroll.Size = UDim2.new(1, -6, 0, 100)
            ui.PlaceFilterScroll.Position = UDim2.new(0, 0, 0, 277)
            ui.PlaceFilterScroll.ScrollBarThickness = 4
        end
        if ui.HatchFilterTitle then
            ui.HatchFilterTitle.Size = UDim2.new(1, -6, 0, 18)
            ui.HatchFilterTitle.Position = UDim2.new(0, 0, 0, 385)
            ui.HatchFilterTitle.TextSize = 9
        end
        if ui.HatchFilterSearch then
            ui.HatchFilterSearch.Size = UDim2.new(1, -6, 0, 25)
            ui.HatchFilterSearch.Position = UDim2.new(0, 0, 0, 406)
            ui.HatchFilterSearch.TextSize = 9
        end
        if ui.HatchFilterScroll then
            ui.HatchFilterScroll.Size = UDim2.new(1, -6, 0, 100)
            ui.HatchFilterScroll.Position = UDim2.new(0, 0, 0, 437)
            ui.HatchFilterScroll.ScrollBarThickness = 4
        end
        if ui.PlaceNowBtn then
            ui.PlaceNowBtn.Size = UDim2.new(1, -6, 0, 28)
            ui.PlaceNowBtn.Position = UDim2.new(0, 0, 0, 545)
            ui.PlaceNowBtn.TextSize = 9
        end
        if ui.HatchNowBtn then
            ui.HatchNowBtn.Size = UDim2.new(1, -6, 0, 28)
            ui.HatchNowBtn.Position = UDim2.new(0, 0, 0, 579)
            ui.HatchNowBtn.TextSize = 9
        end
        if ui.StatusLabel then
            ui.StatusLabel.Size = UDim2.new(1, -6, 0, 102)
            ui.StatusLabel.Position = UDim2.new(0, 0, 0, 615)
            ui.StatusLabel.TextSize = 9
        end
        if ui.PlaceFilterButtons then
            for _, eggButton in pairs(ui.PlaceFilterButtons) do
                eggButton.TextSize = 8
            end
        end
        if ui.HatchFilterButtons then
            for _, eggButton in pairs(ui.HatchFilterButtons) do
                eggButton.TextSize = 8
            end
        end
        Runtime.UIRegs.AutomationPage.CanvasSize = UDim2.new(0, 0, 0, 735)
        Runtime.Weight.LayoutPlace()
        if Runtime.EggAutomation.ApplyFilterCollapseLayout then Runtime.EggAutomation.ApplyFilterCollapseLayout() end
    end

    ModeAutoFarmBtn.Size = UDim2.new(0.5, -3, 0, 27)

    ModeTeleportBtn.Size = UDim2.new(0.5, -3, 0, 27)

    ModeAutoFarmBtn.TextSize = 10

    ModeTeleportBtn.TextSize = 10

    Runtime.UIRegs.ToggleGlobalESPBtn.Size = UDim2.new(1, 0, 0, 28)

    Runtime.UIRegs.ToggleGlobalESPBtn.Position = UDim2.new(0, 0, 0, 0)

    Runtime.UIRegs.ToggleGlobalESPBtn.TextSize = 10

    Runtime.UIRegs.AutoBestEggBtn.Size = UDim2.new(1, 0, 0, 28)

    Runtime.UIRegs.AutoBestEggBtn.Position = UDim2.new(0, 0, 0, 68)

    Runtime.UIRegs.AutoBestEggBtn.TextSize = 10

    Runtime.UIRegs.TPHomeBtn.Size = UDim2.new(1, 0, 0, 28)

    Runtime.UIRegs.TPHomeBtn.Position = UDim2.new(0, 0, 0, 102)

    Runtime.UIRegs.TPHomeBtn.TextSize = 10

    StopAutoFarmBtn.Size = UDim2.new(1, 0, 0, 25)

    StopAutoFarmBtn.Position = UDim2.new(0, 0, 0, 136)

    StopAutoFarmBtn.TextSize = 9

    Runtime.UIRegs.KeybindBtn.Size = UDim2.new(1, 0, 0, 25)

    Runtime.UIRegs.KeybindBtn.TextSize = 9
    Runtime.UIRegs.KeybindBtn.Text = "Mobile Home TP (tap)"
    Runtime.UIRegs.KeybindBtn.TextColor3 = Color3.fromRGB(180, 180, 180)

    SettingsHint.TextSize = 9

    if Runtime.Transport.UI.AutoReconnect then
        Runtime.Transport.UI.AutoReconnect.TextSize = 9
    end
    if Runtime.Transport.UI.AutoExecute then
        Runtime.Transport.UI.AutoExecute.TextSize = 9
    end

    Runtime.UIRegs.ESPColorPanel.Position = UDim2.new(0, 0, 0, 34)
    Runtime.UIRegs.ESPColorPanel.Size = UDim2.new(1, 0, 0, 52)
    Runtime.UIRegs.ESPColorTitle.TextSize = 9
    if Runtime.DropEggQ and Runtime.DropEggQ.UI.Title then
        Runtime.DropEggQ.UI.Title.Position = UDim2.new(0, 0, 0, 92)
        Runtime.DropEggQ.UI.Title.TextSize = 9
    end
    if Runtime.DropEggQ and Runtime.DropEggQ.UI.Toggle then
        Runtime.DropEggQ.UI.Toggle.Position = UDim2.new(0, 0, 0, 112)
        Runtime.DropEggQ.UI.Toggle.Size = UDim2.new(1, 0, 0, 28)
        Runtime.DropEggQ.UI.Toggle.TextSize = 9
    end
    if Runtime.AutoFeed.UI.Title then
        Runtime.AutoFeed.UI.Title.Position = UDim2.new(0, 0, 0, 150)
        Runtime.AutoFeed.UI.Title.TextSize = 10
    end
    if Runtime.AutoFeed.UI.Toggle then
        Runtime.AutoFeed.UI.Toggle.Position = UDim2.new(0, 0, 0, 172)
        Runtime.AutoFeed.UI.Toggle.Size = UDim2.new(1, 0, 0, 28)
        Runtime.AutoFeed.UI.Toggle.TextSize = 9
    end
    if Runtime.AutoFeed.UI.AgeLabel then
        Runtime.AutoFeed.UI.AgeLabel.Position = UDim2.new(0, 0, 0, 205)
        Runtime.AutoFeed.UI.AgeLabel.Size = UDim2.new(1, 0, 0, 14)
        Runtime.AutoFeed.UI.AgeLabel.TextSize = 8
    end
    if Runtime.AutoFeed.UI.AgeControl then
        Runtime.AutoFeed.UI.AgeControl.Position = UDim2.new(0, 0, 0, 222)
        Runtime.AutoFeed.UI.AgeControl.Size = UDim2.new(1, 0, 0, 26)
    end
    if Runtime.AutoFeed.UI.Hint then
        Runtime.AutoFeed.UI.Hint.Position = UDim2.new(0, 0, 0, 253)
        Runtime.AutoFeed.UI.Hint.Size = UDim2.new(1, 0, 0, 42)
        Runtime.AutoFeed.UI.Hint.TextSize = 8
    end
    if Runtime.AutoFeed.UI.Status then
        Runtime.AutoFeed.UI.Status.Position = UDim2.new(0, 0, 0, 299)
        Runtime.AutoFeed.UI.Status.Size = UDim2.new(1, 0, 0, 56)
        Runtime.AutoFeed.UI.Status.TextSize = 8
    end
    Runtime.UIRegs.ListContainerFrame.Position = UDim2.new(0, 0, 0, 56)
    Runtime.UIRegs.ListContainerFrame.Size = UDim2.new(1, 0, 1, -56)

    Runtime.UIRegs.EggCountLabel.TextSize = 9

    Runtime.UIRegs.RefreshBtn.Size = UDim2.new(0.48, -5, 0, 22)

    Runtime.UIRegs.RefreshBtn.Position = UDim2.new(0, 5, 0, 25)

    Runtime.UIRegs.RefreshBtn.TextSize = 9

    Runtime.UIRegs.SortBtn.Size = UDim2.new(0.48, -5, 0, 22)

    Runtime.UIRegs.SortBtn.Position = UDim2.new(0.52, 0, 0, 25)

    Runtime.UIRegs.SortBtn.TextSize = 9

    Runtime.UIRegs.SearchBox.Size = UDim2.new(1, -10, 0, 22)

    Runtime.UIRegs.SearchBox.Position = UDim2.new(0, 5, 0, 51)

    Runtime.UIRegs.SearchBox.TextSize = 9

    Runtime.UIRegs.ScrollList.Size = UDim2.new(1, -10, 1, -78)

    Runtime.UIRegs.ScrollList.Position = UDim2.new(0, 5, 0, 78)

    layoutEggsPage()
    updateSelectedEggPanel()

    LuckTitle.TextSize = 12

    LuckValueLabel.Size = UDim2.new(1, 0, 0, 26)
    LuckValueLabel.Position = UDim2.new(0, 0, 0, 26)
    LuckValueLabel.TextSize = 9

    LuckStatusLabel.Size = UDim2.new(1, 0, 0, 52)
    LuckStatusLabel.Position = UDim2.new(0, 0, 0, 58)
    LuckStatusLabel.TextSize = 9

    AutoHatchLuckBtn.Position = UDim2.new(0, 0, 0, 116)
    AutoHatchLuckBtn.Size = UDim2.new(1, 0, 0, 27)
    AutoHatchLuckBtn.TextSize = 9

    if Runtime.LuckAlertSilencer.UI.ToggleBtn then
        Runtime.LuckAlertSilencer.UI.ToggleBtn.Position = UDim2.new(0, 0, 0, 149)
        Runtime.LuckAlertSilencer.UI.ToggleBtn.Size = UDim2.new(1, 0, 0, 27)
        Runtime.LuckAlertSilencer.UI.ToggleBtn.TextSize = 9
    end

    FindLuckBoardBtn.Position = UDim2.new(0, 0, 0, 182)
    FindLuckBoardBtn.Size = UDim2.new(1, 0, 0, 27)
    FindLuckBoardBtn.TextSize = 9

    Runtime.ESPFilter.Layout()
    Runtime.Weight.LayoutPlace()

    if DeviceFrame and DeviceFrame.Parent then

        DeviceFrame:Destroy()

    end

    MainFrame.Visible = true

    if Runtime.FloatingToggle and Runtime.FloatingToggle.SetReady then
        Runtime.FloatingToggle.SetReady(true)
    end

    selectTab("Eggs")

    populateList()

end

--==================================================

-- BOTONES DE DISPOSITIVO

--==================================================

PCBtn.Activated:Connect(function()

    setPCMode()

end)

MobileBtn.Activated:Connect(function()

    setMobileMode()

end)

-- Touch-only clients should not need to press a desktop-style device chooser.
-- Hybrid/touchscreen PCs keep the chooser unless Touch is actually preferred.
task.defer(function()
    if Runtime.Alive and DeviceFrame and DeviceFrame.Parent and Runtime.InputCompat.IsTouchPreferred() then
        setMobileMode()
        if StatusLabel then
            StatusLabel.Text = "● Mobile input detected — touch-safe controls enabled"
            StatusLabel.TextColor3 = Color3.fromRGB(0, 255, 120)
        end
    end
end)

--==================================================

-- FINAL

--==================================================



Runtime.ESPFilter.Layout()
Runtime.Weight.LayoutPlace()

-- If this execution came from Rejoin Below Min, restore its Min kg + TRUE
-- filters after the normal config autoload window, then resume Get Egg.
task.spawn(function()
    local deadline = os.clock() + 15
    while Runtime.Alive
        and not Runtime.Ready
        and os.clock() < deadline do
        task.wait(0.10)
    end

    -- Config auto-load is scheduled shortly after bootstrap. Give it one final
    -- settle interval so the rejoin payload wins deterministically afterward.
    task.wait(0.45)

    if Runtime.Alive and Runtime.AutoGet.ResumeRejoinBelowMinAfterTeleport then
        local ok, err = pcall(Runtime.AutoGet.ResumeRejoinBelowMinAfterTeleport)
        if not ok then
            RuntimeEnv.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
                "rejoin-resume: " .. tostring(err)
            warn("[ZOLO rejoin resume] " .. tostring(err))
        end
    end
end)

-- Start notifications last. This subsystem is intentionally non-fatal:
-- a notification error is logged but never aborts the main runtime.
task.defer(function()
    if not Runtime.Alive or not Runtime.SpawnNotifications then return end
    local ok, err = pcall(Runtime.SpawnNotifications.Start)
    if not ok then
        Runtime.SpawnNotifications.LastError = "Start: " .. tostring(err)
        warn("[SpawnNotifications] " .. Runtime.SpawnNotifications.LastError)
    end
end)

end -- Runtime.LateBootstrap

-- Last duplicate-startup barrier. If an Auto Execute copy and a manual copy
-- overlap, only the newest generation is allowed to finish activation.
if Runtime.IsSuperseded and Runtime.IsSuperseded() then
    return
end

local lateOk, lateError = xpcall(Runtime.LateBootstrap, function(err)
    local okTrace, trace = pcall(function()
        return debug.traceback(tostring(err), 2)
    end)
    return okTrace and trace or tostring(err)
end)

if not lateOk then
    Runtime.Starting = false
    Runtime.Ready = false
    Runtime.LastStartupError = tostring(lateError)
    RuntimeEnv.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR = Runtime.LastStartupError
    warn("[ZOLO LateBootstrap] " .. Runtime.LastStartupError)
else
    if Runtime.IsCurrentExecution and Runtime.IsCurrentExecution() then
        Runtime.Starting = false
        Runtime.Ready = true
        RuntimeEnv.__ZOLO_EGGS_ESP_QUEUED_BOOT = nil
        RuntimeEnv.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR = nil
    end
end

Runtime.LateBootstrap = nil


]=====]

pcall(function()
    if type(writefile) == "function" then
        if type(makefolder) == "function" then
            if type(isfolder) == "function" then
                if not isfolder("ZoloEggsESP") then
                    makefolder("ZoloEggsESP")
                end
            else
                pcall(makefolder, "ZoloEggsESP")
            end
        end
        writefile(__ZOLO_AUTORUN_PATH, __ZOLO_MAIN_SOURCE)
    end
end)

if type(loadstring) ~= "function" then
    error("Zolo Eggs ESP v3.69 requires loadstring support.")
end

local __ZOLO_CHUNK, __ZOLO_LOAD_ERROR = loadstring(__ZOLO_MAIN_SOURCE)
if not __ZOLO_CHUNK then
    local env = (getgenv and getgenv()) or _G
    env.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR =
        "compile: " .. tostring(__ZOLO_LOAD_ERROR)
    error("Zolo Eggs ESP v3.69 load error: " .. tostring(__ZOLO_LOAD_ERROR))
end

local __ZOLO_OK, __ZOLO_RUNTIME_ERROR = xpcall(__ZOLO_CHUNK, function(err)
    local okTrace, trace = pcall(function()
        return debug.traceback(tostring(err), 2)
    end)
    return okTrace and trace or tostring(err)
end)

if not __ZOLO_OK then
    local env = (getgenv and getgenv()) or _G
    env.__ZOLO_EGGS_ESP_LAST_STARTUP_ERROR = tostring(__ZOLO_RUNTIME_ERROR)
    env.__ZOLO_EGGS_ESP_QUEUED_BOOT = nil
    warn("[ZOLO startup] " .. tostring(__ZOLO_RUNTIME_ERROR))
    error("ZOLO startup failed: " .. tostring(__ZOLO_RUNTIME_ERROR))
end
