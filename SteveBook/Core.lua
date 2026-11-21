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
    say("/book lobby        check the lobby channel the lists of tables and books use")
    say("/book net          show whether each SteveBook channel is really working (/book net test also sends a test message down each path)")
    say("/book guild        turn the guild-chat second path on or off (on by default)")
    say("/book hide         hide the active book from (or show it in) the list of books")
    say("/casino            open the casino (roulette tables)")
    say("/book icon         show or hide the minimap icon")
    say("/book ratio        toggle odds between American (-110) and ratio (0.91x) display")
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
        if ns.BookLobby then ns.BookLobby.Announce() end
        say("Created " .. describe(b) .. ". It is on the list of books; the code is for anyone who wants it.")
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
    elseif cmd == "lobby" then
        if not (ns.CasinoNet and ns.CasinoNet.LobbyReport) then return say("The casino is not available.") end
        if ns.CasinoNet.AskLobby then ns.CasinoNet.AskLobby() end             -- join it and ask, so the answer is fresh
        for _, line in ipairs(ns.CasinoNet.LobbyReport()) do say(line) end
        say("Ask your friend to open /casino and press Join a table, then run /book lobby again: they should be listed.")
    elseif cmd == "guild" then
        db.noGuild = not db.noGuild or nil
        say(db.noGuild and "Guild messages OFF: only the hidden channel is used."
            or "Guild messages ON: every message also goes through guild chat (guild members only).")
    elseif cmd == "net" then
        for _, line in ipairs(ns.Comm.NetReport()) do say(line) end
        if rest and rest:lower():match("^test") then
            for _, line in ipairs(ns.Comm.SendTest()) do say(line) end
        end
    elseif cmd == "hide" then
        local b = Model.ActiveBook(db)
        if not b then return say("No active book. /book use <# or code> first.") end
        b.unlisted = not b.unlisted
        say(b.unlisted and (b.name .. " is hidden from the list of books. Friends can still join with the code " .. b.code .. ".")
            or (b.name .. " is listed again."))
    elseif cmd == "casino" then
        local ui = ns.UI and ns.UI.Casino
        if ui and ui.Toggle then ui.Toggle() else say("The casino is not available.") end
    elseif cmd == "icon" then
        local m = ns.UI and ns.UI.Minimap
        if not (m and m.Toggle) then return say("The minimap icon is not available.") end
        say(m.Toggle() and "Minimap icon shown." or "Minimap icon hidden. /book icon shows it again.")
    elseif cmd == "ratio" then
        db.ratio = not db.ratio
        ns.Odds.SetView(db.ratio and "ratio" or "american")
        say(db.ratio and "Odds shown as ratios (profit per 1 staked: -500 is 0.2x, +150 is 1.5x). /book ratio again for American odds."
            or "Odds shown as American odds (-110, +150).")
        for _, w in ipairs({ "Bettor", "Bookie" }) do
            local ui = ns.UI and ns.UI[w]
            if ui and ui.Refresh then pcall(ui.Refresh) end
        end
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
    ns.Odds.SetView(SteveBookDB.ratio and "ratio" or "american")
    if ns.CasinoNet then ns.CasinoNet.Init() end
    if ns.BookLobby then ns.BookLobby.Init() end
    if ns.UI and ns.UI.Minimap then ns.UI.Minimap.Apply() end
    -- Seed the random numbers (shuffles, ids). The bare global `floor` is nil on this client, which threw
    -- an error on every login (Core.lua, ADDON_LOADED), so use math.floor and never let this line fail.
    pcall(function() math.randomseed((GetServerTime() or 0) + math.floor((GetTime() or 0) * 1000)) end)
    f:UnregisterEvent("ADDON_LOADED")
end)

SLASH_STEVEBOOK1 = "/book"
SlashCmdList["STEVEBOOK"] = handle

-- Shortcuts: /bookie and /bet open the two windows directly.
SLASH_STEVEBOOKIE1 = "/bookie"
SlashCmdList["STEVEBOOKIE"] = function() handle("bookie") end
SLASH_STEVEBET1 = "/bet"
SlashCmdList["STEVEBET"] = function() handle("bet") end

SLASH_STEVECASINO1 = "/casino"
SlashCmdList["STEVECASINO"] = function() handle("casino") end
