return {
  {
    "nvim-treesitter/nvim-treesitter",
    build = ":TSUpdate",
    lazy = true,
    config = function()
      require("nvim-treesitter").setup({})

      local ensure_installed = {
        "bash", "ruby", "html", "css", "scss",
        "javascript", "typescript", "json", "lua",
        "markdown", "markdown_inline", "vimdoc", "query",
      }
      local installed = require("nvim-treesitter.config").get_installed()
      local to_install = {}
      for _, lang in ipairs(ensure_installed) do
        if not vim.list_contains(installed, lang) then
          to_install[#to_install + 1] = lang
        end
      end
      if #to_install > 0 then
        require("nvim-treesitter").install(to_install)
      end

      vim.api.nvim_create_autocmd("FileType", {
        callback = function(args)
          pcall(vim.treesitter.start, args.buf, args.match)
        end,
      })
    end,
  },
}
