-- Spidey in LEGO Gotham: Spider-Man's web-swing, web launch and web shots for the LEGO Batman: Legacy of the Dark Knight player,
-- with Spider-Man Remastered's own music and voice played by SpideyLink.exe (reads the player's Spider-Man install).
-- This file only owns the frame loop and the state; the gameplay lives in spidey.lua.
local SCRIPT_DIR = (debug.getinfo(1, "S").source:gsub("^@", ""):match("^(.*)[/\\]") or ".")
local HOME = (os.getenv("LOCALAPPDATA") or ".") .. "\\SpideyGotham\\"
os.execute('mkdir "' .. HOME .. '" 2>nul')

local S = { powers = false, swinging = false, rope = 0, lastToggle = 0, lastLaunch = 0, lastSwingEnd = 0, prevToggle = false,
            prevLaunch = false, airborne = false, swingTime = 0, maxFall = 0, lastMusicBeat = 0, launchUntil = 0 }

local function load()
    local chunk, err = loadfile(SCRIPT_DIR .. "\\spidey.lua")
    if not chunk then print("[SpideyGotham] load error: " .. tostring(err) .. "\n"); return nil end
    local ok, mod = pcall(chunk, S, SCRIPT_DIR)
    if not ok then print("[SpideyGotham] init error: " .. tostring(mod) .. "\n"); return nil end
    return mod
end

local M = load()
local lastReloadCheck = 0
LoopInGameThreadAfterFrames(1, function()
    -- developer reload: a ".reload" file next to the scripts swaps in new logic/config without new loops
    local t = os.clock()
    if t - lastReloadCheck > 1 then
        lastReloadCheck = t
        local f = io.open(SCRIPT_DIR .. "\\.reload", "r")
        if f then f:close(); os.remove(SCRIPT_DIR .. "\\.reload"); M = load() or M; print("[SpideyGotham] reloaded\n") end
    end
    if M then
        local ok, err = pcall(M.frame)
        if not ok then print("[SpideyGotham] frame error: " .. tostring(err) .. "\n") end
    end
    return false
end)

print("[SpideyGotham] loaded; " .. (M and M.labels or "logic failed to load") .. "\n")