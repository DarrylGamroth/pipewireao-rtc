/* SPDX-License-Identifier: MIT
 * Local RTC management admission, worker lifetime and durable receipts.
 * Scientific/configuration semantics remain in PipeWireAORTC.ManagementCLI.
 */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <gio/gunixsocketaddress.h>
#include <glib-unix.h>
#include <poll.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include <wp/wp.h>

#define PROTOCOL "pipewireao.management/1"
#define CONFIGURATION "pipewireao.configuration/1"
#define SIMULATOR "pipewireao.simulator-settings/1"
#define REQUEST_LIMIT (64 * 1024)
#define RECEIPT_LIMIT (16 * 1024 * 1024 + 4096)
#define CONNECTION_LIMIT 16
#define RECEIPT_CAPACITY 256

typedef struct
{
  char *socket_path, *state_root, *configuration_root, *worker_json;
  char **worker_argv;
  int operation_timeout, describe_timeout, idle_timeout;
  int root_fd, lock_fd, worker_in, worker_out;
  GPid worker_pid;
  gint64 worker_idle;
  GMutex operation, handlers_lock;
  GCond handlers_done;
  gint handlers, stopping;
  int receipt_count;
  GMainLoop *loop;
  GSocketService *service;
  GAsyncQueue *spawn_requests;
  GThread *spawner;
  gboolean owns_socket;
} Management;

/* WpSpaJson intentionally accepts relaxed SPA JSON. Require strict JSON on this
 * public wire boundary before using its object API. Bound recursion as well as bytes. */
typedef struct
{
  const char *p, *end;
  unsigned depth;
} JsonInput;
static void
whitespace (JsonInput *s)
{
  while (s->p < s->end && strchr (" \t\r\n", *s->p))
    s->p++;
}
static gboolean json_value (JsonInput *s);
static gboolean
json_string (JsonInput *s)
{
  if (s->p == s->end || *s->p++ != '"')
    return FALSE;
  while (s->p < s->end)
    {
      unsigned char c = *s->p++;
      if (c == '"')
        return TRUE;
      if (c < 32)
        return FALSE;
      if (c == '\\')
        {
          if (s->p == s->end)
            return FALSE;
          c = *s->p++;
          if (c == 'u')
            {
              if (s->end - s->p >= 4 && !strncmp (s->p, "0000", 4))
                return FALSE;
              for (int i = 0; i < 4; i++)
                if (s->p == s->end || !g_ascii_isxdigit (*s->p++))
                  return FALSE;
            }
          else if (!strchr ("\"\\/bfnrt", c))
            return FALSE;
        }
    }
  return FALSE;
}
static gboolean
json_value (JsonInput *s)
{
  whitespace (s);
  if (s->p == s->end || ++s->depth > 64)
    return FALSE;
  char c = *s->p;
  if (c == '"')
    {
      if (!json_string (s))
        return FALSE;
    }
  else if (c == '{' || c == '[')
    {
      char end = c == '{' ? '}' : ']';
      s->p++;
      whitespace (s);
      if (s->p < s->end && *s->p == end)
        s->p++;
      else
        while (TRUE)
          {
            if (c == '{')
              {
                if (!json_string (s))
                  return FALSE;
                whitespace (s);
                if (s->p == s->end || *s->p++ != ':')
                  return FALSE;
              }
            if (!json_value (s))
              return FALSE;
            whitespace (s);
            if (s->p == s->end)
              return FALSE;
            if (*s->p == end)
              {
                s->p++;
                break;
              }
            if (*s->p++ != ',')
              return FALSE;
            whitespace (s);
          }
    }
  else if (c == '-' || g_ascii_isdigit (c))
    {
      if (*s->p == '-')
        s->p++;
      if (s->p == s->end)
        return FALSE;
      if (*s->p == '0')
        s->p++;
      else
        {
          if (*s->p < '1' || *s->p > '9')
            return FALSE;
          while (s->p < s->end && g_ascii_isdigit (*s->p))
            s->p++;
        }
      if (s->p < s->end && *s->p == '.')
        {
          s->p++;
          if (s->p == s->end || !g_ascii_isdigit (*s->p))
            return FALSE;
          while (s->p < s->end && g_ascii_isdigit (*s->p))
            s->p++;
        }
      if (s->p < s->end && (*s->p == 'e' || *s->p == 'E'))
        {
          s->p++;
          if (s->p < s->end && (*s->p == '+' || *s->p == '-'))
            s->p++;
          if (s->p == s->end || !g_ascii_isdigit (*s->p))
            return FALSE;
          while (s->p < s->end && g_ascii_isdigit (*s->p))
            s->p++;
        }
    }
  else
    {
      const char *literal = c == 't' ? "true" : c == 'f' ? "false" : c == 'n' ? "null" : NULL;
      if (!literal || s->end - s->p < (gssize)strlen (literal)
          || strncmp (s->p, literal, strlen (literal)))
        return FALSE;
      s->p += strlen (literal);
    }
  s->depth--;
  return TRUE;
}
static WpSpaJson *
parse_json (const char *text)
{
  JsonInput s = { text, text + strlen (text), 0 };
  if (!g_utf8_validate (text, -1, NULL) || !json_value (&s))
    return NULL;
  whitespace (&s);
  return s.p == s.end ? wp_spa_json_new_from_string (text) : NULL;
}
static gboolean
valid_id (const char *id)
{
  if (!id || strlen (id) != 32)
    return FALSE;
  for (int i = 0; i < 32; i++)
    if (!(g_ascii_isdigit (id[i]) || (id[i] >= 'a' && id[i] <= 'f')))
      return FALSE;
  return TRUE;
}
/* Enforce known keys, including uniqueness (SPA getters otherwise take one). */
static gboolean
keys (WpSpaJson *json, const char *allowed)
{
  if (!json || !wp_spa_json_is_object (json))
    return FALSE;
  g_autoptr (WpSpaJsonParser) p = wp_spa_json_parser_new_object (json);
  g_autoptr (GHashTable) seen = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
  char *key;
  while ((key = wp_spa_json_parser_get_string (p)))
    {
      g_autofree char *token = g_strdup_printf ("|%s|", key);
      if (strchr (key, '|') || !strstr (allowed, token) || g_hash_table_contains (seen, key))
        {
          g_free (key);
          return FALSE;
        }
      g_hash_table_add (seen, key);
      g_autoptr (WpSpaJson) value = wp_spa_json_parser_get_json (p);
      if (!value)
        return FALSE;
    }
  return TRUE;
}
static WpSpaJson *
error_response (const char *id, const char *error, gboolean unavailable)
{
  return wp_spa_json_new_object ("protocol", "s", PROTOCOL, "id", "s", id ? id : "", "ok", "b",
                                 FALSE, "error", "s", error, "unavailable", "b", unavailable, NULL);
}
static WpSpaJson *
preadmission_error (const char *error)
{
  return wp_spa_json_new_object ("protocol", "s", PROTOCOL, "id", "s", "", "ok", "b", FALSE,
                                 "admitted", "b", FALSE, "error", "s", error, NULL);
}
static WpSpaJson *
result_response (const char *id, WpSpaJson *result)
{
  return wp_spa_json_new_object ("protocol", "s", PROTOCOL, "id", "s", id, "ok", "b", TRUE,
                                 "result", "J", result, NULL);
}
static gint64
deadline_seconds (int seconds)
{
  return g_get_monotonic_time () + (gint64)seconds * G_USEC_PER_SEC;
}
static gboolean
ready (Management *m, int fd, short events, gint64 deadline)
{
  while (!g_atomic_int_get (&m->stopping))
    {
      gint64 left = deadline - g_get_monotonic_time ();
      if (left <= 0)
        return FALSE;
      struct pollfd p = { fd, events, 0 };
      int n = poll (&p, 1, MIN ((left + 999) / 1000, 100));
      if (n > 0)
        return (p.revents & events) != 0;
      if (n < 0 && errno != EINTR)
        return FALSE;
    }
  return FALSE;
}
static gboolean
write_bytes (Management *m, int fd, const char *data, size_t size, gint64 deadline)
{
  while (size)
    {
      if (!ready (m, fd, POLLOUT, deadline))
        return FALSE;
      ssize_t n = write (fd, data, size);
      if (n < 0 && (errno == EINTR || errno == EAGAIN))
        continue;
      if (n <= 0)
        return FALSE;
      data += n;
      size -= n;
    }
  return TRUE;
}
/* Ancillary descriptors are consumed on every recvmsg, including invalid later
 * attachments, so rejection cannot leak descriptors into the companion. */
static char *
read_line (Management *m, int fd, size_t limit, gint64 deadline, gboolean socket_input,
           int *input_fd)
{
  GString *line = g_string_sized_new (256);
  gboolean first = TRUE;
  while (line->len < limit)
    {
      if (!ready (m, fd, POLLIN, deadline))
        break;
      char buffer[4096];
      ssize_t n;
      if (socket_input)
        {
          char control[CMSG_SPACE (sizeof (int) * 16)];
          struct iovec iov = { buffer, first ? 1 : MIN (sizeof buffer, limit - line->len) };
          struct msghdr msg = { .msg_iov = &iov,
                                .msg_iovlen = 1,
                                .msg_control = control,
                                .msg_controllen = sizeof control };
          n = recvmsg (fd, &msg, MSG_CMSG_CLOEXEC);
          gboolean invalid = (msg.msg_flags & (MSG_CTRUNC | MSG_TRUNC)) != 0;
          if (n >= 0)
            for (struct cmsghdr *c = CMSG_FIRSTHDR (&msg); c; c = CMSG_NXTHDR (&msg, c))
              {
                if (c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS)
                  {
                    invalid = TRUE;
                    continue;
                  }
                size_t count = (c->cmsg_len - CMSG_LEN (0)) / sizeof (int);
                int *fds = (int *)CMSG_DATA (c);
                for (size_t i = 0; i < count; i++)
                  {
                    if (first && input_fd && *input_fd < 0 && !invalid)
                      *input_fd = fds[i];
                    else
                      {
                        close (fds[i]);
                        invalid = TRUE;
                      }
                  }
              }
          if (invalid)
            break;
        }
      else
        n = read (fd, buffer, MIN (sizeof buffer, limit - line->len));
      if (n < 0 && (errno == EINTR || errno == EAGAIN))
        continue;
      if (n <= 0)
        break;
      first = FALSE;
      char *newline = memchr (buffer, '\n', n);
      if (memchr (buffer, 0, n))
        break;
      if (newline)
        {
          /* One frame only. Do not silently admit pipelined requests. */
          if (newline != buffer + n - 1)
            break;
          g_string_append_len (line, buffer, n - 1);
          return g_string_free (line, FALSE);
        }
      g_string_append_len (line, buffer, n);
    }
  g_string_free (line, TRUE);
  return NULL;
}
static gboolean
send_response (Management *m, int fd, WpSpaJson *response)
{
  g_autofree char *text = wp_spa_json_to_string (response);
  gint64 deadline = deadline_seconds (10);
  return write_bytes (m, fd, text, strlen (text), deadline)
         && write_bytes (m, fd, "\n", 1, deadline);
}

static gboolean
durable_receipt (Management *m, const char *id, WpSpaJson *record)
{
  g_autofree char *name = g_strdup_printf ("%s.json", id);
  g_autofree char *temp = g_strdup_printf (".%s.tmp", id);
  g_autofree char *text = wp_spa_json_to_string (record);
  int fd = openat (m->root_fd, temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (fd < 0)
    return FALSE;
  size_t left = strlen (text);
  const char *p = text;
  gboolean ok = TRUE;
  while (left)
    {
      ssize_t n = write (fd, p, left);
      if (n < 0 && errno == EINTR)
        continue;
      if (n <= 0)
        {
          ok = FALSE;
          break;
        }
      left -= n;
      p += n;
    }
  if (ok)
    ok = fsync (fd) == 0;
  close (fd);
  if (ok)
    ok = renameat (m->root_fd, temp, m->root_fd, name) == 0;
  if (ok)
    ok = fsync (m->root_fd) == 0;
  if (!ok)
    unlinkat (m->root_fd, temp, 0);
  return ok;
}
static WpSpaJson *
read_receipt (Management *m, const char *id)
{
  g_autofree char *name = g_strdup_printf ("%s.json", id);
  int fd = openat (m->root_fd, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (fd < 0)
    return NULL;
  struct stat st;
  char *data = NULL;
  if (fstat (fd, &st) == 0 && S_ISREG (st.st_mode) && st.st_size > 0 && st.st_size <= RECEIPT_LIMIT)
    {
      data = g_malloc (st.st_size + 1);
      size_t pos = 0;
      while (pos < (size_t)st.st_size)
        {
          ssize_t n = read (fd, data + pos, st.st_size - pos);
          if (n < 0 && errno == EINTR)
            continue;
          if (n <= 0)
            break;
          pos += n;
        }
      if (pos != (size_t)st.st_size)
        g_clear_pointer (&data, g_free);
      else
        data[pos] = 0;
    }
  close (fd);
  g_autofree char *owned = data;
  return owned ? parse_json (owned) : NULL;
}
static WpSpaJson *
receipt_record (const char *id, const char *domain, const char *state, WpSpaJson *response)
{
  if (response)
    return wp_spa_json_new_object ("id", "s", id, "domain", "s", domain, "state", "s", state,
                                   "response", "J", response, NULL);
  return wp_spa_json_new_object ("id", "s", id, "domain", "s", domain, "state", "s", state, NULL);
}
static int
recover_receipts (Management *m)
{
  g_autoptr (GDir) dir = g_dir_open (m->state_root, 0, NULL);
  if (!dir)
    return -1;
  const char *name;
  /* Recover interrupted atomic writes before opening any accepted record. A
   * replacement uses O_EXCL, and directory enumeration has no ordering promise.
   * Only our exact temporary naming scheme belongs to this cleanup. */
  while ((name = g_dir_read_name (dir)))
    {
      if (strlen (name) != 37 || name[0] != '.' || strcmp (name + 33, ".tmp"))
        continue;
      g_autofree char *id = g_strndup (name + 1, 32);
      if (valid_id (id) && unlinkat (m->root_fd, name, 0) < 0)
        return -1;
    }
  g_dir_rewind (dir);
  int count = 0;
  while ((name = g_dir_read_name (dir)))
    {
      if (!g_str_has_suffix (name, ".json"))
        continue;
      g_autofree char *id = g_strndup (name, strlen (name) - 5);
      if (!valid_id (id))
        return -1;
      g_autoptr (WpSpaJson) record = read_receipt (m, id);
      g_autofree char *domain = NULL, *state = NULL, *stored_id = NULL;
      if (!record
          || !wp_spa_json_object_get (record, "id", "s", &stored_id, "domain", "s", &domain,
                                      "state", "s", &state, NULL)
          || strcmp (stored_id, id)
          || (strcmp (state, "accepted") && strcmp (state, "complete")
              && strcmp (state, "unknown")))
        return -1;
      if (!strcmp (state, "accepted"))
        {
          g_autoptr (WpSpaJson) unknown = receipt_record (id, domain, "unknown", NULL);
          if (!durable_receipt (m, id, unknown))
            return -1;
        }
      count++;
    }
  return count;
}
static void
retire_worker (Management *m)
{
  if (m->worker_pid)
    {
      kill (-m->worker_pid, SIGKILL);
      while (waitpid (m->worker_pid, NULL, 0) < 0 && errno == EINTR)
        {
        }
      g_spawn_close_pid (m->worker_pid);
      m->worker_pid = 0;
    }
  if (m->worker_in >= 0)
    close (m->worker_in);
  if (m->worker_out >= 0)
    close (m->worker_out);
  m->worker_in = m->worker_out = -1;
}
static void
worker_setup (gpointer parent_pid)
{
  /* The parent can die between fork and prctl. Close that race before exec.
   * systemd still owns cleanup of the service cgroup's other descendants. */
  if (prctl (PR_SET_PDEATHSIG, SIGKILL) < 0 || getppid () != *(pid_t *)parent_pid
      || setpgid (0, 0) < 0)
    _exit (127);
  sigset_t empty;
  sigemptyset (&empty);
  sigprocmask (SIG_SETMASK, &empty, NULL);
  signal (SIGTERM, SIG_DFL);
  signal (SIGINT, SIG_DFL);
  signal (SIGPIPE, SIG_DFL);
}
static gboolean
spawn_worker (Management *m)
{
  if (m->worker_pid)
    return TRUE;
  g_autoptr (GError) error = NULL;
  pid_t parent_pid = getpid ();
  if (!g_spawn_async_with_pipes (
          NULL, m->worker_argv, NULL, G_SPAWN_DO_NOT_REAP_CHILD | G_SPAWN_SEARCH_PATH, worker_setup,
          &parent_pid, &m->worker_pid, &m->worker_in, &m->worker_out, NULL, &error))
    {
      g_warning ("management worker unavailable: %s", error->message);
      return FALSE;
    }
  if (fcntl (m->worker_in, F_SETFL, O_NONBLOCK) < 0
      || fcntl (m->worker_out, F_SETFL, O_NONBLOCK) < 0)
    {
      g_warning ("cannot make management worker pipes nonblocking: %s", g_strerror (errno));
      retire_worker (m);
      return FALSE;
    }
  return TRUE;
}
/* Linux ties PDEATHSIG to the forking thread, not merely its process. Keep
 * spawning on one persistent thread so closing a client cannot kill the cache.
 * The operation mutex permits only one synchronous spawn handoff at a time. */
typedef struct
{
  Management *management;
  GMutex mutex;
  GCond done;
  gboolean finished, success;
} SpawnRequest;

static gpointer
spawn_thread (gpointer data)
{
  Management *m = data;
  while (TRUE)
    {
      SpawnRequest *request = g_async_queue_pop (m->spawn_requests);
      if ((gpointer)request == m)
        break;
      gboolean success = spawn_worker (request->management);
      g_mutex_lock (&request->mutex);
      request->success = success;
      request->finished = TRUE;
      g_cond_signal (&request->done);
      g_mutex_unlock (&request->mutex);
    }
  return NULL;
}

static gboolean
start_worker (Management *m)
{
  if (m->worker_pid)
    return TRUE;
  if (g_atomic_int_get (&m->stopping))
    return FALSE;
  SpawnRequest request = { .management = m };
  g_mutex_lock (&request.mutex);
  g_async_queue_push (m->spawn_requests, &request);
  while (!request.finished)
    g_cond_wait (&request.done, &request.mutex);
  g_mutex_unlock (&request.mutex);
  g_cond_clear (&request.done);
  g_mutex_clear (&request.mutex);
  return request.success;
}

static WpSpaJson *
execute (Management *m, const char *id, const char *domain, const char *op, WpSpaJson *request,
         size_t limit)
{
  if (!start_worker (m))
    return error_response (id, "management worker unavailable", TRUE);
  g_autofree char *text = wp_spa_json_to_string (request);
  gint64 deadline = deadline_seconds (!strcmp (domain, SIMULATOR) && !strcmp (op, "describe")
                                          ? m->describe_timeout
                                          : m->operation_timeout);
  g_autofree char *line = NULL;
  if (write_bytes (m, m->worker_in, text, strlen (text), deadline)
      && write_bytes (m, m->worker_in, "\n", 1, deadline))
    line = read_line (m, m->worker_out, limit - 128, deadline, FALSE, NULL);
  g_autoptr (WpSpaJson) response = line ? parse_json (line) : NULL;
  gboolean ok = FALSE;
  g_autoptr (WpSpaJson) result = NULL;
  g_autofree char *error = NULL;
  if (response && keys (response, "|ok||result||error||unavailable|")
      && wp_spa_json_object_get (response, "ok", "b", &ok, NULL))
    {
      if (ok && wp_spa_json_object_get (response, "result", "J", &result, NULL))
        {
          WpSpaJson *reply = result_response (id, result);
          if (wp_spa_json_get_size (reply) + 1 <= limit)
            {
              m->worker_idle = g_get_monotonic_time ();
              return reply;
            }
          wp_spa_json_unref (reply);
        }
      if (!ok && wp_spa_json_object_get (response, "error", "s", &error, NULL))
        {
          gboolean unavailable = FALSE;
          wp_spa_json_object_get (response, "unavailable", "b", &unavailable, NULL);
          WpSpaJson *reply = error_response (id, error, unavailable);
          if (wp_spa_json_get_size (reply) + 1 <= limit)
            {
              m->worker_idle = g_get_monotonic_time ();
              return reply;
            }
          wp_spa_json_unref (reply);
        }
    }
  retire_worker (m);
  return error_response (id, "management worker lost, timed out or returned an invalid reply",
                         TRUE);
}
static WpSpaJson *
dispatch (Management *m, const char *line, int fd, gboolean *admitted)
{
  g_autoptr (WpSpaJson) envelope = parse_json (line), request = NULL, args = NULL;
  g_autofree char *id = NULL, *protocol = NULL, *domain = NULL, *op = NULL;
  if (envelope)
    wp_spa_json_object_get (envelope, "id", "s", &id, NULL);
  if (!valid_id (id) || !keys (envelope, "|protocol||id||request|")
      || !wp_spa_json_object_get (envelope, "protocol", "s", &protocol, "request", "J", &request,
                                  NULL)
      || strcmp (protocol, PROTOCOL) || !keys (request, "|protocol||op||arguments|")
      || !wp_spa_json_object_get (request, "protocol", "s", &domain, "op", "s", &op, "arguments",
                                  "J", &args, NULL)
      || !wp_spa_json_is_object (args))
    return error_response (id, "invalid management envelope", FALSE);
  gboolean configuration = !strcmp (domain, CONFIGURATION), simulator = !strcmp (domain, SIMULATOR),
           receipt = !strcmp (domain, PROTOCOL) && !strcmp (op, "receipt");
  gboolean registration = configuration && !strcmp (op, "register");
  gboolean mutation = registration || (configuration && !strcmp (op, "get"))
                      || (simulator && !strcmp (op, "start_rebuild"));
  if (!receipt
      && !(configuration
           && (!strcmp (op, "list") || !strcmp (op, "history") || !strcmp (op, "get")
               || registration))
      && !(simulator
           && (!strcmp (op, "describe") || !strcmp (op, "start_rebuild") || !strcmp (op, "job"))))
    return error_response (id, "unsupported management operation", FALSE);
  if ((fd >= 0) != registration)
    return error_response (
        id, "register requires exactly one descriptor; other operations forbid descriptors", FALSE);
  if (!g_mutex_trylock (&m->operation))
    return error_response (id, "Busy", FALSE);
  *admitted = TRUE;
  WpSpaJson *response = NULL;
  if (receipt)
    {
      g_autofree char *original = NULL;
      if (!keys (args, "|id|") || !wp_spa_json_object_get (args, "id", "s", &original, NULL)
          || !valid_id (original))
        response = error_response (id, "invalid receipt identity", FALSE);
      else
        {
          g_autoptr (WpSpaJson) record = read_receipt (m, original);
          response = record ? result_response (id, record)
                            : error_response (id, "receipt not found", FALSE);
          if (wp_spa_json_get_size (response) + 1 > RECEIPT_LIMIT)
            {
              wp_spa_json_unref (response);
              response = error_response (id, "receipt response exceeds byte limit", FALSE);
            }
        }
      goto out;
    }
  {
    g_autoptr (WpSpaJsonBuilder) builder = wp_spa_json_builder_new_object ();
    g_autoptr (WpSpaJsonParser) parser = wp_spa_json_parser_new_object (args);
    g_autoptr (GHashTable) seen = g_hash_table_new_full (g_str_hash, g_str_equal, g_free, NULL);
    char *key;
    while ((key = wp_spa_json_parser_get_string (parser)))
      {
        g_autofree char *owned = key;
        g_autoptr (WpSpaJson) value = wp_spa_json_parser_get_json (parser);
        if (!value || !strcmp (key, "root") || !strcmp (key, "state_root")
            || !strcmp (key, "configuration_root") || (registration && !strcmp (key, "path"))
            || g_hash_table_contains (seen, key))
          {
            response = error_response (
                id, "client paths, roots or duplicate arguments are forbidden", FALSE);
            goto out;
          }
        g_hash_table_add (seen, g_strdup (key));
        wp_spa_json_builder_add_property (builder, key);
        wp_spa_json_builder_add_json (builder, value);
      }
    if (registration)
      {
        struct stat st;
        if (fstat (fd, &st) < 0 || !S_ISREG (st.st_mode) || st.st_size < 0
            || st.st_size > 512 * 1024 * 1024 || (fcntl (fd, F_GETFL) & O_ACCMODE) == O_WRONLY
            || (fcntl (fd, F_GETFL) & O_PATH))
          {
            response = error_response (
                id, "input must be a readable regular FITS descriptor at most 512 MiB", FALSE);
            goto out;
          }
        g_autofree char *path = g_strdup_printf ("/proc/%ld/fd/%d", (long)getpid (), fd);
        wp_spa_json_builder_add_property (builder, "path");
        wp_spa_json_builder_add_string (builder, path);
      }
    g_autoptr (WpSpaJson) worker_args = wp_spa_json_builder_end (builder);
    g_autoptr (WpSpaJson) worker_request
        = configuration
              ? wp_spa_json_new_object ("protocol", "s", domain, "op", "s", op, "arguments", "J",
                                        worker_args, "root", "s", m->configuration_root, NULL)
          : simulator && !strcmp (op, "start_rebuild")
              ? wp_spa_json_new_object ("protocol", "s", domain, "op", "s", op, "arguments", "J",
                                        worker_args, "id", "s", id, NULL)
              : wp_spa_json_new_object ("protocol", "s", domain, "op", "s", op, "arguments", "J",
                                        worker_args, NULL);
    if (mutation)
      {
        g_autofree char *name = g_strdup_printf ("%s.json", id);
        struct stat st;
        if (fstatat (m->root_fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0)
          {
            response = error_response (id, "duplicate request identity; query its receipt", FALSE);
            goto out;
          }
        if (m->receipt_count >= RECEIPT_CAPACITY)
          {
            response = error_response (id, "receipt store unavailable or full", FALSE);
            goto out;
          }
        g_autoptr (WpSpaJson) accepted = receipt_record (id, domain, "accepted", NULL);
        gboolean persisted = durable_receipt (m, id, accepted);
        /* A rename can succeed even if the following directory fsync fails.
         * It still consumes capacity and must never be silently overwritten. */
        if (fstatat (m->root_fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0)
          m->receipt_count++;
        if (!persisted)
          {
            response = error_response (id, "cannot persist request acceptance", FALSE);
            goto out;
          }
      }
    response = execute (m, id, domain, op, worker_request,
                        configuration ? 16 * 1024 * 1024 : 1024 * 1024);
    if (mutation)
      {
        gboolean unavailable = FALSE;
        wp_spa_json_object_get (response, "unavailable", "b", &unavailable, NULL);
        g_autoptr (WpSpaJson) record = receipt_record (
            id, domain, unavailable ? "unknown" : "complete", unavailable ? NULL : response);
        if (!durable_receipt (m, id, record))
          {
            wp_spa_json_unref (response);
            response = error_response (id, "cannot persist completion; outcome unknown", TRUE);
          }
      }
  }
out:
  return response;
}

typedef struct
{
  Management *m;
  GSocketConnection *connection;
} Handler;
static gpointer
handle_connection (gpointer data)
{
  Handler *h = data;
  Management *m = h->m;
  int socket_fd = g_socket_get_fd (g_socket_connection_get_socket (h->connection)), input_fd = -1;
  struct ucred peer;
  socklen_t len = sizeof (peer);
  if (getsockopt (socket_fd, SOL_SOCKET, SO_PEERCRED, &peer, &len) == 0 && peer.uid == geteuid ())
    {
      fcntl (socket_fd, F_SETFL, O_NONBLOCK);
      g_autofree char *line
          = read_line (m, socket_fd, REQUEST_LIMIT, deadline_seconds (10), TRUE, &input_fd);
      gboolean admitted = FALSE;
      g_autoptr (WpSpaJson) response
          = line ? dispatch (m, line, input_fd, &admitted)
                 : preadmission_error ("invalid, oversized or timed out request");
      send_response (m, socket_fd, response);
      if (admitted)
        g_mutex_unlock (&m->operation);
    }
  if (input_fd >= 0)
    close (input_fd);
  g_io_stream_close (G_IO_STREAM (h->connection), NULL, NULL);
  g_object_unref (h->connection);
  g_free (h);
  g_mutex_lock (&m->handlers_lock);
  m->handlers--;
  g_cond_signal (&m->handlers_done);
  g_mutex_unlock (&m->handlers_lock);
  return NULL;
}
static gboolean
incoming (GSocketService *service G_GNUC_UNUSED, GSocketConnection *connection,
          GObject *source G_GNUC_UNUSED, gpointer data)
{
  Management *m = data;
  int fd = g_socket_get_fd (g_socket_connection_get_socket (connection));
  struct ucred peer;
  socklen_t length = sizeof (peer);
  if (getsockopt (fd, SOL_SOCKET, SO_PEERCRED, &peer, &length) < 0 || peer.uid != geteuid ())
    return TRUE;
  g_mutex_lock (&m->handlers_lock);
  if (m->handlers >= CONNECTION_LIMIT)
    {
      g_mutex_unlock (&m->handlers_lock);
      const char busy[] = "{\"protocol\":\"" PROTOCOL
                          "\",\"id\":\"\",\"ok\":false,\"admitted\":false,\"error\":\"Busy\"}\n";
      send (g_socket_get_fd (g_socket_connection_get_socket (connection)), busy, sizeof (busy) - 1,
            MSG_DONTWAIT | MSG_NOSIGNAL);
      return TRUE;
    }
  m->handlers++;
  g_mutex_unlock (&m->handlers_lock);
  Handler *h = g_new (Handler, 1);
  h->m = m;
  h->connection = g_object_ref (connection);
  GThread *thread = g_thread_new ("management-client", handle_connection, h);
  g_thread_unref (thread);
  return TRUE;
}
static gboolean
idle_worker (gpointer data)
{
  Management *m = data;
  if (g_mutex_trylock (&m->operation))
    {
      if (m->worker_pid
          && g_get_monotonic_time () - m->worker_idle >= (gint64)m->idle_timeout * G_USEC_PER_SEC)
        retire_worker (m);
      g_mutex_unlock (&m->operation);
    }
  return G_SOURCE_CONTINUE;
}
static gboolean
shutdown_service (gpointer data)
{
  Management *m = data;
  g_atomic_int_set (&m->stopping, TRUE);
  g_socket_service_stop (m->service);
  g_main_loop_quit (m->loop);
  return G_SOURCE_CONTINUE;
}
static gboolean
private_directory (const char *path)
{
  if (!path || !g_path_is_absolute (path) || g_mkdir_with_parents (path, 0700) < 0)
    return FALSE;
  struct stat st;
  return lstat (path, &st) == 0 && S_ISDIR (st.st_mode) && st.st_uid == geteuid ()
         && (st.st_mode & 077) == 0;
}
static gboolean
endpoint (Management *m, GError **error)
{
  g_autofree char *parent = g_path_get_dirname (m->socket_path);
  if (!private_directory (parent))
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
                           "socket directory must be owned and mode 0700");
      return FALSE;
    }
  const char *pid = g_getenv ("LISTEN_PID"), *fds = g_getenv ("LISTEN_FDS");
  if (pid && strtol (pid, NULL, 10) == getpid () && fds)
    {
      struct sockaddr_un address = { 0 };
      socklen_t length = sizeof (address);
      int type = 0, listening = 0;
      socklen_t intlen = sizeof (int);
      if (strcmp (fds, "1") || getsockname (3, (struct sockaddr *)&address, &length) < 0
          || address.sun_family != AF_UNIX || address.sun_path[sizeof (address.sun_path) - 1] != 0
          || strcmp (address.sun_path, m->socket_path)
          || getsockopt (3, SOL_SOCKET, SO_TYPE, &type, &intlen) < 0 || type != SOCK_STREAM
          || getsockopt (3, SOL_SOCKET, SO_ACCEPTCONN, &listening, &intlen) < 0 || !listening)
        {
          g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_INVALID_ARGUMENT,
                               "invalid activation socket");
          return FALSE;
        }
      fcntl (3, F_SETFD, FD_CLOEXEC);
      g_autoptr (GSocket) socket = g_socket_new_from_fd (3, error);
      if (!socket)
        return FALSE;
      if (!g_socket_listener_add_socket (G_SOCKET_LISTENER (m->service), socket, NULL, error))
        return FALSE;
    }
  else
    {
      struct stat st;
      if (lstat (m->socket_path, &st) == 0)
        {
          g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_EXISTS,
                               "socket already exists; refusing to replace it");
          return FALSE;
        }
      g_autoptr (GSocketAddress) address = g_unix_socket_address_new (m->socket_path);
      mode_t previous = umask (0077);
      gboolean ok = g_socket_listener_add_address (G_SOCKET_LISTENER (m->service), address,
                                                   G_SOCKET_TYPE_STREAM, G_SOCKET_PROTOCOL_DEFAULT,
                                                   NULL, NULL, error);
      umask (previous);
      if (!ok)
        return FALSE;
      m->owns_socket = TRUE;
      if (chmod (m->socket_path, 0600) < 0)
        {
          g_set_error (error, G_IO_ERROR, g_io_error_from_errno (errno),
                       "cannot set endpoint mode: %s", g_strerror (errno));
          return FALSE;
        }
    }
  struct stat st;
  if (lstat (m->socket_path, &st) < 0 || !S_ISSOCK (st.st_mode) || st.st_uid != geteuid ()
      || (st.st_mode & 0777) != 0600)
    {
      g_set_error_literal (error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
                           "socket must be owned and mode 0600");
      return FALSE;
    }
  return TRUE;
}
int
main (int argc, char **argv)
{
  Management m = { .operation_timeout = 60,
                   .describe_timeout = 120,
                   .idle_timeout = 60,
                   .root_fd = -1,
                   .lock_fd = -1,
                   .worker_in = -1,
                   .worker_out = -1 };
  GOptionEntry options[] = { { "socket", 0, 0, G_OPTION_ARG_FILENAME, &m.socket_path,
                               "Absolute local endpoint", "PATH" },
                             { "state-root", 0, 0, G_OPTION_ARG_FILENAME, &m.state_root,
                               "Private durable receipt directory", "PATH" },
                             { "configuration-root", 0, 0, G_OPTION_ARG_FILENAME,
                               &m.configuration_root, "Owner configuration store", "PATH" },
                             { "worker-argv", 0, 0, G_OPTION_ARG_STRING, &m.worker_json,
                               "Trusted worker JSON argv array", "JSON" },
                             { "operation-timeout", 0, 0, G_OPTION_ARG_INT, &m.operation_timeout,
                               "Operation deadline seconds", "SECONDS" },
                             { "describe-timeout", 0, 0, G_OPTION_ARG_INT, &m.describe_timeout,
                               "Describe deadline seconds", "SECONDS" },
                             { "idle-timeout", 0, 0, G_OPTION_ARG_INT, &m.idle_timeout,
                               "Worker idle grace seconds", "SECONDS" },
                             { NULL } };
  g_autoptr (GOptionContext) context = g_option_context_new (NULL);
  g_option_context_add_main_entries (context, options, NULL);
  g_autoptr (GError) error = NULL;
  if (!g_option_context_parse (context, &argc, &argv, &error))
    {
      g_printerr ("%s\n", error->message);
      return 2;
    }
  if (!m.socket_path)
    {
      const char *override = g_getenv ("PIPEWIREAO_MANAGEMENT_SOCKET");
      m.socket_path = override ? g_strdup (override)
                               : g_build_filename (g_get_user_runtime_dir (), "pipewireao",
                                                   "management.sock", NULL);
    }
  if (!m.state_root)
    m.state_root = g_build_filename (g_get_user_state_dir (), "pipewireao", "management", NULL);
  if (!m.configuration_root)
    m.configuration_root
        = g_build_filename (g_get_user_state_dir (), "pipewireao", "configuration", NULL);
  if (!m.worker_json || argc != 1 || !g_path_is_absolute (m.socket_path)
      || !g_path_is_absolute (m.configuration_root) || m.operation_timeout <= 0
      || m.describe_timeout <= 0 || m.idle_timeout <= 0 || !private_directory (m.state_root))
    {
      g_printerr ("trusted worker argv, absolute paths, private state root and positive timeouts "
                  "required\n");
      return 2;
    }
  g_autoptr (WpSpaJson) argv_json = parse_json (m.worker_json);
  if (!argv_json || !wp_spa_json_is_array (argv_json))
    return 2;
  g_autoptr (WpSpaJsonParser) parser = wp_spa_json_parser_new_array (argv_json);
  g_autoptr (GPtrArray) arguments = g_ptr_array_new_with_free_func (g_free);
  g_autoptr (WpSpaJson) arg = NULL;
  while ((arg = wp_spa_json_parser_get_json (parser)))
    {
      if (!wp_spa_json_is_string (arg))
        return 2;
      g_ptr_array_add (arguments, wp_spa_json_parse_string (arg));
      g_clear_pointer (&arg, wp_spa_json_unref);
    }
  if (!arguments->len)
    return 2;
  g_ptr_array_add (arguments, NULL);
  m.worker_argv = (char **)arguments->pdata;
  m.root_fd = open (m.state_root, O_DIRECTORY | O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
  if (m.root_fd >= 0)
    m.lock_fd = openat (m.root_fd, "lock", O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
  if (m.lock_fd < 0 || flock (m.lock_fd, LOCK_EX | LOCK_NB) < 0)
    {
      g_printerr ("management receipt root locked or invalid\n");
      return 1;
    }
  m.receipt_count = recover_receipts (&m);
  if (m.receipt_count < 0)
    {
      g_printerr ("management receipt root invalid\n");
      return 1;
    }
  signal (SIGPIPE, SIG_IGN);
  m.loop = g_main_loop_new (NULL, FALSE);
  m.service = g_socket_service_new ();
  if (!endpoint (&m, &error))
    {
      g_printerr ("management endpoint: %s\n", error->message);
      return 1;
    }
  m.spawn_requests = g_async_queue_new ();
  m.spawner = g_thread_new ("management-spawn", spawn_thread, &m);
  g_signal_connect (m.service, "incoming", G_CALLBACK (incoming), &m);
  guint idle = g_timeout_add_seconds (1, idle_worker, &m),
        term = g_unix_signal_add (SIGTERM, shutdown_service, &m),
        interrupt = g_unix_signal_add (SIGINT, shutdown_service, &m);
  g_socket_service_start (m.service);
  g_main_loop_run (m.loop);
  g_socket_listener_close (G_SOCKET_LISTENER (m.service));
  g_mutex_lock (&m.handlers_lock);
  while (m.handlers)
    g_cond_wait (&m.handlers_done, &m.handlers_lock);
  g_mutex_unlock (&m.handlers_lock);
  retire_worker (&m);
  g_async_queue_push (m.spawn_requests, &m);
  g_thread_join (m.spawner);
  g_async_queue_unref (m.spawn_requests);
  g_source_remove (idle);
  g_source_remove (term);
  g_source_remove (interrupt);
  if (m.owns_socket)
    unlink (m.socket_path);
  g_object_unref (m.service);
  g_main_loop_unref (m.loop);
  close (m.lock_fd);
  close (m.root_fd);
  g_free (m.socket_path);
  g_free (m.state_root);
  g_free (m.configuration_root);
  g_free (m.worker_json);
  return 0;
}
