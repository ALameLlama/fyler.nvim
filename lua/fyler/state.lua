local libasync = Fyler.import('fyler.lib.async')
local libfs = Fyler.import('fyler.lib.fs')
local libpath = Fyler.import('fyler.lib.path')

---@class fyler.FinderState
---@field meta table<string, boolean>
---@field pseudo_root_path string
---@field root fyler.FinderStateNode
---@field root_path string
---@field scheme fyler.FinderSchemeHandler

---@class fyler.FinderStateNode
---@field children table<string, fyler.FinderStateNode>|nil
---@field value integer|nil

---@class fyler.FinderSchemeHandler
---@field fs_is_dir fun(path: string): boolean
---@field fs_scan_dir fun(path: string, cb: fun(err: string|nil, entries: table|nil))
---@field fs_mutate fun(actions: fyler.Action[], cb: fun(err: string|nil))

local M = {}

M.store = {}
M.store_next_id = 1
M.store_path_id = {}

function M.store_register_fs_entry(fs_entry)
  local k = libpath.to_key(fs_entry.path)
  local id = M.store_path_id[k]
  if id then return id end

  fs_entry.id = M.store_next_id
  M.store_next_id = M.store_next_id + 1
  M.store[fs_entry.id] = fs_entry
  M.store_path_id[libpath.to_key(fs_entry.path)] = fs_entry.id

  return fs_entry.id
end

function M.new(root_path, scheme)
  ---@class fyler.FinderState
  local instance = {
    meta = { [libpath.to_key(root_path)] = true },
    pseudo_root_path = root_path,
    root = {
      value = M.store_register_fs_entry({
        name = vim.fs.basename(root_path),
        path = root_path,
        type = 'directory',
      }),
    },
    root_path = root_path,
    scheme = Fyler.import(('fyler.schemes.%s'):format(scheme)),
  }

  function instance:change_pseudo_root(new_pseudo_root_path)
    self.pseudo_root_path = new_pseudo_root_path
    self.root = {
      value = M.store_path_id[libpath.to_key(new_pseudo_root_path)] or M.store_register_fs_entry({
        name = vim.fs.basename(new_pseudo_root_path),
        path = new_pseudo_root_path,
        type = 'directory',
      }),
    }

    self:toggle(new_pseudo_root_path, true)
  end

  function instance:toggle(target_path, default)
    local k = libpath.to_key(target_path)
    if type(default) == 'boolean' then
      self.meta[k] = default
    else
      self.meta[k] = not self.meta[k]
    end
  end

  function instance:update(target_path, opts, update_callback)
    opts = opts or {}

    local update_target_node
    update_target_node = libasync.wrap(function(target_node, update_target_node_callback)
      local target_node_data = M.store[target_node.value]
      local target_node_path = target_node_data.link or target_node_data.path
      self.scheme.fs_scan_dir(target_node_path, function(errmsg, entries)
        if errmsg or not entries then
          vim.schedule_wrap(vim.notify)(errmsg, vim.log.levels.INFO, { title = 'Fyler.nvim' })
          update_target_node_callback(target_node)
          return
        end

        target_node.children = {}
        vim.iter(entries):each(function(entry)
          local entry_node_value = M.store_path_id[libpath.to_key(entry.path)]
          if not entry_node_value then entry_node_value = M.store_register_fs_entry(entry) end

          target_node.children[entry.name] = { value = entry_node_value }
        end)

        update_target_node_callback(target_node)
      end)
    end)
    libasync.void(function()
      target_path = target_path or self.pseudo_root_path

      local segments = target_path == self.pseudo_root_path and {}
        or libpath.do_split(libpath.to_rel(self.pseudo_root_path, target_path))
      local target_node = self.root
      if not vim.tbl_isempty(segments) then
        vim.iter(segments):each(function(segment)
          assert(target_node.children[segment], 'Unexpected nil child')
          target_node = target_node.children[segment]
        end)
      end

      local target_node_data = M.store[target_node.value]
      if opts.all and target_node_data and target_node_data.link then
        update_callback(target_node)
        return
      end

      if opts.force or not target_node.children then target_node = update_target_node(target_node) end

      if opts.recursive and target_node.children then
        local stack = { target_node }
        while not vim.tbl_isempty(stack) do
          local current_node = table.remove(stack)
          for child_name, child_node in pairs(current_node.children) do
            local child_data = M.store[child_node.value]
            local child_key = libpath.to_key(child_data.path)
            local child_meta = self.meta[child_key]
            if child_data.type == 'directory' and (child_meta or opts.all) and not (opts.all and child_data.link) then
              if opts.force or not child_node.children then
                child_node = update_target_node(child_node)
                current_node.children[child_name] = child_node
              end

              table.insert(stack, child_node)
            end
          end
        end
      end

      update_callback(target_node)
    end)
  end

  function instance:walk(callback, opts)
    opts = opts or {}

    local target_path = opts.target_path
    if target_path then
      local relative = libpath.to_rel(self.pseudo_root_path, target_path)
      if not relative or relative == '' then return end

      if target_path == self.pseudo_root_path then
        callback(self.root, 0)
        return
      end

      local segments = libpath.do_split(relative)
      local node = self.root
      for _, segment in ipairs(segments) do
        if not node.children or not node.children[segment] then return end
        node = node.children[segment]
      end

      callback(node, #segments)
      return
    end

    local function rec(node, depth)
      if not node.value then return end

      local data = M.store[node.value]
      if not data then return end

      if depth > 0 and opts.skip_hidden and libfs.is_hidden(data.path, opts.hidden_items) then return end
      if opts.included and depth > 0 and not opts.included[libpath.to_key(data.path)] then return end

      callback(node, depth)

      if data.type == 'directory'
        and (self.meta[libpath.to_key(data.path)] or opts.search_all)
        and not (opts.search_all and data.link)
      then
        if node.children then
          local children
          if opts.sort_children then
            children = vim.tbl_values(node.children)
            table.sort(children, function(a, b)
              if not a.value or not b.value then return false end

              return libfs.sort(M.store[a.value], M.store[b.value])
            end)
          else
            children = vim.tbl_values(node.children)
          end

          for _, child in ipairs(children) do
            rec(child, depth + 1)
          end
        end
      end
    end

    rec(self.root, 0)
  end

  ---@param hidden_items table|nil
  function instance:to_lines(hidden_items)
    local result = {}

    self:walk(function(node, depth)
      if depth == 0 then return end

      local entry = M.store[node.value]
      local item = { id = entry.id, path = entry.path, name = entry.name, type = entry.type, depth = depth - 1 }

      if entry.type == 'directory' then item.expanded = self.meta[libpath.to_key(entry.path)] or false end

      table.insert(result, item)
    end, { sort_children = true, skip_hidden = hidden_items ~= nil, hidden_items = hidden_items })

    return result
  end

  function instance:fuzzy_score(query, path)
    query = (query or ''):lower()
    path = (path or ''):lower()
    if query == '' then return nil end

    local positions = {}
    local from = 1
    for i = 1, #query do
      local ch = query:sub(i, i)
      local found = path:find(vim.pesc(ch), from)
      if not found then return nil end
      positions[#positions + 1] = found
      from = found + 1
    end

    local span = positions[#positions] - positions[1] + 1
    local compact = span - #query
    local boundary = 0
    if positions[1] == 1 then
      boundary = boundary - 20
    elseif path:sub(positions[1] - 1, positions[1] - 1):match('[/._%-%s]') then
      boundary = boundary - 10
    end
    if path:find(query, 1, true) then compact = compact - 15 end

    return compact * 1000 + span * 100 + #path + boundary, positions
  end

  function instance:to_search_lines(query, hidden_items)
    local included = {}
    local match_positions = {}
    local best
    local match_path = query:find('/', 1, true) ~= nil

    self:walk(function(node)
      local entry = M.store[node.value]
      local rel = libpath.to_rel(self.pseudo_root_path, entry.path)
      local candidate = match_path and rel or entry.name
      local score, positions = self:fuzzy_score(query, candidate)
      if score then
        local item_positions = {}
        if match_path then
          local name_start = #rel - #entry.name + 1
          for _, position in ipairs(positions) do
            if position >= name_start then item_positions[#item_positions + 1] = position - name_start + 1 end
          end
        else
          item_positions = positions
        end
        match_positions[libpath.to_key(entry.path)] = item_positions

        local path = entry.path
        while path and path ~= self.pseudo_root_path do
          included[libpath.to_key(path)] = true
          path = libpath.to_dirname(path)
        end
        if not best or score < best.score or (score == best.score and rel < best.rel) then
          best = { id = entry.id, score = score, rel = rel }
        end
      end
    end, { sort_children = true, search_all = true, skip_hidden = hidden_items ~= nil, hidden_items = hidden_items })

    local result = {}
    self:walk(function(node, depth)
      if depth == 0 then return end
      local entry = M.store[node.value]
      if not included[libpath.to_key(entry.path)] then return end
      local item = { id = entry.id, path = entry.path, name = entry.name, type = entry.type, depth = depth - 1 }
      if entry.type == 'directory' then item.expanded = true end
      item.match_positions = match_positions[libpath.to_key(entry.path)]
      table.insert(result, item)
    end, { sort_children = true, search_all = true, included = included })

    return result, best and best.id or nil
  end

  return instance
end

return M
