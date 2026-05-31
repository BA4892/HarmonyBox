#include "log_util.h"

#include <cerrno>
#include <cstdint>
#include <cstring>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <unistd.h>

// ARM64:  mov w0, #42 ; ret
static const uint8_t kReturn42[] = {
    0x40, 0x05, 0x80, 0x52,
    0xc0, 0x03, 0x5f, 0xd6,
};

typedef int (*Fn)(void);

static bool exec_at(void* p, const char* tag) {
    __builtin___clear_cache((char*)p, (char*)p + sizeof(kReturn42));
    LOGI("[%s] About to JUMP to %p ...", tag, p);
    int v = ((Fn)p)();
    LOGI("[%s] Returned %d (expect 42)", tag, v);
    return v == 42;
}

static void test_mmap_rwx() {
    log_banner("mmap PROT_R|W|X (W^X violation)");
    void* m = mmap(nullptr, 4096,
                   PROT_READ | PROT_WRITE | PROT_EXEC,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) {
        LOGE("mmap RWX failed: errno=%d (%s)", errno, strerror(errno));
        log_result("mmap_rwx", false, strerror(errno));
        return;
    }
    LOGI("mmap RWX OK at %p", m);
    memcpy(m, kReturn42, sizeof(kReturn42));
    bool ok = exec_at(m, "rwx");
    munmap(m, 4096);
    log_result("mmap_rwx", ok, ok ? "executed" : "did not return 42");
}

static void test_mprotect_rx() {
    log_banner("mmap RW + mprotect RX");
    void* m = mmap(nullptr, 4096, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) {
        LOGE("mmap RW failed: %s", strerror(errno));
        log_result("mprotect_rx", false, strerror(errno));
        return;
    }
    memcpy(m, kReturn42, sizeof(kReturn42));
    if (mprotect(m, 4096, PROT_READ | PROT_EXEC) != 0) {
        LOGE("mprotect RX failed: %s", strerror(errno));
        munmap(m, 4096);
        log_result("mprotect_rx", false, strerror(errno));
        return;
    }
    bool ok = exec_at(m, "mprotect_rx");
    munmap(m, 4096);
    log_result("mprotect_rx", ok, ok ? "executed" : "did not return 42");
}

static void test_dual_mapping() {
    log_banner("memfd dual mapping (W and X)");
    int fd = (int)syscall(SYS_memfd_create, "jit", 0u);
    if (fd < 0) {
        LOGE("memfd_create failed: %s", strerror(errno));
        log_result("dual_mapping", false, "memfd failed");
        return;
    }
    if (ftruncate(fd, 4096) != 0) {
        LOGE("ftruncate failed: %s", strerror(errno));
        close(fd);
        log_result("dual_mapping", false, "ftruncate failed");
        return;
    }
    void* w = mmap(nullptr, 4096, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (w == MAP_FAILED) {
        LOGE("W-mmap failed: %s", strerror(errno));
        close(fd);
        log_result("dual_mapping", false, "W mmap failed");
        return;
    }
    void* x = mmap(nullptr, 4096, PROT_READ | PROT_EXEC, MAP_SHARED, fd, 0);
    if (x == MAP_FAILED) {
        LOGE("X-mmap failed: %s", strerror(errno));
        munmap(w, 4096);
        close(fd);
        log_result("dual_mapping", false, "X mmap failed");
        return;
    }
    LOGI("W=%p X=%p", w, x);
    memcpy(w, kReturn42, sizeof(kReturn42));
    bool ok = exec_at(x, "dual");
    munmap(w, 4096);
    munmap(x, 4096);
    close(fd);
    log_result("dual_mapping", ok, ok ? "executed" : "did not return 42");
}

static void test_large_jit() {
    log_banner("16MB JIT region (Box64-style)");
    const size_t SZ = 16 * 1024 * 1024;
    void* m = mmap(nullptr, SZ, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (m == MAP_FAILED) {
        LOGE("mmap %zu RW failed: %s", SZ, strerror(errno));
        log_result("large_jit", false, strerror(errno));
        return;
    }
    if (mprotect(m, SZ, PROT_READ | PROT_EXEC) != 0) {
        LOGE("mprotect 16MB RX failed: %s", strerror(errno));
        munmap(m, SZ);
        log_result("large_jit", false, "mprotect failed");
        return;
    }
    LOGI("16MB R-X region established at %p", m);
    munmap(m, SZ);
    log_result("large_jit", true, "16MB OK");
}

extern "C" void RunJitTests(void) {
    test_mmap_rwx();
    test_mprotect_rx();
    test_dual_mapping();
    test_large_jit();
}