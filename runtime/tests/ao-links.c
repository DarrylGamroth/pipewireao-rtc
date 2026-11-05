/* PipeWireAO RTC — SPDX-License-Identifier: MIT
 * Direct public WpLink lifetime tests. Filter setup derived from WirePlumber's
 * SPDX MIT si-standard-link tests; no SessionItem extension is used. */
#include "base-test-fixture.h"
#include "../modules/ao-link.h"
#include <pipewire/filter.h>
#include <spa/param/ndarray-utils.h>
GType wp_ao_control_endpoint_get_type (void);

typedef struct { WpBaseTestFixture base; } TestFixture;
/* Real inactive NDArray filters provide multiple non-audio ports in opposite
 * declaration orders. No processing callback, data thread or GPU is required. */
static struct pw_filter *
make_ndarray_filter (TestFixture * f, const gchar * name, enum pw_direction direction)
{
  struct pw_filter *filter = pw_filter_new (wp_core_get_pw_core (f->base.core),
      name, pw_properties_new (PW_KEY_NODE_NAME, name, PW_KEY_MEDIA_CLASS,
          direction == PW_DIRECTION_OUTPUT ? "Stream/Output/NDArray" : "Stream/Input/NDArray", NULL));
  guint8 buffer[1024];
  struct spa_pod_builder builder = SPA_POD_BUILDER_INIT (buffer, sizeof (buffer));
  const guint32 shape[] = { 4 };
  const struct spa_pod *format = spa_pod_builder_add_object (&builder,
      SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
      SPA_FORMAT_mediaType, SPA_POD_Id (SPA_MEDIA_TYPE_application),
      SPA_FORMAT_mediaSubtype, SPA_POD_Id (SPA_MEDIA_SUBTYPE_ndarray),
      SPA_FORMAT_NDARRAY_elementType, SPA_POD_Id (SPA_ELEMENT_TYPE_F32_LE),
      SPA_FORMAT_NDARRAY_shape, SPA_POD_Array (sizeof (guint32), SPA_TYPE_Int, 1, shape),
      SPA_FORMAT_NDARRAY_layout, SPA_POD_Id (SPA_NDARRAY_LAYOUT_ROW_MAJOR),
      SPA_FORMAT_NDARRAY_rate, SPA_POD_Fraction (&SPA_FRACTION (10, 1)),
      SPA_FORMAT_NDARRAY_schema, SPA_POD_String ("test.exact/1"));
  g_assert_nonnull (filter);
  for (guint i = 0; i < 2; i++) {
    guint index = direction == PW_DIRECTION_OUTPUT ? 1 - i : i;
    g_autofree gchar *port_name = g_strdup_printf ("science-%u", index);
    g_assert_nonnull (pw_filter_add_port (filter, direction, PW_FILTER_PORT_FLAG_NONE,
        1, pw_properties_new (PW_KEY_PORT_NAME, port_name, PW_KEY_PORT_CONTROL,
            direction == PW_DIRECTION_OUTPUT && index == 1 ? "true" : "false", NULL), &format, 1));
  }
  g_assert_cmpint (pw_filter_connect (filter, PW_FILTER_FLAG_INACTIVE, NULL, 0), ==, 0);
  return filter;
}

static guint32
named_port_id (WpNode * node, const gchar * name)
{
  g_autoptr (WpIterator) iterator = wp_node_new_ports_iterator (node);
  g_auto (GValue) value = G_VALUE_INIT;
  while (wp_iterator_next (iterator, &value)) {
    WpPort *port = g_value_get_object (&value);
    g_autoptr (WpProperties) props = wp_pipewire_object_get_properties (WP_PIPEWIRE_OBJECT (port));
    if (!g_strcmp0 (wp_properties_get (props, PW_KEY_PORT_NAME), name))
      return wp_proxy_get_bound_id (WP_PROXY (port));
    g_value_unset (&value);
  }
  g_assert_not_reached ();
}


struct exact_fixture {
  struct pw_filter *source, *sink;
  WpObjectManager *manager;
  guint32 output_node, input_node, output_id, input_id, control_id;
};

static void
setup (TestFixture *f, gconstpointer data)
{
  (void) data;
  wp_base_test_fixture_setup (&f->base, 0);
  g_autoptr (WpTestServerLocker) lock = wp_test_server_locker_new (&f->base.server);
  g_assert_nonnull (pw_context_load_module (f->base.server.context,
      "libpipewire-module-link-factory", "allow.link.passive=true", NULL));
}

static void
teardown (TestFixture *f, gconstpointer data)
{
  (void) data;
  wp_base_test_fixture_teardown (&f->base);
}

static void
exact_fixture_init (TestFixture *f, struct exact_fixture *exact)
{
  exact->source = make_ndarray_filter (f, "exact-source", PW_DIRECTION_OUTPUT);
  exact->sink = make_ndarray_filter (f, "exact-sink", PW_DIRECTION_INPUT);
  exact->manager = wp_object_manager_new ();
  wp_object_manager_add_interest (exact->manager, WP_TYPE_NODE, NULL);
  wp_object_manager_add_interest (exact->manager, WP_TYPE_LINK, NULL);
  wp_object_manager_request_object_features (exact->manager, WP_TYPE_NODE,
      WP_PIPEWIRE_OBJECT_FEATURES_MINIMAL | WP_NODE_FEATURE_PORTS);
  wp_object_manager_request_object_features (exact->manager, WP_TYPE_LINK,
      WP_PIPEWIRE_OBJECT_FEATURES_MINIMAL);
  test_ensure_object_manager_is_installed (exact->manager, f->base.core, f->base.loop);
  g_autoptr (WpNode) source = NULL, sink = NULL;
  do {
    g_clear_object (&source); g_clear_object (&sink);
    source = wp_object_manager_lookup (exact->manager, WP_TYPE_NODE,
        WP_CONSTRAINT_TYPE_PW_PROPERTY, PW_KEY_NODE_NAME, "=s", "exact-source", NULL);
    sink = wp_object_manager_lookup (exact->manager, WP_TYPE_NODE,
        WP_CONSTRAINT_TYPE_PW_PROPERTY, PW_KEY_NODE_NAME, "=s", "exact-sink", NULL);
    if (!source || !sink) g_main_context_iteration (f->base.context, TRUE);
  } while (!source || !sink);
  exact->output_node = wp_proxy_get_bound_id (WP_PROXY (source));
  exact->input_node = wp_proxy_get_bound_id (WP_PROXY (sink));
  exact->output_id = named_port_id (source, "science-0");
  exact->control_id = named_port_id (source, "science-1");
  exact->input_id = named_port_id (sink, "science-1");
}

static void
exact_fixture_clear (struct exact_fixture *exact)
{
  g_clear_object (&exact->manager);
  pw_filter_destroy (exact->source); pw_filter_destroy (exact->sink);
}

static WpLink *
create_link (TestFixture *f, struct exact_fixture *exact, gboolean control)
{
  WpProperties *props = wp_properties_new (PW_KEY_LINK_PASSIVE, "true",
      PW_KEY_OBJECT_LINGER, "false", PW_KEY_OBJECT_PATH, "test/exact-link", NULL);
  wp_properties_setf (props, PW_KEY_LINK_OUTPUT_NODE, "%u", exact->output_node);
  wp_properties_setf (props, PW_KEY_LINK_INPUT_NODE, "%u", exact->input_node);
  wp_properties_setf (props, PW_KEY_LINK_OUTPUT_PORT, "%u", control ? exact->control_id : exact->output_id);
  wp_properties_setf (props, PW_KEY_LINK_INPUT_PORT, "%u", exact->input_id);
  return wp_link_new_from_factory (f->base.core, "link-factory", props);
}

struct operation_result { guint calls; gboolean success; GError *error; };
static void
activation_finished (WpObject *object, GAsyncResult *res, gpointer data)
{
  struct operation_result *result = data;
  result->calls++;
  result->success = wp_object_activate_finish (object, res, &result->error);
}
static void
retirement_finished (GObject *object, GAsyncResult *res, gpointer data)
{
  struct operation_result *result = data;
  result->calls++;
  result->success = ao_link_retire_finish (WP_LINK (object), res, &result->error);
  g_assert_null (wp_proxy_get_pw_proxy (WP_PROXY (object)));
}
static void
wait_operation (TestFixture *f, struct operation_result *result)
{
  while (!result->calls) g_main_context_iteration (f->base.context, TRUE);
  g_assert_cmpuint (result->calls, ==, 1);
}
static void
assert_link_absent (TestFixture *f, struct exact_fixture *exact)
{
  wp_core_sync (f->base.core, NULL, (GAsyncReadyCallback) test_core_done_cb, &f->base);
  g_main_loop_run (f->base.loop);
  g_autoptr (WpLink) link = wp_object_manager_lookup (exact->manager, WP_TYPE_LINK,
      WP_CONSTRAINT_TYPE_PW_PROPERTY, PW_KEY_OBJECT_PATH, "=s", "test/exact-link", NULL);
  g_assert_null (link);
  g_assert_cmpuint (wp_object_manager_get_n_objects (exact->manager), ==, 2);
}

static void
exact_link (TestFixture *f, gconstpointer data)
{
  const gchar *stage = data;
  struct exact_fixture exact = {0}; exact_fixture_init (f, &exact);
  gboolean control = g_str_equal (stage, "control-selection");
  g_autoptr (WpLink) link = create_link (f, &exact, control);
  struct operation_result activation = {0}, retirement = {0};
  if (!g_str_equal (stage, "never-activated")) {
    wp_object_activate (WP_OBJECT (link), WP_PIPEWIRE_OBJECT_FEATURES_MINIMAL,
        NULL, (GAsyncReadyCallback) activation_finished, &activation);
    wait_operation (f, &activation);
    g_assert_true (activation.success); g_assert_no_error (activation.error);
    guint32 out, in, out_node, in_node;
    wp_link_get_linked_object_ids (link, &out_node, &out, &in_node, &in);
    g_assert_cmpuint (out_node, ==, exact.output_node);
    g_assert_cmpuint (in_node, ==, exact.input_node);
    g_assert_cmpuint (out, ==, control ? exact.control_id : exact.output_id);
    g_assert_cmpuint (in, ==, exact.input_id);
    g_autoptr (WpProperties) props = wp_pipewire_object_get_properties (WP_PIPEWIRE_OBJECT (link));
    g_assert_cmpstr (wp_properties_get (props, PW_KEY_LINK_PASSIVE), ==, "true");
    g_assert_cmpstr (wp_properties_get (props, PW_KEY_OBJECT_LINGER), ==, "false");
    g_assert_cmpstr (wp_properties_get (props, PW_KEY_OBJECT_PATH), ==, "test/exact-link");
  }
  ao_link_retire (link, retirement_finished, &retirement);
  g_assert_cmpuint (retirement.calls, ==, 0);
  wait_operation (f, &retirement);
  g_assert_true (retirement.success); g_assert_no_error (retirement.error);
  assert_link_absent (f, &exact);
  if (g_str_equal (stage, "repeat-retirement")) {
    retirement = (struct operation_result) {0};
    ao_link_retire (link, retirement_finished, &retirement);
    wait_operation (f, &retirement);
    g_assert_true (retirement.success); g_assert_no_error (retirement.error);
  }
  if (g_str_equal (stage, "fresh-generation")) {
    g_autoptr (WpLink) next = create_link (f, &exact, FALSE);
    activation = (struct operation_result) {0}; retirement = (struct operation_result) {0};
    wp_object_activate (WP_OBJECT (next), WP_PIPEWIRE_OBJECT_FEATURES_MINIMAL,
        NULL, (GAsyncReadyCallback) activation_finished, &activation);
    wait_operation (f, &activation); g_assert_true (activation.success);
    ao_link_retire (next, retirement_finished, &retirement);
    wait_operation (f, &retirement); g_assert_true (retirement.success);
    assert_link_absent (f, &exact);
  }
  exact_fixture_clear (&exact);
}

struct trigger { struct operation_result *retirement; guint calls; };
static void
retire_created (WpProxy *proxy, gpointer native, struct trigger *trigger)
{
  (void) native;
  trigger->calls++;
  g_assert_nonnull (wp_proxy_get_pw_proxy (proxy));
  g_assert_false (wp_object_test_active_features (WP_OBJECT (proxy), WP_PROXY_FEATURE_BOUND));
  ao_link_retire (WP_LINK (proxy), retirement_finished, trigger->retirement);
  g_assert_nonnull (wp_proxy_get_pw_proxy (proxy)); /* not destroyed in this stack */
}
static void
retire_bound (WpProxy *proxy, guint id, struct trigger *trigger)
{
  (void) id;
  trigger->calls++;
  g_assert_true (wp_object_test_active_features (WP_OBJECT (proxy), WP_PROXY_FEATURE_BOUND));
  ao_link_retire (WP_LINK (proxy), retirement_finished, trigger->retirement);
  g_assert_nonnull (wp_proxy_get_pw_proxy (proxy));
}
static void
race_link (TestFixture *f, gconstpointer data)
{
  const gchar *stage = data;
  struct exact_fixture exact = {0}; exact_fixture_init (f, &exact);
  g_autoptr (WpLink) link = create_link (f, &exact, FALSE);
  g_autoptr (GCancellable) cancellable = g_cancellable_new ();
  struct operation_result activation = {0}, retirement = {0};
  struct trigger trigger = {&retirement, 0};
  if (g_str_equal (stage, "created"))
    g_signal_connect (link, "pw-proxy-created", G_CALLBACK (retire_created), &trigger);
  if (g_str_equal (stage, "bound"))
    g_signal_connect (link, "bound", G_CALLBACK (retire_bound), &trigger);
  if (!g_str_equal (stage, "unbound"))
    wp_object_activate (WP_OBJECT (link), WP_PIPEWIRE_OBJECT_FEATURES_MINIMAL,
        cancellable, (GAsyncReadyCallback) activation_finished, &activation);
  if (!g_str_equal (stage, "created") && !g_str_equal (stage, "bound")) {
    g_assert_null (wp_proxy_get_pw_proxy (WP_PROXY (link)));
    if (g_str_equal (stage, "cancelled")) g_cancellable_cancel (cancellable);
    if (g_str_equal (stage, "child-error"))
      wp_object_abort_activation (WP_OBJECT (link), "Injected native failure");
    if (g_str_equal (stage, "deactivate"))
      wp_object_deactivate (WP_OBJECT (link), WP_PROXY_FEATURE_BOUND);
    ao_link_retire (link, retirement_finished, &retirement);
    if (g_str_equal (stage, "dropped-owner")) g_clear_object (&link);
  }
  g_assert_cmpuint (retirement.calls, ==, 0);
  wait_operation (f, &retirement);
  g_assert_true (retirement.success); g_assert_no_error (retirement.error);
  if (!g_str_equal (stage, "unbound")) {
    wait_operation (f, &activation);
    /* INFO may finish before a deferred retirement requested from bound. */
    if (!g_str_equal (stage, "bound")) g_assert_false (activation.success);
    g_clear_error (&activation.error);
  }
  if (g_str_equal (stage, "created") || g_str_equal (stage, "bound"))
    g_assert_cmpuint (trigger.calls, ==, 1);
  assert_link_absent (f, &exact);
  exact_fixture_clear (&exact);
}

struct format_observations {
  guint calls;
  WpSpaPod *snapshots[3];
};

static void
object_finalized (gpointer data, GObject *object)
{
  (void) object;
  *(gboolean *) data = TRUE;
}

static void
format_changed (WpPlugin *endpoint, WpLink *link, gpointer data)
{
  struct format_observations *observations = data;
  g_assert_cmpuint (observations->calls, <, 3);
  g_signal_emit_by_name (endpoint, "get-link-format", link,
      &observations->snapshots[observations->calls++]);
}

static void
format_observation (TestFixture *f, gconstpointer data)
{
  (void) data;
  struct exact_fixture exact = {0}; exact_fixture_init (f, &exact);
  g_autoptr (WpLink) link = create_link (f, &exact, FALSE);
  g_autoptr (WpPlugin) endpoint = g_object_new (wp_ao_control_endpoint_get_type (),
      "name", "format-observer", "core", f->base.core, NULL);
  struct format_observations observations = {0};
  gboolean accepted = FALSE;
  g_signal_emit_by_name (endpoint, "observe-link", link, &accepted);
  g_assert_true (accepted);
  g_signal_connect (endpoint, "link-info-changed", G_CALLBACK (format_changed), &observations);
  struct operation_result activation = {0}, retirement = {0};
  wp_object_activate (WP_OBJECT (link), WP_PIPEWIRE_OBJECT_FEATURES_MINIMAL,
      NULL, (GAsyncReadyCallback) activation_finished, &activation);
  wait_operation (f, &activation); g_assert_true (activation.success);
  /* No streaming Format is negotiated by these deliberately inactive filters. */
  for (guint i = 0; i < observations.calls; i++) g_clear_pointer (&observations.snapshots[i], wp_spa_pod_unref);
  observations.calls = 0;
  guint8 buffer[1024];
  struct spa_pod_builder builder = SPA_POD_BUILDER_INIT (buffer, sizeof (buffer));
  const struct spa_pod *invalid = spa_pod_builder_add_object (&builder,
      SPA_TYPE_OBJECT_Format, SPA_PARAM_Format,
      SPA_FORMAT_mediaType, SPA_POD_Id (SPA_MEDIA_TYPE_audio));
  g_autoptr (WpSpaPod) invalid_wrap = wp_spa_pod_new_wrap_const (invalid);
  g_autoptr (WpSpaPod) expected_invalid = wp_spa_pod_copy (invalid_wrap);
  struct pw_link_info info = { .id = wp_proxy_get_bound_id (WP_PROXY (link)),
      .change_mask = PW_LINK_CHANGE_MASK_FORMAT, .format = (struct spa_pod *) invalid };
  struct pw_proxy *proxy = wp_proxy_get_pw_proxy (WP_PROXY (link));
  pw_proxy_notify (proxy, struct pw_link_events, info, 0, &info);
  builder = (struct spa_pod_builder) SPA_POD_BUILDER_INIT (buffer, sizeof (buffer));
  info.format = spa_pod_builder_add_object (&builder, SPA_TYPE_OBJECT_Format, SPA_PARAM_Format,
      SPA_FORMAT_mediaType, SPA_POD_Id (SPA_MEDIA_TYPE_application),
      SPA_FORMAT_mediaSubtype, SPA_POD_Id (SPA_MEDIA_SUBTYPE_ndarray));
  g_autoptr (WpSpaPod) valid_wrap = wp_spa_pod_new_wrap_const (info.format);
  g_autoptr (WpSpaPod) expected_valid = wp_spa_pod_copy (valid_wrap);
  pw_proxy_notify (proxy, struct pw_link_events, info, 0, &info);
  /* Both observations must arrive before any idle: invalid->valid cannot hide
   * an admitted contract violation. Each snapshot survives the later update. */
  g_assert_cmpuint (observations.calls, ==, 2);
  memset (buffer, 0, sizeof (buffer));
  g_assert_true (wp_spa_pod_equal (observations.snapshots[0], expected_invalid));
  g_assert_true (wp_spa_pod_equal (observations.snapshots[1], expected_valid));
  info.format = NULL;
  pw_proxy_notify (proxy, struct pw_link_events, info, 0, &info);
  g_assert_cmpuint (observations.calls, ==, 3);
  g_assert_null (observations.snapshots[2]);
  for (guint i = 0; i < observations.calls; i++) g_clear_pointer (&observations.snapshots[i], wp_spa_pod_unref);
  ao_link_retire (link, retirement_finished, &retirement);
  wait_operation (f, &retirement); g_assert_true (retirement.success);
  assert_link_absent (f, &exact);
  /* Native remove-id has completed. Finalizing the retained WpLink must not
   * detach its observer a second time through the now-freed native proxy. */
  gboolean finalized = FALSE;
  g_object_weak_ref (G_OBJECT (link), object_finalized, &finalized);
  g_clear_object (&link);
  g_assert_true (finalized);
  exact_fixture_clear (&exact);
}

static void
format_observer_rebind (TestFixture *f, gconstpointer data)
{
  (void) data;
  struct exact_fixture exact = {0}; exact_fixture_init (f, &exact);
  g_autoptr (WpLink) link = create_link (f, &exact, FALSE);
  g_autoptr (WpPlugin) endpoint = g_object_new (wp_ao_control_endpoint_get_type (),
      "name", "rebind-observer", "core", f->base.core, NULL);
  struct format_observations observations = {0};
  gboolean accepted = FALSE;
  g_signal_emit_by_name (endpoint, "observe-link", link, &accepted);
  g_assert_true (accepted);
  g_signal_connect (endpoint, "link-info-changed", G_CALLBACK (format_changed), &observations);
  for (guint cycle = 0; cycle < 2; cycle++) {
    struct operation_result activation = {0};
    wp_object_activate (WP_OBJECT (link), WP_PIPEWIRE_OBJECT_FEATURES_MINIMAL,
        NULL, (GAsyncReadyCallback) activation_finished, &activation);
    wait_operation (f, &activation); g_assert_true (activation.success);
    for (guint i = 0; i < observations.calls; i++)
      g_clear_pointer (&observations.snapshots[i], wp_spa_pod_unref);
    observations.calls = 0;
    struct pw_link_info info = { .id = wp_proxy_get_bound_id (WP_PROXY (link)),
        .change_mask = PW_LINK_CHANGE_MASK_FORMAT, .format = NULL };
    pw_proxy_notify (wp_proxy_get_pw_proxy (WP_PROXY (link)),
        struct pw_link_events, info, 0, &info);
    g_assert_cmpuint (observations.calls, ==, 1);
    wp_object_deactivate (WP_OBJECT (link), WP_OBJECT_FEATURES_ALL);
    g_assert_null (wp_proxy_get_pw_proxy (WP_PROXY (link)));
    assert_link_absent (f, &exact);
    observations.calls = 0;
  }
  gboolean finalized = FALSE;
  g_object_weak_ref (G_OBJECT (link), object_finalized, &finalized);
  g_clear_object (&link);
  g_assert_true (finalized);
  exact_fixture_clear (&exact);
}

int main (int argc, gchar **argv)
{
  g_test_init (&argc, &argv, NULL); wp_init (WP_INIT_ALL);
  g_test_add ("/rtc-links/format-observation", TestFixture, NULL, setup, format_observation, teardown);
  g_test_add ("/rtc-links/format-observer-rebind", TestFixture, NULL, setup, format_observer_rebind, teardown);
  const gchar *normal[] = {"exact", "control-selection", "never-activated", "repeat-retirement", "fresh-generation"};
  const gchar *races[] = {"queued", "unbound", "created", "bound", "cancelled", "child-error", "deactivate", "dropped-owner"};
  for (guint i = 0; i < G_N_ELEMENTS (normal); i++) {
    g_autofree gchar *path = g_strdup_printf ("/rtc-links/%s", normal[i]);
    g_test_add (path, TestFixture, normal[i], setup, exact_link, teardown);
  }
  for (guint i = 0; i < G_N_ELEMENTS (races); i++) {
    g_autofree gchar *path = g_strdup_printf ("/rtc-links/race/%s", races[i]);
    g_test_add (path, TestFixture, races[i], setup, race_link, teardown);
  }
  return g_test_run ();
}
