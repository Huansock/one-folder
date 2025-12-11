return {
  {
    "uloco/bluloco.nvim",
    name = "bluloco",
    lazy = false,
    priority = 1000,
    dependencies = { "rktjmp/lush.nvim" },
    config = function()
      -- your optional config goes here, see below.
    end,
  },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "bluloco", -- 여기에 원하는 테마 이름 입력
    },
  },
}
