/* One-session root helper. Build: clang -std=c11 -Wall -Wextra -Werror
 * Tools/DialAwakeHelper.c -framework IOKit -framework CoreFoundation -o DialAwakeHelper
 * Protocol: ready -> start -> active; ping -> pong; stop/EOF/death -> stopped.
 * --check (unprivileged/read-only): false/exit 0, true/exit 2, unknown/exit 1.
 * Errors: error baseline|enable|restore. stopped is emitted only after verified
 * restoration. Missing persisted key in a valid dictionary + kernel false is
 * accepted; restoration leaves an explicit false key. NULL dictionary is unknown.
 * SIGKILL, helper crash or machine failure cannot guarantee restoration. This is
 * no service, recovery journal, or protection against other root writers.
 * DIAL_AWAKE_TESTING uses only fixed files in a disposable test cwd (state,
 * behavior, owner, writes, lock); it never invokes pmset or reads power settings.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <libproc.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifdef DIAL_AWAKE_TESTING
#define LOCK_PATH "lock"
#define LOCK_UID getuid()
#define START_MS 500
#define HEARTBEAT_MS 1000
#define READBACK_MS 200
#define CHILD_MS 500
#else
#define LOCK_PATH "/var/run/io.github.eroyun.dial.awake.lock"
#define LOCK_UID 0
#define START_MS 5000
#define HEARTBEAT_MS 10000
#define READBACK_MS 2000
#define CHILD_MS 5000
/* Exported by IOKit but not declared in the public SDK. */
extern CFDictionaryRef IOPMCopySystemPowerSettings(void) __attribute__((weak_import));
#endif

static volatile sig_atomic_t interrupted;
static int channel = -1, queue = -1, ping_pending, session_ended;
static pid_t owner_pid;
static uid_t owner_uid;
static struct proc_bsdinfo identity;
static uint64_t heartbeat;
static void on_signal(int sig) { (void)sig; interrupted = 1; }
static uint64_t milliseconds(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t) != 0) _exit(1);
    return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
}
static void pause_briefly(void) {
    struct timespec t = {0, 20000000};
    nanosleep(&t, NULL);
}
static int send_line(const char *s) {
    size_t n = strlen(s);
    return send(channel, s, n, 0) == (ssize_t)n;
}
static int probe_owner(struct proc_bsdinfo *p) {
#ifdef DIAL_AWAKE_TESTING
    char b[32] = "";
    FILE *f = fopen("owner", "r");
    if (!f) return 0;
    (void)fgets(b, sizeof(b), f); fclose(f);
    if (strcmp(b, "alive\n") != 0) return 0;
#endif
    return proc_pidinfo(owner_pid, PROC_PIDTBSDINFO, 0, p, sizeof(*p)) == sizeof(*p)
        && p->pbi_pid == (uint32_t)owner_pid && p->pbi_uid == owner_uid
        && p->pbi_ruid == owner_uid && p->pbi_start_tvsec != 0;
}
static int owner_alive(void) {
    struct kevent event;
    struct timespec zero = {0, 0};
    struct proc_bsdinfo current;
    if (kevent(queue, NULL, 0, &event, 1, &zero) != 0) return 0;
    return probe_owner(&current)
        && current.pbi_start_tvsec == identity.pbi_start_tvsec
        && current.pbi_start_tvusec == identity.pbi_start_tvusec;
}
/* Only complete, short ASCII protocol lines are accepted; partial lines cannot
 * extend a deadline. A bounded drain also prevents a ping flood starving cleanup. */
static int receive_line(void) {
    static char line[16];
    static size_t used;
    for (int i = 0; i < 64; ++i) {
        char c;
        ssize_t n = recv(channel, &c, 1, 0);
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return 0;
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return -1;
        if (c == '\n') {
            line[used] = 0; used = 0;
            if (strcmp(line, "start") == 0) return 1;
            if (strcmp(line, "ping") == 0) return 2;
            if (strcmp(line, "stop") == 0) return -1;
            return -1;
        }
        if (c < 'a' || c > 'z' || used == sizeof(line) - 1) return -1;
        line[used++] = c;
    }
    return 0;
}
static int stopping(void) {
    if (session_ended) return 1;
    if (interrupted || !owner_alive() || milliseconds() - heartbeat >= HEARTBEAT_MS)
        return session_ended = 1;
    int message = receive_line();
    if (message == 2) { heartbeat = milliseconds(); if (ping_pending < 64) ++ping_pending; }
    if (message < 0 || message == 1) session_ended = 1;
    return session_ended;
}
#ifndef DIAL_AWAKE_TESTING
static int boolean(CFTypeRef value) {
    if (!value || CFGetTypeID(value) != CFBooleanGetTypeID()) return -2;
    return CFBooleanGetValue((CFBooleanRef)value) ? 1 : 0;
}
#endif
/* -1 unknown; 0 false; 1 true; 2 persisted true/kernel false (owned reset). */
static int read_state(void) {
    int persisted = -2, kernel = -2;
#ifdef DIAL_AWAKE_TESTING
    char extra;
    FILE *f = fopen("state", "r");
    if (!f) return -1;
    if (fscanf(f, "%d %d %c", &persisted, &kernel, &extra) != 2) persisted = -2;
    fclose(f);
#else
    if (!IOPMCopySystemPowerSettings) return -1;
    CFDictionaryRef prefs = IOPMCopySystemPowerSettings();
    if (prefs && CFGetTypeID(prefs) == CFDictionaryGetTypeID()) {
        CFTypeRef v = CFDictionaryGetValue(prefs, CFSTR("SleepDisabled"));
        persisted = v ? boolean(v) : -1; /* Positively absent in valid dictionary. */
    }
    if (prefs) CFRelease(prefs);
    io_registry_entry_t root = IORegistryEntryFromPath(kIOMainPortDefault,
                                                       "IOPower:/IOPowerConnection/IOPMrootDomain");
    if (root) {
        CFTypeRef v = IORegistryEntryCreateCFProperty(root, CFSTR("SleepDisabled"),
                                                     kCFAllocatorDefault, 0);
        kernel = boolean(v);
        if (v) CFRelease(v);
        IOObjectRelease(root);
    }
#endif
    if (kernel == 0 && (persisted == 0 || persisted == -1)) return 0;
    if (kernel == 1 && persisted == 1) return 1;
    if (kernel == 0 && persisted == 1) return 2;
    return -1;
}
#ifdef DIAL_AWAKE_TESTING
static void fixture_write(int enable) {
    char behavior[64] = "";
    FILE *f = fopen("behavior", "r");
    if (f) { (void)fgets(behavior, sizeof(behavior), f); fclose(f); }
    f = fopen("writes", "a");
    if (!f) _exit(1);
    fprintf(f, "%d %d\n", enable, getpid()); fclose(f);
    if ((enable && strstr(behavior, "hang-enable")) ||
        (!enable && strstr(behavior, "hang-restore"))) for (;;) pause();
    if ((!enable && strstr(behavior, "fail-restore"))) _exit(1);
    if ((enable && strstr(behavior, "noop-enable")) ||
        (!enable && strstr(behavior, "noop-restore"))) _exit(0);
    f = fopen("state", "w");
    if (!f) _exit(1);
    fprintf(f, "%d %d\n", enable, enable); fclose(f);
    _exit(enable && strstr(behavior, "fail-enable") ? 1 : 0);
}
#endif
static int write_state(int enable) {
    pid_t child = fork();
    if (child < 0) return 0;
    if (child == 0) {
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL); signal(SIGHUP, SIG_DFL);
#ifdef DIAL_AWAKE_TESTING
        fixture_write(enable);
#else
        int null = open("/dev/null", O_RDWR);
        if (null < 0 || dup2(null, 0) < 0 || dup2(null, 1) < 0 || dup2(null, 2) < 0)
            _exit(127);
        if (null > 2) close(null);
        char *args[] = {"/usr/bin/pmset", "-a", "disablesleep", enable ? "1" : "0", NULL};
        char *env[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};
        execve(args[0], args, env);
        _exit(127);
#endif
    }
    uint64_t deadline = milliseconds() + CHILD_MS;
    int status = 0;
    for (;;) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) return WIFEXITED(status) && WEXITSTATUS(status) == 0;
        if (result < 0 && errno != EINTR) return 0;
        if (milliseconds() >= deadline || (enable && stopping())) {
            kill(child, SIGKILL);
            /* Never start restore with a prior write still in flight. */
            while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
            return 0;
        }
        pause_briefly();
    }
}
static int acquire_lock(void) {
    int fd = open(LOCK_PATH, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0600);
    struct stat s;
    if (fd >= 0 && fstat(fd, &s) == 0 && S_ISREG(s.st_mode) && s.st_uid == LOCK_UID
        && (s.st_mode & 077) == 0 && s.st_nlink == 1
        && flock(fd, LOCK_EX | LOCK_NB) == 0) return fd;
    if (fd >= 0) close(fd);
    return -1; /* Never unlink the shared lock inode. */
}
static int connect_gui(const char *path) {
    struct sockaddr_un address = {.sun_family = AF_UNIX};
    if (path[0] != '/' || strlen(path) >= sizeof(address.sun_path)) return 0;
    memcpy(address.sun_path, path, strlen(path) + 1);
    channel = socket(AF_UNIX, SOCK_STREAM, 0);
    if (channel < 0 || fcntl(channel, F_SETFD, FD_CLOEXEC) < 0 ||
        fcntl(channel, F_SETFL, O_NONBLOCK) < 0) return 0;
    if (connect(channel, (struct sockaddr *)&address, sizeof(address)) < 0) {
        if (errno != EINPROGRESS) return 0;
        struct pollfd p = {.fd = channel, .events = POLLOUT};
        int error = 0; socklen_t size = sizeof(error);
        if (poll(&p, 1, START_MS) <= 0 || getsockopt(channel, SOL_SOCKET, SO_ERROR,
                                                   &error, &size) < 0 || error) return 0;
    }
    uid_t uid; gid_t gid;
    return getpeereid(channel, &uid, &gid) == 0 && uid == owner_uid;
}
static int number(const char *s, unsigned long max, unsigned long *value) {
    if (!*s) return 0;
    for (const char *p = s; *p; ++p) if (*p < '0' || *p > '9') return 0;
    errno = 0; *value = strtoul(s, NULL, 10);
    return errno == 0 && *value <= max;
}
int main(int argc, char **argv) {
    int lock = -1, result = 1, owned = 0;
    unsigned long pid, uid;
    const char *error = "baseline";
    if (argc == 2 && strcmp(argv[1], "--check") == 0) {
        int state = read_state();
        puts(state == 0 ? "false" : state == 1 ? "true" : "unknown");
        return state == 0 ? 0 : state == 1 ? 2 : 1;
    }
#ifndef DIAL_AWAKE_TESTING
    if (geteuid() != 0) return 1;
#endif
    if (argc != 5 || strcmp(argv[1], "--session") != 0 ||
        !number(argv[3], INT_MAX, &pid) || pid == 0 ||
        !number(argv[4], UINT_MAX, &uid)) return 1;
    owner_pid = (pid_t)pid; owner_uid = (uid_t)uid;
    signal(SIGPIPE, SIG_IGN);
    struct sigaction action = {.sa_handler = on_signal};
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL);
    sigaction(SIGHUP, &action, NULL); sigaction(SIGQUIT, &action, NULL);
    if (!probe_owner(&identity)) goto done;
    queue = kqueue();
    if (queue < 0 || fcntl(queue, F_SETFD, FD_CLOEXEC) < 0) goto done;
    struct kevent event;
    EV_SET(&event, owner_pid, EVFILT_PROC, EV_ADD | EV_ONESHOT, NOTE_EXIT, 0, NULL);
    if (kevent(queue, &event, 1, NULL, 0, NULL) < 0 || !owner_alive()) goto done;
    if (!connect_gui(argv[2]) || (lock = acquire_lock()) < 0 || read_state() != 0 ||
        !send_line("ready\n")) goto done;
    uint64_t deadline = milliseconds() + START_MS;
    for (;;) {
        if (interrupted || !owner_alive() || milliseconds() >= deadline) goto done;
        int message = receive_line();
        if (message == 1) break;
        if (message != 0) goto done;
        pause_briefly();
    }
    /* Revalidate after user handshake; external changes may have happened. */
    if (!owner_alive() || interrupted || read_state() != 0) goto done;
    heartbeat = milliseconds();
    if (stopping()) goto done;
    owned = 1; error = "enable";
    if (!write_state(1) || read_state() != 1 || stopping() || !send_line("active\n")) {
        if (session_ended) { result = 0; error = NULL; }
        goto done;
    }
    uint64_t next_read = milliseconds() + READBACK_MS;
    error = NULL; result = 0;
    while (!stopping()) {
        if (ping_pending || milliseconds() >= next_read) {
            int state = read_state();
            if (state < 0) { error = "enable"; result = 1; break; }
            if ((state == 0 || state == 2) && (!write_state(1) || read_state() != 1)) {
                if (!session_ended) { error = "enable"; result = 1; }
                break;
            }
            if (stopping()) break;
            while (ping_pending > 0) {
                if (!send_line("pong\n")) goto done;
                --ping_pending;
            }
            next_read = milliseconds() + READBACK_MS;
        }
        pause_briefly();
    }
done:
    if (error) { char line[32]; snprintf(line, sizeof(line), "error %s\n", error); send_line(line); }
    if (owned) {
        if (write_state(0) && read_state() == 0) send_line("stopped\n");
        else { send_line("error restore\n"); result = 1; }
    }
    if (channel >= 0) close(channel);
    if (queue >= 0) close(queue);
    if (lock >= 0) close(lock);
    return result;
}
