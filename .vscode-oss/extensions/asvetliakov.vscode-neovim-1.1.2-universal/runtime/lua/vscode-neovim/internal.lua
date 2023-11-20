local api, fn = vim.api, vim.fn

local util = require("vscode-neovim.util")

local M = {}

---call from vscode to sync viewport with neovim
---@param vscode_topline number the top line of vscode visible range
---@param vscode_endline number the end line of vscode visible range
function M.scroll_viewport(vscode_topline, vscode_endline)
  local current_height = vim.api.nvim_win_get_height(0)
  local new_height = vscode_endline - vscode_topline + 1
  -- resize height
  if current_height ~= new_height then
    vim.api.nvim_win_set_height(0, new_height)
  end

  local top_line = vim.fn.line("w0")
  local diff = top_line - vscode_topline

  if diff ~= 0 and (vscode_topline > 0) then
    vim.fn.winrestview({
      topline = vscode_topline,
    })
  end
end

---Close windows
---@param wins number[]
function M.close_windows(wins)
  for _, win in ipairs(wins) do
    pcall(vim.api.nvim_win_close, win, true)
  end
end

---Delete buffers
---@param bufs number[]
function M.delete_buffers(bufs)
  for _, buf in ipairs(bufs) do
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end
end

---Handle document changes
---@param bufnr number
---@param changes (string | integer)[][]
---@return number: changed tick of the buffer
function M.handle_changes(bufnr, changes)
  -- Save and restore local marks
  -- Code modified from https://github.com/neovim/neovim/pull/14630
  local marks = {}
  for _, m in pairs(fn.getmarklist(bufnr or api.nvim_get_current_buf())) do
    if m.mark:match("^'[a-z]$") then
      marks[m.mark:sub(2, 2)] = { m.pos[2], m.pos[3] - 1 } -- api-indexed
    end
  end

  for _, change in ipairs(changes) do
    api.nvim_buf_set_text(bufnr, unpack(change))
  end

  local max = api.nvim_buf_line_count(bufnr)
  -- no need to restore marks that still exist
  for _, m in pairs(fn.getmarklist(bufnr or api.nvim_get_current_buf())) do
    marks[m.mark:sub(2, 2)] = nil
  end
  -- restore marks
  for mark, pos in pairs(marks) do
    if pos then
      -- make sure we don't go out of bounds
      local line = (api.nvim_buf_get_lines(bufnr, pos[1] - 1, pos[1], false))[1] or ""
      pos[1] = math.min(pos[1], max)
      pos[2] = math.min(pos[2], #line)
      api.nvim_buf_set_mark(bufnr or 0, mark, pos[1], pos[2], {})
    end
  end

  return api.nvim_buf_get_changedtick(bufnr)
end

do
  --- Replay changes for dotrepeat ---

  local _curr_win, _temp_buf, _temp_win

  ---@param edits string
  ---@param deletes number
  function M.dotrepeat_sync(edits, deletes)
    local ei = vim.opt.ei:get()
    vim.opt.ei = "all"

    _curr_win = api.nvim_get_current_win()
    _temp_buf = api.nvim_create_buf(false, true)
    _temp_win = api.nvim_open_win(_temp_buf, true, { external = true, width = 100, height = 50 })

    if deletes > 0 then
      api.nvim_buf_set_lines(_temp_buf, 0, -1, false, { ("x"):rep(deletes) })
      api.nvim_win_set_cursor(_temp_win, { 1, deletes })
      local bs = ("<BS>"):rep(deletes)
      bs = api.nvim_replace_termcodes(bs, true, true, true)
      api.nvim_feedkeys(bs, "n", false)
    end
    api.nvim_feedkeys(edits, "n", true)

    vim.opt.ei = ei
  end

  function M.dotrepeat_restore()
    local ei = vim.opt.ei:get()
    vim.opt.ei = "all"

    api.nvim_set_current_win(_curr_win)
    pcall(api.nvim_win_close, _temp_win, true)
    pcall(api.nvim_buf_delete, _temp_buf, { force = true })

    vim.opt.ei = ei
  end
end

---Get editor's selections
---@return lsp.Range[]
function M.get_selections(win)
  win = win or api.nvim_get_current_win()
  local buf = api.nvim_win_get_buf(win)
  local mode = api.nvim_get_mode().mode
  local is_visual = mode:match("[vV\x16]")

  local function wincall(cb)
    return api.nvim_win_call(win, cb)
  end

  -- normal

  if not is_visual then
    local pos = vim.lsp.util.make_position_params(win, "utf-16").position
    return { { start = pos, ["end"] = pos } }
  end

  -- linewise/charwise visual

  if mode:lower() == "v" then
    local start_pos, end_pos
    wincall(function()
      start_pos = { fn.line("v"), fn.col("v") - 1 }
      end_pos = { fn.line("."), fn.col(".") - 1 }
    end)
    local start_from_left = true

    if start_pos[1] > end_pos[1] or (start_pos[1] == end_pos[1] and start_pos[2] > end_pos[2]) then
      start_from_left = false
      start_pos, end_pos = end_pos, start_pos
    end

    if mode == "V" then
      start_pos = { start_pos[1], 0 }
      end_pos = { end_pos[1], #(fn.getbufline(buf, end_pos[1])[1] or "") }
    end

    local range = vim.lsp.util.make_given_range_params(start_pos, end_pos, buf, "utf-16").range
    if not start_from_left then
      range = { start = range["end"], ["end"] = range.start }
    end
    return { range }
  end

  -- blockwise visual

  local ranges = {}

  -- 1-indexed {
  local start_line_1, end_line_1, start_vcol, end_vcol
  wincall(function()
    start_line_1 = fn.line("v")
    end_line_1 = fn.line(".")
    start_vcol = fn.virtcol("v")
    end_vcol = fn.virtcol(".")
  end)
  local curr_line_1 = end_line_1
  -- }
  local top_to_bottom = start_line_1 < end_line_1 or (start_line_1 == end_line_1 and start_vcol <= end_vcol)
  local start_from_left = end_vcol >= start_vcol
  if start_line_1 > end_line_1 then
    start_line_1, end_line_1 = end_line_1, start_line_1
  end
  if start_vcol > end_vcol then
    start_vcol, end_vcol = end_vcol, start_vcol
  end

  for line_1 = start_line_1, end_line_1 do
    local line_0 = line_1 - 1
    local line_text = fn.getbufline(buf, line_1)[1] or ""
    local line_diswidth = wincall(function()
      return fn.strdisplaywidth(line_text)
    end)
    if start_vcol > line_diswidth then
      if line_1 == curr_line_1 then
        local pos = { line = line_0, character = ({ vim.str_utfindex(line_text) })[2] }
        table.insert(ranges, { start = pos, ["end"] = pos })
      else
        -- ignore
      end
    else
      local start_col = fn.virtcol2col(win, line_1, start_vcol)
      local end_col = fn.virtcol2col(win, line_1, end_vcol)
      local start_col_offset = fn.strlen(util.get_char_at(line_1, start_col, buf) or "")
      local end_col_offset = fn.strlen(util.get_char_at(line_1, end_col, buf) or "")
      local range = vim.lsp.util.make_given_range_params(
        { line_1, math.max(0, start_col - start_col_offset) },
        { line_1, math.max(0, end_col - end_col_offset) },
        buf,
        "utf-16"
      ).range
      if not start_from_left then
        range = { start = range["end"], ["end"] = range.start }
      end
      table.insert(ranges, range)
    end
  end

  if #ranges == 0 then
    -- impossible
    local pos = vim.lsp.util.make_position_params(win, "utf-16").position
    return { { start = pos, ["end"] = pos } }
  end

  if top_to_bottom then
    local ret = {}
    for i = #ranges, 1, -1 do
      table.insert(ret, ranges[i])
    end
    return ret
  else
    return ranges
  end
end

return M