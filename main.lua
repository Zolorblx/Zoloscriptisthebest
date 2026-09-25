-- ZOLO public loader
-- Put the RAW URL of your public obfuscated release below.
-- Keep this loader tiny; it is also the URL ZOLO uses after a rejoin.

local RELEASE_URL =
    "https://raw.githubusercontent.com/Zolorblx/Zoloscriptisthebest/refs/heads/main/Zolo.lua"

if RELEASE_URL:find("PASTE_", 1, true) then
    error("[ZOLO] Set RELEASE_URL in main.lua first.")
end

local env = (getgenv and getgenv()) or _G
env.__ZOLO_PUBLIC_LOADER_ID = "ZOLO-PUBLIC-LOADER-2026-09-26-RN1"
env.__ZOLO_REMOTE_RELEASE_URL = RELEASE_URL

print("[ZOLO LOADER] " .. env.__ZOLO_PUBLIC_LOADER_ID)

local source = game:HttpGet(RELEASE_URL)
local chunk, err = loadstring(source)

if not chunk then
    error("[ZOLO] Release compile failed: " .. tostring(err))
end

return chunk()
