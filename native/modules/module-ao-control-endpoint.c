/* WirePlumber
 *
 * SPDX-License-Identifier: MIT
 */

#include <wp/wp.h>
#include "ao-link.h"
#include <errno.h>
#include <unistd.h>
#include <pipewire/filter.h>
#include <pipewire/keys.h>
#include <pipewire/link.h>
#include <spa/param/props.h>

WP_DEFINE_LOCAL_LOG_TOPIC ("m-ao-control-endpoint")

#define REQUEST_LIMIT (16u * 1024u)
#define PUBLICATION_LIMIT (64u * 1024u)
#define CONNECT_TIMEOUT_MS 5000u
#define POD_DEPTH_LIMIT 16u
/* One deferred request plus a small handoff for state/rejection observations. */
#define EVENT_LIMIT 4u

typedef struct {
  guint signal;
  WpSpaPod *pod;
  gint state;
  gint64 received_us;
  gchar *message;
} EndpointEvent;

/* Transport only: Lua owns all envelope, admission and lifecycle decisions.
 * All callbacks/actions run on the WpCore main context. No ports, processing
 * callbacks, activation of the filter, or realtime work are provided here.
 *
 * Lua API (Plugin.find(args["plugin.name"] or "ao-control-endpoint")):
 *   parameter(WpSpaPod, int64): deferred owned copy and native receipt time
 *   in monotonic microseconds; queue delay consumes the request budget.
 *   state-changed(int, string): pw_filter_state, error (empty when absent).
 *   transport-error(string): rejected POD or input handoff overflow.
 *   Failed publication returns false to its caller without recursive signals.
 *   publish(WpSpaPod) -> boolean (single record, suitable for a controller).
 *   publish-records(capabilities, completion?, rejection?) -> boolean: replaces
 *   the complete advertised Props record list in one update (64 KiB combined).
 *   get-node-id() -> uint (SPA_ID_INVALID when
 *   unavailable); get-owner-pid() -> uint.
 *   observe-link(WpLink) -> boolean: observe every Format change through
 *   link-info-changed(WpLink) on the control context.
 *   get-link-format(WpLink) -> WpSpaPod: owned native-info snapshot or nil.
 *   retire-link(WpLink) -> boolean: deferred abort/dispose; link-retired
 *   (WpLink, string) follows native retirement (empty string means success).
 *   Lua must also account for pending activation and prove registry absence.
 *   disconnect(): defer wp_core_disconnect; systemd handles owner cleanup.
 *
 * publish replaces the advertised Props with pw_filter_update_params, which
 * does not dispatch an incoming set-param callback. The publishing guard also
 * protects against synchronous callback recursion. Lua must still reject
 * publication envelopes submitted remotely as operator requests.
 * The handoff retains at most one copied request and four events in total.
 * Further requests are dropped before copying until the pending request is
 * delivered. Repeated malformed-POD notifications coalesce. At event capacity,
 * a new state/error replaces the oldest non-request observation; an overflow
 * notification is emitted after retained events drain. No application rejection
 * record is invented here. Terminal failure/disable drops all stale events.
 */
struct _WpAoControlEndpoint
{
  WpPlugin parent;
  WpProperties *properties;
  struct pw_filter *filter;
  struct spa_hook listener;
  WpTransition *enable_transition;
  GSource *connect_timeout;
  GSource *delivery_source;
  GQueue *events;
  gboolean overflow;
  gboolean parameter_pending;
  gboolean publishing;
  gboolean bound;
};

G_DECLARE_FINAL_TYPE (WpAoControlEndpoint, wp_ao_control_endpoint, WP,
    AO_CONTROL_ENDPOINT, WpPlugin)
G_DEFINE_TYPE (WpAoControlEndpoint, wp_ao_control_endpoint, WP_TYPE_PLUGIN)

enum {
  SIGNAL_PARAMETER,
  SIGNAL_STATE_CHANGED,
  SIGNAL_TRANSPORT_ERROR,
  ACTION_PUBLISH,
  ACTION_PUBLISH_RECORDS,
  ACTION_GET_NODE_ID,
  ACTION_GET_OWNER_PID,
  ACTION_DISCONNECT,
  ACTION_RETIRE_LINK,
  SIGNAL_LINK_RETIRED,
  SIGNAL_LINK_INFO_CHANGED,
  ACTION_OBSERVE_LINK,
  ACTION_GET_LINK_FORMAT,
  N_SIGNALS
};
static guint signals[N_SIGNALS];
static void clear_filter (WpAoControlEndpoint *self);

static gboolean
disconnect_core (gpointer data)
{
  wp_core_disconnect (WP_CORE (data));
  return G_SOURCE_REMOVE;
}

static void
wp_ao_control_endpoint_disconnect (WpAoControlEndpoint *self)
{
  g_autoptr (WpCore) core = wp_object_get_core (WP_OBJECT (self));
  if (core)
    wp_core_idle_add (core, NULL, disconnect_core, g_object_ref (core), g_object_unref);
}
/* Native lifetime only. Lua owns terminal fencing, callback accounting,
 * exact registry identity and the subsequent Core sync/absence proof. */
static void
link_retired (GObject *object, GAsyncResult *result, gpointer data)
{
  g_autoptr (WpAoControlEndpoint) self = data;
  g_autoptr (GError) error = NULL;
  ao_link_retire_finish (WP_LINK (object), result, &error);
  g_signal_emit (self, signals[SIGNAL_LINK_RETIRED], 0, object,
      error ? error->message : "");
}

static gboolean
wp_ao_control_endpoint_retire_link (WpAoControlEndpoint *self, WpLink *link)
{
  if (!link) return FALSE;
  g_autoptr (WpCore) core = wp_object_get_core (WP_OBJECT (self));
  g_autoptr (WpCore) link_core = wp_object_get_core (WP_OBJECT (link));
  if (!core || core != link_core) return FALSE;
  ao_link_retire (link, link_retired, g_object_ref (self));
  return TRUE;
}

/* Standard WpLink does not notify Format-only info changes. This observer
 * forwards every observation from the public PipeWire control-context listener.
 * Each watched Link owns one observer; no session or admission state lives here. */
typedef struct {
  struct spa_hook listener;
  WpAoControlEndpoint *endpoint;
  WpLink *link; /* weak: owned by the GObject carrying this qdata */
} LinkObserver;

static void
link_info (void *data, const struct pw_link_info *info)
{
  LinkObserver *observer = data;
  if (!(info->change_mask & PW_LINK_CHANGE_MASK_FORMAT)) return;
  g_autoptr (WpLink) link = g_object_ref (observer->link);
  g_autoptr (WpAoControlEndpoint) endpoint = g_object_ref (observer->endpoint);
  /* WpLink installs its own info listener first. Its native_info snapshot is
   * current here. Forward each change: coalescing invalid->valid updates would
   * erase a required scientific-contract failure. Retirement remains deferred
   * to protect the currently executing native proxy callback. */
  g_signal_emit (endpoint, signals[SIGNAL_LINK_INFO_CHANGED], 0, link);
}

static const struct pw_link_events observed_link_events = {
  PW_VERSION_LINK_EVENTS, .info = link_info,
};

static void
link_observer_detach (WpProxy *link, LinkObserver *observer)
{
  (void) link;
  spa_hook_remove (&observer->listener);
  /* SPA removal leaves the old list pointers behind. Destruction and later
   * qdata finalization may both detach; never revisit a freed native proxy. */
  spa_zero (observer->listener);
}

static void
link_observer_free (gpointer data)
{
  LinkObserver *observer = data;
  link_observer_detach (NULL, observer);
  g_object_unref (observer->endpoint);
  g_free (observer);
}

static void
link_observer_attach (WpProxy *link, gpointer native, LinkObserver *observer)
{
  (void) link;
  pw_link_add_listener (native, &observer->listener, &observed_link_events, observer);
}

static gboolean
wp_ao_control_endpoint_observe_link (WpAoControlEndpoint *self, WpLink *link)
{
  static GQuark key;
  if (!link) return FALSE;
  if (!key) key = g_quark_from_static_string ("pipewireao-rtc-link-observer");
  LinkObserver *observer = g_object_get_qdata (G_OBJECT (link), key);
  if (observer) return observer->endpoint == self;
  g_autoptr (WpCore) core = wp_object_get_core (WP_OBJECT (self));
  g_autoptr (WpCore) link_core = wp_object_get_core (WP_OBJECT (link));
  if (!core || core != link_core) return FALSE;
  observer = g_new0 (LinkObserver, 1);
  spa_list_init (&observer->listener.link);
  observer->endpoint = g_object_ref (self);
  observer->link = link;
  g_object_set_qdata_full (G_OBJECT (link), key, observer, link_observer_free);
  g_signal_connect (link, "pw-proxy-created", G_CALLBACK (link_observer_attach), observer);
  g_signal_connect (link, "pw-proxy-destroyed", G_CALLBACK (link_observer_detach), observer);
  gpointer native = wp_proxy_get_pw_proxy (WP_PROXY (link));
  if (native) link_observer_attach (WP_PROXY (link), native, observer);
  return TRUE;
}

static WpSpaPod *
wp_ao_control_endpoint_get_link_format (WpAoControlEndpoint *self, WpLink *link)
{
  (void) self;
  return link ? ao_link_get_format (link) : NULL;
}

static const gchar *identity_keys[] = {
  PW_KEY_NODE_NAME, "node.cache-params", "pipewireao.rtc-control.protocol",
  "pipewireao.rtc-control.profile", "pipewireao.rtc-control.instance",
  "pipewireao.rtc-control.owner-pid"
};

static gboolean
identity_valid (WpAoControlEndpoint *self)
{
  const struct pw_properties *props = pw_filter_get_properties (self->filter, NULL);
  for (guint i = 0; i < G_N_ELEMENTS (identity_keys); i++)
    if (g_strcmp0 (pw_properties_get (props, identity_keys[i]),
            wp_properties_get (self->properties, identity_keys[i])) != 0)
      return FALSE;
  return TRUE;
}

static void
event_free (EndpointEvent *event)
{
  g_clear_pointer (&event->pod, wp_spa_pod_unref);
  g_free (event->message);
  g_free (event);
}

static void
clear_events (WpAoControlEndpoint *self)
{
  if (self->delivery_source) {
    g_source_destroy (self->delivery_source);
    g_clear_pointer (&self->delivery_source, g_source_unref);
  }
  g_queue_clear_full (self->events, (GDestroyNotify) event_free);
  self->overflow = FALSE;
  self->parameter_pending = FALSE;
}

static gboolean
deliver_event (gpointer data)
{
  g_autoptr (WpAoControlEndpoint) self = g_object_ref (data);
  g_autoptr (GSource) source = g_source_ref (self->delivery_source);
  EndpointEvent *event = g_queue_pop_head (self->events);
  /* Signals are outside the native callback stack: Lua may disable/unload the
   * endpoint here. One event per dispatch also bounds main-loop work. */
  if (event) {
    if (event->signal == SIGNAL_PARAMETER) {
      self->parameter_pending = FALSE;
      g_signal_emit (self, signals[event->signal], 0, event->pod, event->received_us);
    } else if (event->signal == SIGNAL_STATE_CHANGED) {
      if (event->state == PW_FILTER_STATE_ERROR ||
          event->state == PW_FILTER_STATE_UNCONNECTED)
        clear_filter (self);
      g_signal_emit (self, signals[event->signal], 0, event->state, event->message);
    } else
      g_signal_emit (self, signals[event->signal], 0, event->message);
    event_free (event);
  } else if (self->overflow) {
    self->overflow = FALSE;
    g_signal_emit (self, signals[SIGNAL_TRANSPORT_ERROR], 0,
        "control endpoint handoff full; incoming requests or observations dropped");
  }
  if (source != self->delivery_source)
    return G_SOURCE_REMOVE;
  if (g_queue_is_empty (self->events) && !self->overflow) {
    g_clear_pointer (&self->delivery_source, g_source_unref);
    return G_SOURCE_REMOVE;
  }
  return G_SOURCE_CONTINUE;
}

static void
queue_event (WpAoControlEndpoint *self, guint signal, WpSpaPod *pod,
    gint state, const gchar *message, gint64 received_us)
{
  g_autoptr (WpCore) core = wp_object_get_core (WP_OBJECT (self));
  EndpointEvent *event;
  if (!core)
    return;
  /* Coalesce repeated malformed-POD observations without retaining a flood. */
  if (signal == SIGNAL_TRANSPORT_ERROR)
    for (GList *link = self->events->head; link; link = link->next) {
      EndpointEvent *queued = link->data;
      if (queued->signal == signal && g_strcmp0 (queued->message, message) == 0)
        return;
    }
  if (signal == SIGNAL_PARAMETER && self->parameter_pending) {
    self->overflow = TRUE;
    return;
  }
  if (g_queue_get_length (self->events) >= EVENT_LIMIT) {
    self->overflow = TRUE;
    /* Preserve transport state/error observations under request overload. */
    if (signal == SIGNAL_PARAMETER)
      return;
    /* Keep the accepted request; replace the oldest non-request observation. */
    GList *link = self->events->head;
    while (((EndpointEvent *) link->data)->signal == SIGNAL_PARAMETER)
      link = link->next;
    event = link->data;
    g_queue_delete_link (self->events, link);
    event_free (event);
  }
  event = g_new0 (EndpointEvent, 1);
  event->signal = signal;
  event->pod = pod ? wp_spa_pod_ref (pod) : NULL;
  event->state = state;
  event->received_us = received_us;
  event->message = g_strdup (message);
  g_queue_push_tail (self->events, event);
  if (signal == SIGNAL_PARAMETER)
    self->parameter_pending = TRUE;
  if (!self->delivery_source)
    wp_core_idle_add (core, &self->delivery_source, deliver_event,
        g_object_ref (self), g_object_unref);
}

/* Check container boundaries before WpSpaPod/Lua iterators can inspect them.
 * This deliberately checks POD structure, not the application grammar. The
 * native callback contract supplies the full root POD allocation; no byte
 * length accompanies that public callback. All nested lengths are untrusted.
 */
static gboolean pod_body_valid (guint32 type, const guint8 *body, gsize size,
    guint depth);

static gboolean
pod_children_valid (const guint8 *body, gsize size, gsize prefix, guint depth)
{
  while (size) {
    struct spa_pod child;
    gsize total, padded;
    if (size < prefix + sizeof (child))
      return FALSE;
    memcpy (&child, body + prefix, sizeof (child));
    if (child.size > size - prefix - sizeof (child))
      return FALSE;
    total = sizeof (child) + (gsize) child.size;
    padded = (total + 7u) & ~(gsize) 7u;
    if (padded > size - prefix || !pod_body_valid (child.type,
            body + prefix + sizeof (child), child.size, depth + 1))
      return FALSE;
    body += prefix + padded;
    size -= prefix + padded;
  }
  return TRUE;
}

static gboolean
pod_body_valid (guint32 type, const guint8 *body, gsize size, guint depth)
{
  struct spa_pod child;
  gsize offset;
  if (depth > POD_DEPTH_LIMIT)
    return FALSE;
  switch (type) {
  case SPA_TYPE_None:
    return size == 0;
  case SPA_TYPE_Bool:
    if (size == 4) {
      gint32 value;
      memcpy (&value, body, sizeof (value));
      return value == 0 || value == 1;
    }
    return FALSE;
  case SPA_TYPE_Id:
  case SPA_TYPE_Int:
  case SPA_TYPE_Float:
    return size == 4;
  case SPA_TYPE_Long:
  case SPA_TYPE_Double:
  case SPA_TYPE_Fd:
  case SPA_TYPE_Rectangle:
  case SPA_TYPE_Fraction:
    return size == 8;
  case SPA_TYPE_Pointer:
    return size == sizeof (struct spa_pod_pointer_body);
  case SPA_TYPE_String:
    return size > 0 && body[size - 1] == '\0' &&
        memchr (body, '\0', size - 1) == NULL &&
        g_utf8_validate ((const gchar *) body, size - 1, NULL);
  case SPA_TYPE_Bytes:
  case SPA_TYPE_Bitmap:
    return TRUE;
  case SPA_TYPE_Struct:
    return pod_children_valid (body, size, 0, depth);
  case SPA_TYPE_Object:
  case SPA_TYPE_Sequence:
    return size >= 8 && pod_children_valid (body + 8, size - 8, 8, depth);
  case SPA_TYPE_Array:
  case SPA_TYPE_Choice:
    offset = type == SPA_TYPE_Array ? 0 : 8;
    if (size < offset + sizeof (child))
      return FALSE;
    memcpy (&child, body + offset, sizeof (child));
    offset += sizeof (child);
    size -= offset;
    body += offset;
    if (child.size == 0)
      return size == 0 && child.type == SPA_TYPE_None;
    if (size % child.size != 0)
      return FALSE;
    while (size) {
      if (!pod_body_valid (child.type, body, child.size, depth + 1))
        return FALSE;
      body += child.size;
      size -= child.size;
    }
    return TRUE;
  default:
    return FALSE;
  }
}

static gboolean
props_valid (const struct spa_pod *pod, gsize limit)
{
  struct spa_pod_object_body object;
  struct spa_pod_prop prop;
  gsize property_size;
  if (!pod || pod->size > limit - sizeof (*pod) ||
      pod->type != SPA_TYPE_Object || pod->size < sizeof (object))
    return FALSE;
  memcpy (&object, SPA_POD_BODY_CONST (pod), sizeof (object));
  if (object.type != SPA_TYPE_OBJECT_Props || object.id != SPA_PARAM_Props ||
      pod->size < sizeof (object) + sizeof (prop) ||
      !pod_body_valid (pod->type, SPA_POD_BODY_CONST (pod), pod->size, 0))
    return FALSE;
  memcpy (&prop, (const guint8 *) SPA_POD_BODY_CONST (pod) + sizeof (object),
      sizeof (prop));
  property_size = sizeof (prop) + (gsize) prop.value.size;
  return prop.key == SPA_PROP_params && prop.flags == 0 &&
      prop.value.type == SPA_TYPE_Struct &&
      pod->size == sizeof (object) + ((property_size + 7u) & ~(gsize) 7u);
}

static void
clear_timeout (WpAoControlEndpoint *self)
{
  if (self->connect_timeout) {
    g_source_destroy (self->connect_timeout);
    g_clear_pointer (&self->connect_timeout, g_source_unref);
  }
}

static void
clear_filter (WpAoControlEndpoint *self)
{
  self->bound = FALSE;
  clear_events (self);
  if (self->filter) {
    struct pw_filter *filter = g_steal_pointer (&self->filter);
    spa_hook_remove (&self->listener);
    pw_filter_destroy (filter);
  }
}

static void
fail_enable (WpAoControlEndpoint *self, const gchar *message)
{
  g_autoptr (WpTransition) transition =
      g_steal_pointer (&self->enable_transition);
  clear_timeout (self);
  if (transition)
    wp_transition_return_error (transition, g_error_new_literal (
        WP_DOMAIN_LIBRARY, WP_LIBRARY_ERROR_OPERATION_FAILED, message));
}

static void
on_filter_destroy (void *data)
{
  g_autoptr (WpAoControlEndpoint) self = g_object_ref (data);
  /* pw_core destroys its filters before its disconnected signal. */
  self->filter = NULL;
  self->bound = FALSE;
  spa_hook_remove (&self->listener);
  clear_events (self);
  fail_enable (self, "control endpoint core disconnected");
  wp_object_update_features (WP_OBJECT (self), 0, WP_PLUGIN_FEATURE_ENABLED);
  queue_event (self, SIGNAL_STATE_CHANGED, NULL,
      PW_FILTER_STATE_UNCONNECTED, "core disconnected", 0);
}

static void
on_filter_state_changed (void *data, enum pw_filter_state old,
    enum pw_filter_state state, const char *error)
{
  g_autoptr (WpAoControlEndpoint) self = g_object_ref (data);
  if (state == PW_FILTER_STATE_PAUSED && !identity_valid (self)) {
    state = PW_FILTER_STATE_ERROR;
    error = "reserved control endpoint properties changed during export";
  }
  self->bound = state == PW_FILTER_STATE_PAUSED;
  if (self->enable_transition) {
    if (state == PW_FILTER_STATE_PAUSED) {
      g_autoptr (WpTransition) transition =
          g_steal_pointer (&self->enable_transition);
      clear_timeout (self);
      wp_object_update_features (WP_OBJECT (self), WP_PLUGIN_FEATURE_ENABLED, 0);
    } else if (state == PW_FILTER_STATE_ERROR ||
        state == PW_FILTER_STATE_UNCONNECTED) {
      fail_enable (self, error ? error : "control endpoint disconnected");
    }
  }
  if (state == PW_FILTER_STATE_ERROR || state == PW_FILTER_STATE_UNCONNECTED) {
    clear_events (self);
    wp_object_update_features (WP_OBJECT (self), 0, WP_PLUGIN_FEATURE_ENABLED);
  }
  queue_event (self, SIGNAL_STATE_CHANGED, NULL, state, error ? error : "", 0);
}

static void
on_filter_param_changed (void *data, void *port_data, uint32_t id,
    const struct spa_pod *param)
{
  g_autoptr (WpAoControlEndpoint) self = g_object_ref (data);
  g_autoptr (WpSpaPod) wrapped = NULL;
  g_autoptr (WpSpaPod) owned = NULL;
  gint64 received_us = g_get_monotonic_time ();
  if (port_data || id != SPA_PARAM_Props || self->publishing)
    return;
  if (!props_valid (param, REQUEST_LIMIT)) {
    queue_event (self, SIGNAL_TRANSPORT_ERROR, NULL, 0,
        "incoming Props POD is malformed or exceeds 16 KiB", 0);
    return;
  }
  if (self->parameter_pending || g_queue_get_length (self->events) >= EVENT_LIMIT) {
    self->overflow = TRUE;
    return;
  }
  wrapped = wp_spa_pod_new_wrap_const (param);
  owned = wp_spa_pod_copy (wrapped);
  queue_event (self, SIGNAL_PARAMETER, owned, 0, NULL, received_us);
}

static const struct pw_filter_events filter_events = {
  PW_VERSION_FILTER_EVENTS,
  .destroy = on_filter_destroy,
  .state_changed = on_filter_state_changed,
  .param_changed = on_filter_param_changed,
};

static gboolean
on_connect_timeout (gpointer data)
{
  WpAoControlEndpoint *self = WP_AO_CONTROL_ENDPOINT (data);
  clear_filter (self);
  fail_enable (self, "control endpoint export timed out");
  return G_SOURCE_REMOVE;
}

static gboolean
wp_ao_control_endpoint_publish_records (WpAoControlEndpoint *self,
    WpSpaPod *capabilities, WpSpaPod *completion, WpSpaPod *rejection)
{
  g_autoptr (WpCore) core = wp_object_get_core (WP_OBJECT (self));
  WpSpaPod *records[] = { capabilities, completion, rejection };
  const struct spa_pod *pods[3];
  guint n_pods = 0;
  guint64 total_size = 0;
  int res;
  /* Refuse cross-context callers without dispatching Lua signals off-thread. */
  if (!core || !g_main_context_is_owner (wp_core_get_g_main_context (core)))
    return FALSE;
  if (!self->filter || !self->bound || self->publishing || !capabilities)
    goto invalid;
  for (guint i = 0; i < G_N_ELEMENTS (records); i++) {
    const struct spa_pod *pod;
    if (!records[i])
      continue;
    pod = wp_spa_pod_get_spa_pod (records[i]);
    if (!props_valid (pod, PUBLICATION_LIMIT))
      goto invalid;
    total_size += SPA_POD_SIZE (pod);
    if (total_size > PUBLICATION_LIMIT)
      goto invalid;
    pods[n_pods++] = pod;
  }
  self->publishing = TRUE;
  res = pw_filter_update_params (self->filter, NULL, pods, n_pods);
  self->publishing = FALSE;
  if (res < 0) {
    g_autofree gchar *message = g_strdup_printf (
        "control endpoint publication failed: %s", g_strerror (-res));
    wp_warning_object (self, "%s", message);
    return FALSE;
  }
  return TRUE;

invalid:
  wp_warning_object (self, "%s",
      "endpoint unavailable, reentrant publication, or invalid Props records "
      "(64 KiB combined limit)");
  return FALSE;
}

static gboolean
wp_ao_control_endpoint_publish (WpAoControlEndpoint *self, WpSpaPod *param)
{
  return wp_ao_control_endpoint_publish_records (self, param, NULL, NULL);
}

static guint
wp_ao_control_endpoint_get_node_id (WpAoControlEndpoint *self)
{
  return self->filter && self->bound ?
      pw_filter_get_node_id (self->filter) : SPA_ID_INVALID;
}

static guint
wp_ao_control_endpoint_get_owner_pid (WpAoControlEndpoint *self)
{
  return (guint) getpid ();
}

static void
wp_ao_control_endpoint_enable (WpPlugin *plugin, WpTransition *transition)
{
  WpAoControlEndpoint *self = WP_AO_CONTROL_ENDPOINT (plugin);
  g_autoptr (WpCore) core = wp_object_get_core (WP_OBJECT (plugin));
  struct pw_properties *props;
  struct spa_pod_object initial = {
    { sizeof (struct spa_pod_object_body), SPA_TYPE_Object },
    { SPA_TYPE_OBJECT_Props, SPA_PARAM_Props }
  };
  const struct spa_pod *params[] = { &initial.pod };
  int res;

  clear_filter (self);
  if (!core || !wp_core_get_pw_core (core)) {
    wp_transition_return_error (transition, g_error_new_literal (
        WP_DOMAIN_LIBRARY, WP_LIBRARY_ERROR_SERVICE_UNAVAILABLE,
        "control endpoint requires a connected core"));
    return;
  }
  props = pw_properties_new_dict (wp_properties_peek_dict (self->properties));
  if (props)
    self->filter = pw_filter_new (wp_core_get_pw_core (core),
        wp_properties_get (self->properties, PW_KEY_NODE_NAME), props);
  if (!self->filter) {
    wp_transition_return_error (transition, g_error_new_literal (
        WP_DOMAIN_LIBRARY, WP_LIBRARY_ERROR_OPERATION_FAILED,
        "could not allocate control endpoint filter"));
    return;
  }
  pw_filter_add_listener (self->filter, &self->listener, &filter_events, self);
  self->enable_transition = g_object_ref (transition);
  wp_core_timeout_add (core, &self->connect_timeout, CONNECT_TIMEOUT_MS,
      on_connect_timeout, self, NULL);
  res = pw_filter_connect (self->filter, PW_FILTER_FLAG_INACTIVE, params, 1);
  if (res < 0) {
    g_autofree gchar *message = g_strdup_printf (
        "could not connect control endpoint: %s", g_strerror (-res));
    clear_filter (self);
    fail_enable (self, message);
  } else if (!identity_valid (self)) {
    /* filter.rules and PipeWire environment properties can override arguments. */
    clear_filter (self);
    fail_enable (self, "filter configuration overrode reserved endpoint properties");
  }
}

static void
wp_ao_control_endpoint_disable (WpPlugin *plugin)
{
  WpAoControlEndpoint *self = WP_AO_CONTROL_ENDPOINT (plugin);
  clear_filter (self);
  fail_enable (self, "control endpoint disabled during export");
}

static void
wp_ao_control_endpoint_init (WpAoControlEndpoint *self)
{
  self->events = g_queue_new ();
}

static void
wp_ao_control_endpoint_finalize (GObject *object)
{
  WpAoControlEndpoint *self = WP_AO_CONTROL_ENDPOINT (object);
  clear_timeout (self);
  clear_filter (self);
  g_clear_object (&self->enable_transition);
  g_clear_pointer (&self->properties, wp_properties_unref);
  g_clear_pointer (&self->events, g_queue_free);
  G_OBJECT_CLASS (wp_ao_control_endpoint_parent_class)->finalize (object);
}

static void
wp_ao_control_endpoint_class_init (WpAoControlEndpointClass *klass)
{
  GObjectClass *object_class = G_OBJECT_CLASS (klass);
  WpPluginClass *plugin_class = WP_PLUGIN_CLASS (klass);
  object_class->finalize = wp_ao_control_endpoint_finalize;
  plugin_class->enable = wp_ao_control_endpoint_enable;
  plugin_class->disable = wp_ao_control_endpoint_disable;

  signals[SIGNAL_PARAMETER] = g_signal_new ("parameter", G_TYPE_FROM_CLASS (klass),
      G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL, G_TYPE_NONE, 2, WP_TYPE_SPA_POD, G_TYPE_INT64);
  signals[SIGNAL_STATE_CHANGED] = g_signal_new ("state-changed",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
      G_TYPE_NONE, 2, G_TYPE_INT, G_TYPE_STRING);
  signals[SIGNAL_TRANSPORT_ERROR] = g_signal_new ("transport-error",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
      G_TYPE_NONE, 1, G_TYPE_STRING);
  signals[ACTION_PUBLISH] = g_signal_new_class_handler ("publish",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST | G_SIGNAL_ACTION,
      (GCallback) wp_ao_control_endpoint_publish, NULL, NULL, NULL,
      G_TYPE_BOOLEAN, 1, WP_TYPE_SPA_POD);
  signals[ACTION_PUBLISH_RECORDS] = g_signal_new_class_handler ("publish-records",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST | G_SIGNAL_ACTION,
      (GCallback) wp_ao_control_endpoint_publish_records, NULL, NULL, NULL,
      G_TYPE_BOOLEAN, 3, WP_TYPE_SPA_POD, WP_TYPE_SPA_POD, WP_TYPE_SPA_POD);
  signals[ACTION_GET_NODE_ID] = g_signal_new_class_handler ("get-node-id",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST | G_SIGNAL_ACTION,
      (GCallback) wp_ao_control_endpoint_get_node_id, NULL, NULL, NULL,
      G_TYPE_UINT, 0);
  signals[ACTION_GET_OWNER_PID] = g_signal_new_class_handler ("get-owner-pid",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST | G_SIGNAL_ACTION,
      (GCallback) wp_ao_control_endpoint_get_owner_pid, NULL, NULL, NULL,
      G_TYPE_UINT, 0);
  signals[ACTION_GET_LINK_FORMAT] = g_signal_new_class_handler ("get-link-format",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST | G_SIGNAL_ACTION,
      (GCallback) wp_ao_control_endpoint_get_link_format, NULL, NULL, NULL,
      WP_TYPE_SPA_POD, 1, WP_TYPE_LINK);
  signals[ACTION_OBSERVE_LINK] = g_signal_new_class_handler ("observe-link",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST | G_SIGNAL_ACTION,
      (GCallback) wp_ao_control_endpoint_observe_link, NULL, NULL, NULL,
      G_TYPE_BOOLEAN, 1, WP_TYPE_LINK);
  signals[SIGNAL_LINK_INFO_CHANGED] = g_signal_new ("link-info-changed",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
      G_TYPE_NONE, 1, WP_TYPE_LINK);
  signals[ACTION_RETIRE_LINK] = g_signal_new_class_handler ("retire-link",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST | G_SIGNAL_ACTION,
      (GCallback) wp_ao_control_endpoint_retire_link, NULL, NULL, NULL,
      G_TYPE_BOOLEAN, 1, WP_TYPE_LINK);
  signals[SIGNAL_LINK_RETIRED] = g_signal_new ("link-retired",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST, 0, NULL, NULL, NULL,
      G_TYPE_NONE, 2, WP_TYPE_LINK, G_TYPE_STRING);
  signals[ACTION_DISCONNECT] = g_signal_new_class_handler ("disconnect",
      G_TYPE_FROM_CLASS (klass), G_SIGNAL_RUN_LAST | G_SIGNAL_ACTION,
      (GCallback) wp_ao_control_endpoint_disconnect, NULL, NULL, NULL,
      G_TYPE_NONE, 0);
}

WP_PLUGIN_EXPORT GObject *
wireplumber__module_init (WpCore *core, WpSpaJson *args, GError **error)
{
  g_autofree gchar *name = NULL, *node_name = NULL, *profile = NULL;
  g_autofree gchar *instance = NULL;
  g_autoptr (WpSpaJson) instance_json = NULL, extra = NULL;
  g_autoptr (WpProperties) properties = wp_properties_new_empty ();
  gchar *end;
  gint64 value;
  WpAoControlEndpoint *self;

  if (!args || !wp_spa_json_is_object (args) ||
      !wp_spa_json_object_get (args, "node.name", "s", &node_name,
          "profile", "s", &profile, "instance", "J", &instance_json, NULL) ||
      !node_name[0] || !profile[0])
    goto invalid;
  /* WpSpaJson's integer accessor is int32: parse decimal int64 exactly. */
  instance = wp_spa_json_is_string (instance_json) ?
      wp_spa_json_parse_string (instance_json) : wp_spa_json_to_string (instance_json);
  if (!instance || !g_ascii_isdigit (instance[0]))
    goto invalid;
  for (const gchar *p = instance; *p; p++)
    if (!g_ascii_isdigit (*p))
      goto invalid;
  errno = 0;
  value = g_ascii_strtoll (instance, &end, 10);
  if (errno || *end || value <= 0)
    goto invalid;
  wp_spa_json_object_get (args, "plugin.name", "s", &name, NULL);
  if (name && !name[0])
    goto invalid;
  if (wp_spa_json_object_get (args, "properties", "J", &extra, NULL)) {
    if (!wp_spa_json_is_object (extra) ||
        wp_properties_update_from_json (properties, extra) < 0)
      goto invalid;
    for (guint i = 0; i < G_N_ELEMENTS (identity_keys); i++)
      if (wp_properties_get (properties, identity_keys[i]))
        goto invalid;
  }
  wp_properties_set (properties, PW_KEY_NODE_NAME, node_name);
  wp_properties_set (properties, "node.cache-params", "false");
  wp_properties_set (properties, "pipewireao.rtc-control.protocol",
      "pipewireao.rtc-control/1");
  wp_properties_set (properties, "pipewireao.rtc-control.profile", profile);
  wp_properties_setf (properties, "pipewireao.rtc-control.instance",
      "%" G_GINT64_FORMAT, value);
  wp_properties_setf (properties, "pipewireao.rtc-control.owner-pid",
      "%u", (guint) getpid ());
  self = g_object_new (wp_ao_control_endpoint_get_type (),
      "name", name ? name : "ao-control-endpoint", "core", core, NULL);
  self->properties = g_steal_pointer (&properties);
  return G_OBJECT (self);

invalid:
  g_set_error_literal (error, WP_DOMAIN_LIBRARY, WP_LIBRARY_ERROR_INVALID_ARGUMENT,
      "control endpoint requires node.name, profile and a positive int64 instance; "
      "properties must be an object without reserved endpoint identity keys");
  return NULL;
}
