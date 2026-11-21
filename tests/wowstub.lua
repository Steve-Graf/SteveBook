-- wowstub.lua: a just-enough fake of the WoW API for tests that load the real addon files.
-- Usage:  local stub = assert(loadfile("tests/wowstub.lua"))()   -- installs globals, returns control table
-- It does not check that real templates or APIs exist in the game; it only lets the code run.
local unpack = table.unpack or unpack
local stub = {
    time = 1000000,            -- GetServerTime()
    mono = 5000,               -- GetTime() (monotonic seconds)
    player = "Tester",         -- UnitName("player")
    frames = {},               -- every frame created
    tickers = {},              -- C_Timer.NewTicker objects { fn, interval, cancelled }
    afters = {},               -- C_Timer.After callbacks, run by stub.runAfters()
    channels = {},             -- joined channel name -> id
    addonMessages = {},        -- C_ChatInfo.SendAddonMessage calls
    printed = {},              -- print() output
    errors = {},               -- errors passed to geterrorhandler()
    realPrint = print,         -- the real print: the stub captures the global one
}

------------------------------------------------------------------------------------------
-- Frames: any method we haven't defined is a no-op that returns the frame.
------------------------------------------------------------------------------------------

local Frame = {}
Frame.__index = function(self, k)
    local v = rawget(Frame, k)
    if v ~= nil then return v end
    return function() return self end
end

local function scripts(self) local s = rawget(self, "_scripts"); if not s then s = {}; rawset(self, "_scripts", s) end; return s end

function Frame.SetScript(self, name, fn) scripts(self)[name] = fn end
function Frame.GetScript(self, name) return scripts(self)[name] end
function Frame.HookScript(self, name, fn) if not scripts(self)[name] then scripts(self)[name] = fn end end
function Frame.RegisterEvent(self, ev) local e = rawget(self, "_events") or {}; rawset(self, "_events", e); e[ev] = true end
function Frame.UnregisterEvent(self, ev) local e = rawget(self, "_events"); if e then e[ev] = nil end end
function Frame.RegisterAllEvents() end
function Frame.SetText(self, t) rawset(self, "_text", t); local f = scripts(self).OnTextChanged; if f then f(self) end end
function Frame.GetText(self) return rawget(self, "_text") or "" end
function Frame.SetNumber(self, n) rawset(self, "_text", tostring(n)) end
function Frame.GetNumber(self) return tonumber(rawget(self, "_text")) or 0 end
function Frame.Show(self) rawset(self, "_shown", true); local f = scripts(self).OnShow; if f then f(self) end end
function Frame.Hide(self) rawset(self, "_shown", false); local f = scripts(self).OnHide; if f then f(self) end end
function Frame.SetShown(self, v) if v then self:Show() else self:Hide() end end
function Frame.IsShown(self) return rawget(self, "_shown") == true end
function Frame.IsVisible(self) return rawget(self, "_shown") == true end
function Frame.SetEnabled(self, v) rawset(self, "_enabled", v and true or false) end
function Frame.Enable(self) rawset(self, "_enabled", true) end
function Frame.Disable(self) rawset(self, "_enabled", false) end
function Frame.IsEnabled(self) return rawget(self, "_enabled") ~= false end
function Frame.SetChecked(self, v) rawset(self, "_checked", v and true or false) end
function Frame.GetChecked(self) return rawget(self, "_checked") == true end
function Frame.GetWidth() return 500 end
function Frame.GetHeight() return 400 end
function Frame.GetLeft() return 0 end
function Frame.GetRight() return 500 end
function Frame.GetTop() return 400 end
function Frame.GetBottom() return 0 end
function Frame.GetStringWidth(self) return #(rawget(self, "_text") or "") * 6 end
function Frame.GetVerticalScroll() return 0 end
function Frame.GetVerticalScrollRange() return 0 end
function Frame.GetFrameLevel() return 1 end
function Frame.GetFrameStrata() return "MEDIUM" end
function Frame.GetName(self) return rawget(self, "_name") end
function Frame.GetParent(self) return rawget(self, "_parent") end
function Frame.GetNumPoints() return 1 end
function Frame.GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function Frame.HasFocus() return false end
function Frame.Click(self) local f = scripts(self).OnClick; if f then f(self) end end
function Frame.CreateFontString(self) return setmetatable({ _text = "", _parent = self }, Frame) end
function Frame.CreateTexture(self) return setmetatable({ _parent = self }, Frame) end
function Frame.GetFontString(self) return setmetatable({ _text = "" }, Frame) end

local function newFrame(parent, name)
    local f = setmetatable({ _parent = parent, _name = name }, Frame)
    stub.frames[#stub.frames + 1] = f
    return f
end

function stub.newFrame() return newFrame() end

-- Find a frame by exact text (buttons, labels).
function stub.findByText(text)
    for _, f in ipairs(stub.frames) do if rawget(f, "_text") == text then return f end end
end

-- Deliver an event to every frame registered for it (as WoW would).
function stub.fire(event, ...)
    for _, f in ipairs(stub.frames) do
        local e = rawget(f, "_events")
        local h = rawget(f, "_scripts") and f._scripts.OnEvent
        if e and e[event] and h then h(f, event, ...) end
    end
end

-- Move both clocks forward and give every OnUpdate handler a tick (ChatThrottleLib despools
-- queued addon messages from OnUpdate, using GetTime).
function stub.advance(sec)
    stub.time = stub.time + sec
    stub.mono = stub.mono + sec
    for _, f in ipairs(stub.frames) do
        local h = rawget(f, "_scripts") and f._scripts.OnUpdate
        if h then h(f, sec) end
    end
end

function stub.runAfters()
    local list = stub.afters
    stub.afters = {}
    for _, a in ipairs(list) do a.fn() end
end

function stub.runTickers()
    for _, t in ipairs(stub.tickers) do if not t.cancelled then t.fn(t) end end
end

------------------------------------------------------------------------------------------
-- Globals
------------------------------------------------------------------------------------------

function stub.install()
    local G = _G
    -- WoW's Lua accepts extra arguments in xpcall(f, handler, ...); plain Lua 5.1 does not, and
    -- ChatThrottleLib relies on it. Make the stub environment behave like the game.
    do
        local raw = xpcall
        xpcall = function(f, h, ...)
            local n, args = select("#", ...), { ... }
            return raw(function() return f(unpack(args, 1, n)) end, h)
        end
    end
    G.CreateFrame = function(_, name, parent)
        local f = newFrame(parent, name)
        if name then G[name] = f end
        return f
    end
    G.UIParent = newFrame()
    G.UISpecialFrames = {}
    G.GameTooltip = newFrame()
    G.SlashCmdList = {}
    G.GetServerTime = function() return stub.time end
    G.GetTime = function() return stub.mono end
    G.GetFramerate = function() return 60 end
    G.UnitName = function() return stub.player end
    G.GetNormalizedRealmName = function() return "Realm" end
    G.floor = math.floor
    G.date = os.date
    G.strsplit = function(sep, s) local out = {}; for p in (s .. sep):gmatch("(.-)" .. sep:gsub("%p", "%%%0")) do out[#out + 1] = p end; return unpack(out) end
    G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    table.wipe = G.wipe
    G.tinsert = table.insert
    G.tremove = table.remove
    G.format = string.format
    G.geterrorhandler = function() return function(e) stub.errors[#stub.errors + 1] = tostring(e) end end
    G.hooksecurefunc = function() end
    G.securecallfunction = function(f, ...) return f(...) end
    G.issecretvalue = function() return false end
    -- the codes the wiki lists (Enum.SendAddonMessageResult)
    G.Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3, NotInGroup = 5, InvalidChannel = 7,
        ChannelThrottle = 8, GeneralError = 9, AddOnMessageLockdown = 11, TargetOffline = 12 } }
    G.DEFAULT_CHAT_FRAME = newFrame()
    G.NUM_CHAT_WINDOWS = 1
    G.ChatFrame1 = newFrame()
    G.ChatFrame_AddMessageEventFilter = function() end
    G.ChatFrame_RemoveChannel = function() end
    stub.nextChannel = 4
    G.JoinTemporaryChannel = function(name)
        if not stub.channels[name] then stub.nextChannel = stub.nextChannel + 1; stub.channels[name] = stub.nextChannel end
    end
    G.LeaveChannelByName = function(name) stub.channels[name] = nil end
    G.GetChannelName = function(name) return stub.channels[name] or 0 end
    G.RegisterAddonMessagePrefix = function() return true end
    G.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return true end,
        SendAddonMessage = function(prefix, text, chatType, target)
            -- stub.addonBudget = { tokens, burst, rate, last } models the game's per-prefix limit (10 burst,
            -- about 1 message a second after); an empty bucket answers AddonMessageThrottle (3) and sends nothing.
            local b = stub.addonBudget
            if b then
                b.tokens = math.min(b.burst, b.tokens + (stub.mono - b.last) * b.rate)
                b.last = stub.mono
                if b.tokens < 1 then b.refused = (b.refused or 0) + 1; return 3 end
                b.tokens = b.tokens - 1
            end
            stub.addonMessages[#stub.addonMessages + 1] = { prefix = prefix, text = text, chatType = chatType, target = target, at = stub.mono }
            return 0
        end,
    }
    G.C_Timer = {
        NewTicker = function(interval, fn)
            local t = { fn = fn, interval = interval }
            function t:Cancel() self.cancelled = true end
            stub.tickers[#stub.tickers + 1] = t
            return t
        end,
        After = function(sec, fn) stub.afters[#stub.afters + 1] = { sec = sec, fn = fn } end,
    }
    G.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        stub.printed[#stub.printed + 1] = table.concat(parts, " ")
    end
    G.SetCVar = function() end
    G.PlaySound = function() end
    G.SOUNDKIT = {}
    G.StaticPopupDialogs = {}
    G.StaticPopup_Show = function() end
    G.UIParentLoadAddOn = function() end
    G.IsShiftKeyDown = function() return false end
    G.IsControlKeyDown = function() return false end
end

function stub.lastPrint() return stub.printed[#stub.printed] or "" end

stub.install()
return stub
