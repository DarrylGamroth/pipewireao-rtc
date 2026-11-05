/* PipeWireAO RTC
 * SPDX-License-Identifier: MIT
 *
 * Application host using the public libwireplumber API. Lifecycle policy lives
 * in this repository's Lua components; the WirePlumber daemon is independent.
 */
#include "rtc-build.h"
#include <wp/wp.h>
#include <glib-unix.h>
#include <pipewire/keys.h>
#include <locale.h>
#include <stdio.h>

enum { EXIT_USAGE = 64, EXIT_UNAVAILABLE = 69, EXIT_SOFTWARE = 70,
  EXIT_CONFIG = 78 };

typedef struct {
  WpCore *core;
  GMainLoop *loop;
  GCancellable *activation;
  guint signals[2];
  gboolean stopping;
  gint status;
} RtcHost;

static void
host_clear (gpointer data)
{
  RtcHost *host = data;
  g_clear_object (&host->activation);
  g_clear_object (&host->core);
  g_clear_pointer (&host->loop, g_main_loop_unref);
}

static void
host_stop (RtcHost *host, gint status)
{
  if (host->stopping)
    return;
  host->stopping = TRUE;
  host->status = status;
  g_main_loop_quit (host->loop);
}

static void
on_disconnected (WpCore *core, RtcHost *host)
{
  g_autoptr (WpProperties) props = wp_core_get_properties (core);
  /* Only an acknowledged Quit with a successful publication fence sets this
   * private property. A server loss or policy fault is an unsuccessful run. */
  gboolean quit = g_strcmp0 (wp_properties_get (props,
      "pipewireao.rtc.quit-complete"), "true") == 0;
  if (!quit && !host->stopping)
    g_printerr ("pipewireao-rtc: PipeWire connection lost\n");
  host_stop (host, quit ? 0 : EXIT_UNAVAILABLE);
}

static gboolean
on_signal (gpointer data)
{
  host_stop (data, 0);
  return G_SOURCE_CONTINUE;
}

static void
on_activated (GObject *object, GAsyncResult *result, gpointer data)
{
  RtcHost *host = data;
  g_autoptr (GError) error = NULL;
  if (!wp_object_activate_finish (WP_OBJECT (object), result, &error) &&
      !host->stopping) {
    gint status = EXIT_SOFTWARE;
    if (g_error_matches (error, WP_DOMAIN_LIBRARY,
        WP_LIBRARY_ERROR_SERVICE_UNAVAILABLE))
      status = EXIT_UNAVAILABLE;
    else if (g_error_matches (error, WP_DOMAIN_LIBRARY,
        WP_LIBRARY_ERROR_INVALID_ARGUMENT))
      status = EXIT_CONFIG;
    g_printerr ("pipewireao-rtc: initialization failed: %s\n", error->message);
    host_stop (host, status);
  }
  /* The callback retains its owner even if a signal stops startup. */
  g_rc_box_release_full (host, host_clear);
}

static void
set_default_search_path (const gchar *variable, const gchar *application,
    const gchar *library)
{
  if (!g_getenv (variable)) {
    g_autofree gchar *path = g_strjoin (G_SEARCHPATH_SEPARATOR_S,
        application, library, NULL);
    g_setenv (variable, path, FALSE);
  }
}

int
main (int argc, char **argv)
{
  g_autoptr (GOptionContext) options = NULL;
  g_autoptr (GError) error = NULL;
  g_autofree gchar *config_file = NULL;
  g_autoptr (WpConf) conf = NULL;
  gboolean version = FALSE;
  GOptionEntry entries[] = {
    { "config-file", 'c', 0, G_OPTION_ARG_FILENAME, &config_file,
      "Generated RTC configuration (required)", "FILE" },
    { "version", 'v', 0, G_OPTION_ARG_NONE, &version,
      "Show linked library version", NULL },
    { NULL }
  };

  setlocale (LC_ALL, "");
  setlocale (LC_NUMERIC, "C");
  options = g_option_context_new ("- headless PipeWireAO RTC");
  g_option_context_add_main_entries (options, entries, NULL);
  if (!g_option_context_parse (options, &argc, &argv, &error)) {
    g_printerr ("pipewireao-rtc: %s\n", error->message);
    return EXIT_USAGE;
  }
  if (argc != 1 || (!version && !config_file)) {
    g_printerr ("Usage: pipewireao-rtc -c FILE\n");
    return EXIT_USAGE;
  }
  if (version) {
    g_print ("pipewireao-rtc (libwireplumber %s)\n", wp_get_library_version ());
    return 0;
  }

  set_default_search_path ("WIREPLUMBER_MODULE_DIR", RTC_MODULE_DIR, WP_MODULE_DIR);
  set_default_search_path ("WIREPLUMBER_DATA_DIR", RTC_DATA_DIR, WP_DATA_DIR);
  wp_init (WP_INIT_ALL);
  conf = wp_conf_new_open (config_file,
      wp_properties_new ("no-fragments", "true", NULL), &error);
  if (!conf) {
    g_printerr ("pipewireao-rtc: configuration failed: %s\n", error->message);
    return EXIT_CONFIG;
  }

  RtcHost *host = g_rc_box_new0 (RtcHost);
  host->loop = g_main_loop_new (NULL, FALSE);
  host->activation = g_cancellable_new ();
  host->core = wp_core_new (NULL, g_steal_pointer (&conf), wp_properties_new (
      PW_KEY_APP_NAME, "PipeWireAO RTC",
      PW_KEY_APP_ID, "org.pipewireao.rtc",
      "wireplumber.profile", "ao-rtc", NULL));
  if (!host->core) {
    g_printerr ("pipewireao-rtc: could not create application core\n");
    g_rc_box_release_full (host, host_clear);
    return EXIT_SOFTWARE;
  }
  /* WpConf context.properties are merged by WpCore's constructor. Reassert
   * application invariants after that merge and before connecting/loading. */
  wp_core_update_properties (host->core, wp_properties_new (
      PW_KEY_APP_NAME, "PipeWireAO RTC", PW_KEY_APP_ID, "org.pipewireao.rtc",
      "wireplumber.profile", "ao-rtc", "wireplumber.daemon", "false",
      "pipewireao.rtc.quit-complete", "false", NULL));
  g_signal_connect (host->core, "disconnected", G_CALLBACK (on_disconnected), host);
  host->signals[0] = g_unix_signal_add (SIGINT, on_signal, host);
  host->signals[1] = g_unix_signal_add (SIGTERM, on_signal, host);
  wp_object_activate (WP_OBJECT (host->core),
      WP_CORE_FEATURE_CONNECTED | WP_CORE_FEATURE_COMPONENTS, host->activation,
      on_activated, g_rc_box_acquire (host));
  /* An activation error may complete synchronously. */
  if (!host->stopping)
    g_main_loop_run (host->loop);

  for (guint i = 0; i < G_N_ELEMENTS (host->signals); i++)
    g_clear_handle_id (&host->signals[i], g_source_remove);
  g_cancellable_cancel (host->activation);
  g_signal_handlers_disconnect_by_data (host->core, host);
  wp_core_disconnect (host->core);
  gint status = host->status;
  g_clear_object (&host->core);
  /* Dispatch already queued cancellation completions before dropping ownership. */
  for (guint i = 0; i < 32 && g_main_context_pending (NULL); i++)
    g_main_context_iteration (NULL, FALSE);
  g_rc_box_release_full (host, host_clear);
  return status;
}
