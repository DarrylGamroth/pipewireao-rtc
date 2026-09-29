#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <poll.h>
#include <semaphore.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>
#include <unistd.h>

enum {
    MAX_FRAMES = 1024,
    NSEC_PER_SEC = 1000000000,
};

static volatile sig_atomic_t caught_signal;

static void handle_signal(int signal_number)
{
    caught_signal = signal_number;
}

static int install_signal_handlers(void)
{
    const struct sigaction action = {
        .sa_handler = handle_signal,
        .sa_flags = 0,
    };
    struct sigaction configured_action = action;

    if (sigemptyset(&configured_action.sa_mask) != 0) {
        return -1;
    }
    if (sigaction(SIGINT, &configured_action, NULL) != 0) {
        return -1;
    }
    if (sigaction(SIGTERM, &configured_action, NULL) != 0) {
        return -1;
    }
    return 0;
}

static bool parse_uint64(const char *text, uint64_t minimum, uint64_t maximum,
                         uint64_t *value)
{
    char *end = NULL;
    unsigned long long parsed;

    if (text[0] == '\0' || text[0] == '-') {
        return false;
    }

    errno = 0;
    parsed = strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || parsed < minimum ||
        parsed > maximum) {
        return false;
    }

    *value = parsed;
    return true;
}

static uint64_t timespec_to_ns(const struct timespec *time)
{
    return (uint64_t)time->tv_sec * NSEC_PER_SEC + (uint64_t)time->tv_nsec;
}

static struct timespec ns_to_timespec(uint64_t nanoseconds)
{
    const struct timespec time = {
        .tv_sec = (time_t)(nanoseconds / NSEC_PER_SEC),
        .tv_nsec = (long)(nanoseconds % NSEC_PER_SEC),
    };

    return time;
}

static int wait_for_newline(void)
{
    char byte;

    for (;;) {
        if (caught_signal != 0) {
            errno = EINTR;
            return -1;
        }
        struct pollfd input = {
            .fd = STDIN_FILENO,
            .events = POLLIN,
        };
        const int readable = poll(&input, 1, 100);
        if (readable == 0 || (readable < 0 && errno == EINTR)) {
            continue;
        }
        if (readable < 0) {
            return -1;
        }
        const ssize_t received = read(STDIN_FILENO, &byte, sizeof(byte));

        if (received == 1) {
            if (byte == '\n') {
                return 0;
            }
            continue;
        }
        if (received == 0) {
            errno = EPIPE;
            return -1;
        }
        if (errno == EINTR && caught_signal == 0) {
            continue;
        }
        return -1;
    }
}

static int wait_for_ready(sem_t *ready)
{
    for (;;) {
        if (caught_signal != 0) {
            errno = EINTR;
            return -1;
        }
        struct timespec deadline;
        if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) {
            return -1;
        }
        deadline.tv_nsec += 100000000L;
        if (deadline.tv_nsec >= NSEC_PER_SEC) {
            deadline.tv_sec += 1;
            deadline.tv_nsec -= NSEC_PER_SEC;
        }
        if (sem_timedwait(ready, &deadline) == 0) {
            return 0;
        }
        if (errno == EINTR || errno == ETIMEDOUT) {
            continue;
        }
        return -1;
    }
}

static int write_csv(const char *path, const uint64_t *targets,
                     const uint64_t *actuals, size_t frames)
{
    FILE *output = fopen(path, "w");

    if (output == NULL) {
        return -1;
    }
    if (fprintf(output,
                "frame,target_monotonic_ns,actual_monotonic_ns\n") < 0) {
        (void)fclose(output);
        return -1;
    }

    for (size_t frame = 0; frame < frames; ++frame) {
        if (fprintf(output, "%zu,%" PRIu64 ",%" PRIu64 "\n", frame,
                    targets[frame], actuals[frame]) < 0) {
            (void)fclose(output);
            return -1;
        }
    }

    if (fclose(output) != 0) {
        return -1;
    }
    return 0;
}

int main(int argc, char **argv)
{
    char ready_name[64];
    char trigger_name[64];
    sem_t *ready = SEM_FAILED;
    sem_t *trigger = SEM_FAILED;
    bool ready_created = false;
    bool trigger_created = false;
    uint64_t targets[MAX_FRAMES];
    uint64_t actuals[MAX_FRAMES];
    uint64_t frames;
    uint64_t rate_hz;
    int exit_status = EXIT_FAILURE;

    if (argc != 4 ||
        !parse_uint64(argv[1], 1, MAX_FRAMES, &frames) ||
        !parse_uint64(argv[2], 1, 10000, &rate_hz) ||
        argv[3][0] == '\0') {
        fprintf(stderr, "usage: %s FRAMES RATE_HZ OUTPUT_CSV\n", argv[0]);
        return EXIT_FAILURE;
    }
    if (install_signal_handlers() != 0) {
        perror("sigaction");
        return EXIT_FAILURE;
    }
    if (snprintf(ready_name, sizeof(ready_name), "/wfsSim-u%ju-wfs0",
                 (uintmax_t)getuid()) >= (int)sizeof(ready_name) ||
        snprintf(trigger_name, sizeof(trigger_name), "/wfsSim-u%ju-wfs1",
                 (uintmax_t)getuid()) >= (int)sizeof(trigger_name)) {
        fprintf(stderr, "semaphore name construction failed\n");
        return EXIT_FAILURE;
    }

    ready = sem_open(ready_name, O_CREAT | O_EXCL, 0600, 0);
    if (ready == SEM_FAILED) {
        perror("sem_open ready");
        goto cleanup;
    }
    ready_created = true;
    if (caught_signal != 0) {
        goto interrupted;
    }

    trigger = sem_open(trigger_name, O_CREAT | O_EXCL, 0600, 0);
    if (trigger == SEM_FAILED) {
        perror("sem_open trigger");
        goto cleanup;
    }
    trigger_created = true;
    if (caught_signal != 0) {
        goto interrupted;
    }

    puts("sem-created");
    if (fflush(stdout) != 0) {
        perror("flush stdout");
        goto cleanup;
    }

    if (wait_for_ready(ready) != 0) {
        if (caught_signal != 0) {
            goto interrupted;
        }
        perror("sem_wait ready");
        goto cleanup;
    }
    if (caught_signal != 0) {
        goto interrupted;
    }

    puts("sender-ready");
    if (fflush(stdout) != 0) {
        perror("flush stdout");
        goto cleanup;
    }
    if (wait_for_newline() != 0) {
        if (caught_signal != 0) {
            goto interrupted;
        }
        perror("read stdin");
        goto cleanup;
    }
    if (caught_signal != 0) {
        goto interrupted;
    }

    struct timespec release_time;
    if (clock_gettime(CLOCK_MONOTONIC, &release_time) != 0) {
        perror("clock_gettime release");
        goto cleanup;
    }
    const uint64_t release_ns = timespec_to_ns(&release_time);
    if (frames > (UINT64_MAX - release_ns) / NSEC_PER_SEC) {
        fprintf(stderr, "frame count overflows CLOCK_MONOTONIC range\n");
        goto cleanup;
    }

    for (uint64_t frame = 0; frame < frames; ++frame) {
        const uint64_t target_ns =
            release_ns + ((frame + 1) * NSEC_PER_SEC) / rate_hz;
        const struct timespec deadline = ns_to_timespec(target_ns);
        int sleep_result;

        do {
            sleep_result = clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME,
                                           &deadline, NULL);
        } while (sleep_result == EINTR && caught_signal == 0);
        if (sleep_result != 0) {
            if (caught_signal != 0) {
                goto interrupted;
            }
            errno = sleep_result;
            perror("clock_nanosleep");
            goto cleanup;
        }
        if (caught_signal != 0) {
            goto interrupted;
        }
        if (sem_post(trigger) != 0) {
            perror("sem_post trigger");
            goto cleanup;
        }
        struct timespec actual_time;
        if (clock_gettime(CLOCK_MONOTONIC, &actual_time) != 0) {
            perror("clock_gettime trigger");
            goto cleanup;
        }
        targets[frame] = target_ns;
        actuals[frame] = timespec_to_ns(&actual_time);
    }

    if (write_csv(argv[3], targets, actuals, (size_t)frames) != 0) {
        perror("write CSV");
        goto cleanup;
    }
    puts("triggered");
    if (fflush(stdout) != 0) {
        perror("flush stdout");
        goto cleanup;
    }
    if (caught_signal != 0) {
        goto interrupted;
    }
    exit_status = EXIT_SUCCESS;
    goto cleanup;

interrupted:
    fprintf(stderr, "interrupted by signal %d\n", (int)caught_signal);
    exit_status = 128 + caught_signal;

cleanup:
    if (trigger != SEM_FAILED && sem_close(trigger) != 0) {
        perror("sem_close trigger");
        exit_status = EXIT_FAILURE;
    }
    if (ready != SEM_FAILED && sem_close(ready) != 0) {
        perror("sem_close ready");
        exit_status = EXIT_FAILURE;
    }
    if (trigger_created && sem_unlink(trigger_name) != 0) {
        perror("sem_unlink trigger");
        exit_status = EXIT_FAILURE;
    }
    if (ready_created && sem_unlink(ready_name) != 0) {
        perror("sem_unlink ready");
        exit_status = EXIT_FAILURE;
    }
    return exit_status;
}
