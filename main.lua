local RELEASE_URL = "https://raw.githubusercontent.com/Zolorblx/Zoloscriptisthebest/refs/heads/main/Zolo.lua"

local source = game:HttpGet(RELEASE_URL)

local chunk, err = loadstring(source)
if not chunk then
    error("[ZOLO] Load failed: " .. tostring(err))
end

return chunk()
