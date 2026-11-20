-- Smoke test: load every file listed in SteveBook.toc (in order) against a stubbed WoW API and
-- poke the slash commands. Catches load-time errors, bad load order, and typos in glue code.
-- Run from repo root: luajit tests/test_smoke.lua   (or lua5.1 / lua)
local stub = assert(loadfile("tests/wowstub.lua"))()

local out_ = stub.realPrint
local fails = 0
local function check(cond, label)
    if not cond then fails = fails + 1; out_("FAIL: " .. label) end
end

local ADDON = "SteveBook"
local DIR = "SteveBook/"
local ns = {}

local function readFile(path)
    local f = assert(io.open(path, "rb"), "cannot open " .. path)
    local s = f:read("*a"); f:close()
    return s
end

-- Load a .lua file as WoW does: varargs are (addonName, addonTable).
local loaded = {}
local function loadLua(path)
    local chunk, err = loadfile(path)
    if not chunk then check(false, "syntax error in " .. path .. ": " .. tostring(err)); return end
    local ok, e = pcall(chunk, ADDON, ns)
    check(ok, "load " .. path .. (ok and "" or (": " .. tostring(e))))
    loaded[#loaded + 1] = path
end

-- An .xml file only matters here for the <Script file=> and <Include file=> entries.
local loadFile
local function loadXml(path)
    local dir = path:match("^(.*)/[^/]*$") or "."
    for file in readFile(path):gmatch('<[SI][a-z]+%s+file="([^"]+)"') do
        loadFile(dir .. "/" .. file:gsub("\\", "/"))
    end
end

function loadFile(path)
    path = path:gsub("\\", "/")
    if path:match("%.xml$") then loadXml(path)
    elseif path:match("%.lua$") then loadLua(path)
    else check(false, "unsupported file type in toc: " .. path) end
end

-- Parse the toc: non-comment, non-blank lines are files.
local toc = readFile(DIR .. "SteveBook.toc")
local files, savedVars = {}, nil
for line in toc:gmatch("[^\r\n]+") do
    line = line:match("^%s*(.-)%s*$")
    if line:sub(1, 2) == "##" then
        savedVars = savedVars or line:match("^##%s*SavedVariablesPerCharacter:%s*(.+)$") or line:match("^##%s*SavedVariables:%s*(.+)$")
    elseif line ~= "" and line:sub(1, 1) ~= "#" then
        files[#files + 1] = line
    end
end
check(#files > 0, "toc lists files")
check(savedVars == "SteveBookDB", "toc SavedVariables is SteveBookDB (got " .. tostring(savedVars) .. ")")

-- Every .lua under SteveBook/ (outside Libs/) should be in the toc, or it never loads in game.
do
    local listed = {}
    for _, f in ipairs(files) do listed[(f:gsub("\\", "/"))] = true end
    local p = io.popen('find ' .. DIR .. ' -name "*.lua" -not -path "*/Libs/*" | sort')
    for path in p:lines() do
        local rel = path:sub(#DIR + 1)
        check(listed[rel], "file not listed in toc: " .. rel)
    end
    p:close()
end

for _, f in ipairs(files) do
    check(io.open(DIR .. f:gsub("\\", "/"), "rb") ~= nil, "toc entry exists: " .. f)
    loadFile(DIR .. f)
end
check(#loaded >= 10, "loaded the files (" .. #loaded .. ")")
check(#stub.errors == 0, "no errors passed to the error handler during load: " .. table.concat(stub.errors, "; "))

-- Namespace after load.
for _, k in ipairs({ "Odds", "Protocol", "Model", "Bookie", "Cache", "Comm", "BookieNet" }) do
    check(type(ns[k]) == "table", "ns." .. k .. " exists")
end
check(type(ns.UI) == "table" and ns.UI.Bettor and ns.UI.Bookie, "ns.UI.Bettor and ns.UI.Bookie exist")
check(ns.UI.Bettor and ns.UI.Bettor.Toggle and ns.UI.Bookie and ns.UI.Bookie.Toggle, "windows expose Toggle")

-- Slash command.
check(SLASH_STEVEBOOK1 == "/book", "SLASH_STEVEBOOK1")
check(type(SlashCmdList.STEVEBOOK) == "function", "SlashCmdList.STEVEBOOK")

-- ADDON_LOADED creates the SavedVariables.
check(SteveBookDB == nil, "SteveBookDB does not exist before ADDON_LOADED")
stub.fire("ADDON_LOADED", "SomeOtherAddon")
check(SteveBookDB == nil, "ADDON_LOADED for another addon is ignored")
stub.fire("ADDON_LOADED", ADDON)
check(type(SteveBookDB) == "table" and type(SteveBookDB.books) == "table", "SteveBookDB created with books")
check(SteveBookDB and type(SteveBookDB.cache) == "table" and type(SteveBookDB.cache.books) == "table", "SteveBookDB.cache created")

-- Slash commands run without error and say sensible things.
local slash = SlashCmdList.STEVEBOOK
local function run(msg)
    local before = #stub.printed
    local ok, err = pcall(slash, msg)
    check(ok, "/book " .. msg .. (ok and "" or (": " .. tostring(err))))
    local out = {}
    for i = before + 1, #stub.printed do out[#out + 1] = stub.printed[i] end
    return table.concat(out, "\n")
end

check(run(""):find("/book new"), "/book with no book shows help")
check(run("help"):find("/book new"), "/book help")
check(run("list"):find("No books"), "/book list with no books")
local out = run("new Smoke Test")
local code = out:match("(%u%u%u%-%w%w%w%w)")
check(code ~= nil, "/book new prints a join code: " .. out)
check(#ns.Model.ListBooks(SteveBookDB) == 1, "book created in SteveBookDB")
check(run("new   "):find("name"), "/book new with no name is refused")
check(run("list"):find(code or "?", 1, true), "/book list shows the code")
check(run("use 1"):find("Active book"), "/book use 1")
check(run("use " .. (code or "")):find("Active book"), "/book use <code>")
check(run("use 99"):find("no such book"), "/book use unknown")
check(run(""):find("Active book"), "/book shows the active book")

-- The channel for the new book was requested.
check(code and stub.channels[ns.Protocol.ChannelName(code)] ~= nil, "hidden channel joined for the new book")

-- Windows open, close and refresh without error (twice, to cover build-once and reuse paths).
for _, w in ipairs({ "bookie", "bet" }) do
    run(w); run(w); run(w)
end
check(stub.lastPrint() == stub.lastPrint(), "windows toggled")

-- Login: PLAYER_ENTERING_WORLD schedules a delayed channel join for known books.
stub.channels = {}
stub.advance(6)    -- Comm retries a channel join at most every 5 seconds
stub.fire("PLAYER_ENTERING_WORLD", true)
stub.advance(0); for _ = 1, 3 do stub.runAfters() end
stub.runAfters()
check(code and stub.channels[ns.Protocol.ChannelName(code)] ~= nil, "login rejoins the channel of an owned book")

-- Comm.Send goes out through the real AceSerializer/AceComm/ChatThrottleLib as an addon message
-- on the hidden channel.
local before = #stub.addonMessages
local ok, err = ns.Comm.Send("PING", {}, code)
check(ok == true, "Comm.Send PING succeeds: " .. tostring(err))
stub.advance(1); stub.advance(1)
check(#stub.addonMessages > before, "PING reached C_ChatInfo.SendAddonMessage")
local m = stub.addonMessages[#stub.addonMessages]
check(m and m.prefix == "SteveBook" and m.chatType == "CHANNEL" and m.target == stub.channels[ns.Protocol.ChannelName(code)],
    "PING went to the book's channel with our prefix")
check(m and #m.text <= 255, "addon message is within 255 bytes")

-- A reply to one bettor goes out on the channel, addressed to them (never as a WHISPER).
before = #stub.addonMessages
check(ns.Comm.Send("JOIN_DENY", { ownerName = "Tester", reason = "denied" }, code, "Friend") == true, "Comm.Send addressed message succeeds")
stub.advance(1); stub.advance(1)
m = stub.addonMessages[#stub.addonMessages]
check(#stub.addonMessages > before and m.chatType == "CHANNEL" and m.target == stub.channels[ns.Protocol.ChannelName(code)],
    "JOIN_DENY went out on the book's channel")
do
    local AceSer = LibStub("AceSerializer-3.0")
    local okd, env = AceSer:Deserialize(m.text)
    check(okd and env.to == "Friend", "JOIN_DENY is addressed to Friend")
end

-- /book debug traces what is sent and received.
do
    run("debug")
    check(SteveBookDB.debug == true, "/book debug turns tracing on")
    local from = #stub.printed
    ns.Comm.Send("JOIN_DENY", { ownerName = "Tester", reason = "denied" }, code, "Friend")
    stub.advance(1); stub.advance(1)
    local text = table.concat(stub.printed, "\n", from + 1)
    check(text:find("send JOIN_DENY", 1, true) and text:find("to Friend", 1, true), "debug shows the send: " .. text)
    check(text:find("echo of my own JOIN_DENY", 1, true) == nil, "no echo without a server")
    run("debug")
    check(SteveBookDB.debug == false, "/book debug turns tracing off")
    from = #stub.printed
    ns.Comm.Send("JOIN_DENY", { ownerName = "Tester", reason = "denied" }, code, "Friend")
    check(table.concat(stub.printed, "\n", from + 1):find("[debug]", 1, true) == nil, "no tracing when off")
end

-- Sending before the channel is up queues and flushes once it is.
stub.channels = {}
stub.advance(6)
local ok2, why = ns.Comm.Send("PING", {}, code)
check(ok2 == true and why == "queued", "Send queues while the channel is not ready: " .. tostring(ok2) .. " " .. tostring(why))
before = #stub.addonMessages
stub.runTickers(); stub.advance(1); stub.advance(1)
check(#stub.addonMessages > before, "queued message flushed after the channel joined")

-- Tickers (sweep, ping) run without error.
stub.runTickers()
check(#stub.errors == 0, "no errors reported by handlers: " .. table.concat(stub.errors, "; "))

-- A second player's commands before ADDON_LOADED would nil-index SteveBookDB; make sure the
-- addon tolerates a stray ping on a never-created db.
local saved = SteveBookDB
SteveBookDB = nil
check(pcall(stub.runTickers), "tickers tolerate SteveBookDB == nil")
SteveBookDB = saved

if fails == 0 then out_("test_smoke: all passed") else out_(fails .. " FAILED"); os.exit(1) end
