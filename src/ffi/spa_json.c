#include <errno.h>
#include <limits.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdlib.h>

#include <spa/utils/json.h>

enum pipewireao_rtc_spa_json_kind {
    PIPEWIREAO_RTC_SPA_JSON_SCALAR = 1,
    PIPEWIREAO_RTC_SPA_JSON_OBJECT = 2,
    PIPEWIREAO_RTC_SPA_JSON_ARRAY = 3,
};

struct pipewireao_rtc_spa_json_cursor {
    struct spa_json iterator;
    const char *document;
    char *key;
    size_t key_size;
};

struct pipewireao_rtc_spa_json_token {
    const char *data;
    size_t size;
    int kind;
};

struct pipewireao_rtc_spa_json_error {
    int line;
    int column;
    const char *reason;
};

struct pipewireao_rtc_spa_json_entry {
    const char *key;
    size_t key_size;
    struct pipewireao_rtc_spa_json_token value;
};

static void set_location(const char *document, const char *position,
                         const char *reason,
                         struct pipewireao_rtc_spa_json_error *error)
{
    const char *cursor;

    if (error == NULL)
        return;
    error->line = 1;
    error->column = 1;
    error->reason = reason;
    if (document == NULL || position == NULL || position < document)
        return;
    for (cursor = document; cursor < position; cursor++) {
        if (*cursor == '\n') {
            error->line++;
            error->column = 1;
        } else {
            error->column++;
        }
    }
}

static void set_parser_error(struct pipewireao_rtc_spa_json_cursor *cursor,
                             const char *fallback,
                             struct pipewireao_rtc_spa_json_error *error)
{
    struct spa_error_location location;

    if (error == NULL)
        return;
    if (spa_json_get_error(&cursor->iterator, cursor->document, &location)) {
        error->line = location.line;
        error->column = location.col;
        error->reason = location.reason;
    } else {
        set_location(cursor->document, cursor->iterator.cur, fallback, error);
    }
}

static struct pipewireao_rtc_spa_json_cursor *new_container_cursor(
        const char *document, const char *data, size_t size, char type,
        bool relaxed, struct pipewireao_rtc_spa_json_error *error)
{
    struct pipewireao_rtc_spa_json_cursor *cursor;
    int result;

    if (document == NULL || data == NULL || size >= INT_MAX) {
        set_location(document, data, "Invalid SPA-JSON input", error);
        return NULL;
    }
    cursor = calloc(1, sizeof(*cursor));
    if (cursor == NULL) {
        set_location(document, data, "Cannot allocate SPA-JSON cursor", error);
        return NULL;
    }
    cursor->document = document;
    if (type == '{') {
        cursor->key_size = size + 1;
        cursor->key = malloc(cursor->key_size);
        if (cursor->key == NULL) {
            set_location(document, data, "Cannot allocate SPA-JSON key buffer", error);
            free(cursor);
            return NULL;
        }
    }
    if (type == '{') {
        result = relaxed
            ? spa_json_begin_object_relax(&cursor->iterator, data, size)
            : spa_json_begin_object(&cursor->iterator, data, size);
    } else {
        result = relaxed
            ? spa_json_begin_array_relax(&cursor->iterator, data, size)
            : spa_json_begin_array(&cursor->iterator, data, size);
    }
    if (result <= 0) {
        set_parser_error(cursor, type == '{' ? "Expected object" : "Expected array",
                         error);
        free(cursor->key);
        free(cursor);
        return NULL;
    }
    return cursor;
}

struct pipewireao_rtc_spa_json_cursor *
pipewireao_rtc_spa_json_root_object(
        const char *data, size_t size,
        struct pipewireao_rtc_spa_json_error *error)
{
    struct pipewireao_rtc_spa_json_cursor validator = { 0 };
    const char *token;
    int length, container_length;

    if (data == NULL || size >= INT_MAX) {
        set_location(data, data, "Invalid SPA-JSON input", error);
        return NULL;
    }
    validator.document = data;
    spa_json_init(&validator.iterator, data, size);
    length = spa_json_next(&validator.iterator, &token);
    if (length < 0) {
        set_parser_error(&validator, "Invalid configuration", error);
        return NULL;
    }
    if (spa_json_is_object(token, length)) {
        container_length = spa_json_container_len(&validator.iterator, token, length);
        if (container_length <= 0) {
            set_parser_error(&validator, "Invalid configuration object", error);
            return NULL;
        }
        length = spa_json_next(&validator.iterator, &token);
        if (length < 0) {
            set_parser_error(&validator, "Invalid data after configuration", error);
            return NULL;
        }
        if (length > 0) {
            set_location(data, token, "Unexpected data after configuration", error);
            return NULL;
        }
    }
    return new_container_cursor(data, data, size, '{', true, error);
}

struct pipewireao_rtc_spa_json_cursor *
pipewireao_rtc_spa_json_object(
        const char *document, const char *data, size_t size,
        struct pipewireao_rtc_spa_json_error *error)
{
    return new_container_cursor(document, data, size, '{', false, error);
}

struct pipewireao_rtc_spa_json_cursor *
pipewireao_rtc_spa_json_array(
        const char *document, const char *data, size_t size,
        struct pipewireao_rtc_spa_json_error *error)
{
    return new_container_cursor(document, data, size, '[', false, error);
}

static int set_token(struct pipewireao_rtc_spa_json_cursor *cursor,
                     const char *value, int length,
                     struct pipewireao_rtc_spa_json_token *token,
                     struct pipewireao_rtc_spa_json_error *error)
{
    if (spa_json_is_container(value, length)) {
        length = spa_json_container_len(&cursor->iterator, value, length);
        if (length <= 0) {
            set_parser_error(cursor, "Invalid SPA-JSON container", error);
            return -EINVAL;
        }
    }
    token->data = value;
    token->size = (size_t)length;
    token->kind = spa_json_is_object(value, length)
        ? PIPEWIREAO_RTC_SPA_JSON_OBJECT
        : spa_json_is_array(value, length)
            ? PIPEWIREAO_RTC_SPA_JSON_ARRAY
            : PIPEWIREAO_RTC_SPA_JSON_SCALAR;
    return 1;
}

int pipewireao_rtc_spa_json_array_next(
        struct pipewireao_rtc_spa_json_cursor *cursor,
        struct pipewireao_rtc_spa_json_token *token,
        struct pipewireao_rtc_spa_json_error *error)
{
    const char *value;
    int length;

    if (cursor == NULL || token == NULL)
        return -EINVAL;
    length = spa_json_next(&cursor->iterator, &value);
    if (length < 0) {
        set_parser_error(cursor, "Invalid SPA-JSON token", error);
        return length;
    }
    if (length == 0)
        return 0;
    return set_token(cursor, value, length, token, error);
}

int pipewireao_rtc_spa_json_object_next(
        struct pipewireao_rtc_spa_json_cursor *cursor,
        struct pipewireao_rtc_spa_json_entry *entry,
        struct pipewireao_rtc_spa_json_error *error)
{
    const char *value;
    size_t index;
    int length;

    if (cursor == NULL || entry == NULL || cursor->key == NULL)
        return -EINVAL;
    for (index = 0; index < cursor->key_size; index++)
        cursor->key[index] = (char)0xff;
    length = spa_json_object_next(&cursor->iterator, cursor->key,
                                  (int)cursor->key_size, &value);
    if (length < 0) {
        set_parser_error(cursor, "Invalid SPA-JSON object field", error);
        return length;
    }
    if (length == 0)
        return 0;
    index = cursor->key_size;
    while (index > 0 && (unsigned char)cursor->key[index - 1] == 0xff)
        index--;
    if (index == 0 || cursor->key[index - 1] != '\0') {
        set_location(cursor->document, value, "Invalid SPA-JSON object key", error);
        return -EPROTO;
    }
    entry->key = cursor->key;
    entry->key_size = index - 1;
    return set_token(cursor, value, length, &entry->value, error);
}

int pipewireao_rtc_spa_json_parse_string(
        const char *data, size_t size, char *result, size_t result_size,
        size_t *written)
{
    size_t index;
    int status;

    if (data == NULL || result == NULL || written == NULL ||
        size > INT_MAX || result_size > INT_MAX || result_size <= size)
        return -EINVAL;
    for (index = 0; index < result_size; index++)
        result[index] = (char)0xff;
    status = spa_json_parse_stringn(data, (int)size, result,
                                    (int)result_size);
    if (status <= 0)
        return status;
    index = result_size;
    while (index > 0 && (unsigned char)result[index - 1] == 0xff)
        index--;
    if (index == 0 || result[index - 1] != '\0')
        return -EPROTO;
    *written = index - 1;
    return 1;
}

void pipewireao_rtc_spa_json_cursor_destroy(
        struct pipewireao_rtc_spa_json_cursor *cursor)
{
    if (cursor != NULL)
        free(cursor->key);
    free(cursor);
}
