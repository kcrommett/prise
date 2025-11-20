local prise = require("prise")

local state = {
    pty = nil,
    status_bg = "white",
}

local M = {}

function M.update(event)
    if event.type == "pty_attach" then
        state.pty = event.data.pty
    elseif event.type == "key_press" then
        if event.key == "b" and event.ctrl then
            state.status_bg = "magenta"
            prise.set_timeout(500, function()
                state.status_bg = "white"
            end)
        end
    end
end

function M.view()
    local main_view
    local title = " Prise Terminal "

    if state.pty then
        main_view = prise.Surface({ pty = state.pty })

        local pty_title = state.pty:title()
        if pty_title and #pty_title > 0 then
            title = " " .. pty_title .. " "
        end
    else
        main_view = prise.Surface({ pty = 1 })
    end

    return prise.Column({
        cross_axis_align = "stretch",
        children = {
            main_view,
            prise.Text({
                text = title,
                style = { bg = state.status_bg, fg = "black" },
            }),
        },
    })
end

return M
