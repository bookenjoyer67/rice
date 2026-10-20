return {
  "xiyaowong/transparent.nvim",
  lazy = false, -- Must not be lazy-loaded
  config = function()
    require("transparent").setup({
      groups = {
        "Normal", "NormalNC", "Comment", "Constant", "Special", "Identifier",
        "Statement", "PreProc", "Type", "Underlined", "Todo", "String", "Function",
        "Conditional", "Repeat", "Operator", "Structure", "LineNr", "NonText",
        "SignColumn", "CursorLine", "CursorLineNr", "StatusLine", "StatusLineNC",
        "EndOfBuffer",
      },
      extra_groups = {
        "NormalFloat", -- For plugin panels like Lazy, Mason
        "Pmenu",       -- For autocomplete menus
        "NeoTreeNormal", -- If using Neo-tree
        "NeoTreeNormalNC",
      },
    })
  end,
}
