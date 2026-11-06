/* SPDX-License-Identifier: MIT
 * In-process JSON boundary and receipt tests; no worker or service is
 * launched.
 */
#define main management_main
#include "../management.c"
#undef main

static void
strict_json (void)
{
  const char *invalid[] = { "{name:1}",
                            "{\"name\":1,}",
                            "[1,]",
                            "[1 2]",
                            "/* comment */ {}",
                            "{} {}",
                            "{\"n\":+1}",
                            "{\"n\":01}",
                            "{\"n\":1.}",
                            "{\"n\":.1}",
                            "{\"n\":NaN}",
                            "{\"n\":Infinity}",
                            "{\"n\":18446744073709551616}",
                            "{\"n\":-9223372036854775809}",
                            "{\"s\":\"\\u0000\"}",
                            "{\"s\":\"\001\"}",
                            "{\"s\":\"\xff\"}",
                            "{\"a\":1,\"a\":2}",
                            "{\"a\":1,\"\\u0061\":2}",
                            "{\"é\":1,\"\\u00e9\":2}",
                            "{\"nested\":{\"a\":1,\"a\":2}}",
                            "{\"nested\":[{\"/\":1,\"\\/\":2}]}",
                            NULL };
  for (int i = 0; invalid[i]; i++)
    {
      g_autoptr (json_object) value = parse_json (invalid[i]);
      g_assert_null (value);
    }
  g_autoptr (json_object) valid = parse_json (" {\"nested\":[{\"a\":1},{\"a\":2},null,true,false,"
                                              "\"é\\n\\u0061\",{\"é\":\"\\ud83d\\ude80\"}]} \t\r\n");
  g_assert_nonnull (valid);
  g_autoptr (GString) deep = g_string_new (NULL);
  for (int i = 0; i < 63; i++)
    g_string_append_c (deep, '[');
  g_string_append_c (deep, '0');
  for (int i = 0; i < 63; i++)
    g_string_append_c (deep, ']');
  g_autoptr (json_object) boundary = parse_json (deep->str);
  g_assert_nonnull (boundary);
  g_string_prepend_c (deep, '[');
  g_string_append_c (deep, ']');
  g_autoptr (json_object) excessive = parse_json (deep->str);
  g_assert_null (excessive);
}

static void
schema_types (void)
{
  g_autoptr (json_object) value
      = parse_json ("{\"string\":\"true\",\"number\":1,\"boolean\":true,\"null\":null}");
  g_assert_true (keys (value, "|string||number||boolean||null|"));
  g_assert_false (keys (value, "|string||boolean||null|"));
  g_assert_cmpstr (string_member (value, "string"), ==, "true");
  g_assert_null (string_member (value, "number"));
  g_assert_null (string_member (value, "null"));
  g_assert_null (string_member (value, "missing"));
  gboolean boolean = FALSE;
  g_assert_true (boolean_member (value, "boolean", &boolean));
  g_assert_true (boolean);
  boolean = FALSE;
  g_assert_false (boolean_member (value, "number", &boolean));
  g_assert_false (boolean_member (value, "string", &boolean));
  g_assert_false (boolean_member (value, "missing", &boolean));
  g_assert_false (boolean);
  g_autoptr (json_object) error = error_response ("id", "line\n\"quoted\"", TRUE);
  g_assert_cmpstr (json_object_to_json_string_ext (error, JSON_FORMAT), ==,
                   "{\"protocol\":\"pipewireao.management/1\",\"id\":\"id\",\"ok\":false,"
                   "\"error\":\"line\\n\\\"quoted\\\"\",\"unavailable\":true}");
  g_autoptr (json_object) rejected = preadmission_error ("Busy");
  g_assert_true (boolean_member (rejected, "admitted", &boolean));
  g_assert_false (boolean);
  g_assert_null (member (rejected, "unavailable"));
}

static void
numeric_payload_lifetime (void)
{
  const char *payload = "{\"serial\":18446744073709551615,\"negative\":-9223372036854775808,"
                        "\"coefficient\":1.234567890123456789e-123,\"zero\":0.0000,\"large\":"
                        "1e999}";
  json_object *value = parse_json (payload);
  g_assert_nonnull (value);
  g_assert_cmpstr (json_object_to_json_string_ext (value, JSON_FORMAT), ==, payload);
  g_assert_cmpuint (json_object_get_uint64 (member (value, "serial")), ==, G_MAXUINT64);
  json_object *response = result_response ("id", value);
  json_object_put (value);
  g_autoptr (json_object) record = receipt_record ("id", CONFIGURATION, "complete", response);
  json_object_put (response);
  json_object *retained = member (member (record, "response"), "result");
  g_assert_cmpstr (json_object_to_json_string_ext (retained, JSON_FORMAT), ==, payload);
  g_autoptr (json_object) null_response = result_response ("id", NULL);
  json_object *null_value = retained;
  g_assert_true (json_object_object_get_ex (null_response, "result", &null_value));
  g_assert_null (null_value);
}

static void
invalid_envelopes (void)
{
  const char *invalid[] = { "[]",
                            "null",
                            "{\"protocol\":1}",
                            "{\"protocol\":\"pipewireao.management/"
                            "1\",\"id\":\"00000000000000000000000000000001\","
                            "\"request\":{\"protocol\":\"pipewireao.configuration/"
                            "1\",\"op\":\"list\",\"arguments\":[]}}",
                            "{\"protocol\":\"pipewireao.management/"
                            "1\",\"id\":\"00000000000000000000000000000001\","
                            "\"request\":{\"protocol\":\"pipewireao.configuration/"
                            "1\",\"op\":true,\"arguments\":{}}}",
                            "{\"protocol\":\"pipewireao.management/"
                            "1\",\"id\":\"00000000000000000000000000000001\","
                            "\"request\":{\"protocol\":\"pipewireao.configuration/"
                            "1\",\"op\":\"register\",\"arguments\":{}}}",
                            "{\"protocol\":\"pipewireao.management/"
                            "1\",\"id\":\"00000000000000000000000000000001\","
                            "\"request\":{\"protocol\":\"pipewireao.configuration/"
                            "1\",\"op\":\"Start\",\"arguments\":{}}}",
                            "{\"protocol\":\"pipewireao.management/"
                            "1\",\"id\":\"00000000000000000000000000000001\","
                            "\"request\":{\"protocol\":\"pipewireao.configuration/"
                            "1\",\"op\":\"history\",\"arguments\":{}}}",
                            NULL };
  Management management = { 0 };
  for (int i = 0; invalid[i]; i++)
    {
      gboolean admitted = FALSE, ok = TRUE;
      g_autoptr (json_object) response = dispatch (&management, invalid[i], -1, &admitted);
      g_assert_false (admitted);
      g_assert_true (boolean_member (response, "ok", &ok));
      g_assert_false (ok);
    }
}

static void
receipt_compatibility (void)
{
  g_autofree char *directory = g_dir_make_tmp ("rtc-management-json-XXXXXX", NULL);
  g_assert_nonnull (directory);
  Management management = { .state_root = directory, .configuration_root = directory };
  management.root_fd = open (directory, O_DIRECTORY | O_RDONLY | O_CLOEXEC);
  g_assert_cmpint (management.root_fd, >=, 0);
  const char *id = "00000000000000000000000000000001";
  /* Existing WpSpaJson records were plain JSON, without a digest of serialized
   * request bytes. Whitespace and numeric -0 normalization do not affect
   * identity. */
  const char *old_record = "{ \"id\": \"00000000000000000000000000000001\", "
                           "\"domain\": \"pipewireao.configuration/1\", \"state\": \"complete\", "
                           "\"response\": { \"ok\": true, \"result\": { \"serial\": "
                           "18446744073709551615, "
                           "\"coefficient\": 1.234567890123456789e-123 } } }";
  g_autofree char *filename
      = g_build_filename (directory, "00000000000000000000000000000001.json", NULL);
  g_assert_true (g_file_set_contents (filename, old_record, -1, NULL));
  g_assert_cmpint (recover_receipts (&management), ==, 1);
  g_autoptr (json_object) retained = read_receipt (&management, id);
  g_assert_cmpstr (string_member (retained, "state"), ==, "complete");
  json_object *result = member (member (retained, "response"), "result");
  g_assert_cmpuint (json_object_get_uint64 (member (result, "serial")), ==, G_MAXUINT64);
  g_assert_cmpstr (json_object_to_json_string_ext (member (result, "coefficient"), JSON_FORMAT), ==,
                   "1.234567890123456789e-123");
  gboolean admitted = FALSE;
  g_autoptr (json_object) duplicate
      = dispatch (&management,
                  "{\"protocol\":\"pipewireao.management/"
                  "1\",\"id\":\"00000000000000000000000000000001\","
                  "\"request\":{\"protocol\":\"pipewireao.configuration/"
                  "1\",\"op\":\"get\",\"arguments\":{}}}",
                  -1, &admitted);
  g_assert_true (admitted);
  g_mutex_unlock (&management.operation);
  g_assert_cmpstr (string_member (duplicate, "error"), ==,
                   "duplicate request identity; query its receipt");
  g_assert_cmpint (management.worker_pid, ==, 0);
  g_autoptr (json_object) accepted = receipt_record (id, CONFIGURATION, "accepted", NULL);
  g_assert_true (durable_receipt (&management, id, accepted));
  g_assert_cmpint (recover_receipts (&management), ==, 1);
  g_autoptr (json_object) recovered = read_receipt (&management, id);
  g_assert_cmpstr (string_member (recovered, "state"), ==, "unknown");
  g_assert_null (member (recovered, "response"));
  g_assert_cmpint (close (management.root_fd), ==, 0);
  g_assert_cmpint (unlink (filename), ==, 0);
  g_assert_cmpint (rmdir (directory), ==, 0);
  g_mutex_clear (&management.operation);
}

int
main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);
  g_test_add_func ("/management/json/strict", strict_json);
  g_test_add_func ("/management/json/schema", schema_types);
  g_test_add_func ("/management/json/numeric-lifetime", numeric_payload_lifetime);
  g_test_add_func ("/management/json/envelope", invalid_envelopes);
  g_test_add_func ("/management/json/receipt", receipt_compatibility);
  return g_test_run ();
}
