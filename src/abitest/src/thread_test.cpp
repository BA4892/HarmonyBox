#include "log_util.h"

#include <atomic>
#include <cerrno>
#include <cstring>
#include <linux/futex.h>
#include <pthread.h>
#include <sys/syscall.h>
#include <unistd.h>

static std::atomic<int> g_counter{0};

static void* worker_fn(void* arg) {
    long id = (long)arg;
    LOGI("Thread %ld tid=%d running", id, (int)syscall(SYS_gettid));
    g_counter++;
    usleep(2000);
    return (void*)id;
}

static void test_pthread() {
    log_banner("pthread create/join");
    constexpr int N = 8;
    pthread_t th[N];
    g_counter = 0;
    for (int i = 0; i < N; ++i) {
        int rc = pthread_create(&th[i], nullptr, worker_fn, (void*)(long)i);
        if (rc != 0) {
            LOGE("pthread_create[%d] rc=%d (%s)", i, rc, strerror(rc));
            log_result("pthread", false, strerror(rc));
            return;
        }
    }
    for (int i = 0; i < N; ++i) pthread_join(th[i], nullptr);
    LOGI("counter = %d / %d", g_counter.load(), N);
    log_result("pthread", g_counter == N, "joined");
}

static int g_futex_val = 0;

static void* futex_waiter(void*) {
    LOGI("Waiter: futex_wait on val=%d", g_futex_val);
    long rc = syscall(SYS_futex, &g_futex_val, FUTEX_WAIT, 0, nullptr, nullptr, 0);
    if (rc != 0) {
        LOGW("futex_wait rc=%ld errno=%d (%s)",
             rc, errno, strerror(errno));
    } else {
        LOGI("Waiter: woke up, futex=%d", g_futex_val);
    }
    return nullptr;
}

static void test_futex() {
    log_banner("futex wait/wake");
    g_futex_val = 0;
    pthread_t t;
    if (pthread_create(&t, nullptr, futex_waiter, nullptr) != 0) {
        LOGE("waiter create failed");
        log_result("futex", false, "thread create failed");
        return;
    }
    usleep(80000);
    g_futex_val = 1;
    long woken = syscall(SYS_futex, &g_futex_val, FUTEX_WAKE, 1, nullptr, nullptr, 0);
    LOGI("futex_wake returned %ld", woken);
    pthread_join(t, nullptr);
    log_result("futex", woken >= 0, "wake completed");
}

static thread_local int g_tls = 42;

static void* tls_worker(void*) {
    LOGI("TLS in new thread (expect 42): %d", g_tls);
    g_tls = 999;
    LOGI("TLS in new thread set to %d", g_tls);
    return nullptr;
}

static void test_tls() {
    log_banner("Thread-local storage");
    LOGI("TLS on caller (expect 42): %d", g_tls);
    g_tls = 100;
    pthread_t t;
    if (pthread_create(&t, nullptr, tls_worker, nullptr) != 0) {
        LOGE("tls_worker create failed");
        log_result("tls", false, "thread create failed");
        return;
    }
    pthread_join(t, nullptr);
    LOGI("TLS on caller after worker (expect 100): %d", g_tls);
    log_result("tls", g_tls == 100, "isolated");
}

extern "C" void RunThreadTests(void) {
    test_pthread();
    test_tls();
    test_futex();
}