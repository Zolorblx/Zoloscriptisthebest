local RELEASE_URL = "YOUR_PUBLIC_RAW_RELEASE_URL"

local source = game:HttpGet(RELEASE_URL)

local chunk, err = loadstring(source)
if not chunk then
    error("[ZOLO] Load failed: " .. tostring(err))
end

return chunk()
