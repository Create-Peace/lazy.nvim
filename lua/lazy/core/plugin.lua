local Config = require("lazy.core.config")
local Util = require("lazy.core.util")
local Module = require("lazy.core.module")
local Cache = require("lazy.core.cache")

local M = {}

---@alias CachedPlugin LazyPlugin | {_funs: string[]}
local skip = { installed = true, loaded = true, tasks = true, dirty = true, dir = true }
local funs = { config = true, init = true, run = true }

M.dirty = false

---@class LazyPlugin
---@field [1] string
---@field name string display name and name used for plugin config files
---@field uri string
---@field branch? string
---@field dir string
---@field enabled? boolean|(fun():boolean)
---@field opt? boolean
---@field init? fun(LazyPlugin) Will always be run
---@field config? fun(LazyPlugin) Will be executed when loading the plugin
---@field event? string|string[]
---@field cmd? string|string[]
---@field ft? string|string[]
---@field module? string|string[]
---@field keys? string|string[]
---@field requires? string[]
---@field loaded? {[string]:string, time:number}
---@field installed? boolean
---@field run? string|fun()
---@field tasks? LazyTask[]
---@field dirty? boolean
---@field updated? {from:string, to:string}

---@class LazySpec
---@field modname string
---@field modpath string
---@field plugins table<string, LazyPlugin>
---@field funs? table<string, string[]>
local Spec = {}

---@param modname string
---@param modpath string
function Spec.load(modname, modpath)
  local self = setmetatable({}, { __index = Spec })
  self.plugins = {}
  self.modname = modname
  self.modpath = modpath
  local mod, cached = Module.load(modname, modpath)
  M.dirty = M.dirty or not cached
  self:normalize(assert(mod))
  if modname == Config.options.plugins and not self.plugins["lazy.nvim"] then
    self:add({ "folke/lazy.nvim", opt = false })
  end
  return self
end

---@param plugin LazyPlugin
function Spec:add(plugin)
  if type(plugin[1]) ~= "string" then
    Util.error("Invalid plugin spec " .. vim.inspect(plugin))
  end
  plugin.uri = plugin.uri or ("https://github.com/" .. plugin[1] .. ".git")

  -- PERF: optimized code to get package name without using lua patterns
  if not plugin.name then
    local name = plugin[1]:sub(-4) == ".git" and plugin[1]:sub(1, -5) or plugin[1]
    local slash = name:reverse():find("/", 1, true) --[[@as number?]]
    plugin.name = slash and name:sub(#name - slash + 2) or plugin[1]:gsub("%W+", "_")
  end

  M.process_local(plugin)
  local other = self.plugins[plugin.name]
  self.plugins[plugin.name] = other and vim.tbl_extend("force", self.plugins[plugin.name], plugin) or plugin
  return self.plugins[plugin.name]
end

---@param spec table
---@param results? string[]
function Spec:normalize(spec, results)
  results = results or {}
  if type(spec) == "string" then
    table.insert(results, self:add({ spec }).name)
  elseif #spec > 1 or Util.is_list(spec) then
    ---@cast spec table[]
    for _, s in ipairs(spec) do
      self:normalize(s, results)
    end
  elseif spec.enabled == nil or spec.enabled == true or (type(spec.enabled) == "function" and spec.enabled()) then
    local plugin = self:add(spec)
    plugin.requires = plugin.requires and self:normalize(plugin.requires, {}) or nil
    table.insert(results, plugin.name)
  end
  return results
end

---@param spec LazySpec
function Spec.revive(spec)
  if spec.funs then
    ---@type LazySpec
    local loaded = nil
    for fun, plugins in pairs(spec.funs) do
      for _, name in pairs(plugins) do
        ---@diagnostic disable-next-line: no-unknown
        spec.plugins[name][fun] = function(...)
          loaded = loaded or Spec.load(spec.modname, spec.modpath)
          return loaded.plugins[name][fun](...)
        end
      end
    end
  end
  return spec
end

function M.update_state(check_clean)
  ---@type table<"opt"|"start", table<string,boolean>>
  local installed = { opt = {}, start = {} }
  for opt, packs in pairs(installed) do
    Util.ls(Config.options.package_path .. "/" .. opt, function(_, name, type)
      if type == "directory" or type == "link" then
        packs[name] = true
      end
    end)
  end

  for _, plugin in pairs(Config.plugins) do
    plugin[1] = plugin["1"] or plugin[1]
    plugin.opt = plugin.opt == nil and Config.options.opt or plugin.opt
    local opt = plugin.opt and "opt" or "start"
    plugin.dir = Config.options.package_path .. "/" .. opt .. "/" .. plugin.name
    plugin.installed = installed[opt][plugin.name] == true
    installed[opt][plugin.name] = nil
  end

  if check_clean then
    Config.to_clean = {}
    for opt, packs in pairs(installed) do
      for pack in pairs(packs) do
        table.insert(Config.to_clean, {
          name = pack,
          pack = pack,
          dir = Config.options.package_path .. "/" .. opt .. "/" .. pack,
          opt = opt == "opt",
          installed = true,
        })
      end
    end
  end
end

---@param plugin LazyPlugin
function M.process_local(plugin)
  for _, pattern in ipairs(Config.options.plugins_local.patterns) do
    if plugin[1]:find(pattern, 1, true) then
      plugin.uri = Config.options.plugins_local.path .. "/" .. plugin.name
      return
    end
  end
end

---@param cache? table<string,LazySpec>
function M.specs(cache)
  ---@type LazySpec[]
  local specs = {}

  local function _load(name, modpath)
    local modname = Config.options.plugins .. (name and ("." .. name) or "")
    Util.try(function()
      local spec = cache and cache[modname]
      spec = spec and not Module.is_dirty(modname, modpath) and Spec.revive(spec) or Spec.load(modname, modpath)
      table.insert(specs, spec)
    end, "Failed to load **" .. modname .. "**")
  end

  _load(nil, Config.paths.main)
  Util.lsmod(Config.paths.plugins, _load)
  return specs
end

function M.load()
  ---@type boolean, LazyState?
  local ok, state = pcall(vim.json.decode, Cache.get("cache.state"))
  if not (ok and state and vim.deep_equal(Config.options, state.config)) then
    M.dirty = true
    state = nil
  end

  -- load specs
  Util.track("specs")
  local specs = M.specs(state and state.specs)
  Util.track()

  -- merge
  Config.plugins = {}
  for _, spec in ipairs(specs) do
    for _, plugin in pairs(spec.plugins) do
      local other = Config.plugins[plugin.name]
      Config.plugins[plugin.name] = other and vim.tbl_extend("force", other, plugin) or plugin
    end
  end

  Util.track("state")
  M.update_state()
  Util.track()

  if M.dirty then
    Cache.dirty = true
  elseif state then
    require("lazy.core.handler")._groups = state.handlers
  end
end

function M.save()
  ---@class LazyState
  local state = {
    ---@type table<string, LazySpec>
    specs = {},
    handlers = require("lazy.core.handler").group(Config.plugins, true),
    config = Config.options,
  }

  for _, spec in ipairs(M.specs()) do
    spec.funs = {}
    state.specs[spec.modname] = spec
    for _, plugin in pairs(spec.plugins) do
      if plugin.init or (plugin.opt == false and plugin.config) then
        -- no use in caching specs that need init,
        -- or specs that are in start and have a config,
        -- since we'll load the real spec during startup anyway
        state.specs[spec.modname] = nil
        break
      end
      ---@cast plugin CachedPlugin
      for k, v in pairs(plugin) do
        if type(v) == "function" then
          if funs[k] then
            spec.funs[k] = spec.funs[k] or {}
            table.insert(spec.funs[k], plugin.name)
          end
          plugin[k] = nil
        elseif skip[k] then
          plugin[k] = nil
        end
      end
    end
  end
  Cache.set("cache.state", vim.json.encode(state))
end

return M