#include "log_util.h"

#include <cerrno>
#include <cstring>
#include <fstream>
#include <string>
#include <sys/auxv.h>
#include <sys/utsname.h>
#include <unistd.h>

static void dump_uname() {
    log_banner("uname / sysconf");
    struct utsname u{};
    if (uname(&u) == 0) {
        LOGI("sysname:  %s", u.sysname);
        LOGI("nodename: %s", u.nodename);
        LOGI("release:  %s", u.release);
        LOGI("version:  %s", u.version);
        LOGI("machine:  %s", u.machine);
    } else {
        LOGE("uname failed: %s", strerror(errno));
    }
    LOGI("Page size:    %ld", sysconf(_SC_PAGESIZE));
    LOGI("Online CPUs:  %ld", sysconf(_SC_NPROCESSORS_ONLN));
    LOGI("Conf  CPUs:   %ld", sysconf(_SC_NPROCESSORS_CONF));
    LOGI("Phys pages:   %ld", sysconf(_SC_PHYS_PAGES));
    LOGI("Avail pages:  %ld", sysconf(_SC_AVPHYS_PAGES));
    log_result("uname", true, "ok");
}

static void dump_hwcap() {
    log_banner("HWCAP / HWCAP2");
    unsigned long h1 = getauxval(AT_HWCAP);
    unsigned long h2 = getauxval(AT_HWCAP2);
    LOGI("AT_HWCAP:  0x%lx", h1);
    LOGI("AT_HWCAP2: 0x%lx", h2);
    if (h1 & (1u << 1))  LOGI("  +ASIMD");
    if (h1 & (1u << 3))  LOGI("  +AES");
    if (h1 & (1u << 6))  LOGI("  +CRC32");
    if (h1 & (1u << 8))  LOGI("  +ATOMICS(LSE)");
    if (h1 & (1u << 17)) LOGI("  +ASIMDDP");
    if (h1 & (1u << 22)) LOGI("  +SVE");
    log_result("hwcap", true, "ok");
}

static void dump_cpuinfo() {
    log_banner("/proc/cpuinfo (first 24 lines)");
    std::ifstream f("/proc/cpuinfo");
    if (!f.is_open()) {
        LOGE("cannot open /proc/cpuinfo: %s", strerror(errno));
        log_result("cpuinfo", false, "open failed");
        return;
    }
    std::string line;
    int n = 0;
    while (n < 24 && std::getline(f, line)) {
        LOGI("%s", line.c_str());
        n++;
    }
    log_result("cpuinfo", true, "dumped");
}

extern "C" void RunSysInfoTests(void) {
    dump_uname();
    dump_hwcap();
    dump_cpuinfo();
}