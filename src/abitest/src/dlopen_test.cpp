#include "log_util.h"

#include <dlfcn.h>

static void probe(const char* name) {
    void* h = dlopen(name, RTLD_NOW | RTLD_LOCAL);
    if (h) {
        LOGI("dlopen %-32s OK   (%p)", name, h);
        dlclose(h);
    } else {
        const char* err = dlerror();
        LOGW("dlopen %-32s FAIL (%s)", name, err ? err : "?");
    }
}

extern "C" void RunDlopenTests(void) {
    log_banner("dlopen probe");
    static const char* libs[] = {
        "libc.so",            "libc.so.6",
        "ld-musl-aarch64.so.1",
        "libdl.so",           "libpthread.so",
        "libm.so",
        "libstdc++.so",       "libc++.so",
        "libz.so",            "libssl.so",         "libcrypto.so",
        "libGLESv3.so",       "libEGL.so",         "libvulkan.so",
        "libuv.so",           "libhilog_ndk.z.so", "libace_ndk.z.so",
    };
    for (auto n : libs) probe(n);
    log_result("dlopen_probe", true, "see log for each lib");
}