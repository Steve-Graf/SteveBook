-- Core.lua: init, SavedVariables, slash commands.
local ADDON, ns = ...
local Model = ns.Model

local function say(msg) print("|cffffd100SteveBook:|r " .. msg) end

local function describe(b, i)
    return ("%s%s  %s  [%s]"):format(i and (i .. ". ") or "", b.name, b.code, b.ownerName or "?")
end

local function help()
    say("/book new <name>   create a book (generates a join code)")
    say("/book list         list your books")
    say("/book use <# or code>  choose the active book")
    say("/book bookie (or /bookie)  open the bookie window")
    say("/book bet (or /bet)        open the bettor window")
    say("/book loopback     test alone: let this character be bookie and bettor of its own book")
    say("/book debug        print every message sent and received (for troubleshooting)")
    say("/book              open the bettor window (same as /bet)")
    say("/book status       show the active book")
end

local function handle(msg)
    local db = SteveBookDB
    local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
    cmd = cmd:lower()

    if cmd == "new" then
        local b, err = Model.CreateBook(db, rest, UnitName("player"), GetServerTime())
        if not b then return say(err) end
        if ns.Comm then ns.Comm.JoinBook(b.code) end
        say("Created " .. describe(b) .. ". Share the code with friends.")
    elseif cmd == "list" then
        local books = Model.ListBooks(db)
        if #books == 0 then return say("No books yet. /book new <name>") end
        local active = db.activeBook
        for i, b in ipairs(books) do
            say(describe(b, i) .. (b.id == active and "  (active)" or ""))
        end
    elseif cmd == "use" then
        local b, err = Model.PickBook(db, rest)
        if not b then return say(err) end
        say("Active book: " .. describe(b))
    elseif cmd == "loopback" then
        db.loopback = not db.loopback
        if db.loopback then
            say("Loopback ON. Join your own book in /bet, then approve the member named " ..
                (ns.Comm and ns.Comm.LOOPBACK_NAME or "Loopback") .. " in /bookie.")
        else
            say("Loopback OFF.")
        end
    elseif cmd == "debug" then
        db.debug = not db.debug
        say(db.debug and "Debug ON: every message in and out is printed here. Run /book debug again to stop."
            or "Debug OFF.")
    elseif cmd == "bookie" or cmd == "bet" then
        local ui = ns.UI and ns.UI[cmd == "bookie" and "Bookie" or "Bettor"]
        if ui and ui.Toggle then ui.Toggle() else say("That window is not available yet.") end
    elseif cmd == "" then
        handle("bet")                       -- /book alone opens the bettor window
    elseif cmd == "status" then
        local b = Model.ActiveBook(db)
        if b then say("Active book: " .. describe(b)) else help() end
    else
        help()
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("ADDON_LOADED")
f:SetScript("OnEvent", function(_, _, name)
    if name ~= ADDON then return end
    SteveBookDB = SteveBookDB or Model.NewDB()
    SteveBookDB.cache = SteveBookDB.cache or ns.Cache.NewStore()   -- bettor-side cache (Cache.lua)
    math.randomseed(GetServerTime() + floor(GetTime() * 1000))
    f:UnregisterEvent("ADDON_LOADED")
end)

SLASH_STEVEBOOK1 = "/book"
SlashCmdList["STEVEBOOK"] = handle

-- Shortcuts: /bookie and /bet open the two windows directly.
SLASH_STEVEBOOKIE1 = "/bookie"
SlashCmdList["STEVEBOOKIE"] = function() handle("bookie") end
SLASH_STEVEBET1 = "/bet"
SlashCmdList["STEVEBET"] = function() handle("bet") end
