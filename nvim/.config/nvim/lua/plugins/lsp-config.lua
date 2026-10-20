return {
  {
    "williamboman/mason.nvim",
    lazy = false,
    config = function()
      require("mason").setup()
    end,
  },
  {
    "williamboman/mason-lspconfig.nvim",
    lazy = false,
    opts = {
      auto_install = true,
    },
  },
  {
    "neovim/nvim-lspconfig",
    commit = "ed4dff8",
    lazy = false,
    config = function()
      local cmp_nvim_lsp = require("cmp_nvim_lsp")
      local capabilities = vim.tbl_deep_extend(
        "force",
        {},
        vim.lsp.protocol.make_client_capabilities(),
        cmp_nvim_lsp.default_capabilities()
      )

      local lspconfig = require("lspconfig")

      lspconfig.tailwindcss.setup({
        capabilities = capabilities
      })
      lspconfig.ruby_lsp.setup({
        capabilities = capabilities,
      })
      lspconfig.ts_ls.setup({
        capabilities = capabilities,
      })
      lspconfig.lua_ls.setup({
        capabilities = capabilities
      })

      -- svelte-language-server ships typescript-svelte-plugin inside its own
      -- node_modules, so resolve the install path from mason (falling back to
      -- the default mason location if the registry isn't loaded yet).
      local svelte_ls_path = (function()
        local ok, registry = pcall(require, "mason-registry")
        if ok then
          local pok, pkg = pcall(registry.get_package, "svelte-language-server")
          if pok then
            local iok, path = pcall(pkg.get_install_path, pkg)
            if iok then
              return path
            end
          end
        end
        return vim.fn.stdpath("data") .. "/mason/packages/svelte-language-server"
      end)()

      lspconfig.svelte.setup({
        capabilities = capabilities,
        settings = {
          svelte = {
            server = {
              plugins = {
                {
                  name = "typescript-svelte-plugin",
                  location = svelte_ls_path .. "/node_modules/typescript-svelte-plugin",
                  enableForWorkspaceTypeScriptVersions = true,
                },
              },
            },
          },
        },
        -- Runs per project root, so the plugin path is resolved for the project
        -- actually being opened instead of whatever cwd nvim happened to start in.
        on_new_config = function(new_config, root_dir)
          local root = (root_dir and root_dir ~= "") and root_dir or vim.fn.getcwd()
          local icons = root .. "/node_modules/@sveltejs/material-icons-components"
          if vim.uv.fs_stat(icons) then
            table.insert(new_config.settings.svelte.server.plugins, {
              name = "@sveltejs/material-icons-components",
              location = icons,
            })
          end
        end,
      })

      vim.keymap.set("n", "K", vim.lsp.buf.hover, {})
      vim.keymap.set("n", "<leader>gd", vim.lsp.buf.definition, {})
      vim.keymap.set("n", "<leader>gr", vim.lsp.buf.references, {})
      vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, {})
      vim.keymap.set("n", "<leader>gf", vim.lsp.buf.format, {})
      vim.keymap.set('n', '<space>rn', vim.lsp.buf.rename, {})
    end,
  },
}
