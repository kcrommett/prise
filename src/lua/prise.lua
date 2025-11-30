---@class TerminalOpts
---@field pty userdata
---@field ratio? number
---@field id? string
---@field focus? boolean
---@field show_cursor? boolean

---@class TextSegment
---@field text string
---@field style? table

---@class TextOpts
---@field content? TextSegment[]
---@field show_cursor? boolean

---@class LayoutOpts
---@field children? table[]
---@field ratio? number
---@field id? string|number
---@field cross_axis_align? string
---@field show_cursor? boolean

---@class PositionedOpts
---@field child? table
---@field x? number
---@field y? number
---@field anchor? string
---@field ratio? number
---@field id? string|number

---@class TextInputOpts
---@field input userdata
---@field style? table
---@field focus? boolean

---@class ListOpts
---@field items? string[]
---@field selected? number
---@field scroll_offset? number
---@field style? table
---@field selected_style? table

---@class BoxOpts
---@field child? table
---@field border? string
---@field style? table
---@field max_width? number
---@field max_height? number

---@class PaddingOpts
---@field child? table
---@field all? number
---@field top? number
---@field bottom? number
---@field left? number
---@field right? number

local M = {}

---@param opts TerminalOpts
---@return table
function M.Terminal(opts)
    return {
        type = "terminal",
        pty = opts.pty,
        ratio = opts.ratio,
        id = opts.id,
        focus = opts.focus,
        show_cursor = opts.show_cursor,
    }
end

---@param opts string|TextSegment[]|TextOpts
---@return table
function M.Text(opts)
    if type(opts) == "string" then
        return {
            type = "text",
            content = { opts },
        }
    end

    -- If it has numeric keys, treat it as the content array directly
    if opts[1] then
        return {
            type = "text",
            content = opts,
        }
    end

    -- If it has a 'text' key but not 'content', treat it as a single segment
    if opts.text and not opts.content then
        return {
            type = "text",
            content = { opts },
        }
    end

    return {
        type = "text",
        content = opts.content or {},
        show_cursor = opts.show_cursor,
    }
end

---@param opts table[]|LayoutOpts
---@return table
function M.Column(opts)
    -- If opts is an array (has numeric keys), it's just the children
    if opts[1] then
        return {
            type = "column",
            children = opts,
        }
    end

    return {
        type = "column",
        children = opts.children or opts,
        ratio = opts.ratio,
        id = opts.id,
        cross_axis_align = opts.cross_axis_align,
        show_cursor = opts.show_cursor,
    }
end

---@param opts table[]|LayoutOpts
---@return table
function M.Row(opts)
    -- If opts is an array (has numeric keys), it's just the children
    if opts[1] then
        return {
            type = "row",
            children = opts,
        }
    end

    return {
        type = "row",
        children = opts.children or opts,
        ratio = opts.ratio,
        id = opts.id,
        cross_axis_align = opts.cross_axis_align,
        show_cursor = opts.show_cursor,
    }
end

---@param opts table[]|LayoutOpts
---@return table
function M.Stack(opts)
    -- If opts is an array (has numeric keys), it's just the children
    if opts[1] then
        return {
            type = "stack",
            children = opts,
        }
    end

    return {
        type = "stack",
        children = opts.children or {},
        ratio = opts.ratio,
        id = opts.id,
    }
end

---@param opts PositionedOpts
---@return table
function M.Positioned(opts)
    return {
        type = "positioned",
        child = opts.child or opts[1],
        x = opts.x,
        y = opts.y,
        anchor = opts.anchor,
        ratio = opts.ratio,
        id = opts.id,
    }
end

---@param opts TextInputOpts
---@return table
function M.TextInput(opts)
    return {
        type = "text_input",
        input = opts.input,
        style = opts.style,
        focus = opts.focus,
    }
end

---@param opts ListOpts|string[]
---@return table
function M.List(opts)
    return {
        type = "list",
        items = opts.items or opts,
        selected = opts.selected,
        scroll_offset = opts.scroll_offset,
        style = opts.style,
        selected_style = opts.selected_style,
    }
end

---@param opts BoxOpts
---@return table
function M.Box(opts)
    return {
        type = "box",
        child = opts.child or opts[1],
        border = opts.border,
        style = opts.style,
        max_width = opts.max_width,
        max_height = opts.max_height,
    }
end

---@param opts PaddingOpts
---@return table
function M.Padding(opts)
    return {
        type = "padding",
        child = opts.child or opts[1],
        all = opts.all,
        top = opts.top,
        bottom = opts.bottom,
        left = opts.left,
        right = opts.right,
    }
end

return M
