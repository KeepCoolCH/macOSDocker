#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/reboot.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static sigset_t signals;

static void notice(int value) { (void)value; }

static double now(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return value.tv_sec + value.tv_nsec / 1000000000.0;
}

static void pause_ms(long milliseconds) {
    struct timespec interval = { milliseconds / 1000, (milliseconds % 1000) * 1000000 };
    while (nanosleep(&interval, &interval) != 0 && errno == EINTR) {}
}

static pid_t launch(const char *path) {
    pid_t child = fork();
    if (child == 0) {
        sigset_t empty;
        sigemptyset(&empty);
        sigprocmask(SIG_SETMASK, &empty, NULL);
        execl(path, path, (char *)NULL);
        perror(path);
        _exit(127);
    }
    if (child < 0) perror("fork");
    return child;
}

static bool run(const char *path) {
    pid_t child = launch(path);
    if (child < 0) return false;
    int status;
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) return false;
    }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0;
}

static bool children_done(void) {
    while (true) {
        pid_t child = waitpid(-1, NULL, WNOHANG);
        if (child > 0) continue;
        return child < 0 && errno == ECHILD;
    }
}

static bool drain(double seconds) {
    double deadline = now() + seconds;
    do {
        if (children_done()) return true;
        pause_ms(10);
    } while (now() < deadline);
    return children_done();
}

struct mount_entry {
    unsigned long id;
    unsigned depth;
    char *path;
};

static int compare_mounts(const void *left, const void *right) {
    const struct mount_entry *a = left;
    const struct mount_entry *b = right;
    if (a->depth != b->depth) return a->depth > b->depth ? -1 : 1;
    if (a->id != b->id) return a->id > b->id ? -1 : 1;
    return 0;
}

static void unescape(char *path) {
    char *output = path;
    while (*path) {
        if (path[0] == '\\' && path[1] >= '0' && path[1] <= '7' && path[2] >= '0' && path[2] <= '7' && path[3] >= '0' && path[3] <= '7') {
            *output++ = (char)((path[1] - '0') * 64 + (path[2] - '0') * 8 + path[3] - '0');
            path += 4;
        } else {
            *output++ = *path++;
        }
    }
    *output = '\0';
}

static bool virtual_mount(const char *path) {
    const char *roots[] = { "/dev", "/proc", "/sys", "/run", "/tmp" };
    if (strcmp(path, "/") == 0) return true;
    for (size_t i = 0; i < sizeof(roots) / sizeof(roots[0]); i++) {
        size_t length = strlen(roots[i]);
        if (strncmp(path, roots[i], length) == 0 && (path[length] == '\0' || path[length] == '/')) return true;
    }
    return false;
}

static bool unmount_storage(void) {
    FILE *input = fopen("/proc/self/mountinfo", "r");
    if (!input) return false;
    struct mount_entry *entries = NULL;
    size_t count = 0;
    char *line = NULL;
    size_t capacity = 0;
    bool clean = true;
    while (getline(&line, &capacity, input) >= 0) {
        char *save = NULL;
        char *id = strtok_r(line, " ", &save);
        char *path = id;
        for (int i = 0; i < 4 && path; i++) path = strtok_r(NULL, " ", &save);
        if (!id || !path) { clean = false; break; }
        unescape(path);
        if (virtual_mount(path)) continue;
        struct mount_entry *grown = realloc(entries, (count + 1) * sizeof(*entries));
        if (!grown) { clean = false; break; }
        entries = grown;
        char *copy = strdup(path);
        if (!copy) { clean = false; break; }
        unsigned depth = 0;
        for (const char *p = path; *p; p++) if (*p == '/') depth++;
        entries[count++] = (struct mount_entry){ strtoul(id, NULL, 10), depth, copy };
    }
    free(line);
    fclose(input);
    qsort(entries, count, sizeof(*entries), compare_mounts);
    for (size_t i = 0; i < count; i++) {
        if (umount2(entries[i].path, 0) != 0 && errno != EINVAL && errno != ENOENT) {
            fprintf(stderr, "Unmount failed: %s: %s\n", entries[i].path, strerror(errno));
            clean = false;
        }
        free(entries[i].path);
    }
    free(entries);
    return clean;
}

static void shutdown_guest(int command) {
    double began = now();
    fprintf(stderr, "macOSDocker: stopping services\n");
    if (!run("/usr/local/lib/macosdocker/shutdown.sh")) {
        fprintf(stderr, "macOSDocker: service shutdown failed; VM remains powered on\n");
        while (true) pause();
    }
    kill(-1, SIGTERM);
    if (!drain(1.5)) {
        kill(-1, SIGKILL);
        if (!drain(1.5)) {
            fprintf(stderr, "macOSDocker: processes remain busy; VM remains powered on\n");
            while (true) pause();
        }
    }
    sync();
    if (!unmount_storage() || mount(NULL, "/", NULL, MS_REMOUNT | MS_RDONLY, NULL) != 0) {
        fprintf(stderr, "macOSDocker: filesystem shutdown incomplete; VM remains powered on\n");
        while (true) pause();
    }
    sync();
    fprintf(stderr, "macOSDocker: clean shutdown in %.3f seconds\n", now() - began);
    reboot(command);
    perror("reboot");
    while (true) pause();
}

int main(void) {
    if (getpid() != 1) {
        fprintf(stderr, "macOSDocker init must run as PID 1\n");
        return 1;
    }
    setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
    sigemptyset(&signals);
    const int watched[] = { SIGCHLD, SIGUSR1, SIGUSR2, SIGTERM, SIGINT };
    struct sigaction action = {0};
    action.sa_handler = notice;
    sigemptyset(&action.sa_mask);
    for (size_t i = 0; i < sizeof(watched) / sizeof(watched[0]); i++) {
        sigaction(watched[i], &action, NULL);
        sigaddset(&signals, watched[i]);
    }
    sigprocmask(SIG_BLOCK, &signals, NULL);
    int console = open("/dev/console", O_RDWR | O_NOCTTY);
    if (console >= 0) {
        for (int fd = 0; fd < 3; fd++) dup2(console, fd);
        if (console > 2) close(console);
    }
    bool booted = run("/usr/local/lib/macosdocker/boot.sh");
    if (!booted) fprintf(stderr, "macOSDocker: boot failed\n");
    pid_t agent = -1;
    double restart = 0;
    while (true) {
        pid_t child;
        while ((child = waitpid(-1, NULL, WNOHANG)) > 0) {
            if (child == agent) { agent = -1; restart = now() + 1; }
        }
        if (booted && agent < 0 && now() >= restart) {
            agent = launch("/usr/local/lib/macosdocker/agent.sh");
            if (agent < 0) restart = now() + 1;
        }
        struct timespec timeout = { 1, 0 };
        int received = sigtimedwait(&signals, NULL, &timeout);
        if (received == SIGUSR2) shutdown_guest(RB_POWER_OFF);
        if (received == SIGUSR1) shutdown_guest(RB_HALT_SYSTEM);
        if (received == SIGTERM || received == SIGINT) shutdown_guest(RB_AUTOBOOT);
    }
}
