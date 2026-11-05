/* SPDX-License-Identifier: MIT */
#include "rtc-test-build.h"
/* Reuse upstream setup, teardown and script activation unchanged. The RTC only
 * adds its own component before loading the script under test. */
#define main upstream_script_tester_main
#include RTC_WP_SCRIPT_TESTER_SOURCE
#undef main

static void
rtc_tests_setup (ScriptRunnerFixture *f, gconstpointer data)
{
  base_tests_setup (f, data);
  load_component (f, "libwireplumber-module-ao-lua", "module");
}

gint
main (gint argc, gchar *argv[])
{
  g_test_init (&argc, &argv, NULL);
  wp_init (WP_INIT_ALL);
  g_assert_cmpint (argc, >=, 3);
  g_test_add ("/lua/rtc", ScriptRunnerFixture, argv,
      rtc_tests_setup, script_run, base_tests_teardown);
  return g_test_run ();
}
