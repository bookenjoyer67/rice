 local M = {}

function M.setup()
  require('base16-colorscheme').setup({
    base00 = '#271618',
    base01 = '#412528',
    base02 = '#3b2124',
    base03 = '#726263',
    base04 = '#b6afaf',
    base05 = '#f3f2f2',
    base06 = '#f3f2f2',
    base07 = '#f3f2f2',
    base08 = '#fd4663',
    base09 = '#cc66aa',
    base0A = '#d68b5c',
    base0B = '#e46774',
    base0C = '#e996cd',
    base0D = '#ec939c',
    base0E = '#e9b696',
    base0F = '#f4d3be',
  })

  local hi = function(group, opts)
    vim.api.nvim_set_hl(0, group, opts)
  end

  local clear_bg = function(group)
    local ok, hl = pcall(vim.api.nvim_get_hl, 0, { name = group, link = true })
    if not ok or type(hl) ~= 'table' or hl.link or next(hl) == nil then
      return
    end
    hl.bg = nil
    hl.ctermbg = nil
    hi(group, hl)
  end

  for _, group in ipairs({
    'Normal', 'NormalNC', 'NormalFloat', 'NormalSB',
    'FloatBorder', 'FloatTitle', 'FloatFooter', 'FloatShadow', 'FloatShadowThrough',
    'Pmenu', 'PmenuSbar', 'PmenuKind', 'PmenuExtra', 'PopupMenu', 'PopupMenuBorder',
    'EndOfBuffer', 'SignColumn', 'SignColumnSB', 'LineNr', 'CursorLine', 'CursorLineNr',
    'StatusLine', 'StatusLineNC', 'TabLine', 'TabLineFill',
    'WinSeparator', 'VertSplit', 'Folded', 'FoldColumn', 'ColorColumn',
  }) do
    clear_bg(group)
  end

  hi('Comment', { fg = '#b6afaf', italic = true })
  for _, group in ipairs({ '@comment', '@comment.documentation' }) do
    hi(group, { fg = '#b6afaf', italic = true })
  end

  hi('PmenuSel', { fg = '#f3f2f2', bg = '#3b2124' })
  hi('PmenuThumb', { bg = '#3b2124' })
  hi('Visual', { bg = '#3b2124' })

  hi('TelescopeNormal',         { fg = '#f3f2f2' })
  hi('TelescopeBorder',         { fg = '#726263' })
  hi('TelescopePromptNormal',   { fg = '#f3f2f2' })
  hi('TelescopePromptBorder',   { fg = '#726263' })
  hi('TelescopePromptPrefix',   { fg = '#e46774' })
  hi('TelescopePromptCounter',  { fg = '#b6afaf' })
  hi('TelescopePromptTitle',    { fg = '#271618',             bg = '#e46774' })
  hi('TelescopePreviewTitle',   { fg = '#271618',             bg = '#d68b5c' })
  hi('TelescopeResultsTitle',   { fg = '#271618',             bg = '#cc66aa' })
  hi('TelescopeSelection',      { fg = '#f3f2f2',          bg = '#3b2124' })
  hi('TelescopeSelectionCaret', { fg = '#e46774',             bg = '#3b2124' })
  hi('TelescopeMatching',       { fg = '#e46774',             bold = true })

  hi('MiniPickNormal',         { fg = '#f3f2f2' })
  hi('MiniPickBorder',         { fg = '#726263' })
  hi('MiniPickPrompt',         { fg = '#f3f2f2' })
  hi('MiniPickPromptPrefix',   { fg = '#e46774' })
  hi('MiniPickBorderText',     { fg = '#271618',             bg = '#e46774' })
  hi('MiniPickMatchCurrent',   { fg = '#f3f2f2',          bg = '#3b2124' })
  hi('MiniPickPromptCaret',    { fg = '#e46774',             bg = '#3b2124' })
  hi('MiniPickMatchRanges',    { fg = '#e46774',             bold = true })

  for name, hl in pairs(vim.api.nvim_get_hl(0, { link = true })) do
    if not hl.link and (name:match('^Cmp') or name:match('^BlinkCmp')) then
      hl.bg = (name:match('Selection$') or name:match('Thumb$'))
          and '#3b2124' or nil
      hl.ctermbg = nil
      hi(name, hl)
    end
  end

  vim.g.transparent_enabled = true
end

if _G.__matugen_signal then
  _G.__matugen_signal:stop()
  _G.__matugen_signal:close()
end

local signal = vim.uv.new_signal()
_G.__matugen_signal = signal
signal:start(
  'sigusr1',
  vim.schedule_wrap(function()
    package.loaded['matugen'] = nil
    require('matugen').setup()
  end)
)

return M
