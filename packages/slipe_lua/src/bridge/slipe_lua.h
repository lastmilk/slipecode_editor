#ifndef SLIPE_LUA_H
#define SLIPE_LUA_H

#include <stdint.h>

#if defined(_WIN32)
#define SLIPE_LUA_API __declspec(dllexport)
#else
#define SLIPE_LUA_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef struct SlipeLuaVm SlipeLuaVm;

#define SLIPE_LUA_DEFAULT_MEMORY (32u * 1024u * 1024u)
#define SLIPE_LUA_DEFAULT_BUDGET 200000u

/* All strings cross the ABI as NUL-terminated UTF-8. Returned strings and
 * create errors are owned by the caller and must use slipe_lua_free. */
SLIPE_LUA_API SlipeLuaVm *slipe_lua_create(const char *plugin_root,
                                           uint64_t memory_limit,
                                           char **error);
SLIPE_LUA_API char *slipe_lua_exec(SlipeLuaVm *vm, const char *source,
                                   const char *chunkname, uint64_t budget);
SLIPE_LUA_API char *slipe_lua_snapshot(SlipeLuaVm *vm);
SLIPE_LUA_API char *slipe_lua_invoke(SlipeLuaVm *vm, const char *handler,
                                     const char *payload, uint64_t budget);
SLIPE_LUA_API char *slipe_lua_resume(SlipeLuaVm *vm, const char *payload,
                                     int is_error, uint64_t budget);
SLIPE_LUA_API void slipe_lua_destroy(SlipeLuaVm *vm);
SLIPE_LUA_API void slipe_lua_free(void *memory);

#ifdef __cplusplus
}
#endif

#endif
