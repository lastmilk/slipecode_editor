#include "slipe_lua.h"

#include <ctype.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "json.h"
#include "lauxlib.h"
#include "lualib.h"
#include "runtime_lua.h"

#define SLIPE_ERROR_SIZE 512

typedef struct SlipeLuaAllocator {
  uint64_t limit;
  uint64_t used;
} SlipeLuaAllocator;

struct SlipeLuaVm {
  lua_State *L;
  SlipeLuaAllocator allocator;
  uint64_t budget;
  int active;
  int active_ref;
  int next_factory_ref;
  int budget_exhausted;
};

static char registry_key;
static char handlers_key;
static char vm_key;

static char *duplicate_string(const char *text) {
  size_t length;
  char *copy;
  if (text == NULL) return NULL;
  length = strlen(text);
  copy = (char *)malloc(length + 1);
  if (copy != NULL) memcpy(copy, text, length + 1);
  return copy;
}

static void assign_error(char **error, const char *format, ...) {
  char message[SLIPE_ERROR_SIZE];
  va_list args;
  if (error == NULL) return;
  va_start(args, format);
  vsnprintf(message, sizeof(message), format, args);
  va_end(args);
  message[sizeof(message) - 1] = '\0';
  *error = duplicate_string(message);
}

static void *limited_allocator(void *ud, void *ptr, size_t osize, size_t nsize) {
  SlipeLuaAllocator *allocator = (SlipeLuaAllocator *)ud;
  uint64_t previous = ptr == NULL ? 0 : (uint64_t)osize;
  uint64_t next;
  if (nsize == 0) {
    free(ptr);
    allocator->used = previous > allocator->used ? 0 : allocator->used - previous;
    return NULL;
  }
  if (nsize > UINT64_MAX - allocator->used + previous) return NULL;
  next = allocator->used - previous + (uint64_t)nsize;
  if (next > allocator->limit) return NULL;
  ptr = realloc(ptr, nsize);
  if (ptr != NULL) allocator->used = next;
  return ptr;
}

static SlipeLuaVm *vm_from_state(lua_State *L) {
  SlipeLuaVm *vm;
  lua_pushlightuserdata(L, &vm_key);
  lua_rawget(L, LUA_REGISTRYINDEX);
  vm = (SlipeLuaVm *)lua_touserdata(L, -1);
  lua_pop(L, 1);
  return vm;
}

static void instruction_hook(lua_State *L, lua_Debug *ar) {
  SlipeLuaVm *vm = vm_from_state(L);
  (void)ar;
  if (vm == NULL) return;
  if (vm->budget > 0) vm->budget--;
  if (vm->budget == 0) {
    vm->budget_exhausted = 1;
    lua_sethook(L, NULL, 0, 0);
    luaL_error(L, "Lua instruction budget exhausted");
  }
}

static void install_hook(SlipeLuaVm *vm, lua_State *L) {
  if (L != NULL) {
    lua_sethook(L, instruction_hook, LUA_MASKCALL | LUA_MASKRET | LUA_MASKCOUNT, 1);
  }
}

static void begin_budget(SlipeLuaVm *vm, lua_State *co, uint64_t budget) {
  vm->budget = budget == 0 ? SLIPE_LUA_DEFAULT_BUDGET : budget;
  vm->budget_exhausted = 0;
  install_hook(vm, vm->L);
  install_hook(vm, co);
}

static void push_hidden_table(lua_State *L, void *key) {
  lua_pushlightuserdata(L, key);
  lua_rawget(L, LUA_REGISTRYINDEX);
}

static void store_hidden_table(lua_State *L, void *key, int index) {
  index = lua_absindex(L, index);
  lua_pushlightuserdata(L, key);
  lua_pushvalue(L, index);
  lua_rawset(L, LUA_REGISTRYINDEX);
}

static char *make_error_json(const char *message) {
  SlipeJsonBuffer buffer;
  char *result;
  if (message == NULL || message[0] == '\0') message = "Unknown Lua error";
  slipe_json_buffer_init(&buffer);
  if (slipe_json_buffer_append(&buffer, "{\"status\":\"error\",\"error\":{\"message\":") != 0 ||
      slipe_json_buffer_string(&buffer, message, strlen(message)) != 0 ||
      slipe_json_buffer_append(&buffer, "}}") != 0) {
    slipe_json_buffer_dispose(&buffer);
    return duplicate_string("{\"status\":\"error\",\"error\":{\"message\":\"Native JSON allocation failed\"}}");
  }
  result = slipe_json_buffer_take(&buffer);
  slipe_json_buffer_dispose(&buffer);
  return result;
}

static char *make_value_json(lua_State *L, int index, const char *status,
                             const char *field, char *error,
                             size_t error_size) {
  SlipeJsonBuffer buffer;
  char *result;
  slipe_json_buffer_init(&buffer);
  if (slipe_json_buffer_append(&buffer, "{\"status\":") != 0 ||
      slipe_json_buffer_string(&buffer, status, strlen(status)) != 0 ||
      slipe_json_buffer_char(&buffer, ',') != 0 ||
      slipe_json_buffer_string(&buffer, field, strlen(field)) != 0 ||
      slipe_json_buffer_char(&buffer, ':') != 0 ||
      slipe_json_encode(L, index, &buffer, error, error_size) != 0 ||
      slipe_json_buffer_char(&buffer, '}') != 0) {
    slipe_json_buffer_dispose(&buffer);
    return make_error_json(error[0] == '\0' ? "Lua result is not valid JSON" : error);
  }
  result = slipe_json_buffer_take(&buffer);
  slipe_json_buffer_dispose(&buffer);
  return result;
}

static const char *lua_error_message(lua_State *L) {
  const char *message;
  if (lua_type(L, -1) == LUA_TSTRING || lua_type(L, -1) == LUA_TNUMBER) {
    message = lua_tostring(L, -1);
    if (message != NULL) return message;
  }
  return lua_typename(L, lua_type(L, -1));
}

static void clear_active(SlipeLuaVm *vm) {
  if (vm->active_ref != LUA_NOREF) {
    luaL_unref(vm->L, LUA_REGISTRYINDEX, vm->active_ref);
    vm->active_ref = LUA_NOREF;
  }
  vm->active = 0;
  lua_settop(vm->L, 0);
}

static char *finish_resume(SlipeLuaVm *vm, lua_State *co, int status) {
  char error[SLIPE_ERROR_SIZE];
  char *result;
  error[0] = '\0';
  if (status == LUA_YIELD) {
    if (lua_gettop(co) == 0) lua_pushnil(co);
    result = make_value_json(co, 1, "yield", "yield", error, sizeof(error));
    lua_settop(vm->L, 0);
    return result;
  }
  if (status == LUA_OK) {
    if (lua_gettop(co) == 0) lua_pushnil(co);
    result = make_value_json(co, 1, "done", "result", error, sizeof(error));
    clear_active(vm);
    return result;
  }
  if (vm->budget_exhausted) {
    result = make_error_json("Lua instruction budget exhausted");
  } else if (status == LUA_ERRMEM) {
    result = make_error_json("Lua memory limit exhausted");
  } else {
    result = make_error_json(lua_error_message(co));
  }
  clear_active(vm);
  return result;
}

static int lua_json_encode(lua_State *L) {
  SlipeJsonBuffer buffer;
  char error[SLIPE_ERROR_SIZE];
  char *encoded;
  size_t length;
  error[0] = '\0';
  luaL_checkany(L, 1);
  slipe_json_buffer_init(&buffer);
  if (slipe_json_encode(L, 1, &buffer, error, sizeof(error)) != 0) {
    slipe_json_buffer_dispose(&buffer);
    return luaL_error(L, "%s", error[0] == '\0' ? "JSON encoding failed" : error);
  }
  encoded = slipe_json_buffer_take(&buffer);
  slipe_json_buffer_dispose(&buffer);
  if (encoded == NULL) return luaL_error(L, "JSON allocation failed");
  length = strlen(encoded);
  lua_pushlstring(L, encoded, length);
  free(encoded);
  return 1;
}

static int lua_json_decode(lua_State *L) {
  size_t length;
  const char *json = luaL_checklstring(L, 1, &length);
  char error[SLIPE_ERROR_SIZE];
  error[0] = '\0';
  if (slipe_json_decode(L, json, length, error, sizeof(error)) != 0) {
    return luaL_error(L, "%s", error[0] == '\0' ? "JSON decoding failed" : error);
  }
  return 1;
}

static int lua_mark_array(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  slipe_json_mark_array(L, 1);
  return 1;
}

static int lua_yield_next(lua_State *L) {
  luaL_checktype(L, 1, LUA_TTABLE);
  lua_settop(L, 1);
  return lua_yield(L, 1);
}

static int valid_module_name(const char *name, size_t length) {
  size_t i;
  int segment_length = 0;
  if (length == 0 || length > 240) return 0;
  for (i = 0; i < length; i++) {
    unsigned char c = (unsigned char)name[i];
    if (c == '.') {
      if (segment_length == 0) return 0;
      segment_length = 0;
    } else if (isalnum(c) || c == '_' || c == '-') {
      segment_length++;
    } else {
      return 0;
    }
  }
  return segment_length != 0;
}

static int lua_root_loader(lua_State *L) {
  size_t module_length;
  const char *module = luaL_checklstring(L, 1, &module_length);
  const char *root = lua_tostring(L, lua_upvalueindex(1));
  char *relative;
  char *path;
  size_t root_length;
  size_t i;
  int status;
  if (!valid_module_name(module, module_length) || root == NULL) {
    lua_pushliteral(L, "\n\tinvalid module name (only plugin-local Lua modules are allowed)");
    return 1;
  }
  root_length = strlen(root);
  relative = (char *)malloc(module_length + 5);
  if (relative == NULL) return luaL_error(L, "Module path allocation failed");
  for (i = 0; i < module_length; i++) relative[i] = module[i] == '.' ? '/' : module[i];
  memcpy(relative + module_length, ".lua", 5);
  path = (char *)malloc(root_length + module_length + 6);
  if (path == NULL) {
    free(relative);
    return luaL_error(L, "Module path allocation failed");
  }
  memcpy(path, root, root_length);
  path[root_length] = '/';
  memcpy(path + root_length + 1, relative, module_length + 5);
  free(relative);
  status = luaL_loadfilex(L, path, "t");
  if (status == LUA_OK || status != LUA_ERRFILE) {
    free(path);
    if (status == LUA_OK) return 1;
    return lua_error(L);
  }
  free(path);
  return 1;
}

static void set_table_function(lua_State *L, int table, const char *name,
                               lua_CFunction function) {
  table = lua_absindex(L, table);
  lua_pushcfunction(L, function);
  lua_setfield(L, table, name);
}

static void set_table_nil(lua_State *L, int table, const char *name) {
  table = lua_absindex(L, table);
  lua_pushnil(L);
  lua_setfield(L, table, name);
}

static int lua_coroutine_create(lua_State *L) {
  lua_State *co;
  SlipeLuaVm *vm = vm_from_state(L);
  luaL_checktype(L, 1, LUA_TFUNCTION);
  lua_settop(L, 1);
  co = lua_newthread(L);
  if (co == NULL) return luaL_error(L, "Unable to create coroutine");
  lua_pushvalue(L, 1);
  lua_xmove(L, co, 1);
  install_hook(vm, co);
  return 1;
}

static int resume_coroutine(lua_State *L, lua_State *co, int nargs,
                            int wrap) {
  int status;
  int results;
  if (co == L) return luaL_error(L, "cannot resume the running coroutine");
  lua_xmove(L, co, nargs);
  status = lua_resume(co, nargs);
  results = lua_gettop(co);
  luaL_checkstack(L, results + 2, "too many coroutine results");
  lua_xmove(co, L, results);
  if (wrap && status != LUA_OK && status != LUA_YIELD) return lua_error(L);
  lua_pushboolean(L, status == LUA_OK || status == LUA_YIELD);
  lua_insert(L, -results - 1);
  return results + 1;
}

static int lua_coroutine_resume(lua_State *L) {
  lua_State *co = lua_tothread(L, 1);
  if (co == NULL) return luaL_typerror(L, 1, "coroutine");
  return resume_coroutine(L, co, lua_gettop(L) - 1, 0);
}

static int lua_coroutine_wrap_aux(lua_State *L) {
  lua_State *co = lua_tothread(L, lua_upvalueindex(1));
  if (co == NULL) return luaL_error(L, "invalid coroutine wrapper");
  return resume_coroutine(L, co, lua_gettop(L), 1);
}

static int lua_coroutine_wrap(lua_State *L) {
  lua_State *co;
  SlipeLuaVm *vm = vm_from_state(L);
  luaL_checktype(L, 1, LUA_TFUNCTION);
  lua_settop(L, 1);
  co = lua_newthread(L);
  if (co == NULL) return luaL_error(L, "Unable to create coroutine");
  lua_pushvalue(L, 1);
  lua_xmove(L, co, 1);
  install_hook(vm, co);
  lua_pushcclosure(L, lua_coroutine_wrap_aux, 1);
  return 1;
}

static int install_runtime(SlipeLuaVm *vm, const char *plugin_root) {
  lua_State *L = vm->L;
  int status;
  luaL_openlibs(L);

  lua_pushlightuserdata(L, &vm_key);
  lua_pushlightuserdata(L, vm);
  lua_rawset(L, LUA_REGISTRYINDEX);

  lua_newtable(L);
  lua_newtable(L);
  lua_setfield(L, -2, "services");
  lua_newtable(L);
  lua_setfield(L, -2, "events");
  lua_newtable(L);
  lua_setfield(L, -2, "commands");
  lua_newtable(L);
  lua_setfield(L, -2, "config");
  lua_newtable(L);
  lua_setfield(L, -2, "keys");
  lua_newtable(L);
  slipe_json_mark_array(L, -1);
  lua_setfield(L, -2, "hooks");
  store_hidden_table(L, &registry_key, -1);
  lua_pop(L, 1);

  lua_newtable(L);
  store_hidden_table(L, &handlers_key, -1);
  lua_pop(L, 1);

  lua_getglobal(L, "package");
  if (lua_istable(L, -1)) {
    lua_newtable(L);
    lua_pushstring(L, plugin_root);
    lua_pushcclosure(L, lua_root_loader, 1);
    lua_rawseti(L, -2, 1);
    lua_setfield(L, -2, "loaders");
    set_table_nil(L, -1, "loadlib");
    lua_pushliteral(L, "");
    lua_setfield(L, -2, "cpath");
    lua_pushliteral(L, "");
    lua_setfield(L, -2, "path");
  }
  lua_pop(L, 1);

  lua_getglobal(L, "os");
  if (lua_istable(L, -1)) {
    set_table_nil(L, -1, "execute");
    set_table_nil(L, -1, "exit");
  }
  lua_pop(L, 1);
  lua_getglobal(L, "io");
  if (lua_istable(L, -1)) set_table_nil(L, -1, "popen");
  lua_pop(L, 1);
  lua_getglobal(L, "coroutine");
  if (lua_istable(L, -1)) {
    set_table_function(L, -1, "create", lua_coroutine_create);
    set_table_function(L, -1, "resume", lua_coroutine_resume);
    set_table_function(L, -1, "wrap", lua_coroutine_wrap);
  }
  lua_pop(L, 1);
  lua_pushnil(L);
  lua_setglobal(L, "debug");
  lua_pushnil(L);
  lua_setglobal(L, "ffi");
  lua_pushnil(L);
  lua_setglobal(L, "loadfile");
  lua_pushnil(L);
  lua_setglobal(L, "dofile");

  status = luaL_loadbufferx(L, slipe_runtime_lua,
                            sizeof(slipe_runtime_lua) - 1,
                            "=slipe_runtime", "t");
  if (status != LUA_OK) return status;
  push_hidden_table(L, &registry_key);
  push_hidden_table(L, &handlers_key);
  lua_pushcfunction(L, lua_yield_next);
  lua_pushcfunction(L, lua_json_encode);
  lua_pushcfunction(L, lua_json_decode);
  lua_pushcfunction(L, lua_mark_array);
  slipe_json_push_null(L);
  status = lua_pcall(L, 7, 1, 0);
  if (status != LUA_OK) return status;
  vm->next_factory_ref = luaL_ref(L, LUA_REGISTRYINDEX);
  lua_settop(L, 0);
  return LUA_OK;
}

SLIPE_LUA_API SlipeLuaVm *slipe_lua_create(const char *plugin_root,
                                           uint64_t memory_limit,
                                           char **error) {
  SlipeLuaVm *vm;
  int status;
  if (error != NULL) *error = NULL;
  if (plugin_root == NULL || plugin_root[0] == '\0') {
    assign_error(error, "plugin_root must be a non-empty path");
    return NULL;
  }
  vm = (SlipeLuaVm *)calloc(1, sizeof(*vm));
  if (vm == NULL) {
    assign_error(error, "Unable to allocate Lua VM");
    return NULL;
  }
  vm->active_ref = LUA_NOREF;
  vm->next_factory_ref = LUA_NOREF;
  vm->allocator.limit = memory_limit == 0 ? SLIPE_LUA_DEFAULT_MEMORY : memory_limit;
  vm->L = lua_newstate(limited_allocator, &vm->allocator);
  if (vm->L == NULL) {
    assign_error(error, "Lua memory limit exhausted while creating VM");
    free(vm);
    return NULL;
  }
  status = install_runtime(vm, plugin_root);
  if (status != LUA_OK) {
    const char *message = lua_error_message(vm->L);
    assign_error(error, "Unable to initialize Lua VM: %s", message);
    lua_close(vm->L);
    free(vm);
    return NULL;
  }
  return vm;
}

SLIPE_LUA_API char *slipe_lua_exec(SlipeLuaVm *vm, const char *source,
                                   const char *chunkname, uint64_t budget) {
  lua_State *co;
  int status;
  if (vm == NULL || source == NULL) return make_error_json("Invalid VM or Lua source");
  if (vm->active) return make_error_json("Another Lua coroutine is already active");
  lua_settop(vm->L, 0);
  co = lua_newthread(vm->L);
  if (co == NULL) return make_error_json("Unable to create Lua coroutine");
  vm->active_ref = luaL_ref(vm->L, LUA_REGISTRYINDEX);
  vm->active = 1;
  status = luaL_loadbufferx(vm->L, source, strlen(source),
                            chunkname == NULL ? "=slipe" : chunkname, "t");
  if (status != LUA_OK) {
    char *result = make_error_json(lua_error_message(vm->L));
    clear_active(vm);
    return result;
  }
  lua_xmove(vm->L, co, 1);
  begin_budget(vm, co, budget);
  status = lua_resume(co, 0);
  return finish_resume(vm, co, status);
}

SLIPE_LUA_API char *slipe_lua_snapshot(SlipeLuaVm *vm) {
  SlipeJsonBuffer buffer;
  char error[SLIPE_ERROR_SIZE];
  char *result;
  if (vm == NULL) return make_error_json("Invalid Lua VM");
  error[0] = '\0';
  lua_settop(vm->L, 0);
  push_hidden_table(vm->L, &registry_key);
  slipe_json_buffer_init(&buffer);
  if (slipe_json_encode(vm->L, -1, &buffer, error, sizeof(error)) != 0) {
    slipe_json_buffer_dispose(&buffer);
    lua_settop(vm->L, 0);
    return make_error_json(error);
  }
  result = slipe_json_buffer_take(&buffer);
  slipe_json_buffer_dispose(&buffer);
  lua_settop(vm->L, 0);
  return result == NULL ? make_error_json("Snapshot allocation failed") : result;
}

SLIPE_LUA_API char *slipe_lua_invoke(SlipeLuaVm *vm, const char *handler,
                                     const char *payload, uint64_t budget) {
  lua_State *co;
  char error[SLIPE_ERROR_SIZE];
  int status;
  if (vm == NULL || handler == NULL || payload == NULL)
    return make_error_json("Invalid VM, handler, or payload");
  if (vm->active) return make_error_json("Another Lua coroutine is already active");
  error[0] = '\0';
  lua_settop(vm->L, 0);
  push_hidden_table(vm->L, &handlers_key);
  lua_getfield(vm->L, -1, handler);
  if (!lua_isfunction(vm->L, -1)) {
    lua_settop(vm->L, 0);
    return make_error_json("Unknown or unregistered Lua handler");
  }
  lua_remove(vm->L, -2);
  co = lua_newthread(vm->L);
  if (co == NULL) return make_error_json("Unable to create Lua coroutine");
  vm->active_ref = luaL_ref(vm->L, LUA_REGISTRYINDEX);
  vm->active = 1;
  lua_rawgeti(vm->L, LUA_REGISTRYINDEX, vm->active_ref);
  lua_insert(vm->L, -2);
  if (slipe_json_decode(vm->L, payload, strlen(payload), error, sizeof(error)) != 0) {
    char *result = make_error_json(error);
    clear_active(vm);
    return result;
  }
  lua_rawgeti(vm->L, LUA_REGISTRYINDEX, vm->next_factory_ref);
  lua_pushvalue(vm->L, -2);
  status = lua_pcall(vm->L, 1, 1, 0);
  if (status != LUA_OK) {
    char *result = make_error_json(lua_error_message(vm->L));
    clear_active(vm);
    return result;
  }
  lua_xmove(vm->L, co, 3);
  begin_budget(vm, co, budget);
  status = lua_resume(co, 2);
  return finish_resume(vm, co, status);
}

SLIPE_LUA_API char *slipe_lua_resume(SlipeLuaVm *vm, const char *payload,
                                     int is_error, uint64_t budget) {
  lua_State *co;
  char error[SLIPE_ERROR_SIZE];
  int status;
  if (vm == NULL || payload == NULL) return make_error_json("Invalid VM or payload");
  if (!vm->active) return make_error_json("No yielded Lua coroutine to resume");
  error[0] = '\0';
  lua_settop(vm->L, 0);
  lua_rawgeti(vm->L, LUA_REGISTRYINDEX, vm->active_ref);
  co = lua_tothread(vm->L, -1);
  if (co == NULL || lua_status(co) != LUA_YIELD) {
    clear_active(vm);
    return make_error_json("Active Lua coroutine is not resumable");
  }
  if (slipe_json_decode(vm->L, payload, strlen(payload), error, sizeof(error)) != 0) {
    return make_error_json(error);
  }
  lua_pushboolean(vm->L, is_error != 0);
  lua_insert(vm->L, -2);
  lua_xmove(vm->L, co, 2);
  begin_budget(vm, co, budget);
  status = lua_resume(co, 2);
  return finish_resume(vm, co, status);
}

SLIPE_LUA_API void slipe_lua_destroy(SlipeLuaVm *vm) {
  if (vm == NULL) return;
  if (vm->L != NULL) {
    lua_sethook(vm->L, NULL, 0, 0);
    lua_close(vm->L);
  }
  free(vm);
}

SLIPE_LUA_API void slipe_lua_free(void *memory) { free(memory); }
