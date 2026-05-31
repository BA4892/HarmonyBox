#include "log_util.h"

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

static void test_proc_maps() {
    log_banner("/proc/self/maps (first 8 lines)");
    std::ifstream f("/proc/self/maps");
    if (!f.is_open()) {
        LOGE("open failed: %s", strerror(errno));
        log_result("proc_maps", false, "open failed");
        return;
    }
    std::string line;
    int total = 0, shown = 0;
    while (std::getline(f, line)) {
        ++total;
        if (shown < 8) { LOGI("%s", line.c_str()); ++shown; }
    }
    LOGI("Total maps lines: %d", total);
    log_result("proc_maps", total > 0, "readable");
}

static void test_proc_status() {
    log_banner("/proc/self/status (filtered)");
    std::ifstream f("/proc/self/status");
    if (!f.is_open()) {
        LOGE("open failed: %s", strerror(errno));
        log_result("proc_status", false, "open failed");
        return;
    }
    std::string line;
    while (std::getline(f, line)) {
        if (line.rfind("Name:", 0)       == 0 ||
            line.rfind("Pid:", 0)        == 0 ||
            line.rfind("Uid:", 0)        == 0 ||
            line.rfind("Gid:", 0)        == 0 ||
            line.rfind("Cap", 0)         == 0 ||
            line.rfind("Seccomp", 0)     == 0 ||
            line.rfind("NoNewPrivs", 0)  == 0 ||
            line.rfind("Threads:", 0)    == 0) {
            LOGI("%s", line.c_str());
        }
    }
    log_result("proc_status", true, "filtered");
}

static void test_fork() {
    log_banner("fork()");
    pid_t pid = fork();
    if (pid < 0) {
        LOGE("fork failed: errno=%d (%s)", errno, strerror(errno));
        log_result("fork", false, strerror(errno));
        return;
    }
    if (pid == 0) {
        printf("[child pid=%d] hello from child\n", (int)getpid());
        fflush(stdout);
        _exit(123);
    }
    LOGI("Parent waiting for child pid=%d", (int)pid);
    int status = 0;
    if (waitpid(pid, &status, 0) < 0) {
        LOGE("waitpid failed: %s", strerror(errno));
        log_result("fork", false, "waitpid failed");
        return;
    }
    if (WIFEXITED(status)) {
        int c = WEXITSTATUS(status);
        LOGI("Child exit code = %d (expect 123)", c);
        log_result("fork", c == 123, c == 123 ? "exited normally" : "wrong code");
    } else if (WIFSIGNALED(status)) {
        int s = WTERMSIG(status);
        LOGW("Child killed by signal %d (%s)", s, strsignal(s));
        log_result("fork", false, "killed by signal");
    } else {
        LOGW("unknown status 0x%x", status);
        log_result("fork", false, "unknown status");
    }
}

static void test_vfork() {
    log_banner("vfork()");
    pid_t pid = vfork();
    if (pid < 0) {
        LOGE("vfork failed: errno=%d (%s)", errno, strerror(errno));
        log_result("vfork", false, strerror(errno));
        return;
    }
    if (pid == 0) _exit(45);
    int status = 0;
    waitpid(pid, &status, 0);
    bool ok = WIFEXITED(status) && WEXITSTATUS(status) == 45;
    log_result("vfork", ok, ok ? "child exited 45" : "failed");
}

extern "C" void RunProcTests(void) {
    test_proc_maps();
    test_proc_status();
    test_fork();
    test_vfork();
}