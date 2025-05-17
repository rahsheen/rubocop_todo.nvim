local M = {}

local find_file = function(current_file, data)
  -- Check if current file is listed in rubocop_todo.yml (simplified)
  local file_found = false
  for _, v in ipairs(data) do
    if v:match "%s*-%s*'" then
      local filepath = v:match "'(.+)'"
      if current_file:match(filepath) then
        file_found = true
        break
      end
    end
  end

  return file_found
end

M.setup = function(buf)
  -- Check if rubocop_todo.yml exists
  local stat = vim.loop.fs_stat '.rubocop_todo.yml'
  if not stat then
    return
  end

  -- Load rubocop_todo.yml content
  local data = vim.fn.readfile '.rubocop_todo.yml'
  if #data == 0 then
    return
  end

  -- Find the current filename
  local current_file = vim.api.nvim_buf_get_name(buf)
  local file_found = find_file(current_file, data)

  if file_found then
    vim.notify('Rubocop todo found for ' .. current_file, vim.log.levels.WARN)
  end
end

-- Autocommand to trigger the extension on BufEnter
vim.api.nvim_create_autocmd({ 'BufEnter' }, {
  group = vim.api.nvim_create_augroup('RubocopTodo', {}),
  pattern = '*.rb',
  callback = function(event)
    M.setup(event.buf)
  end,
})

return M
