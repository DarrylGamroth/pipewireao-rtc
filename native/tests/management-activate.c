/* SPDX-License-Identifier: MIT
 * Test-owned socket activation: bind the exact listener, then exec the companion.
 * No user services or installed endpoints are involved.
 */
#define _GNU_SOURCE
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

int
main (int argc, char **argv)
{
  const char *path = NULL;
  for (int i = 2; i + 1 < argc; i++)
    if (strcmp (argv[i], "--socket") == 0)
      path = argv[i + 1];
  if (!path || strlen (path) >= sizeof (((struct sockaddr_un *)0)->sun_path))
    return 2;
  int listener = socket (AF_UNIX, SOCK_STREAM, 0);
  struct sockaddr_un address = { .sun_family = AF_UNIX };
  strcpy (address.sun_path, path);
  if (listener < 0 || bind (listener, (struct sockaddr *)&address, sizeof address) < 0
      || chmod (path, 0600) < 0 || listen (listener, 16) < 0)
    return 3;
  if (listener != 3)
    {
      if (dup2 (listener, 3) < 0)
        return 4;
      close (listener);
    }
  if (fcntl (3, F_SETFD, 0) < 0)
    return 5;
  char pid[32];
  snprintf (pid, sizeof pid, "%ld", (long)getpid ());
  setenv ("LISTEN_PID", pid, 1);
  setenv ("LISTEN_FDS", "1", 1);
  execv (argv[1], argv + 1);
  return 6;
}
