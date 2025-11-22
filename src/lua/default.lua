local prise = require("prise")

local state = {
    ptys = {},
    focused_index = 1,
    status_bg = "white",
    pending_command = false,
}

local M = {}

function M.update(event)
    if event.type == "pty_attach" then
        prise.log.info("Lua: pty_attach received")
        table.insert(state.ptys, event.data.pty)
        prise.log.info("Lua: pty count is " .. #state.ptys)

        -- If this is the first terminal, spawn another one
        if #state.ptys == 1 then
            prise.log.info("Lua: spawning second terminal")
            prise.spawn({})
        end
        prise.request_frame()
    elseif event.type == "key_press" then
        -- Handle pending command mode (after Ctrl+b)
        if state.pending_command then
            local handled = false
            if event.data.key == "h" then
                state.focused_index = 1
                handled = true
            elseif event.data.key == "l" then
                state.focused_index = 2
                handled = true
            end

            if handled then
                state.pending_command = false
                state.status_bg = "white"
                prise.request_frame()
                return
            end

            -- Consume other keys and exit command mode
            state.pending_command = false
            state.status_bg = "white"
            prise.request_frame()
            return
        end

        -- Ctrl+b to enter command mode
        if event.data.key == "b" and event.data.ctrl then
            state.pending_command = true
            state.status_bg = "magenta"
            prise.request_frame()
            prise.set_timeout(1000, function()
                if state.pending_command then
                    state.pending_command = false
                    state.status_bg = "white"
                    prise.request_frame()
                end
            end)
            return
        end

        -- Pass through to PTY
        local pty = state.ptys[state.focused_index]
        if pty then
            pty:send_key(event.data)
        end

        -- Ctrl+n to switch focus (legacy)
        if event.data.key == "n" and event.data.ctrl then
            state.focused_index = state.focused_index + 1
            if state.focused_index > #state.ptys then
                state.focused_index = 1
            end
            prise.request_frame()
        end
    elseif event.type == "winsize" then
        prise.request_frame()
    end
end

function M.view()
    local terminal_views = {}

    for i, pty in ipairs(state.ptys) do
        local is_focused = i == state.focused_index
        table.insert(terminal_views, prise.Terminal({ pty = pty, flex = 1, show_cursor = is_focused }))
    end

    if #terminal_views == 0 then
        table.insert(terminal_views, prise.Text("Waiting for terminal..."))
    end

    local title = " Prise Terminal "
    local active_pty = state.ptys[state.focused_index]
    if active_pty then
        local pty_title = active_pty:title()
        if pty_title and #pty_title > 0 then
            title = " " .. pty_title .. " "
        end
    end

    return prise.Column({
        cross_axis_align = "stretch",
        children = {
            prise.Row({
                flex = 1,
                children = terminal_views,
                cross_axis_align = "stretch",
            }),
            prise.Text({
                text = title,
                style = { bg = state.status_bg, fg = "black" },
            }),
        },
    })
end

return M
