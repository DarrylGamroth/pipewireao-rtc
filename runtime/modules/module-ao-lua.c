/* SPDX-License-Identifier: MIT */
#include <wp/wp.h>
#include <spa/pod/pod.h>
#include <spa/utils/defs.h>

/* Property wrappers in libwp intentionally hide their flags and numeric key.
 * Inspect the public SPA Object instead, and copy each value into its owner. */
typedef struct {
  GObject parent;
  gchar *key;
  guint32 id, flags;
  WpSpaPod *value;
} WpAoPodProperty;
typedef GObjectClass WpAoPodPropertyClass;
G_DEFINE_TYPE (WpAoPodProperty, wp_ao_pod_property, G_TYPE_OBJECT)
enum { PROP_0, PROP_KEY, PROP_ID, PROP_FLAGS, PROP_VALUE };

static void
property_get (GObject *object, guint id, GValue *value, GParamSpec *spec)
{
  WpAoPodProperty *self = (WpAoPodProperty *) object;
  switch (id) {
  case PROP_KEY: g_value_set_string (value, self->key); break;
  case PROP_ID: g_value_set_uint (value, self->id); break;
  case PROP_FLAGS: g_value_set_uint (value, self->flags); break;
  case PROP_VALUE: g_value_set_boxed (value, self->value); break;
  default: G_OBJECT_WARN_INVALID_PROPERTY_ID (object, id, spec);
  }
}

static void
property_finalize (GObject *object)
{
  WpAoPodProperty *self = (WpAoPodProperty *) object;
  g_free (self->key);
  g_clear_pointer (&self->value, wp_spa_pod_unref);
  G_OBJECT_CLASS (wp_ao_pod_property_parent_class)->finalize (object);
}

static void wp_ao_pod_property_init (WpAoPodProperty *self G_GNUC_UNUSED) {}
static void
wp_ao_pod_property_class_init (WpAoPodPropertyClass *klass)
{
  klass->get_property = property_get;
  klass->finalize = property_finalize;
  g_object_class_install_property (klass, PROP_KEY,
      g_param_spec_string ("key", "key", "Property name", NULL, G_PARAM_READABLE));
  g_object_class_install_property (klass, PROP_ID,
      g_param_spec_uint ("id", "id", "Numeric key", 0, G_MAXUINT32, 0, G_PARAM_READABLE));
  g_object_class_install_property (klass, PROP_FLAGS,
      g_param_spec_uint ("flags", "flags", "Property flags", 0, G_MAXUINT32, 0, G_PARAM_READABLE));
  g_object_class_install_property (klass, PROP_VALUE,
      g_param_spec_boxed ("value", "value", "Owned value", WP_TYPE_SPA_POD, G_PARAM_READABLE));
}

struct _WpAoLua { WpPlugin parent; };
G_DECLARE_FINAL_TYPE (WpAoLua, wp_ao_lua, WP, AO_LUA, WpPlugin)
G_DEFINE_TYPE (WpAoLua, wp_ao_lua, WP_TYPE_PLUGIN)

static WpSpaPod *
copy_value (const struct spa_pod *pod)
{
  g_autoptr (WpSpaPod) wrapped = wp_spa_pod_new_wrap_const (pod);
  return wp_spa_pod_copy (wrapped);
}

/* The containing WpSpaPod owns its top-level allocation. Validate every child
 * extent before reading or copying it, with subtraction to avoid overflow. */
static gboolean
child_extent (const guint8 *data, gsize remaining, gsize prefix, gsize *step)
{
  if (remaining < prefix + sizeof (struct spa_pod))
    return FALSE;
  const struct spa_pod *child = (const struct spa_pod *) (data + prefix);
  if (child->size > remaining - prefix - sizeof (*child))
    return FALSE;
  gsize size = prefix + sizeof (*child) + child->size;
  gsize padded = SPA_ROUND_UP_N (size, 8);
  if (padded > remaining && size != remaining)
    return FALSE;
  *step = MIN (padded, remaining);
  return TRUE;
}

/* NULL boxed values become truthy userdata in stock Lua. These boolean
 * checks let the wrapper reject them before invoking any boxed method. */
static gboolean wp_ao_lua_iterator_valid (WpAoLua *self G_GNUC_UNUSED, WpIterator *iterator)
{ return iterator != NULL; }
static gboolean wp_ao_lua_pod_valid (WpAoLua *self G_GNUC_UNUSED, WpSpaPod *pod)
{ return pod != NULL; }

static WpIterator *
wp_ao_lua_fields (WpAoLua *self G_GNUC_UNUSED, WpSpaPod *value)
{
  const struct spa_pod *pod = value ? wp_spa_pod_get_spa_pod (value) : NULL;
  if (!pod || pod->size > 65536 - sizeof (*pod) || pod->type != SPA_TYPE_Struct)
    return NULL;
  g_autoptr (GPtrArray) children = g_ptr_array_new_with_free_func (
      (GDestroyNotify) wp_spa_pod_unref);
  const guint8 *data = SPA_POD_BODY_CONST (pod);
  gsize remaining = pod->size, step;
  while (remaining) {
    if (!child_extent (data, remaining, 0, &step))
      return NULL;
    g_ptr_array_add (children, copy_value ((const struct spa_pod *) data));
    data += step;
    remaining -= step;
  }
  return wp_iterator_new_ptr_array (g_steal_pointer (&children), WP_TYPE_SPA_POD);
}

static WpIterator *
wp_ao_lua_properties (WpAoLua *self G_GNUC_UNUSED, WpSpaPod *value)
{
  const struct spa_pod *pod = value ? wp_spa_pod_get_spa_pod (value) : NULL;
  if (!pod || pod->size > 65536 - sizeof (*pod) || pod->type != SPA_TYPE_Object || pod->size < sizeof (struct spa_pod_object_body))
    return NULL;
  const struct spa_pod_object *object = (const struct spa_pod_object *) pod;
  WpSpaIdTable table = wp_spa_type_get_values_table (object->body.type);
  g_autoptr (GPtrArray) children = g_ptr_array_new_with_free_func (g_object_unref);
  const guint8 *data = (const guint8 *) &object->body + sizeof (object->body);
  gsize remaining = pod->size - sizeof (object->body), step;
  while (remaining) {
    if (!child_extent (data, remaining, G_STRUCT_OFFSET (struct spa_pod_prop, value), &step))
      return NULL;
    const struct spa_pod_prop *prop = (const struct spa_pod_prop *) data;
    WpAoPodProperty *item = g_object_new (wp_ao_pod_property_get_type (), NULL);
    WpSpaIdValue key = table ? wp_spa_id_table_find_value (table, prop->key) : NULL;
    item->key = key ? g_strdup (wp_spa_id_value_short_name (key)) :
        g_strdup_printf ("id-%08x", prop->key);
    item->id = prop->key;
    item->flags = prop->flags;
    item->value = copy_value (&prop->value);
    g_ptr_array_add (children, item);
    data += step;
    remaining -= step;
  }
  return wp_iterator_new_ptr_array (g_steal_pointer (&children), wp_ao_pod_property_get_type ());
}

static WpSpaPod *wp_ao_lua_copy (WpAoLua *self G_GNUC_UNUSED, WpSpaPod *pod)
{ return pod ? wp_spa_pod_copy (pod) : NULL; }
static gboolean wp_ao_lua_equals (WpAoLua *self G_GNUC_UNUSED, WpSpaPod *a, WpSpaPod *b)
{ return a && b && wp_spa_pod_equal (a, b); }
static guint64 wp_ao_lua_size (WpAoLua *self G_GNUC_UNUSED, WpSpaPod *value)
{
  const struct spa_pod *pod = value ? wp_spa_pod_get_spa_pod (value) : NULL;
  return pod ? (guint64) sizeof (*pod) + pod->size : 0;
}

static gchar *wp_ao_lua_object_id (WpAoLua *self G_GNUC_UNUSED, WpSpaPod *value)
{
  const struct spa_pod *pod = value ? wp_spa_pod_get_spa_pod (value) : NULL;
  if (!pod || pod->size > 65536 - sizeof (*pod) || pod->type != SPA_TYPE_Object || pod->size < sizeof (struct spa_pod_object_body))
    return NULL;
  const struct spa_pod_object *object = (const struct spa_pod_object *) pod;
  WpSpaIdTable table = wp_spa_type_get_object_id_values_table (object->body.type);
  WpSpaIdValue id = table ? wp_spa_id_table_find_value (table, object->body.id) : NULL;
  return id ? g_strdup (wp_spa_id_value_short_name (id)) :
      g_strdup_printf ("id-%08x", object->body.id);
}

/* Metadata contains only names and UInt32 extents. POD values never pass through
 * JSON, preserving their scalar types, full Int64 bits and signed zero. */
static WpSpaJson *
wp_ao_lua_array_info (WpAoLua *self G_GNUC_UNUSED, WpSpaPod *value)
{
  const struct spa_pod *pod = value ? wp_spa_pod_get_spa_pod (value) : NULL;
  if (!pod || pod->size > 65536 - sizeof (*pod) || (pod->type != SPA_TYPE_Array && pod->type != SPA_TYPE_Choice))
    return NULL;
  guint prefix = pod->type == SPA_TYPE_Array ? sizeof (struct spa_pod_array_body) :
      sizeof (struct spa_pod_choice_body);
  if (pod->size < prefix)
    return NULL;
  const struct spa_pod *child = (const struct spa_pod *)
      ((const guint8 *) SPA_POD_BODY_CONST (pod) + prefix - sizeof (*child));
  guint bytes = pod->size - prefix;
  if (!child->size || bytes % child->size)
    return NULL;
  const gchar *name = wp_spa_type_name (child->type);
  if (!name)
    return NULL;
  if (pod->type == SPA_TYPE_Choice) {
    const struct spa_pod_choice *choice = (const struct spa_pod_choice *) pod;
    WpSpaIdValue kind = wp_spa_id_value_from_number ("Spa:Enum:Choice", choice->body.type);
    if (!kind || !bytes)
      return NULL;
    return wp_spa_json_new_object ("type", "s", name, "width", "i", child->size,
        "count", "i", bytes / child->size, "choice", "s", wp_spa_id_value_short_name (kind), NULL);
  }
  return wp_spa_json_new_object ("type", "s", name, "width", "i", child->size,
      "count", "i", bytes / child->size, NULL);
}

static WpSpaJson *
wp_ao_lua_array_metadata (WpAoLua *self, WpSpaPod *value)
{
  WpSpaJson *info = wp_ao_lua_array_info (self, value);
  /* Keep invalid metadata representable through stock boxed marshalling. */
  return info ? info : wp_spa_json_new_from_string ("{}");
}

static WpSpaPod *
wp_ao_lua_choice_child (WpAoLua *self G_GNUC_UNUSED, WpSpaPod *value)
{
  const struct spa_pod *pod = value ? wp_spa_pod_get_spa_pod (value) : NULL;
  g_autoptr (WpSpaJson) info = wp_ao_lua_array_info (self, value);
  if (!pod || pod->type != SPA_TYPE_Choice || !info)
    return NULL;
  return copy_value (&((const struct spa_pod_choice *) pod)->body.child);
}

static WpObjectManager *
wp_ao_lua_object_manager (WpAoLua *self G_GNUC_UNUSED, guint features)
{
  WpObjectManager *manager = wp_object_manager_new ();
  wp_object_manager_request_object_features (manager, WP_TYPE_OBJECT, features);
  return manager;
}
static void
wp_ao_lua_add_interest (WpAoLua *self G_GNUC_UNUSED, WpObjectManager *manager, WpObjectInterest *interest)
{
  wp_object_manager_add_interest_full (manager, wp_object_interest_ref (interest));
}
static WpEvent *
wp_ao_lua_push_event (WpAoLua *self G_GNUC_UNUSED, const gchar *type, gint priority,
    WpProperties *properties, GObject *source, GObject *subject)
{
  g_autoptr (WpCore) core = wp_object_get_core (WP_OBJECT (self));
  g_autoptr (WpEventDispatcher) dispatcher = wp_event_dispatcher_get_instance (core);
  WpEvent *event = wp_event_new (type, priority,
      properties ? wp_properties_ref (properties) : NULL, source, subject);
  wp_event_dispatcher_push_event (dispatcher, wp_event_ref (event));
  return event;
}

static void wp_ao_lua_enable (WpPlugin *plugin, WpTransition *transition G_GNUC_UNUSED)
{ wp_object_update_features (WP_OBJECT (plugin), WP_PLUGIN_FEATURE_ENABLED, 0); }
static void wp_ao_lua_init (WpAoLua *self G_GNUC_UNUSED) {}
static void
wp_ao_lua_class_init (WpAoLuaClass *klass)
{
  WP_PLUGIN_CLASS (klass)->enable = wp_ao_lua_enable;
#define ACTION(name, callback, result, count, ...) \
  g_signal_new_class_handler (name, G_TYPE_FROM_CLASS (klass), \
      G_SIGNAL_RUN_LAST | G_SIGNAL_ACTION, (GCallback) callback, NULL, NULL, NULL, \
      result, count, __VA_ARGS__)
  ACTION ("pod-copy", wp_ao_lua_copy, WP_TYPE_SPA_POD, 1, WP_TYPE_SPA_POD);
  ACTION ("pod-equals", wp_ao_lua_equals, G_TYPE_BOOLEAN, 2, WP_TYPE_SPA_POD, WP_TYPE_SPA_POD);
  ACTION ("iterator-valid", wp_ao_lua_iterator_valid, G_TYPE_BOOLEAN, 1, WP_TYPE_ITERATOR);
  ACTION ("pod-valid", wp_ao_lua_pod_valid, G_TYPE_BOOLEAN, 1, WP_TYPE_SPA_POD);
  ACTION ("pod-fields", wp_ao_lua_fields, WP_TYPE_ITERATOR, 1, WP_TYPE_SPA_POD);
  ACTION ("pod-properties", wp_ao_lua_properties, WP_TYPE_ITERATOR, 1, WP_TYPE_SPA_POD);
  ACTION ("pod-size", wp_ao_lua_size, G_TYPE_UINT64, 1, WP_TYPE_SPA_POD);
  ACTION ("pod-object-id", wp_ao_lua_object_id, G_TYPE_STRING, 1, WP_TYPE_SPA_POD);
  ACTION ("pod-array-info", wp_ao_lua_array_metadata, WP_TYPE_SPA_JSON, 1, WP_TYPE_SPA_POD);
  ACTION ("pod-choice-child", wp_ao_lua_choice_child, WP_TYPE_SPA_POD, 1, WP_TYPE_SPA_POD);
  ACTION ("object-manager", wp_ao_lua_object_manager, WP_TYPE_OBJECT_MANAGER, 1, G_TYPE_UINT);
  ACTION ("add-interest", wp_ao_lua_add_interest, G_TYPE_NONE, 2, WP_TYPE_OBJECT_MANAGER, WP_TYPE_OBJECT_INTEREST);
  ACTION ("push-event", wp_ao_lua_push_event, WP_TYPE_EVENT, 5,
      G_TYPE_STRING, G_TYPE_INT, WP_TYPE_PROPERTIES, G_TYPE_OBJECT, G_TYPE_OBJECT);
#undef ACTION
}
WP_PLUGIN_EXPORT GObject *
wireplumber__module_init (WpCore *core, WpSpaJson *args G_GNUC_UNUSED, GError **error G_GNUC_UNUSED)
{
  return g_object_new (wp_ao_lua_get_type (), "name", "ao-lua", "core", core, NULL);
}
