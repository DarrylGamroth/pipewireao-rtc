/* PipeWireAO RTC
 * SPDX-License-Identifier: MIT
 * Isolated application-host checks; never connects to the user's service.
 */
#include "test-server.h"
#include <wp/wp.h>
#include <glib/gstdio.h>
#include <gio/gio.h>
#include <signal.h>

typedef struct {
  GMainLoop *loop;
  GSubprocess *process;
  gboolean timeout;
} Wait;

static void
on_waited (GObject *object, GAsyncResult *result, gpointer data)
{
  Wait *wait = data;
  g_autoptr (GError) error = NULL;
  g_assert_true (g_subprocess_wait_finish (G_SUBPROCESS (object), result, &error));
  g_assert_no_error (error);
  g_main_loop_quit (wait->loop);
}

static gboolean
on_timeout (gpointer data)
{
  Wait *wait = data;
  wait->timeout = TRUE;
  g_subprocess_force_exit (wait->process);
  return G_SOURCE_REMOVE;
}

static void
wait_status (GSubprocess *process, gint expected)
{
  Wait wait = { g_main_loop_new (NULL, FALSE), process, FALSE };
  guint timeout = g_timeout_add_seconds (5, on_timeout, &wait);
  g_subprocess_wait_async (process, NULL, on_waited, &wait);
  g_main_loop_run (wait.loop);
  if (!wait.timeout) g_source_remove (timeout);
  g_main_loop_unref (wait.loop);
  g_assert_false (wait.timeout);
  g_assert_true (g_subprocess_get_if_exited (process));
  g_assert_cmpint (g_subprocess_get_exit_status (process), ==, expected);
}

static GSubprocess *
start (const gchar *config)
{
  g_autoptr (GError) error = NULL;
  g_autoptr (GSubprocessLauncher) launcher = g_subprocess_launcher_new (G_SUBPROCESS_FLAGS_NONE);
  g_autofree gchar *directory = g_path_get_dirname (config);
  if (g_file_test (directory, G_FILE_TEST_IS_DIR))
    g_subprocess_launcher_set_cwd (launcher, directory);
  GSubprocess *process = g_subprocess_launcher_spawn (launcher,
      &error, g_getenv ("RTC_TEST_BINARY"), "-c", config, NULL);
  g_assert_no_error (error);
  return process;
}

static int
find_ready (void *data, struct pw_global *global)
{
  if (!g_str_equal (pw_global_get_type (global), PW_TYPE_INTERFACE_Client))
    return 0;
  const struct pw_properties *props = pw_impl_client_get_properties (pw_global_get_object (global));
  if (g_strcmp0 (pw_properties_get (props, "pipewireao.rtc.test-ready"), "true") == 0) {
    g_assert_cmpstr (pw_properties_get (props, PW_KEY_APP_NAME), ==, "PipeWireAO RTC");
    g_assert_cmpstr (pw_properties_get (props, PW_KEY_APP_ID), ==, "org.pipewireao.rtc");
    g_assert_cmpstr (pw_properties_get (props, "wireplumber.profile"), ==, "ao-rtc");
    g_assert_cmpstr (pw_properties_get (props, "wireplumber.daemon"), ==, "false");
    g_assert_cmpstr (pw_properties_get (props, "pipewireao.rtc.quit-complete"), ==, "false");
    *(gboolean *) data = TRUE;
    return 1;
  }
  return 0;
}

static void
host_connection (gconstpointer signal_exit)
{
  WpTestServer server = {0};
  wp_test_server_setup (&server);
  g_autoptr (GError) error = NULL;
  g_autofree gchar *directory = g_dir_make_tmp ("rtc-host-test-XXXXXX", &error);
  g_assert_no_error (error);
  g_autofree gchar *path = g_build_filename (directory, "rtc.conf", NULL);
  /* Try to override the native application's invariant properties. The fixed
   * profile must still run; the injected main profile must never be selected. */
  g_autofree gchar *config = g_strdup_printf (
      "context.properties = { remote.name = \"%s\" application.name = intruder application.id = intruder "
      "wireplumber.profile = main wireplumber.daemon = true "
      "pipewireao.rtc.quit-complete = true }\n"
      "context.modules = [ { name = libpipewire-module-protocol-native } ]\n"
      "wireplumber.profiles = { ao-rtc = { test.ready = required } "
      "main = { test.missing = required } }\n"
      "wireplumber.components = [ "
      "{ name = libwireplumber-module-lua-scripting type = module provides = support.lua } "
      "{ name = \"%s\" type = script/lua provides = test.ready requires = [ support.lua ] } ]\n",
      server.name, g_getenv ("RTC_TEST_SCRIPT"));
  g_assert_true (g_file_set_contents (path, config, -1, &error));
  g_assert_no_error (error);
  g_autofree gchar *shadow = g_build_filename (directory, "host-ready.lua", NULL);
  g_assert_true (g_file_set_contents (shadow, "error ('untrusted cwd entrypoint')", -1, &error));
  g_assert_no_error (error);
  g_autofree gchar *fragments = g_strconcat (path, ".d", NULL);
  g_assert_cmpint (g_mkdir (fragments, 0700), ==, 0);
  g_autofree gchar *fragment = g_build_filename (fragments, "99-intruder.conf", NULL);
  g_assert_true (g_file_set_contents (fragment,
      "context.properties = { remote.name = nonexistent-rtc-server }", -1, &error));
  g_assert_no_error (error);
  g_autoptr (GSubprocess) process = start (path);
  gboolean ready = FALSE;
  gint64 deadline = g_get_monotonic_time () + 5000000;
  while (!ready && g_get_monotonic_time () < deadline) {
    pw_thread_loop_lock (server.thread_loop);
    pw_context_for_each_global (server.context, find_ready, &ready);
    pw_thread_loop_unlock (server.thread_loop);
    if (!ready) g_usleep (1000);
  }
  if (!ready) g_subprocess_force_exit (process);
  g_assert_true (ready);
  if (GPOINTER_TO_INT (signal_exit)) {
    g_subprocess_send_signal (process, SIGTERM);
    wait_status (process, 0);
    wp_test_server_teardown (&server);
  } else {
    wp_test_server_teardown (&server);
    wait_status (process, 69);
  }
  g_remove (fragment);
  g_rmdir (fragments);
  g_remove (shadow);
  g_remove (path);
  g_rmdir (directory);
}

/* Replacing only test paths preserves the maintained SPA-JSON declaration. */
static gchar *
replace (const gchar *text, const gchar *key, const gchar *value)
{
  g_auto (GStrv) parts = g_strsplit (text, key, -1);
  return g_strjoinv (value, parts);
}

static void
public_session_status (void)
{
  WpTestServer server = {0};
  wp_test_server_setup (&server);
  g_autoptr (GError) error = NULL;
  g_autofree gchar *directory = g_dir_make_tmp ("rtc-public-session-XXXXXX", &error);
  g_assert_no_error (error);
  g_autofree gchar *path = g_build_filename (directory, "rtc.conf", NULL);
  g_autofree gchar *client_path = g_build_filename (directory, "client.conf", NULL);
  g_autofree gchar *template_path = g_build_filename (g_getenv ("RTC_TEST_SOURCE"),
      "public-session.conf.in", NULL);
  g_autofree gchar *template = NULL;
  g_assert_true (g_file_get_contents (template_path, &template, NULL, &error));
  g_assert_no_error (error);
  g_autofree gchar *remote = replace (template, "@REMOTE@", server.name);
  g_autofree gchar *policy_path = g_build_filename (g_getenv ("RTC_TEST_SOURCE"),
      "../scripts/ao/session.lua", NULL);
  g_autofree gchar *config = replace (remote, "@POLICY@", policy_path);
  g_assert_true (g_file_set_contents (path, config, -1, &error));
  g_assert_no_error (error);
  g_autoptr (GSubprocess) process = start (path);
  const gchar *pid = g_subprocess_get_identifier (process);
  g_assert_nonnull (pid);
  g_autofree gchar *client_script = g_build_filename (g_getenv ("RTC_TEST_SOURCE"),
      "scripts/session-status-client.lua", NULL);
  g_autofree gchar *client_config = g_strdup_printf (
      "context.properties = { remote.name = \"%s\" support.dbus = false }\n"
      "context.modules = [ { name = libpipewire-module-protocol-native } "
      "{ name = libpipewire-module-client-node } ]\n"
      "wireplumber.profiles = { ao-rtc = { test.client = required } }\n"
      "wireplumber.components = [ "
      "{ name = libwireplumber-module-lua-scripting type = module provides = support.lua } "
      "{ name = libwireplumber-module-ao-control-endpoint type = module provides = test.controller "
      "arguments = { plugin.name = test-status-controller node.name = test-status-controller "
      "profile = pipewireao.rtc.controller/1 instance = 303 } } "
      "{ name = \"%s\" type = script/lua provides = test.client "
      "requires = [ support.lua test.controller ] arguments = { server-pid = %s } } ]\n",
      server.name, client_script, pid);
  g_assert_true (g_file_set_contents (client_path, client_config, -1, &error));
  g_assert_no_error (error);
  g_autoptr (GSubprocess) client = start (client_path);
  wait_status (client, 0);
  g_subprocess_send_signal (process, SIGTERM);
  wait_status (process, 0);
  wp_test_server_teardown (&server);
  g_remove (client_path);
  g_remove (path);
  g_rmdir (directory);
}

static void
missing_configuration (void)
{
  g_autoptr (GSubprocess) process = start ("/invalid/rtc.conf");
  wait_status (process, 78);
}

int
main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);
  wp_init (WP_INIT_ALL);
  g_test_add_func ("/rtc-host/missing-configuration", missing_configuration);
  g_test_add_func ("/rtc-host/public-session-status", public_session_status);
  g_test_add_data_func ("/rtc-host/termination", GINT_TO_POINTER (1), host_connection);
  g_test_add_data_func ("/rtc-host/connection-lost", GINT_TO_POINTER (0), host_connection);
  return g_test_run ();
}
