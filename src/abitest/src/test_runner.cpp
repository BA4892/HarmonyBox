#include "test_runner.h"
#include "log_util.h"

#include <cerrno>
#include <cstring>
#include <exception>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

extern "C" {
    void RunSysInfoTests(void);
    void RunProcTests   (void);
    void RunDlopenTests (void);
    void RunSignalTests (void);
    void RunThreadTests (void);
    void RunSyscallTests(void);
    void RunSigsysTests (void);
    void RunJitTests    (void);
}

const TestSuite g_test_suites[] = {
    { "sysinfo", "System information",       RunSysInfoTests },
    { "proc",    "Process / fork / vfork",   RunProcTests    },
    { "dlopen",  "Library availability",     RunDlopenTests  },
    { "signal",  "Signal handling",          RunSignalTests  },
    { "thread",  "Pthread / TLS / Futex",    RunThreadTests  },
    { "syscall", "Syscall availability",     RunSyscallTests },
    { "sigsys",  "SIGSYS catch & recover",   RunSigsysTests  },
    { "jit",     "JIT memory (W^X / dual)",  RunJitTests     },
};
const int g_test_suite_count = sizeof(g_test_suites) / sizeof(g_test_suites[0]);

bool run_suite_inline(const TestSuite& s) {
    try {
        s.func();
        return true;
    } catch (const std::exception& e) {
        LOGE("Suite '%s' threw std::exception: %s", s.key, e.what());
        return false;
    } catch (...) {
        LOGE("Suite '%s' threw unknown C++ exception", s.key);
        return false;
    }
}

bool run_suite_isolated(const TestSuite& s) {
    fflush(stdout);
    fflush(stderr);

    pid_t pid = fork();
    if (pid < 0) {
        LOGE("fork failed for suite '%s': errno=%d (%s)",
             s.key, errno, strerror(errno));
        return false;
    }

    if (pid == 0) {
        // child
        try {
            s.func();
            fflush(stdout);
            fflush(stderr);
            _exit(0);
        } catch (const std::exception& e) {
            fprintf(stderr, "[child] threw std::exception: %s\n", e.what());
            _exit(2);
        } catch (...) {
            fprintf(stderr, "[child] threw unknown C++ exception\n");
            _exit(3);
        }
    }

    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        LOGE("waitpid failed for suite '%s': %s", s.key, strerror(errno));
        return false;
    }

    if (WIFEXITED(status)) {
        int code = WEXITSTATUS(status);
        if (code == 0) return true;
        LOGE("Suite '%s' child exited with code %d", s.key, code);
        return false;
    }
    if (WIFSIGNALED(status)) {
        int sig = WTERMSIG(status);
        LOGE("Suite '%s' child KILLED by signal %d (%s)%s",
             s.key, sig, strsignal(sig),
             WCOREDUMP(status) ? " [core dumped]" : "");
        return false;
    }
    LOGE("Suite '%s' child abnormal status=0x%x", s.key, status);
    return false;
}