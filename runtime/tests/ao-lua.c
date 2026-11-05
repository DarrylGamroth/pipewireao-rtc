/* SPDX-License-Identifier: MIT */
#include "base-test-fixture.h"
#include "../modules/module-ao-lua.c"
#include <spa/pod/builder.h>
#include <pipewire/filter.h>

typedef struct { WpBaseTestFixture base; } TestFixture;

static void
property_records (void)
{
  guint8 bytes[256];
  struct spa_pod_builder builder = SPA_POD_BUILDER_INIT (bytes, sizeof (bytes));
  struct spa_pod_frame frame;
  spa_pod_builder_push_object (&builder, &frame, SPA_TYPE_OBJECT_Props, SPA_PARAM_Props);
  spa_pod_builder_prop (&builder, 0xf0000001, SPA_POD_PROP_FLAG_READONLY | SPA_POD_PROP_FLAG_HARDWARE);
  spa_pod_builder_long (&builder, G_MAXINT64);
  spa_pod_builder_prop (&builder, 0xf0000001, 0xf0000000);
  spa_pod_builder_long (&builder, G_MININT64);
  g_autoptr (WpSpaPod) parent = copy_value (spa_pod_builder_pop (&builder, &frame));
  g_autoptr (WpIterator) iterator = wp_ao_lua_properties (NULL, parent);
  g_assert_nonnull (iterator);
  g_clear_pointer (&parent, wp_spa_pod_unref);
  memset (bytes, 0, sizeof (bytes));
  for (guint i = 0; i < 2; i++) {
    g_auto (GValue) item = G_VALUE_INIT;
    g_assert_true (wp_iterator_next (iterator, &item));
    g_autofree gchar *key = NULL;
    guint id, flags;
    g_autoptr (WpSpaPod) child = NULL;
    g_object_get (g_value_get_object (&item), "key", &key, "id", &id,
        "flags", &flags, "value", &child, NULL);
    g_assert_cmpstr (key, ==, "id-f0000001");
    g_assert_cmpuint (id, ==, 0xf0000001);
    g_assert_cmpuint (flags, ==, i ? 0xf0000000 :
        (SPA_POD_PROP_FLAG_READONLY | SPA_POD_PROP_FLAG_HARDWARE));
    gint64 value;
    g_assert_true (wp_spa_pod_get_long (child, &value));
    g_assert_cmpint (value, ==, i ? G_MININT64 : G_MAXINT64);
  }
  g_assert_false (wp_iterator_next (iterator, NULL));
}

static void
struct_lifetime_and_bounds (void)
{
  guint8 bytes[128];
  struct spa_pod_builder builder = SPA_POD_BUILDER_INIT (bytes, sizeof (bytes));
  struct spa_pod_frame frame;
  spa_pod_builder_push_struct (&builder, &frame);
  spa_pod_builder_long (&builder, G_MAXINT64);
  spa_pod_builder_float (&builder, -0.0f);
  struct spa_pod *raw = spa_pod_builder_pop (&builder, &frame);
  g_autoptr (WpSpaPod) parent = copy_value (raw);
  g_autoptr (WpIterator) iterator = wp_ao_lua_fields (NULL, parent);
  g_assert_nonnull (iterator);
  g_clear_pointer (&parent, wp_spa_pod_unref);
  memset (bytes, 0, sizeof (bytes));
  g_auto (GValue) item = G_VALUE_INIT;
  g_assert_true (wp_iterator_next (iterator, &item));
  g_autoptr (WpSpaPod) retained = g_value_dup_boxed (&item);
  g_value_unset (&item);
  g_clear_pointer (&iterator, wp_iterator_unref);
  gint64 value;
  g_assert_true (wp_spa_pod_get_long (retained, &value));
  g_assert_cmpint (value, ==, G_MAXINT64);

  /* A valid first child does not allow partial acceptance of a bad second. */
  struct { struct spa_pod pod; struct spa_pod_long first; struct spa_pod second; } bad = {
    { 24, SPA_TYPE_Struct }, { { 8, SPA_TYPE_Long }, 1 }, { G_MAXUINT32, SPA_TYPE_Long }
  };
  g_autoptr (WpSpaPod) wrapped = wp_spa_pod_new_wrap (&bad.pod);
  g_assert_null (wp_ao_lua_fields (NULL, wrapped));
  bad.second.size = 0;
  bad.pod.size = 23;
  g_assert_null (wp_ao_lua_fields (NULL, wrapped));
}

static void
property_bounds (void)
{
  struct {
    struct spa_pod_object object;
    struct { guint32 key, flags; struct spa_pod_long value; } first;
    struct spa_pod_prop second;
  } bad = {
    { { 48, SPA_TYPE_Object }, { SPA_TYPE_OBJECT_Props, SPA_PARAM_Props } },
    { 1, 0, { { 8, SPA_TYPE_Long }, 1 } },
    { 2, 0, { G_MAXUINT32, SPA_TYPE_Long } }
  };
  g_autoptr (WpSpaPod) wrapped = wp_spa_pod_new_wrap (&bad.object.pod);
  g_assert_null (wp_ao_lua_properties (NULL, wrapped));
  bad.second.value.size = 0;
  bad.object.pod.size = 47;
  g_assert_null (wp_ao_lua_properties (NULL, wrapped));
  bad.object.pod.size = 7;
  g_assert_null (wp_ao_lua_properties (NULL, wrapped));
  g_assert_null (wp_ao_lua_object_id (NULL, wrapped));
}

static void
choice_and_array_bounds (void)
{
  struct { struct spa_pod_choice choice; gint32 values[3]; } source = {
    { { 28, SPA_TYPE_Choice }, { SPA_CHOICE_None, 0xf0000000, { 4, SPA_TYPE_Int } } },
    { 42, 7, 9 }
  };
  g_autoptr (WpSpaPod) parent = wp_spa_pod_new_wrap (&source.choice.pod);
  g_autoptr (WpSpaJson) info = wp_ao_lua_array_info (NULL, parent);
  gint count, width;
  g_autofree gchar *kind = NULL;
  g_assert_nonnull (info);
  g_assert_true (wp_spa_json_object_get (info, "count", "i", &count,
      "width", "i", &width, "choice", "s", &kind, NULL));
  g_assert_cmpint (count, ==, 3);
  g_assert_cmpint (width, ==, 4);
  g_assert_cmpstr (kind, ==, "None");
  g_autoptr (WpSpaPod) child = wp_ao_lua_choice_child (NULL, parent);
  g_assert_nonnull (child);
  g_assert_cmpuint (source.choice.body.flags, ==, 0xf0000000);
  g_assert_cmpint (source.values[1], ==, 7);
  source.values[0] = -1;
  gint32 value;
  g_assert_true (wp_spa_pod_get_int (child, &value));
  g_assert_cmpint (value, ==, 42);
  source.choice.pod.size--;
  g_assert_null (wp_ao_lua_array_info (NULL, parent));
  g_assert_null (wp_ao_lua_choice_child (NULL, parent));
  source.choice.pod.size++;
  source.choice.body.child.size = 0;
  g_assert_null (wp_ao_lua_array_info (NULL, parent));
  source.choice.body.child.size = 4;
  source.choice.pod.size = 15;
  g_assert_null (wp_ao_lua_array_info (NULL, parent));

  struct { struct spa_pod_array array; gint32 values[2]; } array = {
    { { 16, SPA_TYPE_Array }, { { 4, SPA_TYPE_Int } } }, { 4, 8 }
  };
  g_autoptr (WpSpaPod) wrapped = wp_spa_pod_new_wrap (&array.array.pod);
  g_autoptr (WpSpaJson) array_info = wp_ao_lua_array_info (NULL, wrapped);
  g_assert_nonnull (array_info);
  g_assert_true (wp_spa_json_object_get (array_info, "count", "i", &count, NULL));
  g_assert_cmpint (count, ==, 2);
  array.array.pod.size--;
  g_assert_null (wp_ao_lua_array_info (NULL, wrapped));
  array.array.body.child.size = 0;
  g_assert_null (wp_ao_lua_array_info (NULL, wrapped));
}

static void
unused_nested_value (void)
{
  /* Unknown top-level properties are copied without recursively parsing a
   * nested value; only a selected value's metadata would reject this Array. */
  struct {
    struct spa_pod_object object;
    struct { guint32 key, flags; struct spa_pod_array array; } prop;
  } source = {
    { { 32, SPA_TYPE_Object }, { SPA_TYPE_OBJECT_Format, SPA_PARAM_Format } },
    { 0xf0000001, 0, { { 8, SPA_TYPE_Array }, { { 0, SPA_TYPE_Int } } } }
  };
  g_autoptr (WpSpaPod) parent = wp_spa_pod_new_wrap (&source.object.pod);
  g_autoptr (WpIterator) iterator = wp_ao_lua_properties (NULL, parent);
  g_assert_nonnull (iterator);
  g_auto (GValue) item = G_VALUE_INIT;
  g_assert_true (wp_iterator_next (iterator, &item));
  g_autoptr (WpSpaPod) value = NULL;
  g_object_get (g_value_get_object (&item), "value", &value, NULL);
  g_assert_true (wp_spa_pod_is_array (value));
  g_assert_null (wp_ao_lua_array_info (NULL, value));
}

static void setup (TestFixture *f, gconstpointer data)
{ (void) data; wp_base_test_fixture_setup (&f->base, 0); }
static void teardown (TestFixture *f, gconstpointer data)
{ (void) data; wp_base_test_fixture_teardown (&f->base); }

static void
selected_features (TestFixture *f, gconstpointer data)
{
  (void) data;
  struct pw_filter *filter = pw_filter_new (wp_core_get_pw_core (f->base.core),
      "binding-features", pw_properties_new (PW_KEY_NODE_NAME, "binding-features", NULL));
  g_assert_nonnull (filter);
  g_assert_cmpint (pw_filter_connect (filter, PW_FILTER_FLAG_INACTIVE, NULL, 0), ==, 0);
  g_autoptr (WpObjectManager) manager = wp_ao_lua_object_manager (NULL,
      WP_PROXY_FEATURE_BOUND | WP_PIPEWIRE_OBJECT_FEATURE_INFO);
  g_autoptr (WpObjectInterest) interest = wp_object_interest_new (WP_TYPE_NODE,
      WP_CONSTRAINT_TYPE_PW_GLOBAL_PROPERTY, PW_KEY_NODE_NAME, "=s", "binding-features", NULL);
  wp_ao_lua_add_interest (NULL, manager, interest);
  test_ensure_object_manager_is_installed (manager, f->base.core, f->base.loop);
  g_autoptr (WpNode) node = NULL;
  gint64 deadline = g_get_monotonic_time () + 5000000;
  do {
    node = wp_object_manager_lookup (manager, WP_TYPE_NODE, NULL);
    if (!node) g_main_context_iteration (f->base.context, FALSE);
  } while (!node && g_get_monotonic_time () < deadline);
  g_assert_nonnull (node);
  g_assert_cmpuint (wp_object_get_active_features (WP_OBJECT (node)), ==,
      WP_PROXY_FEATURE_BOUND | WP_PIPEWIRE_OBJECT_FEATURE_INFO);
  pw_filter_destroy (filter);
}

static void
native_event_properties (TestFixture *f, gconstpointer data)
{
  (void) data;
  g_autoptr (WpAoLua) plugin = g_object_new (wp_ao_lua_get_type (),
      "core", f->base.core, "name", "ao-lua", NULL);
  g_autoptr (WpProperties) properties = wp_properties_new ("ao.session.epoch", "9007199254740993", NULL);
  GObject *source = g_object_new (G_TYPE_OBJECT, NULL);
  GObject *subject = g_object_new (G_TYPE_OBJECT, NULL);
  g_autoptr (WpEvent) event = wp_ao_lua_push_event (plugin, "ao-test-native-event", 1,
      properties, source, subject);
  g_assert_nonnull (event);
  g_object_unref (source);
  g_object_unref (subject);
  wp_properties_set (properties, "ao.session.epoch", "changed");
  g_autoptr (GObject) retained_source = wp_event_get_source (event);
  g_autoptr (GObject) retained_subject = wp_event_get_subject (event);
  g_autoptr (WpProperties) retained_properties = wp_event_get_properties (event);
  g_assert_true (G_IS_OBJECT (retained_source));
  g_assert_true (G_IS_OBJECT (retained_subject));
  g_assert_cmpstr (wp_properties_get (retained_properties, "ao.session.epoch"),
      ==, "9007199254740993");
  g_assert_cmpstr (wp_properties_get (retained_properties, "event.type"),
      ==, "ao-test-native-event");
}

int main (int argc, char **argv)
{
  g_test_init (&argc, &argv, NULL);
  wp_init (WP_INIT_ALL);
  g_test_add_func ("/ao-lua/properties-owned-flags-duplicates", property_records);
  g_test_add_func ("/ao-lua/struct-owned-bounds", struct_lifetime_and_bounds);
  g_test_add_func ("/ao-lua/property-bounds", property_bounds);
  g_test_add_func ("/ao-lua/choice-array-bounds", choice_and_array_bounds);
  g_test_add_func ("/ao-lua/unused-nested-value", unused_nested_value);
  g_test_add ("/ao-lua/native-event-properties", TestFixture, NULL, setup, native_event_properties, teardown);
  g_test_add ("/ao-lua/selected-features", TestFixture, NULL, setup, selected_features, teardown);
  return g_test_run ();
}
