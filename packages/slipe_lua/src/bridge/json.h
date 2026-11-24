#ifndef SLIPE_LUA_JSON_H
#define SLIPE_LUA_JSON_H

#include <stddef.h>

#include "lua.h"

#ifndef lua_absindex
#define lua_absindex(L, index) \
  (((index) > 0 || (index) <= LUA_REGISTRYINDEX) \
       ? (index) \
       : lua_gettop(L) + (index) + 1)
#endif

#define SLIPE_JSON_MAX_BYTES (1024u * 1024u)
#define SLIPE_JSON_MAX_DEPTH 64

typedef struct SlipeJsonBuffer {
  char *data;
  size_t length;
  size_t capacity;
  int failed;
} SlipeJsonBuffer;

void slipe_json_buffer_init(SlipeJsonBuffer *buffer);
void slipe_json_buffer_dispose(SlipeJsonBuffer *buffer);
int slipe_json_buffer_append_n(SlipeJsonBuffer *buffer, const char *text,
                               size_t length);
int slipe_json_buffer_append(SlipeJsonBuffer *buffer, const char *text);
int slipe_json_buffer_char(SlipeJsonBuffer *buffer, char value);
int slipe_json_buffer_string(SlipeJsonBuffer *buffer, const char *text,
                             size_t length);
char *slipe_json_buffer_take(SlipeJsonBuffer *buffer);

/* Pushes exactly one decoded value onto L. */
int slipe_json_decode(lua_State *L, const char *json, size_t length,
                      char *error, size_t error_size);

/* Encodes the value at index without changing the Lua stack. */
int slipe_json_encode(lua_State *L, int index, SlipeJsonBuffer *buffer,
                      char *error, size_t error_size);

/* Marks a table as a JSON array, including when it is empty. */
void slipe_json_mark_array(lua_State *L, int index);

/* JSON null is a private sentinel so object fields and array slots survive. */
void slipe_json_push_null(lua_State *L);

#endif
