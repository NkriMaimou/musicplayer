--[[
    CC:Tweaked Pocket Music Player
    Advanced Noisy Pocket Computer Edition

    Features:
      - Built-in speaker upgrade
      - Search
      - Playlist
      - Queue
      - Autoplay
      - DFPWM streaming
      - Play / pause
      - Stop
      - Next
      - Search scrolling
      - Playlist scrolling
      - Queue scrolling
      - Video monitor support
      - Search Enter bug fixed
      - No tape drive required

    Designed for small Pocket Computer screens.
]]

------------------------------------------------------------
-- CONFIG
------------------------------------------------------------

local api_base_url =
    "https://ipod-2to6magyna-uc.a.run.app/"

local version = "2.2-pocket"

local backend_url =
    "https://k76fpz4gem61.shares.zrok.io/convert?url="

local backend_video_url =
    "https://k76fpz4gem61.shares.zrok.io/convertVideo?url="

local player_update_url =
    "https://k76fpz4gem61.shares.zrok.io/musica.lua"

------------------------------------------------------------
-- HARDWARE
------------------------------------------------------------

local speaker = peripheral.find("speaker")
local original_term = term.current()
local monitor_check_ok, monitor_check_result =
    pcall(peripheral.hasType, original_term, "monitor")

local monitor_ui =
    monitor_check_ok
    and monitor_check_result == true

local display_monitor =
    monitor_ui
    and original_term
    or peripheral.find("monitor")

local video_monitor = display_monitor
local DEFAULT_MONITOR_PALETTE = {
    {240, 240, 240},
    {242, 178, 51},
    {229, 127, 216},
    {153, 178, 242},
    {222, 222, 108},
    {127, 204, 25},
    {242, 178, 204},
    {76, 76, 76},
    {153, 153, 153},
    {76, 153, 178},
    {178, 102, 229},
    {51, 102, 204},
    {127, 102, 76},
    {87, 166, 78},
    {204, 76, 76},
    {25, 25, 25}
}

local function setMonitorPalette(target, palette)
    if not target then
        return
    end

    for index = 1, 16 do
        local color = palette[index]
            or DEFAULT_MONITOR_PALETTE[index]

        pcall(function()
            target.setPaletteColor(
                2 ^ (index - 1),
                color[1] / 255,
                color[2] / 255,
                color[3] / 255
            )
        end)
    end
end

if display_monitor then
    pcall(function()
        display_monitor.setTextScale(0.5)
    end)

    setMonitorPalette(display_monitor, DEFAULT_MONITOR_PALETTE)
end

if monitor_ui then
    video_monitor = nil
end

local width, height = term.getSize()
local inline_video =
    monitor_ui
local video_palette_target =
    monitor_ui
    and display_monitor
    or video_monitor

local function restoreVideoPalette()
    setMonitorPalette(video_palette_target, DEFAULT_MONITOR_PALETTE)
end

if display_monitor then
    display_monitor.setBackgroundColor(colors.black)
    display_monitor.clear()
end

if not speaker then
    term.clear()
    term.setCursorPos(1, 1)
    term.setTextColor(colors.red)
    print("No speaker upgrade found.")
    print("")
    print("Install the Speaker Upgrade")
    print("on the Pocket Computer.")
    return
end

------------------------------------------------------------
-- STATE
------------------------------------------------------------

local tab = 1
-- 1 = Search
-- 2 = Playlist
-- 3 = Queue

local waiting_for_input = false
local search_input = ""

local last_search = nil
local last_search_url = nil
local update_in_progress = false
local update_status = nil

local search_results = nil
local search_error = false
local search_scroll = 0
local max_scroll = 0

local playlist = {}
local playlist_scroll = 0
local playlist_max_scroll = 0

local tape_queue = {}
local queue_scroll = 0
local queue_max_scroll = 0

local autoplay_next = true

------------------------------------------------------------
-- AUDIO STATE
------------------------------------------------------------

local currentTrack = nil
local pendingTrack = nil

local audio_playing = false
local audio_paused = false
local audio_stopped = true

local audio_request_id = 0

local audio_handle = nil
local audio_decoder = nil

local audio_byte_position = 0
local audio_total_bytes = 0

local audio_samples_played = 0
local audio_samples_submitted = 0

local audio_start_time = nil

local AUDIO_SAMPLE_RATE = 48000
local DFPWM_CHUNK_SIZE = 16 * 1024

local AUDIO_VOLUME = 1.0

local AUDIO_POSITION_UPDATE = 0.05

------------------------------------------------------------
-- VIDEO STATE
------------------------------------------------------------

local currentVideo = nil
local playingVideo = false

local video_fps = 20
local inline_video_fps = 10
local monitor_fps = 20

local last_rendered_frame = nil

local VIDEO_PREBUFFER_FRAMES = 30

local VIDEO_BUFFER_FRAMES = 80
local VIDEO_REFILL_FRAMES = 20
local VIDEO_REFILL_THRESHOLD = 30

local video_streaming = false
local video_stream_handle = nil
local video_stream_coroutine = nil

------------------------------------------------------------
-- GENERAL STATE
------------------------------------------------------------

local restart_requested = false

------------------------------------------------------------
-- AUDIO HELPERS
------------------------------------------------------------

local function getAudioTime()
    if audio_samples_played <= 0 then
        return 0
    end

    return audio_samples_played / AUDIO_SAMPLE_RATE
end

local function getAudioDuration()
    if audio_total_bytes <= 0 then
        return 0
    end

    -- DFPWM is one bit/sample.
    -- Therefore 1 byte = 8 samples.
    return (audio_total_bytes * 8)
        / AUDIO_SAMPLE_RATE
end

local function resetAudioState()
    audio_samples_played = 0
    audio_samples_submitted = 0

    audio_byte_position = 0

    audio_total_bytes = 0

    audio_start_time = nil

    audio_playing = false
    audio_paused = false
    audio_stopped = true

    audio_decoder = nil

    if audio_handle then
        pcall(function()
            audio_handle.close()
        end)

        audio_handle = nil
    end

    pcall(function()
        speaker.stop()
    end)
end

------------------------------------------------------------
-- VIDEO BUFFER
------------------------------------------------------------

local function getBufferedFrame(video, frame_number)

    if not video then
        return nil
    end

    if frame_number < video.first_frame then
        return nil
    end

    if frame_number > video.last_frame then
        return nil
    end

    local index =
        ((frame_number - 1)
        % video.buffer_size) + 1

    return video.frames[index]
end

------------------------------------------------------------
-- STOP VIDEO
------------------------------------------------------------

local function stopVideoStream()

    video_streaming = false

    if video_stream_handle then
        pcall(function()
            video_stream_handle.close()
        end)

        video_stream_handle = nil
    end

    video_stream_coroutine = nil
end

------------------------------------------------------------
-- STREAM VIDEO
------------------------------------------------------------

local function streamNFV(url)

    stopVideoStream()

    local handle =
        http.get(url)

    if not handle then
        return nil, "HTTP failed"
    end

    local header =
        handle.readLine()

    if not header then
        handle.close()
        return nil, "Empty NFV response"
    end

    local stream_width,
          stream_height,
          stream_fps,
          palette_text =
        header:match(
            "^(%d+)%s+(%d+)%s+(%d+)%s*(.*)$"
        )

    stream_width = tonumber(stream_width)
    stream_height = tonumber(stream_height)
    stream_fps = tonumber(stream_fps)

    local stream_palette = {}
    for hex_color in (palette_text or ""):gmatch("%x%x%x%x%x%x") do
        stream_palette[#stream_palette + 1] = {
            tonumber(hex_color:sub(1, 2), 16),
            tonumber(hex_color:sub(3, 4), 16),
            tonumber(hex_color:sub(5, 6), 16)
        }
    end

    if #stream_palette < 2 or #stream_palette > 16 then
        stream_palette = DEFAULT_MONITOR_PALETTE
    end

    if not stream_width
        or not stream_height
        or not stream_fps then

        handle.close()

        return nil, "Invalid NFV header"
    end

    currentVideo = {

        width = stream_width,
        height = stream_height,
        fps = stream_fps,
        palette = stream_palette,

        frames = {},

        buffer_size =
            VIDEO_BUFFER_FRAMES,

        first_frame = 1,
        last_frame = 0,

        received_frames = 0,

        pending_frames =
            VIDEO_PREBUFFER_FRAMES,

        finished = false,

        stream_error = nil
    }

    last_rendered_frame = nil

    video_stream_handle = handle
    video_streaming = true

    video_stream_coroutine =
        coroutine.create(function()

            local video =
                currentVideo

            while video
                and video_streaming
                and currentVideo == video do

                if video.pending_frames <= 0 then

                    coroutine.yield()

                else

                    local frame =
                        handle.readLine()

                    if not frame then
                        break
                    end

                    video.pending_frames =
                        video.pending_frames - 1

                    video.received_frames =
                        video.received_frames + 1

                    local frame_number =
                        video.received_frames

                    local index =
                        ((frame_number - 1)
                        % video.buffer_size) + 1

                    video.frames[index] =
                        frame

                    video.last_frame =
                        frame_number

                    if video.last_frame
                        - video.first_frame
                        + 1
                        > video.buffer_size then

                        video.first_frame =
                            video.last_frame
                            - video.buffer_size
                            + 1
                    end

                    coroutine.yield()
                end
            end

            pcall(function()
                handle.close()
            end)

            if video_stream_handle == handle then
                video_stream_handle = nil
            end

            video_streaming = false

            video.finished = true
        end)

    return currentVideo
end

------------------------------------------------------------
-- VIDEO STREAM LOOP
------------------------------------------------------------

local function videoStreamLoop()

    while true do

        if video_stream_coroutine then

            if coroutine.status(
                video_stream_coroutine
            ) == "dead" then

                video_stream_coroutine = nil

            elseif currentVideo
                and currentVideo.pending_frames > 0 then

                local ok, err =
                    coroutine.resume(
                        video_stream_coroutine
                    )

                if not ok then

                    if currentVideo then
                        currentVideo.stream_error =
                            tostring(err)

                        currentVideo.finished =
                            true
                    end

                    video_streaming = false

                    if video_stream_handle then
                        pcall(function()
                            video_stream_handle.close()
                        end)

                        video_stream_handle = nil
                    end

                    video_stream_coroutine = nil
                end

            else

                sleep(0.01)
            end

        else

            sleep(0.01)
        end
    end
end

------------------------------------------------------------
-- VIDEO PREBUFFER
------------------------------------------------------------

local function waitForVideoPrebuffer(video)

    if not video then
        return false
    end

    local start_time =
        os.epoch("utc")

    local timeout_ms =
        5000

    while true do

        if currentVideo ~= video then
            return false
        end

        if video.received_frames
            >= VIDEO_PREBUFFER_FRAMES then

            return true
        end

        if video.finished then
            return video.received_frames > 0
        end

        if os.epoch("utc")
            - start_time
            >= timeout_ms then

            return video.received_frames > 0
        end

        sleep(0.01)
    end
end

------------------------------------------------------------
-- DRAW VIDEO FRAME
------------------------------------------------------------

local function drawVideoFrame(
    target,
    frame,
    w,
    h,
    x,
    y
)

    local text =
        string.rep(" ", w)

    local foreground =
        string.rep("0", w)

    for row = 1, h do

        local row_start =
            (row - 1)
            * w
            + 1

        local background =
            frame:sub(
                row_start,
                row_start + w - 1
            )

        target.setCursorPos(
            x,
            y + row - 1
        )

        target.blit(
            text,
            foreground,
            background
        )
    end
end

local function drawHalfBlockVideoFrame(
    target,
    frame,
    w,
    h,
    x,
    y
)

    local columns = math.floor(w / 2)
    local glyphs = string.rep(string.char(149), columns)

    for row = 1, h do
        local row_start = (row - 1) * w + 1
        local left_colors = {}
        local right_colors = {}

        for column = 0, columns - 1 do
            local pixel = row_start + column * 2
            left_colors[#left_colors + 1] = frame:sub(pixel, pixel)
            right_colors[#right_colors + 1] = frame:sub(pixel + 1, pixel + 1)
        end

        target.setCursorPos(x, y + row - 1)
        target.blit(
            glyphs,
            table.concat(left_colors),
            table.concat(right_colors)
        )
    end
end

------------------------------------------------------------
-- RENDER VIDEO
------------------------------------------------------------

local function renderCurrentVideoFrame()

    local target =
        inline_video
        and original_term
        or video_monitor

    if not target
        or not playingVideo
        or not currentVideo then

        return
    end

    local video =
        currentVideo

    local audio_time =
        getAudioTime()

    local target_frame =
        math.floor(
            audio_time * video.fps
        ) + 1

    if target_frame < 1 then
        target_frame = 1
    end

    if video.last_frame
        < video.first_frame then

        return
    end

    if target_frame >
        video.last_frame then

        return
    end

    if video.last_frame
        - target_frame
        <= VIDEO_REFILL_THRESHOLD
        and video.pending_frames <= 0
        and not video.finished then

        video.pending_frames =
            VIDEO_REFILL_FRAMES
    end

    local frame =
        getBufferedFrame(
            video,
            target_frame
        )

    if not frame then
        return
    end

    if frame ==
        last_rendered_frame then

        return
    end

    local target_width,
          target_height

    local target_cell_width

    if inline_video then
        target_cell_width = width
        target_width = target_cell_width * 2
        target_height = math.max(1, height - 6)
    else
        target_cell_width,
        target_height =
            target.getSize()

        target_width = target_cell_width * 2
    end

    local draw_width =
        math.min(
            video.width,
            target_width
        )

    local draw_height =
        math.min(
            video.height,
            target_height
        )

    local x = 1
    local y = 1

    if inline_video then
        x = 1
        y = 7
    else
        local rendered_columns = math.floor(draw_width / 2)
        x = math.max(1, math.floor((target_cell_width - rendered_columns) / 2) + 1)
        y = math.max(1, math.floor((target_height - draw_height) / 2) + 1)
    end

    drawHalfBlockVideoFrame(
        target,
        frame,
        draw_width,
        draw_height,
        x,
        y
    )

    last_rendered_frame =
        frame
end

------------------------------------------------------------
-- FILTER SEARCH RESULTS
------------------------------------------------------------

local function filterPromo(results)

    if not results then
        return nil
    end

    local cleaned = {}

    for _, item in ipairs(results) do

        local name =
            string.lower(
                item.name or ""
            )

        local artist =
            string.lower(
                item.artist or ""
            )

        if not name:find("patreon")
            and not artist:find("patreon") then

            table.insert(
                cleaned,
                item
            )
        end
    end

    return cleaned
end

------------------------------------------------------------
-- BUILD DOWNLOAD URL
------------------------------------------------------------

local function build_download_url(result)

    local video_url =
        result.url
        or result.id
        or ""

    if video_url == "" then
        return nil
    end

    return backend_url
        .. textutils.urlEncode(
            video_url
        )
end

------------------------------------------------------------
-- SEARCH
------------------------------------------------------------

local function startSearch(input)

    if not input
        or #input == 0 then

        last_search = nil
        last_search_url = nil
        search_results = nil
        search_error = false
        search_scroll = 0

        return
    end

    last_search =
        input

    last_search_url =
        api_base_url
        .. "?v="
        .. version
        .. "&search="
        .. textutils.urlEncode(
            input
        )

    search_results = nil
    search_error = false
    search_scroll = 0

    local ok =
        pcall(
            http.request,
            last_search_url
        )

    if not ok then
        search_error = true
    end
end

------------------------------------------------------------
-- AUDIO DOWNLOAD
------------------------------------------------------------

local function openAudio(url)

    local handle =
        http.get(
            url,
            nil,
            true
        )

    if not handle then
        return nil
    end

    return handle
end

------------------------------------------------------------
-- START TRACK
------------------------------------------------------------

local function startTrack(result)

    if not result then
        return false
    end

    local url =
        build_download_url(
            result
        )

    if not url then
        return false
    end

    resetAudioState()

    stopVideoStream()
    restoreVideoPalette()

    audio_request_id =
        audio_request_id + 1

    local my_request =
        audio_request_id

    playingVideo = false
    currentVideo = nil
    last_rendered_frame = nil

    currentTrack =
        result

    local handle =
        openAudio(url)

    if not handle then
        return false
    end

    if audio_request_id ~= my_request then
        pcall(function()
            handle.close()
        end)

        return false
    end

    audio_handle =
        handle

    audio_decoder =
        require(
            "cc.audio.dfpwm"
        ).make_decoder()

    audio_playing = true
    audio_paused = false
    audio_stopped = false

    --------------------------------------------------------
    -- VIDEO
    --------------------------------------------------------

    local video_source =
        result.url
        or result.id

    if video_source
        and (video_monitor or inline_video) then

        local video_width,
              video_height

        if inline_video then
            video_width = width * 2
            video_height = math.max(1, height - 6)
        else
            video_width,
            video_height =
                video_monitor.getSize()

            video_width = video_width * 2
        end

        video_width =
            math.min(
                video_width,
                256
            )

        video_height =
            math.min(
                video_height,
                72
            )

        local video_url =
            backend_video_url
            .. textutils.urlEncode(
                tostring(
                    video_source
                )
            )
            .. "&resolution="
            .. video_width
            .. "x"
            .. video_height
            .. "&fps="
            .. (inline_video and inline_video_fps or video_fps)

        local streamedVideo =
            streamNFV(
                video_url
            )

        if streamedVideo then

            waitForVideoPrebuffer(
                streamedVideo
            )

            playingVideo = true

            currentVideo =
                streamedVideo

            setMonitorPalette(
                video_palette_target,
                streamedVideo.palette
            )
        end
    end

    --------------------------------------------------------
    -- AUDIO PLAYER THREAD
    --------------------------------------------------------

    while audio_playing
        and audio_request_id == my_request
        and audio_handle == handle do

        local chunk =
            handle.read(
                DFPWM_CHUNK_SIZE
            )

        if not chunk
            or #chunk == 0 then

            audio_playing = false

            audio_stopped = true

            audio_paused = false

            break
        end

        audio_byte_position =
            audio_byte_position
            + #chunk

        local decoded =
            audio_decoder(
                chunk
            )

        while true do

            if not audio_playing
                or audio_request_id ~= my_request then

                break
            end

            if speaker.playAudio(
                decoded,
                AUDIO_VOLUME
            ) then

                audio_samples_submitted =
                    audio_samples_submitted
                    + #decoded

                if not audio_start_time then
                    audio_start_time =
                        os.epoch("utc")
                end

                break
            end

            os.pullEvent()
        end

        if not audio_playing
            or audio_request_id ~= my_request then
            break
        end

        sleep(0)
    end

    if audio_handle == handle then

        pcall(function()
            handle.close()
        end)

        audio_handle = nil
    end

    if audio_request_id == my_request then

        audio_playing = false
        audio_stopped = true

        if playingVideo then
            playingVideo = false
        end
    end

    return true
end

------------------------------------------------------------
-- STOP
------------------------------------------------------------

local function stopPlayback()

    audio_request_id =
        audio_request_id + 1

    audio_playing = false
    audio_paused = false
    audio_stopped = true
    pendingTrack = nil
    restoreVideoPalette()

    pcall(function()
        speaker.stop()
    end)

    os.queueEvent("playback_wakeup")

    if audio_handle then

        pcall(function()
            audio_handle.close()
        end)

        audio_handle = nil
    end

    stopVideoStream()

    playingVideo = false
    currentVideo = nil
    last_rendered_frame = nil
end

------------------------------------------------------------
-- PAUSE
------------------------------------------------------------

local function pausePlayback()

    if not audio_playing then
        return
    end

    audio_playing = false
    audio_paused = true

    pcall(function()
        speaker.stop()
    end)

    os.queueEvent("playback_wakeup")
end

------------------------------------------------------------
-- ASYNCHRONOUS TRACK START
------------------------------------------------------------

local function queueTrackForPlaying(result)

    if not result then
        return
    end

    stopPlayback()
    pendingTrack = result
    os.queueEvent("play_track")
end

local function playbackLoop()

    while true do

        if pendingTrack then
            local result = pendingTrack
            pendingTrack = nil
            startTrack(result)
        else
            os.pullEvent("play_track")
        end
    end
end

------------------------------------------------------------
-- NEXT TRACK
------------------------------------------------------------

local function playNext()

    if not tape_queue[1] then
        return
    end

    local result =
        table.remove(
            tape_queue,
            1
        )

    if result.type == "playlist"
        and result.playlist_items
        and result.playlist_items[1] then

        result =
            result.playlist_items[1]
    end

    queueTrackForPlaying(result)
end

------------------------------------------------------------
-- AUTOPLAY
------------------------------------------------------------

local function autoplayNextTrack()

    if not autoplay_next then
        return
    end

    if not tape_queue[1] then
        return
    end

    playNext()
end

------------------------------------------------------------
-- PROGRESS
------------------------------------------------------------

local function drawProgress()
    local bar_x = 2
    local bar_y = 6
    local bar_w = math.max(1, width - 3)
    local duration = getAudioDuration()
    local position = getAudioTime()
    local pct = 0

    if duration > 0 then
        pct = math.min(1, position / duration)
    end

    local filled = math.floor(bar_w * pct)

    term.setCursorPos(bar_x, bar_y)
    term.setBackgroundColor(colors.gray)
    term.write(string.rep(" ", bar_w))

    if filled > 0 then
        term.setCursorPos(bar_x, bar_y)
        term.setBackgroundColor(colors.green)
        term.write(string.rep(" ", filled))
    end

    term.setBackgroundColor(colors.black)
end

------------------------------------------------------------
-- METADATA
------------------------------------------------------------

local function drawMetadata()

    term.setCursorPos(
        2,
        7
    )

    term.setBackgroundColor(
        colors.black
    )

    term.setTextColor(
        colors.lightGray
    )

    term.clearLine()

    local name =
        currentTrack
        and currentTrack.name
        or "No track"

    local artist =
        currentTrack
        and currentTrack.artist
        or ""

    local duration =
        getAudioDuration()

    local position =
        getAudioTime()

    local status = "STOPPED"

    if audio_playing then
        status = "PLAYING"
    elseif audio_paused then
        status = "PAUSED"
    end

    local text =
        name

    if artist ~= "" then
        text =
            text
            .. " - "
            .. artist
    end

    text =
        text
        .. " ["
        .. status
        .. "]"

    if duration > 0 then

        text =
            text
            .. " "
            .. math.floor(position)
            .. "/"
            .. math.floor(duration)
            .. "s"
    end

    if #text > width - 2 then
        text =
            text:sub(
                1,
                width - 2
            )
    end

    term.write(text)
end

------------------------------------------------------------
-- SCROLLBAR
------------------------------------------------------------

local function drawScrollbar(
    count,
    scroll,
    max_scroll,
    top
)

    if count <= 0 then
        return
    end

    local list_height =
        count * 2

    local view_height =
        height - top + 1

    if list_height <= view_height then
        return
    end

    local bar_x =
        width

    local bar_y_top =
        top

    local bar_y_bottom =
        height

    local track_height =
        bar_y_bottom
        - bar_y_top
        + 1

    local thumb_height =
        math.max(
            1,
            math.floor(
                track_height
                * (view_height
                / list_height)
            )
        )

    local thumb_range =
        track_height
        - thumb_height

    local thumb_offset = 0

    if max_scroll > 0 then
        thumb_offset =
            math.floor(
                (scroll / max_scroll)
                * thumb_range
            )
    end

    for y =
        bar_y_top,
        bar_y_bottom do

        term.setCursorPos(
            bar_x,
            y
        )

        term.setBackgroundColor(
            colors.gray
        )

        term.write(" ")
    end

    for y =
        bar_y_top + thumb_offset,
        bar_y_top
        + thumb_offset
        + thumb_height
        - 1 do

        term.setCursorPos(
            bar_x,
            y
        )

        term.setBackgroundColor(
            colors.white
        )

        term.write(" ")
    end

    term.setBackgroundColor(
        colors.black
    )
end

------------------------------------------------------------
-- SEARCH SCREEN
------------------------------------------------------------

local function drawSearch()

    paintutils.drawFilledBox(
        1,
        3,
        width,
        5,
        colors.lightGray
    )

    term.setBackgroundColor(
        colors.lightGray
    )

    term.setTextColor(
        colors.black
    )

    term.setCursorPos(
        2,
        4
    )

    local search_text =
        waiting_for_input
        and search_input
        or last_search
        or "Search..."

    local visible_search_width =
        math.max(0, width - 3)

    if #search_text > visible_search_width then

        if waiting_for_input then
            search_text = search_text:sub(-visible_search_width)
        else
            search_text = search_text:sub(1, visible_search_width)
        end
    end

    term.write(
        search_text
    )

    if waiting_for_input then
        term.setCursorPos(
            math.min(width - 1, 2 + #search_text),
            4
        )
        term.setCursorBlink(true)
    end

    if inline_video and playingVideo and currentVideo then
        term.setCursorBlink(false)
        term.setCursorPos(2, 6)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.white)
        term.clearLine()

        local title =
            currentTrack
            and currentTrack.name
            or "Now playing"

        term.write(title:sub(1, math.max(0, width - 2)))
        return
    end

    drawProgress()
    drawMetadata()

    if search_results then

        max_scroll =
            math.max(
                0,
                (#search_results * 2)
                - (height - 8)
            )

        for i = 1,
            #search_results do

            local y_name =
                8
                + (i - 1) * 2
                - search_scroll

            local y_artist =
                9
                + (i - 1) * 2
                - search_scroll

            if y_name >= 8
                and y_name <= height then

                term.setBackgroundColor(
                    colors.black
                )

                term.setTextColor(
                    colors.white
                )

                term.setCursorPos(
                    2,
                    y_name
                )

                local name =
                    search_results[i].name
                    or "Unknown"

                local max_width =
                    width - 4

                if #name > max_width then
                    name =
                        name:sub(
                            1,
                            max_width
                        )
                end

                term.write(name)

                if width >= 6 then

                    term.setCursorPos(
                        width - 2,
                        y_name
                    )

                    term.setTextColor(
                        colors.green
                    )

                    term.write("+")
                end
            end

            if y_artist >= 8
                and y_artist <= height then

                term.setBackgroundColor(
                    colors.black
                )

                term.setTextColor(
                    colors.lightGray
                )

                term.setCursorPos(
                    2,
                    y_artist
                )

                local artist =
                    search_results[i].artist
                    or ""

                local max_width =
                    width - 4

                if #artist > max_width then
                    artist =
                        artist:sub(
                            1,
                            max_width
                        )
                end

                term.write(artist)
            end
        end

        drawScrollbar(
            #search_results,
            search_scroll,
            max_scroll,
            8
        )

    else

        term.setBackgroundColor(
            colors.black
        )

        term.setCursorPos(
            2,
            8
        )

        if search_error then

            term.setTextColor(
                colors.red
            )

            term.write(
                "Search failed."
            )

        elseif last_search_url then

            term.setTextColor(
                colors.lightGray
            )

            term.write(
                "Searching..."
            )

        else

            term.setTextColor(
                colors.lightGray
            )

            term.write(
                "Enter a song or YouTube link."
            )
        end
    end
end

------------------------------------------------------------
-- PLAYLIST SCREEN
------------------------------------------------------------

local function drawPlaylist()

    term.setBackgroundColor(
        colors.black
    )

    term.setTextColor(
        colors.white
    )

    term.setCursorPos(
        2,
        3
    )

    term.write(
        "Playlist"
    )

    if #playlist == 0 then

        term.setCursorPos(
            2,
            5
        )

        term.setTextColor(
            colors.lightGray
        )

        term.write(
            "Playlist empty."
        )

        return
    end

    playlist_max_scroll =
        math.max(
            0,
            (#playlist * 2)
            - (height - 4)
        )

    for i = 1,
        #playlist do

        local y_name =
            4
            + (i - 1) * 2
            - playlist_scroll

        local y_controls =
            5
            + (i - 1) * 2
            - playlist_scroll

        if y_name >= 4
            and y_name <= height then

            term.setCursorPos(
                2,
                y_name
            )

            term.setTextColor(
                colors.white
            )

            local name =
                playlist[i].name
                or "Unknown"

            if #name > width - 2 then
                name =
                    name:sub(
                        1,
                        width - 2
                    )
            end

            term.write(name)
        end

        if y_controls >= 4
            and y_controls <= height then

            term.setCursorPos(
                2,
                y_controls
            )

            term.setTextColor(
                colors.green
            )

            term.write("^ ")

            term.setTextColor(
                colors.cyan
            )

            term.write("v ")

            term.setTextColor(
                colors.red
            )

            term.write("X")
        end
    end

    drawScrollbar(
        #playlist,
        playlist_scroll,
        playlist_max_scroll,
        4
    )
end

------------------------------------------------------------
-- QUEUE SCREEN
------------------------------------------------------------

local function drawQueue()

    term.setBackgroundColor(
        colors.black
    )

    term.setTextColor(
        colors.white
    )

    term.setCursorPos(
        2,
        3
    )

    local autoplay =
        autoplay_next
        and "ON"
        or "OFF"

    term.write(
        "Queue A:"
        .. autoplay
    )

    if #tape_queue == 0 then

        term.setCursorPos(
            2,
            5
        )

        term.setTextColor(
            colors.lightGray
        )

        term.write(
            "Queue empty."
        )

        return
    end

    queue_max_scroll =
        math.max(
            0,
            (#tape_queue * 2)
            - (height - 4)
        )

    for i = 1,
        #tape_queue do

        local y_name =
            4
            + (i - 1) * 2
            - queue_scroll

        local y_controls =
            5
            + (i - 1) * 2
            - queue_scroll

        if y_name >= 4
            and y_name <= height then

            term.setCursorPos(
                2,
                y_name
            )

            term.setTextColor(
                colors.white
            )

            local name =
                tape_queue[i].name
                or "Unknown"

            if #name > width - 2 then
                name =
                    name:sub(
                        1,
                        width - 2
                    )
            end

            term.write(name)
        end

        if y_controls >= 4
            and y_controls <= height then

            term.setCursorPos(
                2,
                y_controls
            )

            term.setTextColor(
                colors.green
            )

            term.write("^ ")

            term.setTextColor(
                colors.cyan
            )

            term.write("v ")

            term.setTextColor(
                colors.red
            )

            term.write("X")
        end
    end

    drawScrollbar(
        #tape_queue,
        queue_scroll,
        queue_max_scroll,
        4
    )
end

------------------------------------------------------------
-- HEADER
------------------------------------------------------------

local function redrawScreen()

    term.setCursorBlink(false)

    term.setBackgroundColor(
        colors.black
    )

    term.clear()

    --------------------------------------------------------
    -- TOP BAR
    --------------------------------------------------------

    term.setCursorPos(
        1,
        1
    )

    term.setBackgroundColor(
        colors.gray
    )

    term.clearLine()

    local tabs = {
        "S",
        "P",
        "Q",
        "PLAY",
        "STOP",
        "NEXT"
    }

    local zones = #tabs

    for i = 1,
        #tabs do

        local bg =
            colors.gray

        local fg =
            colors.white

        if i == 1
            or i == 2
            or i == 3 then

            if tab == i then
                bg = colors.white
                fg = colors.black
            end

        elseif i == 4 then

            if audio_playing then
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
        end

        local start_x =
            math.floor(
                ((i - 1)
                * width)
                / zones
            ) + 1

        local end_x =
            math.floor(
                (i * width)
                / zones
            )

        term.setBackgroundColor(
            bg
        )

        term.setTextColor(
            fg
        )

        term.setCursorPos(
            start_x,
            1
        )

        term.write(
            string.rep(
                " ",
                end_x
                - start_x
                + 1
            )
        )

        local label =
            tabs[i]

        local label_x =
            start_x
            + math.floor(
                (
                    end_x
                    - start_x
                    + 1
                    - #label
                ) / 2
            )

        term.setCursorPos(
            label_x,
            1
        )

        term.write(label)
    end

    --------------------------------------------------------
    -- CONTENT
    --------------------------------------------------------

    if tab == 1 then

        drawSearch()

    elseif tab == 2 then

        drawPlaylist()

    elseif tab == 3 then

        drawQueue()
    end

    if update_status then
        term.setCursorPos(2, 2)
        term.setBackgroundColor(colors.black)
        term.setTextColor(colors.cyan)
        term.clearLine()
        term.write(update_status:sub(1, width - 2))
    end

    if inline_video and playingVideo and currentVideo then
        last_rendered_frame = nil
        renderCurrentVideoFrame()
    end
end

------------------------------------------------------------
-- HTTP LOOP
------------------------------------------------------------

local function httpLoop()

    while true do

        local event,
              url,
              handle,
              reason =
            os.pullEvent()

        if event == "http_success" then

            if url ==
                last_search_url then

                local body =
                    handle.readAll()

                handle.close()

                local ok,
                      raw =
                    pcall(
                        textutils.unserialiseJSON,
                        body
                    )

                if ok
                    and type(raw)
                        == "table" then

                    search_results =
                        filterPromo(raw)

                    search_error =
                        false

                else

                    search_results = nil
                    search_error = true
                end

                os.queueEvent(
                    "redraw_screen"
                )

            elseif url == player_update_url then

                local body = handle.readAll()
                handle.close()
                update_in_progress = false

                local program_path = shell.getRunningProgram()

                if body and #body > 0 and program_path then
                    local file
                    local saved, save_error = pcall(function()
                        file = fs.open(program_path, "w")

                        if not file then
                            error("could not open running program")
                        end

                        file.write(body)
                        file.close()
                        file = nil
                    end)

                    if file then
                        pcall(function()
                            file.close()
                        end)
                    end

                    if saved then
                        update_status = "Updated. Restart player to load new version."
                    else
                        update_status = "Update save failed: " .. tostring(save_error)
                    end
                else
                    update_status = "Update failed: empty response or unknown program path."
                end

                os.queueEvent("redraw_screen")
            end

        elseif event == "http_failure" then

            if url ==
                last_search_url then

                search_error = true

                os.queueEvent(
                    "redraw_screen"
                )
            end

            if url == player_update_url then
                update_in_progress = false
                update_status = "Update failed: " .. tostring(handle)

                if reason and type(reason.close) == "function" then
                    pcall(reason.close)
                end

                os.queueEvent("redraw_screen")
            end
        end
    end
end

local function requestPlayerUpdate()

    if update_in_progress then
        return
    end

    update_in_progress = true
    update_status = "Downloading update..."

    local ok = pcall(http.request, player_update_url)

    if not ok then
        update_in_progress = false
        update_status = "Update failed: HTTP request could not start."
    end

    os.queueEvent("redraw_screen")
end

------------------------------------------------------------
-- VIDEO LOOP
------------------------------------------------------------

local function videoLoop()

    local frame_period =
        1 / monitor_fps

    while true do

        if playingVideo
            and currentVideo
            and audio_playing then

            local ok, err =
                pcall(
                    renderCurrentVideoFrame
                )

            if not ok then

                playingVideo = false
                restoreVideoPalette()

                if video_monitor then
                    video_monitor.clear()
                end
            end

            sleep(
                frame_period
            )

        else

            sleep(0.05)
        end
    end
end

------------------------------------------------------------
-- AUDIO MONITOR
------------------------------------------------------------

local function audioMonitorLoop()

    while true do

        if audio_playing then

            ------------------------------------------------
            -- Approximate the amount of audio actually
            -- played.
            --
            -- The speaker API does not expose a tape-style
            -- getPosition(), so the player uses elapsed
            -- playback time, limited by submitted samples.
            ------------------------------------------------

            if audio_start_time then

                local now = os.epoch("utc")
                local elapsed =
                    (now - audio_start_time) / 1000

                local elapsed_samples =
                    math.floor(
                        elapsed
                        * AUDIO_SAMPLE_RATE
                    )

                local available_samples =
                    math.max(
                        0,
                        audio_samples_submitted
                        - audio_samples_played
                    )

                audio_samples_played =
                    audio_samples_played
                    + math.min(
                        elapsed_samples,
                        available_samples
                    )

                audio_start_time = now
            end

            if not audio_handle
                and audio_samples_submitted > 0
                and audio_samples_played >= audio_samples_submitted then

                audio_playing = false
                audio_stopped = true

                if playingVideo then
                    playingVideo = false
                end

                stopVideoStream()
                restoreVideoPalette()

                os.queueEvent(
                    "track_finished"
                )
            end

            if not (inline_video and playingVideo) then
                os.queueEvent(
                    "redraw_screen"
                )
            end

            sleep(
                AUDIO_POSITION_UPDATE
            )

        else

            sleep(0.05)
        end
    end
end

------------------------------------------------------------
-- MAIN UI LOOP
------------------------------------------------------------

local function uiLoop()

    redrawScreen()

    while not restart_requested do

        local event,
              p1,
              x,
              y =
            os.pullEvent()

        if waiting_for_input then

            if event == "char" then
                search_input = search_input .. p1
                redrawScreen()

            elseif event == "paste" then
                search_input = search_input .. p1
                redrawScreen()

            elseif event == "key" and p1 == keys.backspace then
                search_input = search_input:sub(1, -2)
                redrawScreen()

            elseif event == "key" and p1 == keys.enter then
                term.setCursorBlink(false)
                waiting_for_input = false
                startSearch(search_input)
                search_input = ""
                redrawScreen()

            elseif event == "redraw_screen" then
                redrawScreen()

            elseif event == "track_finished" then
                if autoplay_next then
                    playNext()
                end

                redrawScreen()
            end

        else

            ------------------------------------------------
            -- REDRAW
            ------------------------------------------------

            if event == "redraw_screen" then

                redrawScreen()

            ------------------------------------------------
            -- TRACK FINISHED
            ------------------------------------------------

            elseif event == "track_finished" then

                if autoplay_next then
                    playNext()
                end

                redrawScreen()

            elseif event == "char" and p1:lower() == "u" then

                requestPlayerUpdate()

            ------------------------------------------------
            -- SCROLL
            ------------------------------------------------

            elseif event == "mouse_scroll" then

                if tab == 1
                    and search_results then

                    search_scroll =
                        search_scroll
                        + p1 * 2

                    search_scroll =
                        math.max(
                            0,
                            math.min(
                                max_scroll,
                                search_scroll
                            )
                        )

                elseif tab == 2 then

                    playlist_scroll =
                        playlist_scroll
                        + p1 * 2

                    playlist_scroll =
                        math.max(
                            0,
                            math.min(
                                playlist_max_scroll,
                                playlist_scroll
                            )
                        )

                elseif tab == 3 then

                    queue_scroll =
                        queue_scroll
                        + p1 * 2

                    queue_scroll =
                        math.max(
                            0,
                            math.min(
                                queue_max_scroll,
                                queue_scroll
                            )
                        )
                end

                redrawScreen()

            ------------------------------------------------
            -- CLICK
            ------------------------------------------------

            elseif event == "mouse_click"
                or (event == "monitor_touch" and monitor_ui) then

                if event == "monitor_touch" then
                    p1 = 1
                end

                local button = p1

                ------------------------------------------------
                -- TOP BAR
                ------------------------------------------------

                if y == 1 then

                    local zone =
                        math.floor(
                            ((x - 1)
                            * 6)
                            / width
                        ) + 1

                    if zone < 1 then
                        zone = 1
                    end

                    if zone > 6 then
                        zone = 6
                    end

                    ------------------------------------------------
                    -- SEARCH
                    ------------------------------------------------

                    if zone == 1 then

                        tab = 1
                        redrawScreen()

                    ------------------------------------------------
                    -- PLAYLIST
                    ------------------------------------------------

                    elseif zone == 2 then

                        tab = 2
                        redrawScreen()

                    ------------------------------------------------
                    -- QUEUE
                    ------------------------------------------------

                    elseif zone == 3 then

                        tab = 3
                        redrawScreen()

                    ------------------------------------------------
                    -- PLAY / PAUSE
                    ------------------------------------------------

                    elseif zone == 4 then

                        if audio_playing then

                            pausePlayback()

                        elseif currentTrack
                            and audio_paused then

                            ------------------------------------------------
                            -- Restarting a paused stream from an exact
                            -- speaker position is not directly supported
                            -- by the speaker API.
                            --
                            -- For reliability on Pocket computers,
                            -- resume starts the current track again.
                            ------------------------------------------------

                            queueTrackForPlaying(
                                currentTrack
                            )

                        elseif currentTrack then

                            queueTrackForPlaying(
                                currentTrack
                            )
                        end

                        redrawScreen()

                    ------------------------------------------------
                    -- STOP
                    ------------------------------------------------

                    elseif zone == 5 then

                        stopPlayback()

                        redrawScreen()

                    ------------------------------------------------
                    -- NEXT
                    ------------------------------------------------

                    elseif zone == 6 then

                        playNext()

                        redrawScreen()
                    end

                ------------------------------------------------
                -- SEARCH BAR
                ------------------------------------------------

                elseif tab == 1
                    and y >= 3
                    and y <= 5 then

                    waiting_for_input = true
                    search_input = ""

                    term.setCursorPos(
                        2,
                        4
                    )

                    term.setBackgroundColor(
                        colors.white
                    )

                    term.setTextColor(
                        colors.black
                    )

                    term.clearLine()

                    redrawScreen()

                ------------------------------------------------
                -- PROGRESS BAR
                ------------------------------------------------

                elseif tab == 1
                    and y == 6 then

                    ------------------------------------------------
                    -- Speaker playback does not expose a direct
                    -- seek operation. Do not pretend it does.
                    ------------------------------------------------

                ------------------------------------------------
                -- SEARCH RESULTS
                ------------------------------------------------

                elseif tab == 1
                    and search_results then

                    for i = 1,
                        #search_results do

                        local y_name =
                            8
                            + (i - 1) * 2
                            - search_scroll

                        local y_artist =
                            y_name + 1

                        if y == y_name
                            or y == y_artist then

                            local result =
                                search_results[i]

                            if result.type
                                == "playlist"
                                and result.playlist_items
                                and result.playlist_items[1] then

                                result =
                                    result.playlist_items[1]
                            end

                            ------------------------------------------------
                            -- ADD TO PLAYLIST
                            ------------------------------------------------

                            if y == y_name
                                and x >= width - 3 then

                                table.insert(
                                    playlist,
                                    result
                                )

                                redrawScreen()

                                break
                            end

                            ------------------------------------------------
                            -- RIGHT CLICK = QUEUE
                            ------------------------------------------------

                            if button == 2 then

                                table.insert(
                                    tape_queue,
                                    result
                                )

                                redrawScreen()

                                break
                            end

                            ------------------------------------------------
                            -- LEFT CLICK = PLAY
                            ------------------------------------------------

                            if button == 1 then

                                local copied =
                                    result

                                queueTrackForPlaying(
                                    copied
                                )

                                redrawScreen()

                                break
                            end
                        end
                    end

                ------------------------------------------------
                -- PLAYLIST
                ------------------------------------------------

                elseif tab == 2 then

                    if y >= 4
                        and #playlist > 0 then

                        for i = 1,
                            #playlist do

                            local y_controls =
                                5
                                + (i - 1) * 2
                                - playlist_scroll

                            if y == y_controls then

                                ------------------------------------------------
                                -- UP
                                ------------------------------------------------

                                if x == 2
                                    or x == 3 then

                                    if i > 1 then

                                        playlist[i],
                                        playlist[i - 1] =
                                            playlist[i - 1],
                                            playlist[i]
                                    end
                                end

                                ------------------------------------------------
                                -- DOWN
                                ------------------------------------------------

                                if x == 4
                                    or x == 5 then

                                    if i <
                                        #playlist then

                                        playlist[i],
                                        playlist[i + 1] =
                                            playlist[i + 1],
                                            playlist[i]
                                    end
                                end

                                ------------------------------------------------
                                -- REMOVE
                                ------------------------------------------------

                                if x >= 6
                                    and x <= 7 then

                                    table.remove(
                                        playlist,
                                        i
                                    )
                                end

                                redrawScreen()

                                break
                            end
                        end
                    end

                ------------------------------------------------
                -- QUEUE
                ------------------------------------------------

                elseif tab == 3 then

                    ------------------------------------------------
                    -- AUTOPLAY
                    ------------------------------------------------

                    if y == 3 then

                        autoplay_next =
                            not autoplay_next

                        redrawScreen()

                    elseif y >= 4
                        and #tape_queue > 0 then

                        for i = 1,
                            #tape_queue do

                            local y_controls =
                                5
                                + (i - 1) * 2
                                - queue_scroll

                            if y ==
                                y_controls then

                                ------------------------------------------------
                                -- UP
                                ------------------------------------------------

                                if x == 2
                                    or x == 3 then

                                    if i > 1 then

                                        tape_queue[i],
                                        tape_queue[i - 1] =
                                            tape_queue[i - 1],
                                            tape_queue[i]
                                    end
                                end

                                ------------------------------------------------
                                -- DOWN
                                ------------------------------------------------

                                if x == 4
                                    or x == 5 then

                                    if i <
                                        #tape_queue then

                                        tape_queue[i],
                                        tape_queue[i + 1] =
                                            tape_queue[i + 1],
                                            tape_queue[i]
                                    end
                                end

                                ------------------------------------------------
                                -- REMOVE
                                ------------------------------------------------

                                if x >= 6
                                    and x <= 7 then

                                    table.remove(
                                        tape_queue,
                                        i
                                    )
                                end

                                redrawScreen()

                                break
                            end
                        end
                    end
                end
            end
        end
    end
end

------------------------------------------------------------
-- START
------------------------------------------------------------

term.setBackgroundColor(
    colors.black
)

term.setTextColor(
    colors.white
)

term.clear()

term.setCursorPos(
    1,
    1
)

parallel.waitForAny(
    uiLoop,
    playbackLoop,
    httpLoop,
    videoLoop,
    videoStreamLoop,
    audioMonitorLoop
)

------------------------------------------------------------
-- CLEANUP
------------------------------------------------------------

pcall(function()
    speaker.stop()
end)

stopVideoStream()
restoreVideoPalette()

if display_monitor then
    display_monitor.setBackgroundColor(
        colors.black
    )

    display_monitor.clear()
end

term.setBackgroundColor(
    colors.black
)

term.setTextColor(
    colors.white
)

term.clear()

term.setCursorPos(
    1,
    1
)
