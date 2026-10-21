/* PipeWireAO RTC — SPDX-License-Identifier: MIT */
#include "ao-link.h"
#include <pipewire/link.h>
#include <spa/pod/pod.h>

static gboolean
retire_link (gpointer data)
{
  GTask *task = data;
  WpLink *link = g_task_get_source_object (task);
  /* BOUND deactivation alone cannot cancel queued/unbound activation. Abort
   * settles those transitions; dispose also destroys a created native proxy.
   * This idle is essential when retirement originates in pw-proxy-created. */
  wp_object_abort_activation (WP_OBJECT (link), "RTC Link retired");
  g_object_run_dispose (G_OBJECT (link));
  if (wp_proxy_get_pw_proxy (WP_PROXY (link)))
    g_task_return_new_error (task, WP_DOMAIN_LIBRARY,
        WP_LIBRARY_ERROR_OPERATION_FAILED, "RTC Link native proxy remains");
  else
    g_task_return_boolean (task, TRUE);
  return G_SOURCE_REMOVE;
}

void
ao_link_retire (WpLink *link, GAsyncReadyCallback callback, gpointer data)
{
  g_autoptr (WpCore) core = wp_object_get_core (WP_OBJECT (link));
  GTask *task = g_task_new (link, NULL, callback, data);
  g_task_set_source_tag (task, ao_link_retire);
  if (!core) {
    g_task_return_new_error (task, WP_DOMAIN_LIBRARY,
        WP_LIBRARY_ERROR_OPERATION_FAILED, "RTC Link core unavailable; retirement unknown");
    g_object_unref (task);
    return;
  }
  wp_core_idle_add (core, NULL, retire_link, task, g_object_unref);
}

gboolean
ao_link_retire_finish (WpLink *link, GAsyncResult *result, GError **error)
{
  g_return_val_if_fail (g_task_is_valid (result, link), FALSE);
  g_return_val_if_fail (g_async_result_is_tagged (result, ao_link_retire), FALSE);
  return g_task_propagate_boolean (G_TASK (result), error);
}

WpSpaPod *
ao_link_get_format (WpLink *link)
{
  const struct pw_link_info *info =
      wp_pipewire_object_get_native_info (WP_PIPEWIRE_OBJECT (link));
  if (!info || !info->format || SPA_POD_SIZE (info->format) < 16 ||
      SPA_POD_SIZE (info->format) > 65536)
    return NULL;
  g_autoptr (WpSpaPod) wrapped = wp_spa_pod_new_wrap_const (info->format);
  return wp_spa_pod_copy (wrapped);
}
