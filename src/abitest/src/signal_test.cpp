#include "log_util.h"

#include <atomic>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <setjmp.h>
#include <signal.h>
#include <unistd.h>

static std::atomic<int> g_usr1{0};
static sigjmp_buf       g_jmp;
static volatile int     g_segv_seen = 0;

static void usr1_handler(int) { g_usr1++; }

static void segv_handler(int, siginfo_t*, void*) {
    g_segv_seen = 1;
    siglongjmp(g_jmp, 1);
}

static void test_sigusr1() {
    log_banner("SIGUSR1 raise + handler");
    struct sigaction sa{};
    sa.sa_handler = usr1_handler;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGUSR1, &sa, nullptr) != 0) {
        LOGE("sigaction(SIGUSR1) failed: %s", strerror(errno));
        log_result("sigusr1", false, strerror(errno));
        return;
    }
    g_usr1 = 0;
    raise(SIGUSR1);
    usleep(20000);
    int n = g_usr1.load();
    LOGI("Handler invoked %d time(s)", n);
    log_result("sigusr1", n == 1, n == 1 ? "handler ran" : "no handler");
}

static void test_sigaltstack() {
    log_banner("sigaltstack");
    stack_t ss{};
    ss.ss_sp   = malloc(SIGSTKSZ);
    if (!ss.ss_sp) {
        LOGE("malloc(SIGSTKSZ=%d) failed", SIGSTKSZ);
        log_result("sigaltstack", false, "malloc failed");
        return;
    }
    ss.ss_size = SIGSTKSZ;
    if (sigaltstack(&ss, nullptr) != 0) {
        LOGE("sigaltstack failed: %s", strerror(errno));
        free(ss.ss_sp);
        log_result("sigaltstack", false, strerror(errno));
        return;
    }
    LOGI("alt stack at %p, size %d", ss.ss_sp, SIGSTKSZ);
    stack_t off{};
    off.ss_flags = SS_DISABLE;
    sigaltstack(&off, nullptr);
    free(ss.ss_sp);
    log_result("sigaltstack", true, "registered");
}

static void test_sigsegv_recover() {
    log_banner("SIGSEGV recover via siglongjmp");
    struct sigaction sa{};
    sa.sa_sigaction = segv_handler;
    sa.sa_flags     = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, nullptr) != 0) {
        LOGE("sigaction(SIGSEGV) failed: %s", strerror(errno));
        log_result("sigsegv_recover", false, strerror(errno));
        return;
    }
    g_segv_seen = 0;
    if (sigsetjmp(g_jmp, 1) == 0) {
        LOGI("Triggering NULL deref ...");
        volatile int* p = nullptr;
        int x = *p;
        (void)x;
        LOGE("UNREACHABLE");
        log_result("sigsegv_recover", false, "no SEGV");
    } else {
        LOGI("Recovered from SIGSEGV");
        log_result("sigsegv_recover", g_segv_seen == 1,
                   g_segv_seen == 1 ? "handler ran" : "not seen");
    }
    signal(SIGSEGV, SIG_DFL);
}

extern "C" void RunSignalTests(void) {
    test_sigusr1();
    test_sigaltstack();
    test_sigsegv_recover();
}