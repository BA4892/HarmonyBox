#include "log_util.h"

#include <atomic>
#include <cerrno>
#include <cstring>
#include <signal.h>
#include <sys/syscall.h>
#include <ucontext.h>
#include <unistd.h>

static std::atomic<int> g_caught{0};

static void sigsys_handler(int, siginfo_t* info, void* ucontext) {
    g_caught++;
    auto* uc = static_cast<ucontext_t*>(ucontext);
    int nr = info->si_syscall;
    LOGW("Caught SIGSYS for syscall nr=%d, faking -ENOSYS", nr);
#if defined(__aarch64__)
    uc->uc_mcontext.regs[0] = (unsigned long)(-ENOSYS);
#elif defined(__x86_64__)
    uc->uc_mcontext.gregs[REG_RAX] = (greg_t)(-ENOSYS);
#elif defined(__arm__)
    uc->uc_mcontext.arm_r0 = (unsigned long)(-ENOSYS);
#elif defined(__i386__)
    uc->uc_mcontext.gregs[REG_EAX] = (greg_t)(-ENOSYS);
#else
    (void)uc;
#endif
}

extern "C" void RunSigsysTests(void) {
    log_banner("SIGSYS catch & recover (TRAP vs KILL)");

    struct sigaction sa{};
    sa.sa_sigaction = sigsys_handler;
    sa.sa_flags     = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSYS, &sa, nullptr) != 0) {
        LOGE("sigaction(SIGSYS) failed: %s", strerror(errno));
        log_result("sigsys_handler", false, "cannot install");
        return;
    }
    LOGI("SIGSYS handler installed.");

    g_caught = 0;
#ifdef __NR_unshare
    LOGI("Calling blocked syscall unshare(0)...");
    errno = 0;
    long ret = syscall(__NR_unshare, 0);
    int e = errno;
    LOGI("After unshare: ret=%ld errno=%d caught=%d", ret, e, g_caught.load());
#else
    LOGW("__NR_unshare not defined on this build");
#endif

    if (g_caught > 0) {
        LOGI(">>> seccomp uses RET_TRAP: SIGSYS catchable & recoverable <<<");
        log_result("sigsys_recover", true, "TRAP mode");
    } else {
        LOGW("Handler not invoked: either unshare is allowed, or seccomp is KILL mode");
        log_result("sigsys_recover", false, "handler not called");
    }

#ifdef __NR_kcmp
    LOGI("Second blocked syscall kcmp...");
    errno = 0;
    long ret2 = syscall(__NR_kcmp, getpid(), getpid(), 99, 0, 0);
    LOGI("kcmp: ret=%ld errno=%d totalCaught=%d", ret2, errno, g_caught.load());
#endif

    signal(SIGSYS, SIG_DFL);
}