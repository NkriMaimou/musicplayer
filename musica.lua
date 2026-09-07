--[[
    CC:Tweaked Tape Media Player
    Unified file with search, playlist, queue, progress bar, metadata,
    play/pause, stop=rewind, wipe, next button, and scrollbars.
    Search fix applied (zone detection + tab switching).
    Playlist tab added with controls, history removed.
]]

-----------------------------
-- CONFIG / GLOBAL STATE
-----------------------------

local api_base_url = "https://ipod-2to6magyna-uc.a.run.app/"
local version = "2.1"
local backend_url = "https://trade-playhouse-excavate.ngrok-free.dev/convert?url="
local backend_video_url = "https://trade-playhouse-excavate.ngrok-free.dev/convertVideo?url="
local player_update_url = "https://trade-playhouse-excavate.ngrok-free.dev/musica.lua"


local width, height = term.getSize()
local tab = 1 -- 1=Search, 2=Playlist, 3=Queue

-- Search state
local waiting_for_input = false
local last_search = nil
local last_search_url = nil
local search_results = nil
local search_error = false
local search_scroll = 0
local max_scroll = 0

-- Playlist state
local playlist = {}
local playlist_scroll = 0
local playlist_max_scroll = 0

-- Queue state
local tape_queue = {}
local queue_scroll = 0
local queue_max_scroll = 0
local autoplay_next = true

-- Video state
local currentVideo = nil
local playingVideo = false
local audioPosition = 0
local restart_requested = false

-- Tape drive
local tape = peripheral.find("tape_drive")
local video_monitor = peripheral.find("monitor")

if video_monitor then
    pcall(function() video_monitor.setTextScale(0.5) end)
    video_monitor.setBackgroundColor(colors.black)
    video_monitor.clear()
end

term.clear()
if not tape then
    print("No Tape Drive found!")
    return
else
    pcall(function() tape.getPosition() end)
end

-----------------------------
-- HELPERS
-----------------------------

local function filterPromo(results)
    if not results then return nil end
    local cleaned = {}
    for _, item in ipairs(results) do
        local name = string.lower(item.name or "")
        local artist = string.lower(item.artist or "")
        if not name:find("patreon") and not artist:find("patreon") then
            table.insert(cleaned, item)
        end
    end
    return cleaned
end

local function build_download_url(result)
    local video_url = result.url or result.id or ""
    if video_url == "" then return nil end
    return backend_url .. textutils.urlEncode(video_url)
end

local function fetchNFV(url)
    local h = http.get(url)
    if not h then return nil, "HTTP failed" end
    local data = h.readAll()
    h.close()
    return data
end

local function downloadLatestPlayer()
    local response, request_error = http.get(player_update_url, nil, true)
    if not response then return false, request_error or "HTTP request failed" end

    local code = response.readAll()
    response.close()
    if type(code) ~= "string" or code == "" then return false, "Empty response" end

    local file = fs.open("musica.lua.new", "w")
    if not file then return false, "Cannot open musica.lua.new" end
    file.write(code)
    file.close()
    return true, nil
end

local function replacePlayerFile()
    if fs.exists("musica.lua") then fs.delete("musica.lua") end
    fs.move("musica.lua.new", "musica.lua")
end

local function parseNFV(raw)
    local lines = {}
    for line in raw:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    local header = lines[1]
    local w, h, fps = header:match("(%d+)%s+(%d+)%s+(%d+)")
    w, h, fps = tonumber(w), tonumber(h), tonumber(fps)

    local frames = {}
    for i = 2, #lines do
        frames[i - 1] = lines[i]
    end

    return {
        width = w,
        height = h,
        fps = fps,
        frames = frames
    }
end

local function drawNFVFrame(target, frame, w, h, x, y)
    for row = 1, h do
        local row_start = (row - 1) * w + 1
        local background = frame:sub(row_start, row_start + w - 1):lower()
        background = background:gsub("#", "f"):gsub("%.", "0")
        target.setCursorPos(x, y + row - 1)
        target.blit(string.rep(" ", w), string.rep("0", w), background)
    end
    target.setBackgroundColor(colors.black)
end

local function drawCurrentVideoFrame()
    if not video_monitor or not playingVideo or not currentVideo then return end

    local frame_index = math.floor(audioPosition * currentVideo.fps) + 1
    if frame_index < 1 then frame_index = 1 end
    if frame_index > #currentVideo.frames then
        frame_index = #currentVideo.frames
    end

    local frame = currentVideo.frames[frame_index]
    if frame then
        drawNFVFrame(
            video_monitor,
            frame,
            currentVideo.width,
            currentVideo.height,
            1,
            1
        )
    end
end


-----------------------------
-- SCROLLBARS / PROGRESS / METADATA
-----------------------------

local function drawScrollbarSearch()
    if not search_results then return end

    local list_height = #search_results * 2
    local view_height = height - 8
    if list_height <= view_height then return end

    local bar_x = width - 1
    local bar_y_top = 8
    local bar_y_bottom = height
    local track_height = bar_y_bottom - bar_y_top + 1
    local thumb_height = math.max(1, math.floor(track_height * (view_height / list_height)))
    local max_thumb_offset = track_height - thumb_height
    local thumb_offset = math.floor((search_scroll / max_scroll) * max_thumb_offset)

    for y = bar_y_top, bar_y_bottom do
        term.setCursorPos(bar_x, y)
        term.setBackgroundColor(colors.gray)
        term.write(" ")
    end
    for y = bar_y_top + thumb_offset, bar_y_top + thumb_offset + thumb_height - 1 do
        term.setCursorPos(bar_x, y)
        term.setBackgroundColor(colors.white)
        term.write(" ")
    end
    term.setBackgroundColor(colors.black)
end

local function drawScrollbarPlaylist()
    if #playlist == 0 then return end

    local list_height = #playlist * 2
    local view_height = height - 4
    if list_height <= view_height then return end

    local bar_x = width - 1
    local bar_y_top = 4
    local bar_y_bottom = height
    local track_height = bar_y_bottom - bar_y_top + 1
    local thumb_height = math.max(1, math.floor(track_height * (view_height / list_height)))
    local max_thumb_offset = track_height - thumb_height
    local thumb_offset = math.floor((playlist_scroll / playlist_max_scroll) * max_thumb_offset)

    for y = bar_y_top, bar_y_bottom do
        term.setCursorPos(bar_x, y)
        term.setBackgroundColor(colors.gray)
        term.write(" ")
    end
    for y = bar_y_top + thumb_offset, bar_y_top + thumb_offset + thumb_height - 1 do
        term.setCursorPos(bar_x, y)
        term.setBackgroundColor(colors.white)
        term.write(" ")
    end
    term.setBackgroundColor(colors.black)
end

local function drawScrollbarQueue()
    if #tape_queue == 0 then return end

    local list_height = #tape_queue * 2
    local view_height = height - 4
    if list_height <= view_height then return end

    local bar_x = width - 1
    local bar_y_top = 4
    local bar_y_bottom = height
    local track_height = bar_y_bottom - bar_y_top + 1
    local thumb_height = math.max(1, math.floor(track_height * (view_height / list_height)))
    local max_thumb_offset = track_height - thumb_height
    local thumb_offset = math.floor((queue_scroll / queue_max_scroll) * max_thumb_offset)

    for y = bar_y_top, bar_y_bottom do
        term.setCursorPos(bar_x, y)
        term.setBackgroundColor(colors.gray)
        term.write(" ")
    end
    for y = bar_y_top + thumb_offset, bar_y_top + thumb_offset + thumb_height - 1 do
        term.setCursorPos(bar_x, y)
        term.setBackgroundColor(colors.white)
        term.write(" ")
    end
    term.setBackgroundColor(colors.black)
end

local function drawTapeProgress()
    if not tape then return end

    local size = tape.getSize()
    if size <= 0 then return end

    local pos = tape.getPosition()
    if pos < 0 then pos = 0 end
    if pos > size then pos = size end

    local bar_x = 2
    local bar_y = 6
    local bar_w = width - 3

    local pct = pos / size
    local filled = math.floor(bar_w * pct)

    term.setCursorPos(bar_x, bar_y)
    term.setBackgroundColor(colors.gray)
    term.write(string.rep(" ", bar_w))

    term.setCursorPos(bar_x, bar_y)
    term.setBackgroundColor(colors.green)
    term.write(string.rep(" ", filled))

    term.setBackgroundColor(colors.black)
end

local function drawMetadataPanel()
    if not tape then return end

    local label = tape.getLabel() or "No Label"
    local pos = tape.getPosition()
    local size = tape.getSize()

    term.setCursorPos(2, 7)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.lightGray)
    term.clearLine()

    local pct = 0
    if size > 0 then pct = math.floor((pos / size) * 100) end

    term.write(label .. "  |  " .. pct .. "%")
end

-----------------------------
-- DRAW SCREENS
-----------------------------

local function drawSearch()
    paintutils.drawFilledBox(2, 3, width - 1, 5, colors.lightGray)
    term.setBackgroundColor(colors.lightGray)
    term.setCursorPos(3, 4)
    term.setTextColor(colors.black)
    term.write(last_search or "Search...")

    drawTapeProgress()
    drawMetadataPanel()

    if search_results then
        term.setBackgroundColor(colors.black)
        max_scroll = math.max(0, (#search_results * 2) - (height - 8))

        for i = 1, #search_results do
            local y_name = 8 + (i - 1) * 2 - search_scroll
            local y_artist = 9 + (i - 1) * 2 - search_scroll

            if y_name >= 8 and y_name <= height then
                term.setTextColor(colors.white)
                term.setCursorPos(2, y_name)
                local name = search_results[i].name or "Unknown"
                local max_name_width = width - 4 -- leave space for + button and scrollbar
                if #name > max_name_width then
                    name = name:sub(1, max_name_width)
                end
                term.write(name)

                -- + button to store in playlist (right side, left of scrollbar)
                term.setCursorPos(width - 2, y_name)
                term.setTextColor(colors.green)
                term.write("+")
            end

            if y_artist >= 8 and y_artist <= height then
                term.setTextColor(colors.lightGray)
                term.setCursorPos(2, y_artist)
                local artist = search_results[i].artist or ""
                local max_artist_width = width - 4
                if #artist > max_artist_width then
                    artist = artist:sub(1, max_artist_width)
                end
                term.write(artist)
            end
        end

        drawScrollbarSearch()
    else
        term.setBackgroundColor(colors.black)
        term.setCursorPos(2, 8)
        if search_error then
            term.setTextColor(colors.red)
            term.write("Network error")
        elseif last_search_url then
            term.setTextColor(colors.lightGray)
            term.write("Searching...")
        else
            term.setCursorPos(1, 8)
            term.setTextColor(colors.lightGray)
            print("Tip: Paste YouTube links.")
        end
    end
end

local function drawPlaylist()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(2, 3)
    term.write("Playlist (? ? ?)")

    if #playlist == 0 then
        term.setCursorPos(2, 5)
        term.setTextColor(colors.lightGray)
        term.write("No tracks in playlist.")
        return
    end

    playlist_max_scroll = math.max(0, (#playlist * 2) - (height - 4))

    for i = 1, #playlist do
        local y_name = 4 + (i - 1) * 2 - playlist_scroll
        local y_controls = 5 + (i - 1) * 2 - playlist_scroll

        if y_name >= 4 and y_name <= height then
            term.setCursorPos(2, y_name)
            term.setTextColor(colors.white)
            term.write(playlist[i].name or "Unknown")
        end

        if y_controls >= 4 and y_controls <= height then
            term.setCursorPos(2, y_controls)
            term.setTextColor(colors.green)
            term.write("? ")
            term.setTextColor(colors.cyan)
            term.write("? ")
            term.setTextColor(colors.red)
            term.write("?")
        end
    end

    drawScrollbarPlaylist()
end

local function drawQueue()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(2, 3)
    term.write("Queue (? ? ?)  Autoplay: " .. (autoplay_next and "ON" or "OFF"))

    if #tape_queue == 0 then
        term.setCursorPos(2, 5)
        term.setTextColor(colors.lightGray)
        term.write("No tracks queued.")
        return
    end

    queue_max_scroll = math.max(0, (#tape_queue * 2) - (height - 4))

    for i = 1, #tape_queue do
        local y_name = 4 + (i - 1) * 2 - queue_scroll
        local y_controls = 5 + (i - 1) * 2 - queue_scroll

        if y_name >= 4 and y_name <= height then
            term.setCursorPos(2, y_name)
            term.setTextColor(colors.white)
            term.write(tape_queue[i].name or "Unknown")
        end

        if y_controls >= 4 and y_controls <= height then
            term.setCursorPos(2, y_controls)
            term.setTextColor(colors.green)
            term.write("? ")
            term.setTextColor(colors.cyan)
            term.write("? ")
            term.setTextColor(colors.red)
            term.write("?")
        end
    end

    drawScrollbarQueue()
end

-----------------------------
-- TAPE OPERATIONS
-----------------------------

local function write_url_to_tape(url)
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(2, 10)
    term.clearLine()
    term.write("Downloading DFPWM...")

    local response = http.get(url, nil, true)
    if not response then
        term.setCursorPos(2, 11)
        term.setTextColor(colors.red)
        term.write("Download failed.")
        sleep(1)
        return
    end

    tape.seek(-999999999999)
    tape.write(response.readAll())
    response.close()
    tape.seek(-999999999999)

    term.setCursorPos(2, 12)
    term.setTextColor(colors.white)
    term.write("Tape name:")
    term.setCursorPos(2, 13)
    term.setTextColor(colors.lightGray)
    term.write("Name: ")
    local name = read()
    tape.setLabel(name)

    term.setCursorPos(2, 15)
    term.setTextColor(colors.green)
    term.write("Done!")
    sleep(1.5)
end

local function autoplayNextTrack()
    if not autoplay_next then return end
    if not tape_queue[1] then return end

    local result = tape_queue[1]
    table.remove(tape_queue, 1)

    if result.type == "playlist" and result.playlist_items and result.playlist_items[1] then
        result = result.playlist_items[1]
    end

    local url = build_download_url(result)
    if not url or not tape then return end

    local response = http.get(url, nil, true)
    if not response then return end

    tape.seek(-9999999999)
    tape.write(response.readAll())
    response.close()
    tape.seek(-9999999999)
    tape.setLabel(result.name or "Unknown")
    tape.play()
end

-----------------------------
-- MAIN REDRAW
-----------------------------

local function redrawScreen()
    if waiting_for_input then return end

    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.clear()

    term.setCursorPos(width, 1)
    term.setTextColor(colors.white)
    write("X")

    term.setCursorPos(1, 1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()

    local playLabel = " play "
    if tape and tape.isPlaying and tape.isPlaying() then
        playLabel = " pause "
    end

    -- Tabs: 1 Search, 2 Playlist, 3 Queue, 4 play/pause, 5 stop, 6 next, 7 wipe
    local tabs = {
        " Search ",
        " Playlist ",
        " Queue ",
        playLabel,
        " stop ",
        " next ",
        " wipe "
    }

    for i = 1, #tabs do
        local bg = colors.gray
        local fg = colors.white

        if i == 4 then
            if tape and tape.isPlaying and tape.isPlaying() then
                bg = colors.red
                fg = colors.white
            else
                bg = colors.green
                fg = colors.black
            end
        elseif i == 5 then
            bg = colors.orange
            fg = colors.black
        elseif i == 6 then
            bg = colors.purple
            fg = colors.white
        elseif i == 7 then
            bg = colors.red
            fg = colors.white
        end

        if (i == 1 or i == 2 or i == 3) and tab == i then
            bg = colors.white
            fg = colors.black
        end

        term.setBackgroundColor(bg)
        term.setTextColor(fg)

        local pos = (math.floor((width / #tabs) * (i - 0.5))) - math.ceil(#tabs[i] / 2) + 1
        term.setCursorPos(pos, 1)
        term.write(tabs[i])
    end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)

    if tab == 1 then
        drawSearch()
    elseif tab == 2 then
        drawPlaylist()
    elseif tab == 3 then
        drawQueue()
    end
end

-----------------------------
-- UI LOOP
-----------------------------

local function uiLoop()
    redrawScreen()

    while true do
        if restart_requested then return end

        if waiting_for_input then
            parallel.waitForAny(
                function()
                    term.setCursorPos(3, 4)
                    term.setBackgroundColor(colors.white)
                    term.setTextColor(colors.black)
                    local input = read()

                    if #input > 0 then
                        last_search = input
                        last_search_url = api_base_url .. "?v=" .. version .. "&search=" .. textutils.urlEncode(input)
                        http.request(last_search_url)
                        search_results = nil
                        search_error = false
                        search_scroll = 0
                    else
                        last_search = nil
                        last_search_url = nil
                        search_results = nil
                        search_error = false
                    end

                    waiting_for_input = false
                    os.queueEvent("redraw_screen")
                end,
                function()
                    while waiting_for_input do
                        local event, button, x, y = os.pullEvent("mouse_click")
                        if y < 3 or y > 5 or x < 2 or x > width - 1 then
                            waiting_for_input = false
                            os.queueEvent("redraw_screen")
                            break
                        end
                    end
                end
            )
        else
            parallel.waitForAny(
                function()
                    local event, p1, x, y = os.pullEvent()

                    local update_key = event == "key" and p1 == keys.u
                    local update_char = event == "char" and string.lower(p1 or "") == "u"
                    if update_key or update_char then
                        local updated, update_error = downloadLatestPlayer()
                        term.setCursorPos(2, 2)
                        term.setTextColor(updated and colors.green or colors.red)
                        term.write(updated and "Downloaded musica.lua.new" or "Update failed: " .. update_error)
                        sleep(1.5)
                        if updated then
                            if tape then tape.stop() end
                            playingVideo = false
                            currentVideo = nil
                            audioPosition = 0
                            replacePlayerFile()
                            restart_requested = true
                            return
                        end
                        redrawScreen()
                        return
                    end

                    if tape and tape.isPlaying and tape.isPlaying() then
                        local size = tape.getSize()
                        local pos = tape.getPosition()
                        if pos >= size - 1 then
                            tape.stop()
                            playingVideo = false
                            currentVideo = nil
                            audioPosition = 0
                            autoplayNextTrack()
                        end
                        redrawScreen()
                    end

                    -- SCROLL HANDLING
                    if event == "mouse_scroll" then
                        if tab == 1 and search_results then
                            search_scroll = search_scroll + (p1 * 2)
                            if search_scroll < 0 then search_scroll = 0 end
                            if search_scroll > max_scroll then search_scroll = max_scroll end
                            redrawScreen()
                        elseif tab == 2 and #playlist > 0 then
                            playlist_scroll = playlist_scroll + (p1 * 2)
                            if playlist_scroll < 0 then playlist_scroll = 0 end
                            if playlist_scroll > playlist_max_scroll then playlist_scroll = playlist_max_scroll end
                            redrawScreen()
                        elseif tab == 3 and #tape_queue > 0 then
                            queue_scroll = queue_scroll + (p1 * 2)
                            if queue_scroll < 0 then queue_scroll = 0 end
                            if queue_scroll > queue_max_scroll then queue_scroll = queue_max_scroll end
                            redrawScreen()
                        end
                    end

                    -- CLICK HANDLING
                    if event == "mouse_click" then
                        local button = p1

                        -- TAB BAR CLICK
                        if y == 1 then
                            local zone = math.ceil((x / width) * 7)

                            if zone == 1 or zone == 2 or zone == 3 then
                                tab = zone
                                redrawScreen()
                                return
                            end

                            -- play/pause
                            if zone == 4 and tape then
                                if tape.isPlaying and tape.isPlaying() then
                                    -- Pause without resetting the current video.
                                    tape.stop()
                                else
                                    tape.play()
                                end
                                redrawScreen()
                                return
                            end

                            -- stop = rewind
                            if zone == 5 and tape then
                                tape.stop()
                                tape.seek(-99999999999)
                                playingVideo = false
                                currentVideo = nil
                                audioPosition = 0
                                redrawScreen()
                                return
                            end

                            -- NEXT BUTTON: manual queue advance
                            if zone == 6 then
                                if tape_queue[1] then
                                    local result = tape_queue[1]
                                    table.remove(tape_queue, 1)

                                    if result.type == "playlist" and result.playlist_items and result.playlist_items[1] then
                                        result = result.playlist_items[1]
                                    end

                                    local url = build_download_url(result)
                                    if url and tape then
                                        playingVideo = false
                                        currentVideo = nil
                                        audioPosition = 0
                                        tape.seek(-999999999999)
                                        local response = http.get(url, nil, true)
                                        if response then
                                            tape.write(response.readAll())
                                            response.close()
                                        end
                                        tape.setLabel(result.name or "Unknown")
                                        tape.seek(-999999999999)
                                        tape.play()
                                    end
                                end
                                redrawScreen()
                                return
                            end

                            -- wipe
                            if zone == 7 and tape then
                                tape.seek(-99999999999)
                                tape.write(string.rep("\0", tape.getSize()))
                                tape.seek(-99999999999)
                                redrawScreen()
                                return
                            end
                        end

                        -- PROGRESS BAR SEEK
                        if tab == 1 and y == 6 and tape then
                            local bar_x = 2
                            local bar_w = width - 3
                            if x >= bar_x and x <= bar_x + bar_w then
                                local pct = (x - bar_x) / bar_w
                                pct = math.max(0, math.min(1, pct))
                                local size = tape.getSize()
                                local target = math.floor(size * pct)
                                local current = tape.getPosition()
                                tape.seek(target - current)
                                redrawScreen()
                                return
                            end
                        end

                        -- SEARCH BAR CLICK
                        if tab == 1 and y >= 3 and y <= 5 then
                            paintutils.drawFilledBox(2, 3, width - 1, 5, colors.white)
                            term.setBackgroundColor(colors.white)
                            waiting_for_input = true
                            return
                        end

                        -- SEARCH RESULTS CLICK (+ and play/queue)
                        if tab == 1 and search_results then
                            for i = 1, #search_results do
                                local y_name = 8 + (i - 1) * 2 - search_scroll
                                local y_artist = 9 + (i - 1) * 2 - search_scroll

                                if y == y_name or y == y_artist then
                                    local result = search_results[i]
                                    if result.type == "playlist" then
                                        result = result.playlist_items[1]
                                    end

                                    -- + button: add to playlist
                                    if y == y_name and x == width - 2 then
                                        table.insert(playlist, result)
                                        redrawScreen()
                                        return
                                    end

                                    -- normal click behavior
                                    if button == 2 then
                                        table.insert(tape_queue, result)
                                        redrawScreen()
                                        return
                                    end

                                    if button == 1 then
                                        playingVideo = false
                                        currentVideo = nil
                                        audioPosition = 0

                                        local url = build_download_url(result)
                                        if url and tape then
                                            tape.seek(-999999999999999)
                                            local response = http.get(url, nil, true)
                                            if response then
                                                tape.write(response.readAll())
                                                response.close()
                                            end
                                            tape.setLabel(result.name or "Unknown")
                                            tape.seek(-999999999999999)
                                            tape.play()
                                        end

                                        local video_source = result.url or result.id
                                        if video_source and video_monitor then
                                            local video_width, video_height = video_monitor.getSize()
                                            local video_url = backend_video_url
                                                .. textutils.urlEncode(tostring(video_source))
                                                .. "&resolution=" .. video_width .. "x" .. video_height
                                                .. "&fps=12"
                                            local rawNFV = fetchNFV(video_url)

                                            if rawNFV then
                                                currentVideo = parseNFV(rawNFV)
                                                playingVideo = currentVideo ~= nil
                                            end
                                        elseif not video_monitor then
                                            term.setCursorPos(2, 2)
                                            term.setTextColor(colors.red)
                                            term.write("No monitor found")
                                            sleep(1.5)
                                        end

                                        redrawScreen()
                                        return
                                    end
                                end
                            end
                        end

                        -- PLAYLIST TAB CLICK (controls)
                        if tab == 2 then
                            if #playlist > 0 and y >= 4 then
                                for i = 1, #playlist do
                                    local y_controls = 5 + (i - 1) * 2 - playlist_scroll

                                    if y == y_controls then
                                        -- move up
                                        if x == 2 or x == 3 then
                                            if i > 1 then
                                                playlist[i], playlist[i - 1] = playlist[i - 1], playlist[i]
                                            end
                                        end

                                        -- move down
                                        if x == 4 or x == 5 then
                                            if i < #playlist then
                                                playlist[i], playlist[i + 1] = playlist[i + 1], playlist[i]
                                            end
                                        end

                                        -- remove
                                        if x == 6 or x == 7 then
                                            table.remove(playlist, i)
                                        end

                                        redrawScreen()
                                        return
                                    end
                                end
                            end
                        end

                        -- QUEUE TAB CLICK (controls)
                        if tab == 3 then
                            if y == 3 then
                                autoplay_next = not autoplay_next
                                redrawScreen()
                                return
                            end

                            if #tape_queue > 0 and y >= 4 then
                                for i = 1, #tape_queue do
                                    local y_controls = 5 + (i - 1) * 2 - queue_scroll

                                    if y == y_controls then
                                        if x == 2 or x == 3 then
                                            if i > 1 then
                                                tape_queue[i], tape_queue[i - 1] = tape_queue[i - 1], tape_queue[i]
                                            end
                                        end

                                        if x == 4 or x == 5 then
                                            if i < #tape_queue then
                                                tape_queue[i], tape_queue[i + 1] = tape_queue[i + 1], tape_queue[i]
                                            end
                                        end

                                        if x == 6 or x == 7 then
                                            table.remove(tape_queue, i)
                                        end

                                        redrawScreen()
                                        return
                                    end
                                end
                            end
                        end
                    end
                end,

                function()
                    local event = os.pullEvent("redraw_screen")
                    redrawScreen()
                end
            )
        end
    end
end

-----------------------------
-- HTTP LOOP
-----------------------------

local function httpLoop()
    while true do
        parallel.waitForAny(
            function()
                local event, url, handle = os.pullEvent("http_success")
                if url == last_search_url then
                    local body = handle.readAll()
                    handle.close()
                    local raw = textutils.unserialiseJSON(body)
                    search_results = filterPromo(raw)
                    os.queueEvent("redraw_screen")
                    redrawScreen()
                end
            end,
            function()
                local event, url = os.pullEvent("http_failure")
                if url == last_search_url then
                    search_error = true
                    os.queueEvent("redraw_screen")
                end
            end
        )
    end
end

-----------------------------
-- VIDEO LOOP
-----------------------------

local function videoLoop()
    while true do
        if playingVideo and currentVideo and tape then
            local size = tape.getSize()
            local pos = tape.getPosition()

            if size > 0 then
                audioPosition = (pos / size) * (size / 48000)
            else
                audioPosition = 0
            end

            drawCurrentVideoFrame()
        end

        sleep(0.05)
    end
end

-----------------------------
-- START
-----------------------------

parallel.waitForAny(uiLoop, httpLoop, videoLoop)

term.setBackgroundColor(colors.black)
term.setTextColor(colors.white)
term.clear()
term.setCursorPos(1, 1)
