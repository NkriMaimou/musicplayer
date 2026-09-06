local api_base_url = "https://ipod-2to6ogaina-uc.a.run.app/"
local version = "2.1"

local backend_url = "http://localhost:3000/convert?url="

local width, height = term.getSize()
local tab = 1

local waiting_for_input = false
local last_search = nil
local last_search_url = nil
local search_results = nil
local search_error = false
local in_search_result = false
local clicked_result = nil

-- Tape drives
local cache_tape = peripheral.find("tape_drive", function(name, p)
    return peripheral.getName(p):match("back")
end)

local tape = peripheral.find("tape_drive", function(name, p)
    return not peripheral.getName(p):match("back")
end)

term.clear()
if not tape and not cache_tape then
    print("No Tape Drives found!")
    return
end

pcall(function() if tape then tape.getPosition() end end)
pcall(function() if cache_tape then cache_tape.getPosition() end end)

function redrawScreen()
    if waiting_for_input then return end

    term.setCursorBlink(false)
    term.setBackgroundColor(colors.black)
    term.clear()

    term.setCursorPos(1,1)
    term.setBackgroundColor(colors.gray)
    term.clearLine()

    local tabs = {" Now Playing ", " Search "}
    for i=1,#tabs do
        if tab == i then
            term.setTextColor(colors.black)
            term.setBackgroundColor(colors.white)
        else
            term.setTextColor(colors.white)
            term.setBackgroundColor(colors.gray)
        end
        term.setCursorPos((math.floor((width/#tabs)*(i-0.5))) - math.ceil(#tabs[i]/2) + 1, 1)
        term.write(tabs[i])
    end

    if tab == 1 then
        drawNowPlaying()
    elseif tab == 2 then
        drawSearch()
    end
end

function drawNowPlaying()
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(2,3)
    term.write("TapeWriter for Revelation")

    term.setTextColor(colors.lightGray)
    term.setCursorPos(2,4)
    term.write("Search, pick a track, write to tape.")

    term.setTextColor(colors.white)
    term.setBackgroundColor(colors.gray)
    term.setCursorPos(2,6)
    term.write(" Write queued track to tape ")

    term.setCursorPos(2,8)
    term.write(" Play from cache tape ")
end

function drawSearch()
    paintutils.drawFilledBox(2,3,width-1,5,colors.lightGray)
    term.setBackgroundColor(colors.lightGray)
    term.setCursorPos(3,4)
    term.setTextColor(colors.black)
    term.write(last_search or "Search...")

    if search_results ~= nil then
        term.setBackgroundColor(colors.black)
        for i=1,#search_results do
            term.setTextColor(colors.white)
            term.setCursorPos(2,7 + (i-1)*2)
            term.write(search_results[i].name)
            term.setTextColor(colors.lightGray)
            term.setCursorPos(2,8 + (i-1)*2)
            term.write(search_results[i].artist)
        end
    else
        term.setCursorPos(2,7)
        term.setBackgroundColor(colors.black)
        if search_error then
            term.setTextColor(colors.red)
            term.write("Network error")
        elseif last_search_url ~= nil then
            term.setTextColor(colors.lightGray)
            term.write("Searching...")
        else
            term.setCursorPos(1,7)
            term.setTextColor(colors.lightGray)
            print("Tip: Paste YouTube links.")
        end
    end

    if in_search_result then
        term.setBackgroundColor(colors.black)
        term.clear()
        term.setCursorPos(2,2)
        term.setTextColor(colors.white)
        term.write(search_results[clicked_result].name)
        term.setCursorPos(2,3)
        term.setTextColor(colors.lightGray)
        term.write(search_results[clicked_result].artist)

        term.setBackgroundColor(colors.gray)
        term.setTextColor(colors.white)

        term.setCursorPos(2,6)
        term.clearLine()
        term.write("Write this to tape")

        term.setCursorPos(2,8)
        term.clearLine()
        term.write("Cache + play from back tape")

        term.setCursorPos(2,13)
        term.clearLine()
        term.write("Cancel")
    end
end

local tape_queue = {}

local function write_url_to_tape(url, target_tape)
    if not target_tape then return end

    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    term.setCursorPos(2,10)
    term.clearLine()
    term.write("Downloading DFPWM...")

    local response = http.get(url, nil, true)
    if not response then
        term.setCursorPos(2,11)
        term.setTextColor(colors.red)
        term.write("Download failed.")
        sleep(1)
        return
    end

    target_tape.seek(0)
    target_tape.write(response.readAll())
    response.close()
    target_tape.seek(0)

    if target_tape ~= cache_tape then
        term.setCursorPos(2,12)
        term.setTextColor(colors.white)
        term.write("Tape name:")
        term.setCursorPos(2,13)
        term.setTextColor(colors.lightGray)
        term.write("Name: ")
        local name = read()
        target_tape.setLabel(name)

        term.setCursorPos(2,15)
        term.setTextColor(colors.green)
        term.write("Done!")
        sleep(1.5)
    else
        term.setCursorPos(2,12)
        term.setTextColor(colors.green)
        term.write("Cached on back tape.")
        sleep(1)
    end
end

local function play_from_cache_tape()
    if not cache_tape then return end
    cache_tape.seek(0)
    cache_tape.play()
end

local function build_download_url(result)
    local video_url = result.url or result.id or ""
    if video_url == "" then return nil end
    return backend_url .. textutils.urlEncode(video_url)
end

function uiLoop()
    redrawScreen()

    while true do
        if waiting_for_input then
            parallel.waitForAny(
                function()
                    term.setCursorPos(3,4)
                    term.setBackgroundColor(colors.white)
                    term.setTextColor(colors.black)
                    local input = read()

                    if #input > 0 then
                        last_search = input
                        last_search_url = api_base_url .. "?v=" .. version .. "&search=" .. textutils.urlEncode(input)
                        http.request(last_search_url)
                        search_results = nil
                        search_error = false
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
                        if y < 3 or y > 5 or x < 2 or x > width-1 then
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
                    local event, button, x, y = os.pullEvent("mouse_click")

                    if button == 1 then
                        if not in_search_result then
                            if y == 1 then
                                tab = (x < width/2) and 1 or 2
                                redrawScreen()
                            end
                        end

                        if tab == 2 and not in_search_result then
                            if y >= 3 and y <= 5 then
                                paintutils.drawFilledBox(2,3,width-1,5,colors.white)
                                term.setBackgroundColor(colors.white)
                                waiting_for_input = true
                            end

                            if search_results then
                                for i=1,#search_results do
                                    if y == 7 + (i-1)*2 or y == 8 + (i-1)*2 then
                                        in_search_result = true
                                        clicked_result = i
                                        redrawScreen()
                                    end
                                end
                            end

                        elseif tab == 2 and in_search_result then
                            if y == 6 then
                                in_search_result = false
                                local result = search_results[clicked_result]
                                if result.type == "playlist" then
                                    result = result.playlist_items[1]
                                end
                                local url = build_download_url(result)
                                if url then write_url_to_tape(url, tape) end
                            end

                            if y == 8 then
                                in_search_result = false
                                local result = search_results[clicked_result]
                                if result.type == "playlist" then
                                    for _, item in ipairs(result.playlist_items) do
                                        table.insert(tape_queue, item)
                                    end
                                else
                                    table.insert(tape_queue, result)
                                end
                            end

                            if y == 13 then
                                in_search_result = false
                            end

                            redrawScreen()

                        elseif tab == 1 then
                            if y == 6 then
                                if #tape_queue == 0 then
                                    term.setCursorPos(2,8)
                                    term.setTextColor(colors.red)
                                    term.write("Queue empty.")
                                    sleep(1)
                                else
                                    local result = tape_queue[1]
                                    table.remove(tape_queue, 1)
                                    local url = build_download_url(result)
                                    if url then write_url_to_tape(url, tape) end
                                end
                            elseif y == 8 then
                                if cache_tape then
                                    local result = tape_queue[1]
                                    if result then
                                        local url = build_download_url(result)
                                        if url then
                                            write_url_to_tape(url, cache_tape)
                                            play_from_cache_tape()
                                        end
                                    else
                                        play_from_cache_tape()
                                    end
                                end
                            end
                            redrawScreen()
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

function httpLoop()
    while true do
        parallel.waitForAny(
            function()
                local event, url, handle = os.pullEvent("http_success")
                if url == last_search_url then
                    search_results = textutils.unserialiseJSON(handle.readAll())
                    os.queueEvent("redraw_screen")
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

parallel.waitForAny(uiLoop, httpLoop)
