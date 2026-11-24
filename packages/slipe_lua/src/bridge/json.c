#include "json.h"

#include <ctype.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lauxlib.h"

#if defined(_MSC_VER) && !defined(isfinite)
#define isfinite _finite
#endif

static char json_null_sentinel;

void slipe_json_push_null(lua_State *L) {
  lua_pushlightuserdata(L, &json_null_sentinel);
}

static void set_error(char *error, size_t size, const char *format, ...) {
  va_list args;
  if (error == NULL || size == 0) return;
  va_start(args, format);
  vsnprintf(error, size, format, args);
  va_end(args);
  error[size - 1] = '\0';
}

void slipe_json_buffer_init(SlipeJsonBuffer *buffer) {
  memset(buffer, 0, sizeof(*buffer));
}

void slipe_json_buffer_dispose(SlipeJsonBuffer *buffer) {
  free(buffer->data);
  memset(buffer, 0, sizeof(*buffer));
}

static int buffer_reserve(SlipeJsonBuffer *buffer, size_t extra) {
  size_t needed;
  size_t capacity;
  char *data;
  if (buffer->failed || extra > SLIPE_JSON_MAX_BYTES - buffer->length) {
    buffer->failed = 1;
    return -1;
  }
  needed = buffer->length + extra + 1;
  if (needed <= buffer->capacity) return 0;
  capacity = buffer->capacity == 0 ? 256 : buffer->capacity;
  while (capacity < needed) {
    if (capacity >= SLIPE_JSON_MAX_BYTES) {
      capacity = SLIPE_JSON_MAX_BYTES + 1;
      break;
    }
    capacity *= 2;
  }
  data = (char *)realloc(buffer->data, capacity);
  if (data == NULL) {
    buffer->failed = 1;
    return -1;
  }
  buffer->data = data;
  buffer->capacity = capacity;
  return 0;
}

int slipe_json_buffer_append_n(SlipeJsonBuffer *buffer, const char *text,
                               size_t length) {
  if (buffer_reserve(buffer, length) != 0) return -1;
  memcpy(buffer->data + buffer->length, text, length);
  buffer->length += length;
  buffer->data[buffer->length] = '\0';
  return 0;
}

int slipe_json_buffer_append(SlipeJsonBuffer *buffer, const char *text) {
  return slipe_json_buffer_append_n(buffer, text, strlen(text));
}

int slipe_json_buffer_char(SlipeJsonBuffer *buffer, char value) {
  return slipe_json_buffer_append_n(buffer, &value, 1);
}

char *slipe_json_buffer_take(SlipeJsonBuffer *buffer) {
  char *data;
  if (buffer->failed) return NULL;
  if (buffer->data == NULL) {
    data = (char *)malloc(1);
    if (data != NULL) data[0] = '\0';
    return data;
  }
  data = buffer->data;
  buffer->data = NULL;
  buffer->length = 0;
  buffer->capacity = 0;
  return data;
}

static int utf8_sequence(const unsigned char *text, size_t available,
                         size_t *length) {
  unsigned char c;
  uint32_t codepoint;
  size_t needed;
  size_t i;
  if (available == 0) return -1;
  c = text[0];
  if (c < 0x80) {
    *length = 1;
    return 0;
  }
  if (c >= 0xc2 && c <= 0xdf) {
    needed = 2;
    codepoint = c & 0x1f;
  } else if (c >= 0xe0 && c <= 0xef) {
    needed = 3;
    codepoint = c & 0x0f;
  } else if (c >= 0xf0 && c <= 0xf4) {
    needed = 4;
    codepoint = c & 0x07;
  } else {
    return -1;
  }
  if (available < needed) return -1;
  for (i = 1; i < needed; i++) {
    if ((text[i] & 0xc0) != 0x80) return -1;
    codepoint = (codepoint << 6) | (text[i] & 0x3f);
  }
  if ((needed == 3 && codepoint < 0x800) ||
      (needed == 4 && codepoint < 0x10000) ||
      (codepoint >= 0xd800 && codepoint <= 0xdfff) ||
      codepoint > 0x10ffff) {
    return -1;
  }
  *length = needed;
  return 0;
}

int slipe_json_buffer_string(SlipeJsonBuffer *buffer, const char *text,
                             size_t length) {
  static const char hex[] = "0123456789abcdef";
  size_t i = 0;
  if (slipe_json_buffer_char(buffer, '"') != 0) return -1;
  while (i < length) {
    unsigned char c = (unsigned char)text[i];
    const char *escape = NULL;
    switch (c) {
      case '"': escape = "\\\""; break;
      case '\\': escape = "\\\\"; break;
      case '\b': escape = "\\b"; break;
      case '\f': escape = "\\f"; break;
      case '\n': escape = "\\n"; break;
      case '\r': escape = "\\r"; break;
      case '\t': escape = "\\t"; break;
      default: break;
    }
    if (escape != NULL) {
      if (slipe_json_buffer_append(buffer, escape) != 0) return -1;
      i++;
    } else if (c < 0x20) {
      char encoded[6] = {'\\', 'u', '0', '0', hex[c >> 4], hex[c & 15]};
      if (slipe_json_buffer_append_n(buffer, encoded, sizeof(encoded)) != 0)
        return -1;
      i++;
    } else if (c < 0x80) {
      if (slipe_json_buffer_char(buffer, (char)c) != 0) return -1;
      i++;
    } else {
      size_t sequence_length;
      if (utf8_sequence((const unsigned char *)text + i, length - i,
                        &sequence_length) != 0) {
        buffer->failed = 1;
        return -1;
      }
      if (slipe_json_buffer_append_n(buffer, text + i, sequence_length) != 0)
        return -1;
      i += sequence_length;
    }
  }
  return slipe_json_buffer_char(buffer, '"');
}

typedef struct JsonParser {
  const char *cursor;
  const char *end;
  lua_State *L;
  char *error;
  size_t error_size;
} JsonParser;

static void parser_skip_space(JsonParser *parser) {
  while (parser->cursor < parser->end &&
         (*parser->cursor == ' ' || *parser->cursor == '\t' ||
          *parser->cursor == '\n' || *parser->cursor == '\r')) {
    parser->cursor++;
  }
}

static int hex_digit(char c) {
  if (c >= '0' && c <= '9') return c - '0';
  if (c >= 'a' && c <= 'f') return c - 'a' + 10;
  if (c >= 'A' && c <= 'F') return c - 'A' + 10;
  return -1;
}

static int parse_hex4(JsonParser *parser, uint32_t *value) {
  int i;
  uint32_t result = 0;
  if ((size_t)(parser->end - parser->cursor) < 4) return -1;
  for (i = 0; i < 4; i++) {
    int digit = hex_digit(parser->cursor[i]);
    if (digit < 0) return -1;
    result = (result << 4) | (uint32_t)digit;
  }
  parser->cursor += 4;
  *value = result;
  return 0;
}

static void append_utf8(char *output, size_t *length, uint32_t codepoint) {
  size_t n = *length;
  if (codepoint <= 0x7f) {
    output[n++] = (char)codepoint;
  } else if (codepoint <= 0x7ff) {
    output[n++] = (char)(0xc0 | (codepoint >> 6));
    output[n++] = (char)(0x80 | (codepoint & 0x3f));
  } else if (codepoint <= 0xffff) {
    output[n++] = (char)(0xe0 | (codepoint >> 12));
    output[n++] = (char)(0x80 | ((codepoint >> 6) & 0x3f));
    output[n++] = (char)(0x80 | (codepoint & 0x3f));
  } else {
    output[n++] = (char)(0xf0 | (codepoint >> 18));
    output[n++] = (char)(0x80 | ((codepoint >> 12) & 0x3f));
    output[n++] = (char)(0x80 | ((codepoint >> 6) & 0x3f));
    output[n++] = (char)(0x80 | (codepoint & 0x3f));
  }
  *length = n;
}

static int parser_string(JsonParser *parser) {
  char *output;
  size_t output_length = 0;
  size_t capacity;
  if (parser->cursor >= parser->end || *parser->cursor != '"') return -1;
  parser->cursor++;
  capacity = (size_t)(parser->end - parser->cursor) + 1;
  output = (char *)malloc(capacity);
  if (output == NULL) {
    set_error(parser->error, parser->error_size, "JSON allocation failed");
    return -1;
  }
  while (parser->cursor < parser->end) {
    unsigned char c = (unsigned char)*parser->cursor++;
    if (c == '"') {
      lua_pushlstring(parser->L, output, output_length);
      free(output);
      return 0;
    }
    if (c < 0x20) break;
    if (c == '\\') {
      char escape;
      if (parser->cursor >= parser->end) break;
      escape = *parser->cursor++;
      switch (escape) {
        case '"': output[output_length++] = '"'; break;
        case '\\': output[output_length++] = '\\'; break;
        case '/': output[output_length++] = '/'; break;
        case 'b': output[output_length++] = '\b'; break;
        case 'f': output[output_length++] = '\f'; break;
        case 'n': output[output_length++] = '\n'; break;
        case 'r': output[output_length++] = '\r'; break;
        case 't': output[output_length++] = '\t'; break;
        case 'u': {
          uint32_t codepoint;
          if (parse_hex4(parser, &codepoint) != 0) goto invalid;
          if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
            uint32_t low;
            if ((size_t)(parser->end - parser->cursor) < 6 ||
                parser->cursor[0] != '\\' || parser->cursor[1] != 'u' ||
                (parser->cursor += 2, parse_hex4(parser, &low) != 0) ||
                low < 0xdc00 || low > 0xdfff) {
              goto invalid;
            }
            codepoint = 0x10000 + ((codepoint - 0xd800) << 10) +
                        (low - 0xdc00);
          } else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) {
            goto invalid;
          }
          append_utf8(output, &output_length, codepoint);
          break;
        }
        default: goto invalid;
      }
    } else if (c < 0x80) {
      output[output_length++] = (char)c;
    } else {
      size_t sequence_length;
      parser->cursor--;
      if (utf8_sequence((const unsigned char *)parser->cursor,
                        (size_t)(parser->end - parser->cursor),
                        &sequence_length) != 0) {
        goto invalid;
      }
      memcpy(output + output_length, parser->cursor, sequence_length);
      output_length += sequence_length;
      parser->cursor += sequence_length;
    }
  }

invalid:
  free(output);
  set_error(parser->error, parser->error_size, "Invalid JSON string");
  return -1;
}

static int parser_value(JsonParser *parser, int depth);

static int parser_array(JsonParser *parser, int depth) {
  int index = 1;
  parser->cursor++;
  lua_newtable(parser->L);
  slipe_json_mark_array(parser->L, -1);
  parser_skip_space(parser);
  if (parser->cursor < parser->end && *parser->cursor == ']') {
    parser->cursor++;
    return 0;
  }
  for (;;) {
    if (parser_value(parser, depth + 1) != 0) return -1;
    lua_rawseti(parser->L, -2, index++);
    parser_skip_space(parser);
    if (parser->cursor >= parser->end) break;
    if (*parser->cursor == ']') {
      parser->cursor++;
      return 0;
    }
    if (*parser->cursor++ != ',') break;
    parser_skip_space(parser);
  }
  set_error(parser->error, parser->error_size, "Invalid JSON array");
  return -1;
}

static int parser_object(JsonParser *parser, int depth) {
  parser->cursor++;
  lua_newtable(parser->L);
  parser_skip_space(parser);
  if (parser->cursor < parser->end && *parser->cursor == '}') {
    parser->cursor++;
    return 0;
  }
  for (;;) {
    if (parser_string(parser) != 0) return -1;
    parser_skip_space(parser);
    if (parser->cursor >= parser->end || *parser->cursor++ != ':') {
      set_error(parser->error, parser->error_size, "Expected ':' in JSON object");
      return -1;
    }
    parser_skip_space(parser);
    if (parser_value(parser, depth + 1) != 0) return -1;
    lua_rawset(parser->L, -3);
    parser_skip_space(parser);
    if (parser->cursor >= parser->end) break;
    if (*parser->cursor == '}') {
      parser->cursor++;
      return 0;
    }
    if (*parser->cursor++ != ',') break;
    parser_skip_space(parser);
  }
  set_error(parser->error, parser->error_size, "Invalid JSON object");
  return -1;
}

static int parser_number(JsonParser *parser) {
  const char *start = parser->cursor;
  const char *p = start;
  char *token;
  char *endptr;
  size_t length;
  double number;
  if (p < parser->end && *p == '-') p++;
  if (p >= parser->end) return -1;
  if (*p == '0') {
    p++;
    if (p < parser->end && isdigit((unsigned char)*p)) return -1;
  } else if (*p >= '1' && *p <= '9') {
    do { p++; } while (p < parser->end && isdigit((unsigned char)*p));
  } else {
    return -1;
  }
  if (p < parser->end && *p == '.') {
    p++;
    if (p >= parser->end || !isdigit((unsigned char)*p)) return -1;
    do { p++; } while (p < parser->end && isdigit((unsigned char)*p));
  }
  if (p < parser->end && (*p == 'e' || *p == 'E')) {
    p++;
    if (p < parser->end && (*p == '+' || *p == '-')) p++;
    if (p >= parser->end || !isdigit((unsigned char)*p)) return -1;
    do { p++; } while (p < parser->end && isdigit((unsigned char)*p));
  }
  length = (size_t)(p - start);
  token = (char *)malloc(length + 1);
  if (token == NULL) return -1;
  memcpy(token, start, length);
  token[length] = '\0';
  number = strtod(token, &endptr);
  if ((size_t)(endptr - token) != length || !isfinite(number)) {
    free(token);
    return -1;
  }
  free(token);
  lua_pushnumber(parser->L, (lua_Number)number);
  parser->cursor = p;
  return 0;
}

static int parser_value(JsonParser *parser, int depth) {
  if (depth > SLIPE_JSON_MAX_DEPTH) {
    set_error(parser->error, parser->error_size, "JSON nesting is too deep");
    return -1;
  }
  parser_skip_space(parser);
  if (parser->cursor >= parser->end) return -1;
  switch (*parser->cursor) {
    case '"': return parser_string(parser);
    case '[': return parser_array(parser, depth);
    case '{': return parser_object(parser, depth);
    case 'n':
      if ((size_t)(parser->end - parser->cursor) >= 4 &&
          memcmp(parser->cursor, "null", 4) == 0) {
        parser->cursor += 4;
        slipe_json_push_null(parser->L);
        return 0;
      }
      break;
    case 't':
      if ((size_t)(parser->end - parser->cursor) >= 4 &&
          memcmp(parser->cursor, "true", 4) == 0) {
        parser->cursor += 4;
        lua_pushboolean(parser->L, 1);
        return 0;
      }
      break;
    case 'f':
      if ((size_t)(parser->end - parser->cursor) >= 5 &&
          memcmp(parser->cursor, "false", 5) == 0) {
        parser->cursor += 5;
        lua_pushboolean(parser->L, 0);
        return 0;
      }
      break;
    default:
      if (*parser->cursor == '-' || isdigit((unsigned char)*parser->cursor))
        return parser_number(parser) == 0 ? 0 : -1;
      break;
  }
  set_error(parser->error, parser->error_size, "Invalid JSON value");
  return -1;
}

void slipe_json_mark_array(lua_State *L, int index) {
  index = lua_absindex(L, index);
  if (!lua_getmetatable(L, index)) {
    lua_newtable(L);
    lua_pushvalue(L, -1);
    lua_setmetatable(L, index);
  }
  lua_pushboolean(L, 1);
  lua_setfield(L, -2, "__slipe_json_array");
  lua_pushboolean(L, 0);
  lua_setfield(L, -2, "__metatable");
  lua_pop(L, 1);
}

int slipe_json_decode(lua_State *L, const char *json, size_t length,
                      char *error, size_t error_size) {
  JsonParser parser;
  int status;
  int top = lua_gettop(L);
  if (json == NULL || length > SLIPE_JSON_MAX_BYTES) {
    set_error(error, error_size, "JSON input exceeds 1 MiB");
    return -1;
  }
  parser.cursor = json;
  parser.end = json + length;
  parser.L = L;
  parser.error = error;
  parser.error_size = error_size;
  status = parser_value(&parser, 0);
  if (status == 0) {
    parser_skip_space(&parser);
    if (parser.cursor != parser.end) {
      set_error(error, error_size, "Trailing data after JSON value");
      status = -1;
    }
  }
  if (status != 0) {
    lua_settop(L, top);
    if (error != NULL && error_size != 0 && error[0] == '\0')
      set_error(error, error_size, "Invalid JSON");
  }
  return status;
}

typedef struct JsonEncoder {
  lua_State *L;
  SlipeJsonBuffer *buffer;
  const void *tables[SLIPE_JSON_MAX_DEPTH + 1];
  char *error;
  size_t error_size;
} JsonEncoder;

static int encode_value(JsonEncoder *encoder, int index, int depth);

static int table_is_marked_array(lua_State *L, int index) {
  int marked = 0;
  if (lua_getmetatable(L, index)) {
    lua_getfield(L, -1, "__slipe_json_array");
    marked = lua_toboolean(L, -1);
    lua_pop(L, 2);
  }
  return marked;
}

static int encode_array(JsonEncoder *encoder, int index, int depth,
                        int length) {
  int i;
  if (slipe_json_buffer_char(encoder->buffer, '[') != 0) return -1;
  for (i = 1; i <= length; i++) {
    if (i > 1 && slipe_json_buffer_char(encoder->buffer, ',') != 0) return -1;
    lua_rawgeti(encoder->L, index, i);
    if (encode_value(encoder, -1, depth + 1) != 0) {
      lua_pop(encoder->L, 1);
      return -1;
    }
    lua_pop(encoder->L, 1);
  }
  return slipe_json_buffer_char(encoder->buffer, ']');
}

static int encode_object(JsonEncoder *encoder, int index, int depth) {
  int first = 1;
  if (slipe_json_buffer_char(encoder->buffer, '{') != 0) return -1;
  lua_pushnil(encoder->L);
  while (lua_next(encoder->L, index) != 0) {
    size_t key_length;
    const char *key;
    if (lua_type(encoder->L, -2) != LUA_TSTRING) {
      set_error(encoder->error, encoder->error_size,
                "JSON object keys must be strings");
      lua_pop(encoder->L, 2);
      return -1;
    }
    key = lua_tolstring(encoder->L, -2, &key_length);
    if (!first && slipe_json_buffer_char(encoder->buffer, ',') != 0) {
      lua_pop(encoder->L, 2);
      return -1;
    }
    first = 0;
    if (slipe_json_buffer_string(encoder->buffer, key, key_length) != 0 ||
        slipe_json_buffer_char(encoder->buffer, ':') != 0 ||
        encode_value(encoder, -1, depth + 1) != 0) {
      lua_pop(encoder->L, 2);
      return -1;
    }
    lua_pop(encoder->L, 1);
  }
  return slipe_json_buffer_char(encoder->buffer, '}');
}

static int encode_table(JsonEncoder *encoder, int index, int depth) {
  lua_State *L = encoder->L;
  const void *identity = lua_topointer(L, index);
  int i;
  int numeric = 0;
  int string = 0;
  int count = 0;
  lua_Integer maximum = 0;
  int marked;
  if (depth > SLIPE_JSON_MAX_DEPTH) {
    set_error(encoder->error, encoder->error_size, "JSON nesting is too deep");
    return -1;
  }
  for (i = 0; i < depth; i++) {
    if (encoder->tables[i] == identity) {
      set_error(encoder->error, encoder->error_size, "JSON table contains a cycle");
      return -1;
    }
  }
  encoder->tables[depth] = identity;
  marked = table_is_marked_array(L, index);
  lua_pushnil(L);
  while (lua_next(L, index) != 0) {
    count++;
    if (lua_type(L, -2) == LUA_TNUMBER) {
      lua_Number number = lua_tonumber(L, -2);
      lua_Integer integer;
      if (!isfinite(number) || number < 1 || number > 9007199254740991.0) {
        lua_pop(L, 2);
        set_error(encoder->error, encoder->error_size, "Invalid JSON array index");
        return -1;
      }
      integer = (lua_Integer)number;
      if ((lua_Number)integer != number) {
        lua_pop(L, 2);
        set_error(encoder->error, encoder->error_size, "Invalid JSON array index");
        return -1;
      }
      numeric = 1;
      if (integer > maximum) maximum = integer;
    } else if (lua_type(L, -2) == LUA_TSTRING) {
      string = 1;
    } else {
      lua_pop(L, 2);
      set_error(encoder->error, encoder->error_size, "Unsupported JSON table key");
      return -1;
    }
    lua_pop(L, 1);
  }
  if (numeric && string) {
    set_error(encoder->error, encoder->error_size, "Cannot mix JSON array and object keys");
    return -1;
  }
  if (numeric && maximum != count) {
    set_error(encoder->error, encoder->error_size, "Sparse tables are not JSON arrays");
    return -1;
  }
  if (marked || numeric) return encode_array(encoder, index, depth, count);
  return encode_object(encoder, index, depth);
}

static int encode_number(JsonEncoder *encoder, lua_Number number) {
  char text[64];
  int length;
  char *comma;
  if (!isfinite(number)) {
    set_error(encoder->error, encoder->error_size,
              "NaN and Infinity are not valid JSON");
    return -1;
  }
  length = snprintf(text, sizeof(text), "%.17g", (double)number);
  if (length < 0 || (size_t)length >= sizeof(text)) return -1;
  comma = strchr(text, ',');
  if (comma != NULL) *comma = '.';
  return slipe_json_buffer_append_n(encoder->buffer, text, (size_t)length);
}

static int encode_value(JsonEncoder *encoder, int index, int depth) {
  size_t length;
  const char *text;
  switch (lua_type(encoder->L, index)) {
    case LUA_TNIL:
      return slipe_json_buffer_append(encoder->buffer, "null");
    case LUA_TBOOLEAN:
      return slipe_json_buffer_append(encoder->buffer,
                                      lua_toboolean(encoder->L, index)
                                          ? "true"
                                          : "false");
    case LUA_TNUMBER:
      return encode_number(encoder, lua_tonumber(encoder->L, index));
    case LUA_TLIGHTUSERDATA:
      if (lua_touserdata(encoder->L, index) == &json_null_sentinel) {
        return slipe_json_buffer_append(encoder->buffer, "null");
      }
      set_error(encoder->error, encoder->error_size,
                "Unsupported light userdata in JSON");
      return -1;
    case LUA_TSTRING:
      text = lua_tolstring(encoder->L, index, &length);
      if (slipe_json_buffer_string(encoder->buffer, text, length) != 0) {
        set_error(encoder->error, encoder->error_size,
                  "JSON output is oversized or contains invalid UTF-8");
        return -1;
      }
      return 0;
    case LUA_TTABLE:
      return encode_table(encoder, lua_absindex(encoder->L, index), depth);
    default:
      set_error(encoder->error, encoder->error_size,
                "Unsupported Lua value in JSON: %s",
                lua_typename(encoder->L, lua_type(encoder->L, index)));
      return -1;
  }
}

int slipe_json_encode(lua_State *L, int index, SlipeJsonBuffer *buffer,
                      char *error, size_t error_size) {
  JsonEncoder encoder;
  memset(&encoder, 0, sizeof(encoder));
  encoder.L = L;
  encoder.buffer = buffer;
  encoder.error = error;
  encoder.error_size = error_size;
  index = lua_absindex(L, index);
  if (encode_value(&encoder, index, 0) != 0 || buffer->failed) {
    if (error != NULL && error_size != 0 && error[0] == '\0')
      set_error(error, error_size, "JSON output exceeds 1 MiB");
    return -1;
  }
  return 0;
}
