#include "log_util.h"

#include <cerrno>
#include <cstring>
#include <linux/futex.h>
#include <signal.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static inline pid_t safe_gettid() { return (pid_t)syscall(SYS_gettid); }

struct ProbeResult { long ret; int err; };

static void probe_isolated(const char* name, long nr,
                           long a0, long a1, long a2,
                           long a3, long a4, long a5) {
    int pipefd[2];
    if (pipe(pipefd) != 0) {
        LOGE("pipe failed for %s: %s", name, strerror(errno));
        return;
    }
    pid_t pid = fork();
    if (pid < 0) {
        LOGE("fork failed for %s: %s", name, strerror(errno));
        close(pipefd[0]); close(pipefd[1]);
        return;
    }
    if (pid == 0) {
        close(pipefd[0]);
        errno = 0;
        long r = syscall(nr, a0, a1, a2, a3, a4, a5);
        ProbeResult res = { r, errno };
        ssize_t n = write(pipefd[1], &res, sizeof(res));
        (void)n;
        close(pipefd[1]);
        _exit(0);
    }

    close(pipefd[1]);
    ProbeResult res = { 0, 0 };
    ssize_t n = read(pipefd[0], &res, sizeof(res));
    close(pipefd[0]);

    int status = 0;
    waitpid(pid, &status, 0);

    if (WIFEXITED(status) && WEXITSTATUS(status) == 0 && n == (ssize_t)sizeof(res)) {
        const char* v;
        if (res.ret >= 0)             v = "AVAILABLE-OK   ";
        else if (res.err == EPERM)    v = "EPERM-seccomp? ";
        else if (res.err == ENOSYS)   v = "ENOSYS         ";
        else                          v = "AVAILABLE-err  ";
        LOGI("%-26s nr=%-4ld ret=%-10ld errno=%-3d %s (%s)",
             name, nr, res.ret, res.err, v,
             res.err ? strerror(res.err) : "ok");
    } else if (WIFSIGNALED(status)) {
        int sig = WTERMSIG(status);
        LOGE("%-26s nr=%-4ld *** KILLED by signal %d (%s) ***  (seccomp KILL)",
             name, nr, sig, strsignal(sig));
    } else {
        LOGW("%-26s nr=%-4ld abnormal status=0x%x n=%zd",
             name, nr, status, n);
    }
}

#define PROBE(NAME, NR, A0, A1, A2, A3, A4, A5) \
    probe_isolated(NAME, NR, (long)(A0), (long)(A1), (long)(A2), \
                              (long)(A3), (long)(A4), (long)(A5))

extern "C" void RunSyscallTests(void) {
    log_banner("Syscall probe (fork-isolated)");
    LOGI("Watch for '*** KILLED ***' lines == seccomp KILL policy");

    pid_t self_pid = getpid();
    pid_t self_tid = safe_gettid();
    LOGI("parent pid=%d tid=%d", self_pid, self_tid);

#ifdef __NR_membarrier
    PROBE("membarrier(QUERY)",     __NR_membarrier,     0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_pkey_alloc
    PROBE("pkey_alloc",            __NR_pkey_alloc,     0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_pkey_mprotect
    PROBE("pkey_mprotect(bad)",    __NR_pkey_mprotect,  0, 0, 0, -1, 0, 0);
#endif
#ifdef __NR_clone3
    { char tiny[16]={0}; PROBE("clone3(size=1)", __NR_clone3, tiny, 1, 0, 0, 0, 0); }
#endif
#ifdef __NR_ptrace
    PROBE("ptrace(invalid)",       __NR_ptrace, 0xdead, self_pid, 0, 0, 0, 0);
#endif
#ifdef __NR_tgkill
    PROBE("tgkill(self,sig=0)",    __NR_tgkill, self_pid, self_tid, 0, 0, 0, 0);
#endif
#ifdef __NR_rt_sigqueueinfo
    PROBE("rt_sigqueueinfo(self)", __NR_rt_sigqueueinfo, self_pid, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_eventfd2
    PROBE("eventfd2",              __NR_eventfd2, 0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_epoll_create1
    PROBE("epoll_create1",         __NR_epoll_create1, 0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_memfd_create
    PROBE("memfd_create",          __NR_memfd_create, (long)"p", 0, 0, 0, 0, 0);
#endif
#ifdef __NR_signalfd4
    PROBE("signalfd4(bad)",        __NR_signalfd4, -1, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_timerfd_create
    PROBE("timerfd_create",        __NR_timerfd_create, 1, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_pidfd_open
    PROBE("pidfd_open(self)",      __NR_pidfd_open, self_pid, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_userfaultfd
    PROBE("userfaultfd",           __NR_userfaultfd, 0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_inotify_init1
    PROBE("inotify_init1",         __NR_inotify_init1, 0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_futex
    { int loc=0; PROBE("futex(WAKE)", __NR_futex, &loc, FUTEX_WAKE, 0, 0, 0, 0); }
#endif
#ifdef __NR_get_robust_list
    { void* h=nullptr; size_t l=0;
      PROBE("get_robust_list(self)", __NR_get_robust_list, 0, &h, &l, 0, 0, 0); }
#endif
#ifdef __NR_unshare
    PROBE("unshare(0)",            __NR_unshare, 0, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_setns
    PROBE("setns(bad)",            __NR_setns, -1, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_kcmp
    PROBE("kcmp(self,self,99)",    __NR_kcmp, self_pid, self_pid, 99, 0, 0, 0);
#endif
#ifdef __NR_io_uring_setup
    PROBE("io_uring_setup",        __NR_io_uring_setup, 1, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_seccomp
    PROBE("seccomp(GET_AVAIL)",    __NR_seccomp, 2, 0, 0, 0, 0, 0);
#endif
#ifdef __NR_perf_event_open
    PROBE("perf_event_open",       __NR_perf_event_open, 0, 0, -1, -1, 0, 0);
#endif
#ifdef __NR_process_vm_readv
    PROBE("process_vm_readv",      __NR_process_vm_readv, self_pid, 0, 0, 0, 0, 0);
#endif

    log_result("syscall_probe", true, "see log");
}