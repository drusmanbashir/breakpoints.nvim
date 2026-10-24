if vim.g.loaded_breakpoints then return end
vim.g.loaded_breakpoints = true
require("breakpoints").setup()
