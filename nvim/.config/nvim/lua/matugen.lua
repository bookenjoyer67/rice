 local M = {}

-- Applied on every wallpaper / palette change (noctalia regenerates this file
-- and pings nvim with SIGUSR1), so anything that must keep being true belongs
-- inside M.setup() -- not in a one-shot startup hook.
function M.setup()
  require('base16-colorscheme').setup({
    base00 = '#291414',
    base01 = '#452122',
    base02 = '#3e1e1f',
    base03 = '#716261',
    base04 = '#b6afaf',
    base05 = '#f3f2f2',
    base06 = '#f3f2f2',
    base07 = '#f3f2f2',
    base08 = '#f73136',
    base09 = '#f7f33b',
    base0A = '#f7943b',
    base0B = '#f85357',
    base0C = '#faf884',
    base0D = '#fa8487',
    base0E = '#fabc84',
    base0F = '#fcd7b6',
  })

  local hi = function(group, opts)
    vim.api.nvim_set_hl(0, group, opts)
  end

  -- Strip the background off an already-defined group. base16-nvim paints
  -- Normal and friends with a solid surface colour; a Lua colorscheme does not
  -- fire the ColorScheme autocmd, so transparent plugins never re-clear them.
  -- Doing it here means it also survives every palette re-apply.
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

  -- Legible comments: base16 maps Comment to base03 (outline), which is dim.
  hi('Comment', { fg = '#b6afaf', italic = true })
  for _, group in ipairs({ '@comment', '@comment.documentation' }) do
    hi(group, { fg = '#b6afaf', italic = true })
  end

  -- Selection still needs some tint, or it is invisible on a transparent bg.
  hi('PmenuSel', { fg = '#f3f2f2', bg = '#3e1e1f' })
  hi('PmenuThumb', { bg = '#3e1e1f' })
  hi('Visual', { bg = '#3e1e1f' })

  -- telescope.nvim (titles keep a filled background on purpose -- they are chips)
  hi('TelescopeNormal',         { fg = '#f3f2f2' })
  hi('TelescopeBorder',         { fg = '#716261' })
  hi('TelescopePromptNormal',   { fg = '#f3f2f2' })
  hi('TelescopePromptBorder',   { fg = '#716261' })
  hi('TelescopePromptPrefix',   { fg = '#f85357' })
  hi('TelescopePromptCounter',  { fg = '#b6afaf' })
  hi('TelescopePromptTitle',    { fg = '#291414',             bg = '#f85357' })
  hi('TelescopePreviewTitle',   { fg = '#291414',             bg = '#f7943b' })
  hi('TelescopeResultsTitle',   { fg = '#291414',             bg = '#f7f33b' })
  hi('TelescopeSelection',      { fg = '#f3f2f2',          bg = '#3e1e1f' })
  hi('TelescopeSelectionCaret', { fg = '#f85357',             bg = '#3e1e1f' })
  hi('TelescopeMatching',       { fg = '#f85357',             bold = true })

  -- mini.pick
  hi('MiniPickNormal',         { fg = '#f3f2f2' })
  hi('MiniPickBorder',         { fg = '#716261' })
  hi('MiniPickPrompt',         { fg = '#f3f2f2' })
  hi('MiniPickPromptPrefix',   { fg = '#f85357' })
  hi('MiniPickBorderText',     { fg = '#291414',             bg = '#f85357' })
  hi('MiniPickMatchCurrent',   { fg = '#f3f2f2',          bg = '#3e1e1f' })
  hi('MiniPickPromptCaret',    { fg = '#f85357',             bg = '#3e1e1f' })
  hi('MiniPickMatchRanges',    { fg = '#f85357',             bold = true })

  -- Anything the previous colorscheme left behind (nvim-cmp / blink.cmp menus
  -- are not defined by base16-nvim, so their old opaque fills survive).
  for name, hl in pairs(vim.api.nvim_get_hl(0, { link = true })) do
    if not hl.link and (name:match('^Cmp') or name:match('^BlinkCmp')) then
      hl.bg = (name:match('Selection$') or name:match('Thumb$'))
          and '#3e1e1f' or nil
      hl.ctermbg = nil
      hi(name, hl)
    end
  end

  -- Keep transparent.nvim (and any theme that honours this flag) in agreement.
  vim.g.transparent_enabled = true
end

-- Register a signal handler for SIGUSR1 (matugen updates).
-- The handler re-requires this module, which re-runs the code below, so the
-- previous handle is stopped first; otherwise handlers double on every signal.
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
