--- rubocop_todo.nvim
---
--- Flags buffers that `.rubocop_todo.yml` excludes from one or more cops, so you know a
--- file carries lint debt before you start editing it.
---
--- Surfacing is passive: a buffer-local `b:rubocop_todo` plus a statusline section.
--- `:RubocopTodo` escalates on demand — it re-runs rubocop against a todo-free copy of
--- the project config, scoped to just those cops, and publishes the real offenses as
--- diagnostics.

local M = {}

M.config = {
  todo_file = '.rubocop_todo.yml',
  config_file = '.rubocop.yml',
  cmd = { 'rubocop', '--no-server' },
  -- The old BufEnter notification, off by default. The statusline is the point.
  notify = false,
  icon = vim.g.have_nerd_font and '' or 'rubocop',
}

local ns = vim.api.nvim_create_namespace 'rubocop_todo'

-- root -> { mtime, exact = { [relpath] = { cop, ... } }, globs = { { pattern, cop }, ... } }
local cache = {}

---------------------------------------------------------------------------
-- Parsing
---------------------------------------------------------------------------

-- Coyote's todo file is generated with --auto-gen-only-exclude, so every entry is a
-- literal path and the exact table carries all of them. Globs are handled anyway
-- because a hand-edited todo can contain them; the list is normally empty.
local function glob_to_pattern(glob)
  local p = glob:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0')
  p = p:gsub('%*%*/?', '\1')
  p = p:gsub('%*', '[^/]*')
  p = p:gsub('\1', '.-')
  return '^' .. p .. '$'
end

-- Line-oriented rather than a real YAML parse: the file is machine-generated and
-- 6k+ lines, and this only ever needs `<Cop>: Exclude: [paths]`.
local function parse(todo_path)
  local exact, globs = {}, {}
  local cop, in_exclude = nil, false

  for line in io.lines(todo_path) do
    if line:match '^%s*$' or line:match '^%s*#' then -- luacheck: ignore
      -- blank or comment
    elseif line:match '^%S' then
      cop = line:match '^([^:%s]+):'
      in_exclude = false
    elseif cop then
      local key = line:match '^%s+([%w_]+):'
      if key then
        in_exclude = key == 'Exclude'
      elseif in_exclude then
        local path = line:match "^%s*%-%s*'(.*)'%s*$"
          or line:match '^%s*%-%s*"(.*)"%s*$'
          or line:match '^%s*%-%s*(%S+)%s*$'
        if path then
          if path:find '%*' then
            globs[#globs + 1] = { glob_to_pattern(path), cop }
          else
            local t = exact[path]
            if t then
              t[#t + 1] = cop
            else
              exact[path] = { cop }
            end
          end
        end
      end
    end
  end

  return exact, globs
end

local function todo_data(root, todo_path)
  local stat = vim.uv.fs_stat(todo_path)
  if not stat then
    cache[root] = nil
    return nil
  end

  local entry = cache[root]
  if not entry or entry.mtime ~= stat.mtime.sec then
    local exact, globs = parse(todo_path)
    entry = { mtime = stat.mtime.sec, exact = exact, globs = globs }
    cache[root] = entry
  end

  return entry
end

---------------------------------------------------------------------------
-- Buffer resolution
---------------------------------------------------------------------------

-- Returns an absolute path only for buffers backed by a real file. The URI guard is
-- what keeps fugitive out: `fugitive:///…/.git//0/app/foo.rb` ends in .rb and sails
-- through any filename-pattern check.
local function buf_file(buf)
  if not vim.api.nvim_buf_is_valid(buf) then
    return nil
  end
  if vim.bo[buf].buftype ~= '' then
    return nil
  end

  local name = vim.api.nvim_buf_get_name(buf)
  if name == '' or name:match '^%w[%w%+%-%.]*://' then
    return nil
  end

  local path = vim.fs.normalize(vim.fn.fnamemodify(name, ':p'))
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    return nil
  end

  return path
end

-- Search upward from the buffer, not from nvim's cwd: the old version read a relative
-- '.rubocop_todo.yml' and silently did nothing whenever cwd was outside the project.
local function locate(path)
  local found = vim.fs.find(M.config.todo_file, {
    upward = true,
    path = vim.fs.dirname(path),
    type = 'file',
  })[1]

  if not found then
    return nil
  end

  found = vim.fs.normalize(found)
  return vim.fs.dirname(found), found
end

---------------------------------------------------------------------------
-- Detection (B)
---------------------------------------------------------------------------

--- Recompute `b:rubocop_todo` for a buffer.
function M.check(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  vim.b[buf].rubocop_todo = nil

  local path = buf_file(buf)
  if not path then
    return
  end

  local root, todo_path = locate(path)
  if not root then
    return
  end

  local data = todo_data(root, todo_path)
  if not data then
    return
  end

  local rel = path:sub(#root + 2)

  -- Fresh list every time; the exact table is cached and must not be appended to.
  local cops = {}
  vim.list_extend(cops, data.exact[rel] or {})
  for _, glob in ipairs(data.globs) do
    if rel:match(glob[1]) then
      cops[#cops + 1] = glob[2]
    end
  end

  if #cops == 0 then
    return
  end

  table.sort(cops)
  vim.b[buf].rubocop_todo = { root = root, rel = rel, count = #cops, cops = cops }

  if M.config.notify then
    vim.notify(string.format('%s: %d rubocop todo cop(s)', rel, #cops), vim.log.levels.INFO)
  end
end

--- Statusline section. Empty string when the buffer is clean, so
--- `MiniStatusline.combine_groups` drops it.
function M.statusline()
  local todo = vim.b.rubocop_todo
  if not todo or todo.count == 0 then
    return ''
  end
  return string.format('%s %d', M.config.icon, todo.count)
end

---------------------------------------------------------------------------
-- Inspection (C)
---------------------------------------------------------------------------

-- A todo file is just an exclusion list pulled in via `inherit_from`. Drop that one
-- line and rubocop reports the offenses it was suppressing. The copy has to live in
-- the project root so the config's own relative `require:` paths still resolve.
local function todo_free_config(root)
  local src = root .. '/' .. M.config.config_file
  if not vim.uv.fs_stat(src) then
    return nil, src .. ' not found'
  end

  local kept = {}
  for _, line in ipairs(vim.fn.readfile(src)) do
    local is_todo_entry = line:match '^%s*%-' and line:find(M.config.todo_file, 1, true)
    if not is_todo_entry then
      kept[#kept + 1] = line
    end
  end

  local dest = root .. '/.rubocop_nvim_check.yml'
  vim.fn.writefile(kept, dest)
  return dest
end

local severity = {
  fatal = vim.diagnostic.severity.ERROR,
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
  convention = vim.diagnostic.severity.INFO,
  refactor = vim.diagnostic.severity.HINT,
}

local function to_diagnostics(decoded)
  local diags = {}
  for _, file in ipairs(decoded.files or {}) do
    for _, off in ipairs(file.offenses or {}) do
      local loc = off.location or {}
      local line = loc.start_line or loc.line or 1
      local col = loc.start_column or loc.column or 1
      diags[#diags + 1] = {
        lnum = math.max(line - 1, 0),
        col = math.max(col - 1, 0),
        end_lnum = math.max((loc.last_line or line) - 1, 0),
        end_col = math.max(loc.last_column or col, 0),
        severity = severity[off.severity] or vim.diagnostic.severity.INFO,
        source = 'rubocop-todo',
        code = off.cop_name,
        message = off.message,
      }
    end
  end
  return diags
end

--- Run rubocop against the todo-free config, scoped to this file's todo cops, and
--- publish the results as diagnostics.
function M.inspect(buf)
  buf = buf or vim.api.nvim_get_current_buf()

  local path = buf_file(buf)
  if not path then
    return vim.notify('rubocop_todo: not a file-backed buffer', vim.log.levels.WARN)
  end

  local todo = vim.b[buf].rubocop_todo
  if not todo then
    return vim.notify('rubocop_todo: no todo entries for this file', vim.log.levels.INFO)
  end

  local only = {}
  for _, cop in ipairs(todo.cops) do
    if cop ~= 'AllCops' then
      only[#only + 1] = cop
    end
  end

  local cfg, err = todo_free_config(todo.root)
  if not cfg then
    return vim.notify('rubocop_todo: ' .. err, vim.log.levels.ERROR)
  end

  local cmd = vim.list_extend(vim.deepcopy(M.config.cmd), { '--format', 'json', '--config', cfg })
  if #only > 0 then
    vim.list_extend(cmd, { '--only', table.concat(only, ',') })
  end
  vim.list_extend(cmd, { '--', path })

  vim.notify('rubocop_todo: checking ' .. table.concat(only, ', '), vim.log.levels.INFO)

  vim.system(cmd, { cwd = todo.root, text = true }, function(res)
    -- vim.system completes in a fast event context; nothing below is allowed there.
    vim.schedule(function()
      pcall(vim.fn.delete, cfg)

      -- rubocop exits 1 when it finds offenses, which is the expected case here.
      if res.code and res.code > 1 then
        local detail = (res.stderr or ''):gsub('%s+$', '')
        return vim.notify('rubocop_todo: rubocop failed\n' .. detail, vim.log.levels.ERROR)
      end

      local ok, decoded = pcall(vim.json.decode, res.stdout or '')
      if not ok or type(decoded) ~= 'table' then
        return vim.notify('rubocop_todo: could not parse rubocop output', vim.log.levels.ERROR)
      end

      local diags = to_diagnostics(decoded)
      vim.diagnostic.set(ns, buf, diags)
      vim.notify(
        string.format('rubocop_todo: %d offense(s) across %d todo cop(s)', #diags, #only),
        #diags > 0 and vim.log.levels.WARN or vim.log.levels.INFO
      )
    end)
  end)
end

--- Clear the diagnostics published by `M.inspect`.
function M.clear(buf)
  vim.diagnostic.reset(ns, buf or vim.api.nvim_get_current_buf())
end

---------------------------------------------------------------------------
-- Wiring
---------------------------------------------------------------------------

--- @param opts table|nil overrides merged into `M.config`
function M.setup(opts)
  M.config = vim.tbl_deep_extend('force', M.config, opts or {})
  return M
end

local group = vim.api.nvim_create_augroup('RubocopTodo', { clear = true })

-- BufReadPost, not BufEnter: BufEnter fires on every window switch and split, which is
-- why the same file announced itself two and three times. This runs once per load.
--
-- No filename pattern either. The todo lists .jbuilder files too, and the lookup is a
-- hash hit against a cached parse, so gating by extension buys nothing and was the
-- other half of the fugitive bug.
vim.api.nvim_create_autocmd('BufReadPost', {
  group = group,
  callback = function(ev)
    M.check(ev.buf)
  end,
})

vim.api.nvim_create_user_command('RubocopTodo', function(cmd)
  if cmd.bang then
    M.clear()
  else
    M.inspect()
  end
end, {
  bang = true,
  desc = 'Report the rubocop offenses .rubocop_todo.yml suppresses for this file (! to clear)',
})

return M
