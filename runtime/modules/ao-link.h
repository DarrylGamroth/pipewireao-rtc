/* PipeWireAO RTC — SPDX-License-Identifier: MIT */
#pragma once
#include <wp/wp.h>

/* Dispose an application-owned Link after any creation/bind stack unwinds.
 * Cancellation is deliberately not exposed: retirement must continue after a
 * policy deadline. The caller also accounts for its activation callbacks. */
void ao_link_retire (WpLink *link, GAsyncReadyCallback callback, gpointer data);
gboolean ao_link_retire_finish (WpLink *link, GAsyncResult *result, GError **error);

/* Snapshot of standard public pw_link_info, independent of daemon internals. */
WpSpaPod *ao_link_get_format (WpLink *link);
