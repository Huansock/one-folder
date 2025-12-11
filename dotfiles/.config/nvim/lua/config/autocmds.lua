-- Autocmds are automatically loaded on the VeryLazy event
-- Default autocmds that are always set: https://github.com/LazyVim/LazyVim/blob/main/lua/lazyvim/config/autocmds.lua
--
-- Add any additional autocmds here
-- with `vim.api.nvim_create_autocmd`
--
-- Or remove existing autocmds by their group name (which is prefixed with `lazyvim_` for the defaults)
-- e.g. vim.api.nvim_del_augroup_by_name("lazyvim_wrap_spell")

-- Markdown 파일 저장(BufWritePre) 직전에 실행
vim.api.nvim_create_autocmd("BufWritePre", {
  pattern = "*.md",
  callback = function()
    local save_cursor = vim.fn.getpos(".")
    -- 파일의 상단 10줄만 검사
    local n = math.min(10, vim.api.nvim_buf_line_count(0))
    local lines = vim.api.nvim_buf_get_lines(0, 0, n, false)

    -- [수정 1] 헤더 변수 분리 (찾는 말과 바꾸는 말을 일치시키기 위해)
    local header = "Last Modified: "

    -- [수정 2] os.date 결과를 명확히 string으로 변환하여 타입 에러 해결
    local date_str = os.date("%Y-%m-%d %H:%M:%S")
    local full_text = header .. tostring(date_str)

    for i, line in ipairs(lines) do
      -- [수정 3] 헤더와 일치하는 줄을 찾음
      if line:match("^" .. header) then
        vim.api.nvim_buf_set_lines(0, i - 1, i, false, { full_text })
        break
      end
    end
    vim.fn.setpos(".", save_cursor)
  end,
})
