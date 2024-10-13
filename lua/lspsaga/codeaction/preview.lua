local api, lsp = vim.api, vim.lsp
local config = require('lspsaga').config
local win = require('lspsaga.window')
local util = require('lspsaga.util')

local function get_action_diff(main_buf, tuple)
  local act = require('lspsaga.codeaction.init')
  local action = tuple[2]
  if not action then
    return
  end

  local id = tuple[1]
  local client = lsp.get_client_by_id(id)
  if not action.edit and client and act:support_resolve(client) then
    action = act:get_resolve_action(client, action, main_buf)
    if not action then
      return
    end
    tuple[2] = action
  end

  if not action.edit then
    return
  end

  local all_changes = {}
  if action.edit.documentChanges then
    for _, item in pairs(action.edit.documentChanges) do
      if item.textDocument then
        if not all_changes[item.textDocument.uri] then
          all_changes[item.textDocument.uri] = {}
        end
        for _, edit in pairs(item.edits) do
          all_changes[item.textDocument.uri][#all_changes[item.textDocument.uri] + 1] = edit
        end
      end
    end
  elseif action.edit.changes then
    all_changes = action.edit.changes
  end

  if not (all_changes and not vim.tbl_isempty(all_changes)) then
    return
  end

  local tmp_buf = api.nvim_create_buf(false, false)
  vim.bo[tmp_buf].bufhidden = 'wipe'
  local lines = api.nvim_buf_get_lines(main_buf, 0, -1, false)
  api.nvim_buf_set_lines(tmp_buf, 0, -1, false, lines)

  local srow = 0
  local erow = 0
  for _, changes in pairs(all_changes) do
    lsp.util.apply_text_edits(changes, tmp_buf, client.offset_encoding)
    vim.tbl_map(function(item)
      srow = srow == 0 and item.range.start.line or srow
      erow = erow == 0 and item.range['end'].line or erow
      srow = math.min(srow, item.range.start.line)
      erow = math.max(erow, item.range['end'].line)
    end, changes)
  end

  local data = api.nvim_buf_get_lines(tmp_buf, 0, -1, false)
  data = vim.tbl_map(function(line)
    return line .. '\n'
  end, data)

  lines = vim.tbl_map(function(line)
    return line .. '\n'
  end, lines)

  api.nvim_buf_delete(tmp_buf, { force = true })
  local diff = vim.diff(table.concat(lines), table.concat(data), {
    algorithm = 'minimal',
    ctxlen = 3,
  })

  if #diff == 0 then
    return
  end

  diff = vim.tbl_filter(function(item)
    return not item:find('@@%s')
  end, vim.split(diff, '\n'))
  return diff
end

local preview_buf, preview_winid

---create a preview window according given window
---default is under the given window
local function create_preview_win(content, main_winid, main_buf)
  -- 初始化记录 '+' 和 '-' 的行号表
  local plus_lines = {}
  local minus_lines = {}

  -- 处理内容，去掉 '+' 和 '-'，并记录缩进信息
  local original_content = {} -- 存储原始的未处理的行
  local processed_content = {}
  local indents = {} -- 记录每行的缩进量（以空格为单位）

  -- 获取 'tabstop' 设置，默认为 4
  local tabstop = vim.api.nvim_buf_get_option(main_buf, 'tabstop') or 4

  -- 定义一个函数，将制表符展开为空格
  local function expand_tabs(s, tabstop)
    local result = ''
    local col = 0
    for i = 1, #s do
      local c = s:sub(i, i)
      if c == '\t' then
        local spaces = tabstop - (col % tabstop)
        result = result .. string.rep(' ', spaces)
        col = col + spaces
      else
        result = result .. c
        col = col + 1
      end
    end
    return result
  end

  -- 第一步：去掉 '+' 和 '-'，并收集原始内容
  for i, line in ipairs(content) do
    local first_char = line:sub(1, 1)
    if first_char == '+' then
      line = line:sub(2)
      table.insert(plus_lines, i)
    elseif first_char == '-' then
      line = line:sub(2)
      table.insert(minus_lines, i)
    end
    original_content[i] = line
  end

  -- 第二步：移除 `original_content` 末尾的空行
  while #original_content > 0 and original_content[#original_content]:match('^%s*$') do
    table.remove(original_content, #original_content)
    -- 需要同时调整 `plus_lines` 和 `minus_lines`
    if plus_lines[#plus_lines] == #original_content + 1 then
      table.remove(plus_lines, #plus_lines)
    end
    if minus_lines[#minus_lines] == #original_content + 1 then
      table.remove(minus_lines, #minus_lines)
    end
  end

  -- 第三步：重新计算 `min_indent`，并处理内容
  local min_indent = nil -- 用于存储最小缩进（以空格为单位）
  for i, line in ipairs(original_content) do
    -- 将制表符展开为空格
    local expanded_line = expand_tabs(line, tabstop)
    processed_content[i] = expanded_line

    -- 计算行首空白字符数量（缩进量，以空格为单位）
    local indent_str = expanded_line:match('^%s*') or ''
    local indent_level = #indent_str

    indents[i] = indent_level

    -- 更新最小缩进，只考虑非空行
    if expanded_line:match('%S') then
      if min_indent == nil or indent_level < min_indent then
        min_indent = indent_level
      end
    end
  end

  -- 如果没有非空行，设置最小缩进为 0
  min_indent = min_indent or 0

  -- 第四步：根据新的 `min_indent` 调整每行的缩进
  for i, line in ipairs(processed_content) do
    local adjusted_line = line:sub(min_indent + 1)
    processed_content[i] = adjusted_line
  end

  -- 以下是原来的函数内容，使用处理后的内容
  local win_conf = vim.api.nvim_win_get_config(main_winid)
  local max_height
  local opt = {
    relative = win_conf.relative,
    win = win_conf.win,
    col = win_conf.col,
    anchor = win_conf.anchor,
    focusable = false,
    zindex = 60,
  }

  local max_width = vim.api.nvim_win_get_width(win_conf.win) - win_conf.col - 8
  local content_width = util.get_max_content_length(processed_content)
  if content_width > max_width then
    opt.width = max_width
  else
    opt.width = content_width < win_conf.width and win_conf.width or content_width
  end

  local winheight = vim.api.nvim_win_get_height(win_conf.win)
  if win_conf.anchor:find('^S') then
    opt.row = win_conf.row - win_conf.height - 2
    max_height = win_conf.row - win_conf.height
  elseif win_conf.anchor:find('^N') then
    opt.row = win_conf.row + win_conf.height + 2
    max_height = winheight - opt.row
  end

  opt.height = math.min(max_height, #processed_content)

  if config.ui.title then
    opt.title = { { 'Action Preview', 'ActionPreviewTitle' } }
    opt.title_pos = 'center'
  end

  preview_buf, preview_winid = win
    :new_float(opt, false, true)
    :setlines(processed_content)
    :bufopt({
      ['filetype'] = vim.bo[main_buf].filetype,
      ['bufhidden'] = 'wipe',
      ['buftype'] = 'nofile',
      ['modifiable'] = false,
    })
    :winhl('ActionPreviewNormal', 'ActionPreviewBorder')
    :wininfo()
  vim.b[preview_buf].gitsigns_preview = true

  local ns_id = vim.api.nvim_create_namespace('ActionPreviewLineHL')

  -- 应用行高亮
  for _, line_num in ipairs(plus_lines) do
    if line_num <= #processed_content then
      vim.api.nvim_buf_set_extmark(preview_buf, ns_id, line_num - 1, 0, {
        line_hl_group = 'GitSignsAddPreview',
      })
    end
  end
  for _, line_num in ipairs(minus_lines) do
    if line_num <= #processed_content then
      vim.api.nvim_buf_set_extmark(preview_buf, ns_id, line_num - 1, 0, {
        line_hl_group = 'GitSignsDeletePreview',
      })
    end
  end
end

local function preview_win_close()
  if preview_winid and api.nvim_win_is_valid(preview_winid) then
    api.nvim_win_close(preview_winid, true)
    preview_winid = nil
    preview_buf = nil
  end
end

local function action_preview(main_winid, main_buf, tuple)
  local diff = get_action_diff(main_buf, tuple)
  if not diff or #diff == 0 then
    if preview_winid and api.nvim_win_is_valid(preview_winid) then
      api.nvim_win_close(preview_winid, true)
      preview_buf = nil
      preview_winid = nil
    end
    return
  end

  if not preview_winid or not api.nvim_win_is_valid(preview_winid) then
    create_preview_win(diff, main_winid, main_buf)
  else
    preview_win_close()
    create_preview_win(diff, main_winid, main_buf)
  end

  return preview_buf, preview_winid
end

return {
  action_preview = action_preview,
  preview_win_close = preview_win_close,
}
