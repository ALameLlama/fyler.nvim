local helper = require('tests.helper')
local n = helper.new_child_neovim()
local T = helper.new_set({ hooks = { pre_case = n.setup, post_once = n.stop } })

local eq = helper.expect.equality

local function make_tree(root_path)
  n.lua(
    [[
      local root_path = ...
      require('fyler').setup({})

      local state = require('fyler.state')
      state.store = {}
      state.store_next_id = 1
      state.store_path_id = {}

      local instance = state.new(root_path, 'file')
      local function node(name, path, type, link)
        return {
          value = state.store_register_fs_entry({
            name = name,
            path = path,
            type = type,
            link = link,
          }),
        }
      end

      instance.root.children = {
        fyler = node('fyler', root_path .. '/fyler', 'directory'),
        unrelated = node('unrelated', root_path .. '/unrelated', 'directory'),
        vendor = node('vendor', root_path .. '/vendor', 'directory', '/outside/vendor'),
      }
      instance.root.children.fyler.children = {
        extensions = node('extensions', root_path .. '/fyler/extensions', 'directory'),
      }
      instance.root.children.fyler.children.extensions.children = {
        trash = node('trash.lua', root_path .. '/fyler/extensions/trash.lua', 'file'),
      }
      instance.root.children.vendor.children = {
        target = node('target.lua', root_path .. '/vendor/target.lua', 'file'),
      }

      _G.state_under_test = instance
    ]],
    { root_path }
  )
end

local function search_names(query)
  n.lua(
    [[
      local lines = _G.state_under_test:to_search_lines(...)
      _G.search_names = vim.iter(lines):map(function(item) return item.name end):totable()
    ]],
    { query }
  )
  return n.lua_get('_G.search_names')
end

T['search matches names without including descendants matched only by ancestor path'] = function()
  make_tree(helper.abspath('tmp', 'state-search'))

  eq(search_names('fyler'), { 'fyler' })
end

T['search can match paths when query contains slash'] = function()
  make_tree(helper.abspath('tmp', 'state-search'))

  eq(search_names('fyler/trash'), { 'fyler', 'extensions', 'trash.lua' })
end

T['search does not traverse symlinked directories'] = function()
  make_tree(helper.abspath('tmp', 'state-search'))

  eq(search_names('target'), {})
end

return T
