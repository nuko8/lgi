------------------------------------------------------------------------------
--
--  LGI Lua-side core.
--
--  Copyright (c) 2010, 2011 Pavel Holejsovsky
--  Licensed under the MIT license:
--  http://www.opensource.org/licenses/mit-license.php
--
------------------------------------------------------------------------------

local assert, setmetatable, getmetatable, type, pairs, string, rawget,
table, require, tostring, error, pcall, ipairs, unpack,
next, select =
   assert, setmetatable, getmetatable, type, pairs, string, rawget,
   table, require, tostring, error, pcall, ipairs, unpack or table.unpack,
   next, select
local package, math = package, math

-- Require core lgi utilities, used during bootstrap.
local core = require 'lgi._core'

-- Initialize GI wrapper from the core.
local gi = core.gi
assert(gi.require ('GLib', '2.0'))
assert(gi.require ('GObject', '2.0'))

-- Create lgi table, containing the module.
local lgi = {}

-- Add simple flag-checking function, avoid compatibility hassle with
-- importing bitlib just because of this simple operation.
function lgi.has_bit(value, flag)
   return value % (2 * flag) >= flag
end

-- Forward 'yield' functionality into external interface.
lgi.yield = core.yield

-- If global package 'bytes' does not exist (i.e. not provided
-- externally), use our internal (although incomplete) implementation.
local ok, bytes = pcall(require, 'bytes')
if not ok or not bytes then
   package.loaded.bytes = core.bytes
end

-- Prepare logging support.  'log' is module-exported table, containing all
-- functionality related to logging wrapped around GLib g_log facility.
local logtable = { ERROR = 'assert', DEBUG = 'silent' }
lgi.log = logtable
core.set('logger',
	 function(domain, level, message)
	    -- Create domain table in the log table if it does not
	    -- exist yet.
	    if not logtable[domain] then logtable[domain] = {} end

	    -- Check whether message should generate assert (i.e. Lua
	    -- exception).
	    local setting = logtable[domain][level] or logtable[level]
	    if setting == 'assert' then error() end
	    if setting == 'silent' then return true end

	    -- Get handler for the domain and invoke it.
	    local handler = logtable[domain].handler or logtable.handler
	    return handler and handler(domain, level, message)
	 end)

-- Main logging facility.
function logtable.log(domain, level, format, ...)
   local ok, msg = pcall(string.format, format, ...)
   if not ok then msg = ("BAD FMT: `%s', `%s'"):format(format, msg) end
   core.log(domain, level, msg)
end

-- Creates table containing methods 'message', 'warning', 'critical', 'error',
-- 'debug' methods which log to specified domain.
function logtable.domain(name)
   local domain = logtable[name] or {}
   for _, level in ipairs { 'message', 'warning', 'critical',
			    'error', 'debug' } do
      if not domain[level] then
	 domain[level] = function(format, ...)
			    logtable.log(name, level:upper(), format, ...)
			 end
      end
   end
   logtable[name] = domain
   return domain
end

-- For the rest of bootstrap, prepare logging to Lgi domain.
local log = logtable.domain('Lgi')

log.message('Lua to GObject-Introspection binding v0.1')

-- Repository, table with all loaded namespaces.  Its metatable takes care of
-- loading on-demand.  Created by C-side bootstrap.
local repo = core.repo

-- Gets table for category of compound (i.e. _field of struct or _property
-- for class etc).  Installs metatable which performs on-demand lookup of
-- symbols.
local function get_category(children, xform_value,
			    xform_name, xform_name_reverse)
   -- Either none or both transform methods must be provided.
   assert(not xform_name or xform_name_reverse)

   -- Early shortcircuit; no elements, no table needed at all.
   if #children == 0 then return nil end

   -- Index contains array of indices which were still not retrieved
   -- from 'children' table, and table part contains name->index
   -- mapping.
   local index, mt = {}, {}
   for i = 1, #children do index[i] = i end

   -- Fully resolves the category (i.e. loads everything remaining to
   -- be loaded in given category) and disconnects on-demand loading
   -- metatable.
   local function resolve(category)
      -- Load al values from unknown indices.
      local ei, en, val
      local function xvalue(arg)
	 if not xform_value then return arg end
	 if arg then
	    local ok, res = pcall(xform_value, arg)
	    return ok and res
	 end
      end
      while #index > 0 do
	 ei = children[table.remove(index)]
	 val = xvalue(ei)
	 if val then
	    en = ei.name
	    en = not xform_name_reverse and en or xform_name_reverse(en)
	    if en then category[en] = val end
	 end
      end

      -- Load all known indices.
      for en, idx in pairs(index) do
	 val = xvalue(children[idx])
	 en = not xform_name_reverse and en or xform_name_reverse(en)
	 if en then category[en] = val end
      end

      -- Metatable is no longer needed, disconnect it.
      return setmetatable(category, nil)
   end

   function mt:__index(requested_name)
      -- Check if closure for fully resolving the category is needed.
      if requested_name == '_resolve' then return resolve end

      -- Transform name by transform function.
      local name = not xform_name and requested_name
	 or xform_name(requested_name)
      if not name then return end

      -- Check, whether we already know its index.
      local idx, val = index[name]
      if idx then
	 -- We know at least the index, so get info directly.
	 val = children[idx]
	 index[name] = nil
      else
	 -- Not yet, go through unknown indices and try to find the
	 -- name.
	 while #index > 0 do
	    idx = table.remove(index)
	    val = children[idx]
	    local en = val.name
	    if en == name then break end
	    val = nil
	    index[en] = idx
	 end
      end

      -- If there is nothing in the index, we can disconnect
      -- metatable, because everything is already loaded.
      if not next(index) then
	 setmetatable(self, nil)
      end

      -- Transform found value and store it into the category (self)
      -- table.
      if not val then return nil end
      if xform_value then val = xform_value(val) end
      if not val then return nil end
      self[requested_name] = val
      return val
   end
   return setmetatable({}, mt)
end

-- Generic component metatable.  Component is any entity in the repo,
-- e.g. record, object, enum, etc.
local component_mt = {}

-- Creates new component table by cloning all contents and setting
-- categories table.
function component_mt:clone(categories)
   local new_component = {}
   for key, value in pairs(self) do new_component[key] = value end
   if categories then
      categories[#categories + 1] = '_attribute'
      new_component._categories = categories
   end
   return new_component
end

-- __index implementation, uses _element method to perform lookup.
function component_mt:__index(key)
   -- First try to invoke our own _element method.
   local _element, mt = rawget(self, '_element')
   if not _element then
      mt = getmetatable(self)
      _element = rawget(mt, '_element')
   end
   local value = _element(self, nil, key)
   if value then return value end

   -- If not found as object element, examine the metatable itself.
   return rawget(mt or getmetatable(self), key)
end

-- __call implementation, uses _new method to create new instance of
-- component type.
function component_mt:__call(...)
   return self:_new(...)
end

-- Fully resolves the whole typetable, i.e. load all symbols normally
-- loaded on-demand at once.  Returns self, so that resolve can be
-- easily chained for the caller.
function component_mt:_resolve()
   local categories = self._categories or {}
   for i = 1, #categories do
      -- Invoke '_resolve' function for all category tables, if they have it.
      local category = rawget(self, categories[i])
      local resolve = type(category) == 'table' and category._resolve
      if resolve then resolve(category) end
   end
   return self
end

-- Implementation of _access method, which is called by _core when
-- repo instance is accessed for reading or writing.
function component_mt:_access(instance, symbol, ...)
   -- Invoke _element, which converts symbol to element and category.
   local element, category = self:_element(instance, symbol)
   if not element then
      error(("%s: no `%s'"):format(self._name, symbol))
   end

   -- Get category handler to be used, and invoke it.
   local handler = self['_access' .. category]
   if handler then return handler(self, instance, element, ...) end

   -- If specific accessor does not exist, consider the element to be
   -- 'static const' attribute of the class.  This works well for
   -- methods, constants and assorted other elements added manually
   -- into the class by overrides.
   if select('#', ...) > 0 then
      error(("%s: `%s' is not writable"):format(self._name, symbol))
   end
   return element
end

-- Keyword translation dictionary.  Used for translating Lua keywords
-- which might appear as symbols in typelibs into Lua-neutral identifiers.
local keyword_dictionary = {
   _end = 'end', _do = 'do', _then = 'then', _elseif = 'elseif', _in = 'in',
   _local = 'local', _function = 'function', _nil = 'nil', _false = 'false',
   _true = 'true', _and = 'and', _or = 'or', _not = 'not',
}

-- Retrieves (element, category) pair from given componenttable and
-- instance for given symbol.
function component_mt:_element(instance, symbol)
   -- Check keyword translation dictionary.  If the symbol can be
   -- found there, try to lookup translated symbol.
   symbol = keyword_dictionary[symbol] or symbol

   -- Check whether symbol is directly accessible in the component.
   local element = rawget(self, symbol)
   if element then return element end

   -- Decompose symbol name, in case that it contains category prefix
   -- (e.g. '_field_name' when requesting explicitely field called
   -- name).
   local category, name = string.match(symbol, '^(_.-)_(.*)$')
   if category and name then
      -- Check requested category.
      local cat = rawget(self, category)
      element = cat and cat[name]
      if element then return element, category end
   elseif string.sub(symbol, 1, 1) ~= '_' then
      -- Check all available categories.
      local categories = self._categories or {}
      for i = 1, #categories do
	 category = categories[i]
	 local cat = rawget(self, category)
	 element = cat and cat[symbol]
	 if element then return element, category end
      end
   end
end

-- Implementation of attribute accessor.  Attribute is either function
-- to be directly invoked, or table containing set and get functions.
function component_mt:_access_attribute(instance, element, ...)
   -- If element is a table, assume that this table contains 'get' and
   -- 'set' methods.  Dispatch to them, and error out if they are
   -- missing.
   if type(element) == 'table' then
      local mode = select('#', ...) == 0 and 'get' or 'set'
      if not element[mode] then
	 error(("%s: cannot %s `%s'"):format(
		  self._name, mode == 'get' and 'read' or 'write',
		  name))
      end
      element = element[mode]
   end

   -- Invoke attribute access function.
   return element(instance, ...)
end

-- Implementation of record_mt, which is inherited from component_mt
-- and provides customizations for structures and unions.
local record_mt = component_mt:clone { '_method', '_field' }

-- Add accessor for handling fields.
function record_mt:_access_field(instance, element, ...)
   assert(gi.isinfo(element) and element.is_field)
   -- Check the type of the field.
   local ii = element.typeinfo.interface
   if ii and (ii.type == 'struct' or ii.type == 'union') then
      -- Nested structure, handle assignment to it specially.  Get
      -- access to underlying nested structure.
      local subrecord = core.record.field(instance, element)

      -- Reading it is simple, we are done.
      if select('#', ...) == 0 then return subrecord end

      -- Writing means assigning all fields from the source table.
      for name, value in pairs(...) do subrecord[name] = value end
   else
      -- In other cases, just access the instance using given info.
      return core.record.field(instance, element, ...)
   end
end

-- Create structure instance and initialize it with given fields.
function record_mt:_new(fields)
   -- Find baseinfo of requested record.
   local info
   if self._gtype then
      -- Try to lookup info by gtype.
      info = gi[self._gtype]
   end
   if not info then
      -- GType is not available, so lookup info by name.
      local ns, name = self._name:match('^(.-)%.(.+)$')
      info = assert(gi[ns][name])
   end

   -- Create the structure instance.
   local struct = core.record.new(info)

   -- Set values of fields.
   for name, value in pairs(fields or {}) do struct[name] = value end
   return struct
end

-- Implementation of class_mt, inherited from component_mt and
-- providing basic class functionality.  Note that signals and
-- properties are implemented later on GObject descendants only.
local class_mt = component_mt:clone {
   '_virtual', '_method', '_constant', '_field'
}

-- Resolver for classes, recursively resolves also all parents and
-- implemented interfaces.
function class_mt:_resolve(recursive)
   -- Resolve itself using inherited implementation.
   component_mt._resolve(self)

   -- Go to parent and implemented interfaces and resolve them too.
   if recursive then
      for _, iface in pairs(self._implements or {}) do
	 iface:_resolve(recursive)
      end
      if self._parent then
	 self._parent:_resolve(recursive)
      end
   end
   return self
end

-- _element implementation for objects, checks parent and implemented
-- interfaces if element cannot be found in current typetable.
function class_mt:_element(instance, symbol)
   -- Check default implementation.
   local element, category = component_mt._element(self, instance, symbol)
   if element then return element, category end

   -- Check parent and all implemented interfaces.
   local parent = rawget(self, '_parent')
   if parent then
      element, category = parent:_element(instance, symbol)
      if element then return element, category end
   end
   local implements = rawget(self, '_implements') or {}
   for _, implemented in pairs(implements or {}) do
      element, category = implemented:_element(instance, symbol)
      if element then return element, category end
   end
end

-- Implementation of field accessor.  Note that compound fields are
-- not supported in classes (because they are not seen in the wild and
-- I'm lazy).
function class_mt:_access_field(instance, field, ...)
   return core.object.field(instance, field, ...)
end

-- Implementation of virtual method accessor.  Virtuals are
-- implemented by accessing callback pointer in the class struct of
-- the class.  Note that currently we support only reading of them,
-- writing would mean overriding, which is not supported yet.
function class_mt:_access_virtual(instance, vfunc, ...)
   if select('#', ...) > 0 then
      error(("%s: cannot override virtual `%s' "):format(
	       self._name, vfunc.name))
   end
   -- Get typestruct of this class.
   local typestruct = core.object.query(instance, 'class',
					vfunc.container.gtype)

   -- Resolve the field of the typestruct with the virtual name.  This
   -- returns callback to the virtual, which can be directly called.
   return core.record.field(typestruct, self._class[vfunc.name])
end

-- Object constructor, does not accept any arguments.  Overriden later
-- for GObject which accepts properties table to initialize object
-- with.
local object_new = core.callable.new(gi.require('GObject').Object.methods.new)
function class_mt:_new()
   -- Create the object.
   return object_new(self._gtype, {})
end

-- Implementation of interface_mt.
local interface_mt = component_mt:clone {
   '_virtual', '_property', '_signal', '_method', '_constant'
}

-- Creates new component and sets up common parts according to given
-- info.
local function create_component(info, mt)
   -- Fill in meta of the compound.
   local component = { _name = info.fullname }
   if info.gtype then
      -- Bind component in repo, make the relation using GType.
      component._gtype = info.gtype
      repo[info.gtype] = component
   end
   return setmetatable(component, mt)
end

-- Core callback, gets gtype from advanced types like structs and objects.
core.set('getgtype',
	 function(t)
	    assert(type(t) == 'table', 'bad argument, not GType')
	    return t._gtype
	 end)

-- Table containing loaders for various GI types, indexed by
-- gi.InfoType constants.
local typeloader = {}

typeloader['function'] =
   function(namespace, info)
      return core.callable.new(info), '_function'
   end

function typeloader.constant(namespace, info)
   return core.constant(info), '_constant'
end

local function load_enum(info, meta)
   local value = {}

   -- Load all enum values.
   local values = info.values
   for i = 1, #values do
      local mi = values[i]
      value[mi.name:upper()] = mi.value
   end

   -- Install metatable providing reverse lookup (i.e name(s) by
   -- value).
   setmetatable(value, meta)
   return value
end

-- Enum reverse mapping, value->name.
local enum_mt = {}
function enum_mt:__index(value)
   for name, val in pairs(self) do
      if val == value then return name end
   end
end

function typeloader.enum(namespace, info)
   return load_enum(info, enum_mt), '_enum'
end

-- Resolving arbitrary number to the table containing symbolic names
-- of contained bits.
local bitflags_mt = {}
function bitflags_mt:__index(value)
   if type(value) ~= 'number' then return end
   local t = {}
   for name, flag in pairs(self) do
      if type(flag) == 'number' and lgi.has_bit(value, flag) then
	 t[name] = flag
      end
   end
   return t
end

function typeloader.flags(namespace, info)
   return load_enum(info, bitflags_mt), '_enum'
end

local function load_signal_name(name)
   name = name:match('^on_(.+)$')
   return name and name:gsub('_', '%-')
end

local function load_signal_name_reverse(name)
   return 'on_' .. name:gsub('%-', '_')
end

local function load_vfunc_name(name)
   return name:match('^virtual_(.+)$')
end

local function load_vfunc_name_reverse(name)
   return 'virtual_' .. name
end

local function load_method(mi)
   local flags = mi.flags
   if not flags.is_getter and not flags.is_setter then
      return core.callable.new(mi)
   end
end

-- Loads structure information into table representing the structure
local function load_record(info)
   local record = create_component(info, record_mt)
   record._method = get_category(info.methods, core.callable.new)
   record._field = get_category(info.fields)

   -- Check, whether global namespace contains 'constructor' method,
   -- i.e. method which has the same name as our record type (except
   -- that type is in CamelCase, while method is
   -- under_score_delimited).  If not found, check for 'new' method.
   local func = info.name:gsub('([%l%d])([%u])', '%1_%2'):lower()
   local ctor = gi[info.namespace][func]
   if not ctor then ctor = info.methods.new end

   -- Check, whether ctor is valid.  In order to be valid, it must
   -- return instance of this record.
   if (ctor and ctor.return_type.tag =='interface'
       and ctor.return_type.interface == info) then
      ctor = core.callable.new(ctor)
      record._new = function(typetable, ...) return ctor(...) end
   end
   return record
end

function typeloader.struct(namespace, info)
   -- Avoid exposing internal structs created for object implementations.
   if not info.is_gtype_struct then
      return load_record(info), '_struct'
   end
end

function typeloader.union(namespace, info)
   return load_record(info), '_union'
end

local function load_properties(info)
   return get_category(
      info.properties, nil,
      function(name) return string.gsub(name, '_', '%-') end,
      function(name) return string.gsub(name, '%-', '_') end)
end

local function find_constructor(info)
   local name = info.name:gsub('([%d%l])(%u)', '%1_%2'):lower()
   local ctor = gi[info.namespace][name]

   -- Check that return value conforms to info type.
   if ctor then
      local ret = ctor.return_type.interface
      for walk in function(_, c) return c.parent end, nil, info do
	 if ret and walk == ret then
	    ctor = core.callable.new(ctor)
	    return function(self, ...) return ctor(...) end
	 end
      end
   end
end

function typeloader.interface(namespace, info)
   -- Load all components of the interface.
   local interface = create_component(info, interface_mt)
   interface._property = load_properties(info)
   interface._method = get_category(info.methods, load_method)
   interface._signal = get_category(info.signals, nil, load_signal_name,
				     load_signal_name_reverse)
   interface._constant = get_category(info.constants, core.constant)
   local type_struct = info.type_struct
   if type_struct then
      interface._virtual = get_category(info.vfuncs, nil, load_vfunc_name,
					load_vfunc_name_reverse)
      interface._class = load_record(type_struct)
   end
   interface._new = find_constructor(info)
   return interface, '_interface'
end

function typeloader.object(namespace, info)
   -- Find parent record, if available.
   local parent = info.parent
   if parent then
      local ns, name = parent.namespace, parent.name
      if ns ~= namespace._name or name ~= info.name then
	 parent = repo[ns][name]
      end
   end

   -- Create class instance, copy mt from parent, if parent exists,
   -- otherwise defaults to class_mt.
   local class = create_component(info,
				  parent and getmetatable(parent) or class_mt)
   class._parent = parent
   class._property = load_properties(info)
   class._method = get_category(info.methods, load_method)
   class._signal = get_category(info.signals, nil,
				 load_signal_name, load_signal_name_reverse)
   class._constant = get_category(info.constants, core.constant)
   class._field = get_category(info.fields)
   local type_struct = info.type_struct
   if type_struct then
      class._virtual = get_category(info.vfuncs, nil, load_vfunc_name,
				    load_vfunc_name_reverse)
      class._class = load_record(type_struct)
   end

   -- Populate inheritation information (_implements and _parent fields).
   local interfaces, implements = info.interfaces, {}
   for i = 1, #interfaces do
      local iface = interfaces[i]
      implements[iface.fullname] = repo[iface.namespace][iface.name]
   end
   class._implements = implements
   class._new = find_constructor(info)
   return class, '_class'
end

-- Repo namespace metatable.
local namespace_mt = {
   _categories = { '_class', '_interface', '_struct', '_union', '_enum',
		   '_function', '_constant', } }

-- Gets symbol of the specified namespace, if not present yet, tries to load it
-- on-demand.
function namespace_mt:__index(symbol)
   -- Check whether symbol is present in the metatable.
   local val = namespace_mt[symbol]
   if val then return val end

   -- Check, whether there is some precondition in the lazy-loading table.
   local preconditions = rawget(self, '_precondition')
   local precondition = preconditions and preconditions[symbol]
   if precondition then
      local package = preconditions[symbol]
      if not preconditions[package] then
	 preconditions[package] = true
	 require('lgix.' .. package)
	 preconditions[package] = nil
      end
      preconditions[symbol] = nil
      if not next(preconditions) then self._precondition = nil end
   end

   -- Check, whether symbol is already loaded.
   val = component_mt._element(self, nil, symbol, namespace_mt._categories)
   if val then return val end

   -- Lookup baseinfo of requested symbol in the GIRepository.
   local info = gi[self._name][symbol]
   if not info then return nil end

   -- Decide according to symbol type what to do.
   local loader = typeloader[info.type]
   if loader then
      local category
      val, category = loader(self, info)

      -- Cache the symbol in specified category in the namespace.
      if val then
	 local cat = rawget(self, category)
	 if not cat then
	    cat = {}
	    self[category] = cat
	 end
	 assert(not cat[symbol])
	 cat[symbol] = val
      end
   end
   return val
end

-- Resolves everything in the namespace by iterating through it.
function namespace_mt:_resolve(recurse)
   -- Iterate through all items in the namespace and dereference them,
   -- which causes them to be loaded in and cached inside the namespace
   -- table.
   local gi_ns = gi[self._name]
   for i = 1, #gi_ns do
      local ok, component = pcall(function() return self[gi_ns[i].name] end)
      if ok and recurse and type(component) == 'table' then
	 local resolve = component._resolve
	 if resolve then resolve(component, recurse) end
      end
   end
   return self
end

-- Makes sure that the namespace (optionally with requested version)
-- is properly loaded.
function lgi.require(name, version)
   -- Load the namespace info for GIRepository.
   local ns_info = assert(gi.require(name, version))

   -- If the repository table does not exist yet, create it.
   local ns = rawget(repo, name)
   if not ns then
      ns = setmetatable({ _name = name, _version = ns_info.version,
			  _dependencies = ns_info.dependencies },
			namespace_mt)
      repo[name] = ns

      -- Make sure that all dependent namespaces are also loaded.
      for name, version in pairs(ns._dependencies or {}) do
	 lgi.require(name, version)
      end

      -- Try to load override, if it is present.
      local lgix_name = 'lgix.' .. ns._name
      local ok, msg = pcall(require, lgix_name)
      if not ok then
	 -- Try parsing message; if it is something different than
	 -- "module xxx not found", then rethrow the exception.
	 assert(msg:find("module '" .. lgix_name .. "' not found:", 1, true),
		msg)
      end
   else
      assert(not version or ns._version == version,
	     ("loading '%s-%s', but version '%s' is already loaded"):format(
	  ns._name, version, ns._version))
   end
   return ns
end

-- Install metatable into repo table, so that on-demand loading works.
setmetatable(repo, { __index = function(_, name) return lgi.require(name) end })

-- Add gtypes to important GLib and GObject structures, for which the
-- typelibs do not contain them.
for gtype_name, gi_name in pairs {
      GDate = 'GLib.Date', GRegex = 'GLib.Regex', GDateTime = 'GLib.DateTime',
      GVariantType = 'GLib.VariantType', GParam = 'GObject.ParamSpec',
} do
   local gtype = core.gtype(gtype_name)
   local ns, name = gi_name:match('^([%w_]+)%.([%w_]+)$')
   local gi_type = repo[ns][name]
   gi_type._gtype = gtype
   repo[gtype] = gi_type
end

-- Add synthetic GObject.Type, containing well-known GType constants
-- and grouping some type_xxx methods.
local Type = { STRV = 'GStrv', ARRAY = 'GArray', BYTE_ARRAY = 'GByteArray',
	       PTR_ARRAY = 'GPtrArray', HASH_TABLE = 'GHashTable',
	       ERROR = 'GError', GTYPE = 'GType' }
repo.GObject.Type = Type
for _, name in pairs { 'name', 'qname', 'from_name', 'parent', 'depth',
		       'next_base', 'is_a', 'children', 'interfaces',
		       'query', 'fundamental_next', 'fundamental'} do
   Type[name] = repo.GObject['type_' .. name]
end
for num, name in ipairs { 'NONE', 'INTERFACE', 'CHAR', 'UCHAR', 'BOOLEAN',
			  'INT', 'UINT', 'LONG', 'ULONG', 'INT64', 'UINT64',
			  'ENUM', 'FLAGS', 'FLOAT', 'DOUBLE', 'STRING',
			  'POINTER', 'BOXED', 'PARAM', 'OBJECT', 'VARIANT' } do
   Type[name] = Type.name(num * 4)
end

-- Map of basic typeinfo tags to GType.
local type_tag_map = {
   gboolean = Type.BOOLEAN, gint8 = Type.CHAR, guint8 = Type.UCHAR,
   gint16 = Type.INT, guint16 = Type.UINT,
   gint32 = Type.INT, guint32 = Type.UINT,
   gint64 = Type.INT64, guint64 = Type.UINT64,
   gunichar = Type.UINT, gfloat = Type.FLOAT, gdouble = Type.DOUBLE,
   GType = Type.GTYPE, utf8 = Type.STRING, filename = Type.STRING,
   ghash = Type.HASH_TABLE, glist = Type.POINTER, gslist = Type.POINTER,
   error = Type.ERROR }

-- Gets GType corresponding to specified typeinfo.
function Type.from_typeinfo(ti)
   local gtype = type_tag_map[ti.tag]
   if not gtype then
      if ti.tag == 'interface' then
	 gtype = Type.name(ti.interface.gtype)
      elseif ti.tag == 'array' then
	 local atype = ti.array_type
	 if atype == 'c' then
	    gtype = Type.POINTER
	    -- Check for Strv.
	    local etag = ti.params[1].tag
	    if ((etag == 'utf8' or etag == 'filename')
		and ti.is_zero_terminated) then
	       gtype = Type.STRV
	    end
	 else
	    gtype = ({ array = Type.ARRAY, byte_array = Type.BYTE_ARRAY,
		       ptr_array = Type.PTR_ARRAY })[atype]
	 end
      end
   end
   return gtype
end

-- Value is constructible from any kind of source Lua value, and the
-- type of the value can be hinted by type name.
local Value = repo.GObject.Value
local value_info = gi.GObject.Value

-- Workaround for incorrect annotations - g_value_set_xxx are missing
-- (allow-none) annotations in glib < 2.30.
for _, name in pairs { 'set_object', 'set_variant', 'set_string' } do
   if not value_info.methods[name].args[1].optional then
      log.message("g_value_%s() is missing (allow-none)", name)
      local setter = Value[name]
      Value._method[name] =
      function(value, val)
	 if not val then Value.reset(value) else setter(value, val) end
      end
   end
end

-- Do not allow direct access to fields.
local value_field_gtype = Value._field.g_type
Value._field = nil

-- 'type' property controls gtype of the property.
Value._attribute = { gtype = {} }
function Value._attribute.gtype.get(value)
   return core.record.field(value, value_field_gtype)
end
function Value._attribute.gtype.set(value, newtype)
   local gtype = core.record.field(value, value_field_gtype)
   if gtype then
      if newtype then
	 -- Try converting old value to new one.
	 local dest = core.record.new(value_info)
	 Value.init(dest, newtype)
	 if not Value.transform(value, dest) then
	    error(("GObject.Value: cannot convert `%s' to `%s'"):format(
		     gtype, core.record.field(dest, value_field_gtype)))
	 end
	 Value.unset(value)
	 Value.init(value, newtype)
	 Value.copy(dest, value)
      else
	 Value.unset(value)
      end
   elseif newtype then
      -- No value was set and some is requested, so set it.
      Value.init(value, newtype)
   end
end

local value_marshallers = {}
for name, gtype in pairs(Type) do
   local get = Value._method['get_' .. name:lower()]
   local set = Value._method['set_' .. name:lower()]
   if get and set then
      value_marshallers[gtype] =
      function(value, params, ...)
	 return (select('#', ...) > 0 and set or get)(value, ...)
      end
   end
end

-- Interface marshaller is the same as object marshallers.
value_marshallers[Type.INTERFACE] = value_marshallers[Type.OBJECT]

-- Override 'boxed' marshaller, default one marshalls to gpointer
-- instead of target boxed type.
value_marshallers[Type.BOXED] =
function(value, params, ...)
   local gtype = core.record.field(value, value_field_gtype)
   if select('#', ...) > 0 then
      Value.set_boxed(value, core.record.query((...), 'addr', gtype))
   else
      return core.record.new(gi[core.gtype(gtype)], Value.get_boxed(value))
   end
end

-- Create GStrv marshaller, implement it using typeinfo marshaller
-- with proper null-terminated-array-of-utf8 typeinfo 'stolen' from
-- g_shell_parse_argv().
value_marshallers[Type.STRV] = core.marshal.container(
   gi.GLib.shell_parse_argv.args[3].typeinfo)

function Value._method.find_marshaller(attrs)
   -- Check whether we can have marshaller for typeinfo.
   local marshaller
   if attrs.typeinfo then
      marshaller = core.marshal.container(attrs.typeinfo, attrs.transfer)
      if marshaller then return marshaller end
   end

   local gtype = attrs.gtype
   -- Special marshaller, allowing only 'nil'.
   if not gtype then return function() end end

   -- Find marshaller according to gtype of the value.
   while gtype do
      -- Check simple and/or fundamental marshallers.
      marshaller = value_marshallers[gtype] or core.marshal.fundamental(gtype)
      if marshaller then return marshaller end
      gtype = Type.parent(gtype)
   end
   error(("GValue marshaller for `%s' not found"):format(tostring(attrs.gtype)))
end

-- Value 'value' property provides access to GValue's embedded data.
function Value._attribute:value(...)
   local attrs = { gtype = core.record.field(self, value_field_gtype) }
   local marshaller = Value._method.find_marshaller(attrs)
   return marshaller(self, attrs, ...)
end

-- Implement custom 'constructor', taking optionally two values (type
-- and value).  The reason why it is overriden is that the order of
-- initialization is important, and standard record intializer cannot
-- enforce the order.
function Value:_new(gtype, value)
   local v = core.record.new(value_info)
   if gtype then v.gtype = gtype end
   if value then v.value = value end
   return v
end

-- Implementation of closure support, together with marshalling.
local Closure = repo.GObject.Closure
local closure_info = gi.GObject.Closure

-- Compile callable_info into table which allows fast marshalling
local function callable_info_compile(callable_info, to_lua)
   local res = { has_self = (callable_info.is_signal
			     or callable_info.is_virtual) }
   local argc, gtype = 0

   -- If this is a C array with explicit length argument, mark it.
   local function mark_array_length(cell, ti)
      local len = ti.array_length
      if len then
	 cell.len_index = 1 + len + (res.has_self and 1 or 0)
	 if not res[cell.len_index] then res[cell.len_index] = {} end
	 res[cell.len_index].internal = true
      end
   end

   -- Fill in 'self' argument.
   if res.has_self then
      argc = 1
      gtype = callable_info.container.gtype
      res[1] = { dir = 'in', gtype = gtype,
		 [to_lua and 'to_lua' or 'to_value']
		 = Value.find_marshaller { gtype = gtype } }
   end

   -- Go through arguments.
   local phantom_return
   for i = 1, #callable_info.args do
      local ai = callable_info.args[i]
      local ti = ai.typeinfo

      -- Prepare parameter cell in res array.
      argc = argc + 1
      if not res[argc] then res[argc] = {} end
      local cell = res[argc]

      -- Fill in marshaller(s) for the cell.
      cell.dir = ai.direction
      cell.gtype = Type.from_typeinfo(ti)
      if (cell.dir == (to_lua and 'in' or 'out') or cell.dir == 'inout'
	  or (to_lua and cell.dir == 'out-caller-alloc')) then
	 cell.to_lua = Value.find_marshaller {
	    gtype = cell.gtype, typeinfo = ti,
	    transfer = (ai.direction == 'inout'
			and 'none' or ti.transfer) }
      end
      if (cell.dir == (to_lua and 'out' or 'in') or cell.dir == 'inout'
	  or (not to_lua and cell.dir == 'out-caller-alloc')) then
	 cell.to_value = Value.find_marshaller {
	    gtype = cell.gtype, typeinfo = ti,
	    transfer = (ai.direction == 'inout'
			and 'none' or ti.transfer) }
      end
      mark_array_length(cell, ti)

      -- Check for output parameters; if present, enable
      -- phantom-return heuristics.
      phantom_return = phantom_return or cell.dir == 'out'
   end

   -- Prepare retval marshalling.
   local ti = callable_info.return_type
   if ti.tag ~= 'void' or ti.is_pointer then
      gtype = Type.from_typeinfo(ti)
      local ret = { dir = 'out', gtype = gtype,
		    to_value = Value.find_marshaller {
		       gtype = gtype,
		       typeinfo = ti,
		       transfer = callable_info.return_transfer } }
      mark_array_length(ret, ti)
      if phantom_return and ti.tag == 'gboolean' then
	 res.ret = ret
      else
	 res.phantom = ret
      end
   end
   return res
end

-- Marshal single call_info cell (either input or output).
local function callable_info_marshal_cell(
      call_info, cell, direction, args, argc,
      marshalling_params, value, params)
   local marshaller = cell[direction]
   if not marshaller or cell.internal then return argc end
   argc = argc + 1
   local length_marshaller
   if cell.len_index then
      -- Prepare length argument marshaller.
      length_marshaller = call_info[cell.len_index][direction]
      if direction == 'to_lua' then
	 marshalling_params.length = length_marshaller(
	    params[cell.len_index], {})
      end
   end
   if direction == 'to_lua' then
      -- Marshal from C to Lua
      args[argc] = marshaller(value, marshalling_params)
   else
      -- Marshal from Lua to C
      marshaller(value, marshalling_params, args[argc])

      -- Marshal array length output, if applicable.
      if length_marshaller then
	 length_marshaller(params[cell.len_index], {},
			   marshalling_params.length)
      end

      -- Marshal phantom return, if applicable.
      if retval and call_info.phantom and args[argc] == nil then
	 call_info.phantom.to_value(retval, marshalling_params, false)
      end
   end
   return argc
end

-- Creates GClosure marshaller, optionally with callable_info, in
-- which case it is used for marshalling.
local function get_closure_marshal(target, callable_info)
   -- If callable_info is not specified, create simple marshaller
   -- based on GValue types.
   if not callable_info then
      return function(closure, retval, params)
		local args = {}
		for i, val in ipairs(params) do args[i] = val.value end
		local ret = target(unpack(args, 1, #params))
		if retval then retval.value = ret end
	     end
   end

   local call_info = callable_info_compile(callable_info, true)
   return function (closure, retval, params)
      local marshalling_params = { keepalive = {} }
      local args, argc = {}, 0

      -- Marshal input arguments.
      for i = 1, #call_info do
	 argc = callable_info_marshal_cell(
	    call_info, call_info[i], 'to_lua', args, argc,
	    marshalling_params, params[i], params)
      end

      -- Do the call.
      args = { target(unpack(args, 1, argc)) }
      argc = 0
      marshalling_params = { keepalive = {} }

      -- Marshall the return value.
      if call_info.ret and retval then
	 argc = callable_info_marshal_cell(
	    call_info, call_info.ret, 'to_value', args, argc,
	    marshalling_params, retval, params)
      end

      -- Prepare 'true' into phantom return, will be reset to 'false'
      -- when some output argument is returned as 'nil'.
      if call_info.phantom and retval then
	 call_info.phantom.to_value(retval, marshalling_params, true)
      end

      -- Marshal output arguments.
      for i = 1, #call_info do
	 argc = callable_info_marshal_cell(
	    call_info, call_info[i], 'to_value', args, argc,
	    marshalling_params, params[i], params)
      end
   end
end

-- Marshalls Lua arguments into Values suitable for invoking closures
-- and signals.  Returns Value (for retval), array of Value (for
-- params) and keepalive value (which must be kept alive during the
-- call)
local function callable_info_pre_call(call_info, ...)
   -- Prepare array of param values and initialize them with correct type.
   local params = {}
   for i = 1, #call_info do params[#params + 1] = Value(call_info[i].gtype) end
   local marshalling_params = { keepalive = {} }

   -- Marshal input values.
   local args, argc = { ... }, 0
   for i = 1, #call_info do
      argc = callable_info_marshal_cell(
	 call_info, call_info[i], 'to_value', args, argc,
	 marshalling_params, params[i], params)
   end

   -- Prepare return value.
   local retval = Value()
   if call_info.ret then retval.type = call_info.ret.gtype end
   if call_info.phantom then retval.type = call_info.phantom.gtype end
   return retval, params, marshalling_params.keepalive
end

-- Unmarshalls Lua restuls from Values after invoking closure or
-- signal.  Returns all unmarshalled Lua values.
local function callable_info_post_call(call_info, params, retval)
   local marshalling_params = { keepalive = {} }
   local args, argc = {}, 0
   -- Check, whether phantom return exists and returned 'false'.  If
   -- yes, return just nil.
   if (call_info.phantom
       and not call_info.phantom.to_lua(retval, marshalling_params)) then
      return nil
   end

   -- Unmarshal return value.
   if call_info.ret and retval then
      argc = callable_info_marshal_cell(
	 call_info, call_info.ret, 'to_lua', args, argc,
	 marshalling_params, retval, params)
   end

   -- Unmarshal output arguments.
   for i = 1, #call_info do
      argc = callable_info_marshal_cell(
	 call_info, call_info[i], 'to_lua', args, argc,
	 marshalling_params, params[i], params)
   end

   -- Return all created Lua values.
   return unpack(args, 1, argc)
end

-- Create new closure invoking Lua target function (or anything else
-- that can be called).  Optionally callback_info specifies detailed
-- information about how to marshal signals.
function Closure:_new(target, callback_info)
   local closure = Closure._method.new_simple(closure_info.size, nil)
   if target then
      core.marshal.closure_set_marshal(
	 closure, get_closure_marshal(target, callback_info))
   end
   Closure.ref(closure)
   Closure.sink(closure)
   return closure
end

-- GObject overrides.  Create new mt table for GObject.
local gobject_mt = class_mt:clone {
   '_virtual', '_property', '_signal', '_method', '_constant', '_field'
}
local Object = setmetatable(repo.GObject.Object, gobject_mt)

-- Object constructor, 'param' contains table with properties/signals
-- to initialize.
local parameter_info = gi.GObject.Parameter
function Object:_new(args)
   -- Process 'args' table, separate properties from other fields.
   local params, others, safe = {}, {}, {}
   for name, arg in pairs(args or {}) do
      local argtype = self[name]
      if gi.isinfo(argtype) and argtype.is_property then
	 local param = core.record.new(parameter_info)
	 name = argtype.name

	 -- Store the name string in some safe Lua place ('safe'
	 -- table), because param is GParameter, which contains only
	 -- non-owning pointer to the string, and it could be
	 -- Lua-GC'ed while still referenced by GParameter instance.
	 safe[#safe + 1] = name

	 param.name = name
	 local attrs = { typeinfo = argtype.typeinfo,
			 gtype = Type.from_typeinfo(argtype.typeinfo) }
	 Value.init(param.value, attrs.gtype)
	 Value.find_marshaller(attrs)(param.value, attrs, arg)
	 params[#params + 1] = param
      else
	 others[name] = arg
      end
   end

   -- Create the object.
   local object = object_new(self._gtype, params)

   -- Attach arguments previously filtered out from creation.
   for name, func in pairs(others) do object[name] = func end
   return object
end

-- Initially unowned creation is similar to normal GObject creation,
-- but we have to ref_sink newly created object.
local InitiallyUnowned = repo.GObject.InitiallyUnowned
function InitiallyUnowned:_new(args)
   local object = Object._new(self, args)
   return Object.ref_sink(object)
end

-- Custom _element implementation, checks dynamically inherited
-- interfaces and dynamic properties.
function Object:_element(object, name)
   local element, category = class_mt._element(self, object, name)
   if element then return element, category end

   -- Everything else works only if we have object instance.
   if not object then return nil end

   -- List all interfaces implemented by this object and try whether
   -- they can handle specified _element request.
   local interfaces = Type.interfaces(core.object.query(object, 'gtype'))
   for i = 1, #interfaces do
      local info = gi[core.gtype(interfaces[i])]
      local iface = repo[info.namespace][info.name]
      element, category = iface and iface:_element(object, name)
      if element then return element, category end
   end

   -- Element not found in the repo (typelib), try whether dynamic
   -- property of the specified name exists.
   local class = core.record.cast(core.object.query(object, 'class'),
				  Object._class)
   local property = Object._class.find_property(class, name:gsub('_', '%-'))
   if property then return property, '_paramspec' end

   -- If nothing else is found, return simple artificial attribute
   -- which reads/writes object's env table.
   local env = core.object.query(object, 'env')
   return { get = function(obj) return env.name end,
	    set = function(obj, val) env.name = val end, }, '_attribute'
end

-- Sets/gets property using specified marshaller attributes.
local function marshal_property(obj, name, flags, attrs, ...)
   -- Check access rights of the property.
   local mode = select('#', ...) > 0 and 'WRITABLE' or 'READABLE'
   if not lgi.has_bit(flags, repo.GObject.ParamFlags[mode]) then
      error(("%s: `%s' not %s"):format(core.object.query(obj, 'repo')._name,
				       name, mode:lower()))
   end
   local marshaller = Value.find_marshaller(attrs)
   local value = core.record.new(value_info)
   Value.init(value, attrs.gtype)
   if mode == 'WRITABLE' then
      marshaller(value, attrs, ...)
      Object.set_property(obj, name, value)
   else
      Object.get_property(obj, name, value)
      return marshaller(value, attrs)
   end
end

-- GI property accessor.
function Object:_access_property(object, property, ...)
   local typeinfo = property.typeinfo
   return marshal_property(object, property.name, property.flags,
			   { gtype = Type.from_typeinfo(typeinfo),
			     typeinfo = typeinfo,
			     transfer = property.transfer }, ...)
end

-- GLib property accessor (paramspec).
function Object:_access_paramspec(object, pspec, ...)
   return marshal_property(object, pspec.name, pspec.flags,
			   { gtype = pspec.value_type }, ...)
end

local quark_from_string = repo.GLib.quark_from_string
local signal_lookup = repo.GObject.signal_lookup
local signal_connect_closure_by_id = repo.GObject.signal_connect_closure_by_id
local signal_emitv = repo.GObject.signal_emitv
-- Connects signal to specified object instance.
local function connect_signal(obj, gtype, name, closure, detail, after)
   return signal_connect_closure_by_id(
      obj, signal_lookup(name, gtype), quark_from_string(detail), closure,
      after or false)
end
-- Emits signal on specified object instance.
local function emit_signal(obj, gtype, info, detail, ...)
   -- Compile callable info.
   local call_info = callable_info_compile(info)

   -- Marshal input arguments.
   local retval, params, keepalive = callable_info_pre_call(call_info, obj, ...)

   -- Invoke the signal.
   signal_emitv(params, signal_lookup(info.name, gtype),
		quark_from_string(detail), retval)

   -- Unmarshal results.
   return callable_info_post_call(call_info, params, retval)
end

-- Creates closure implementing _access_element for signals
local function get_signal_attribute(info, gtype,
				   get_target, get_detail, get_args)
   local function get_closure(target)
      return Closure(get_target and get_target(target) or target, info)
   end
   if not get_args then get_args = function(object, ...) return ... end end
   local function access_signal(object, ...)
      if select('#', ...) > 0 then
	 -- Assignment means 'connect signal without detail'.
	 connect_signal(object, gtype, info.name, get_closure(...))
      else
	 -- Reading yields table with signal operations.
	 local pad = {}
	 function pad:connect(target, detail, after)
	    return connect_signal(object, gtype, info.name, get_closure(target),
				  get_detail and get_detail(detail) or detail,
				  after)
	 end
	 function pad:emit(detail, ...)
	    return emit_signal(object, gtype, info,
			       get_detail and get_detail(detail) or detail,
			       get_args(object, ...))
	 end

	 -- If signal supports details, add metatable implementing
	 -- __newindex for connecting in the 'on_signal['detail'] =
	 -- handler' form.
	 if not info.is_signal or info.flags.detailed then
	    local meta = {}
	    function meta:__newindex(detail, target)
	       connect_signal(object, gtype, info.name, get_closure(target),
			      get_detail and get_detail(detail) or detail)
	    end
	    setmetatable(pad, meta)
	 end

	 -- Return created signal pad.
	 return pad
      end
   end
   return access_signal
end

-- Custom access_element, reacts on dynamic properties
function Object:_accessor_attribute(object, element, ...)
   if gi.isinfo(element) and element.is_signal then
      return get_signal_attribute(element, self._gtype)(object, ...)
   elseif gi.isinfo(element) and element.is_property then
      -- Process property using GI.
      local typeinfo = element.typeinfo
      return marshal_property(object, element.name, element.flags,
			      { gtype = Type.from_typeinfo(typeinfo),
				typeinfo = typeinfo,
				transfer = element.transfer }, ...)
   elseif is_param_spec(element) then
      -- Process property using GLib.
      return marshal_property(object, element.name, element.flags,
			      { gtype = element.value_type }, ...)
   else
      -- Forward to 'inherited' generic object implementation.
      return class_mt._attribute(self, object, element, ...)
   end
end

-- Create lazy-loading components for variant stuff.
repo.GLib._precondition = {}
for _, name in pairs { 'Variant', 'VariantType', 'VariantBuilder' } do
   repo.GLib._precondition[name] = 'GLib-Variant'
end

-- Access to module proxies the whole repo, for convenience.
return setmetatable(lgi, { __index = repo })
