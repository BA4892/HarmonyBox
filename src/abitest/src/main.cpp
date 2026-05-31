#include "log_util.h"
#include "test_runner.h"

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <chrono>
#include <string>
#include <vector>
#include <unistd.h>

static void print_usage(const char* prog) {
    printf(
        "HarmonyOS ABI Compatibility Test Tool\n"
        "\n"
        "Usage: %s [options] [suite...]\n"
        "\n"
        "Options:\n"
        "  -h, --help        show this help and exit\n"
        "  -l, --list        list available suites and exit\n"
        "  -a, --all         run all suites (default if none specified)\n"
        "      --no-color    disable ANSI colors\n"
        "      --no-hilog    disable hilog output\n"
        "      --no-fork     run tests directly (no fork isolation; risky)\n"
        "\n"
        "Suites:\n",
        prog);
    for (int i = 0; i < g_test_suite_count; i++) {
        printf("  %-10s  %s\n",
               g_test_suites[i].key, g_test_suites[i].desc);
    }
    printf(
        "\n"
        "Examples:\n"
        "  %s                  # run everything\n"
        "  %s sysinfo proc     # only those two\n"
        "  %s --no-fork jit    # inline JIT (will crash if JIT denied)\n"
        "\n",
        prog, prog, prog);
}

int main(int argc, char** argv) {
    bool use_color = true;
    bool use_hilog = true;
    bool use_fork  = true;
    bool list_only = false;
    std::vector<std::string> wanted;

    for (int i = 1; i < argc; i++) {
        const char* a = argv[i];
        if      (!strcmp(a, "-h") || !strcmp(a, "--help"))     { print_usage(argv[0]); return 0; }
        else if (!strcmp(a, "-l") || !strcmp(a, "--list"))     { list_only = true; }
        else if (!strcmp(a, "-a") || !strcmp(a, "--all"))      { wanted.clear(); }
        else if (!strcmp(a, "--no-color"))                     { use_color = false; }
        else if (!strcmp(a, "--no-hilog"))                     { use_hilog = false; }
        else if (!strcmp(a, "--no-fork"))                      { use_fork  = false; }
        else if (a[0] == '-')                                  {
            fprintf(stderr, "unknown option: %s (try --help)\n", a);
            return 2;
        } else {
            wanted.emplace_back(a);
        }
    }

    log_init(use_color, use_hilog);

    if (list_only) {
        for (int i = 0; i < g_test_suite_count; i++) {
            printf("%-10s  %s\n", g_test_suites[i].key, g_test_suites[i].desc);
        }
        return 0;
    }

    log_section("HarmonyOS ABI Compatibility Test");
    LOGI("pid=%d  uid=%d  gid=%d  fork=%s  color=%s  hilog=%s",
         (int)getpid(), (int)getuid(), (int)getgid(),
         use_fork ? "on" : "off",
         use_color ? "on" : "off",
         use_hilog ? "on" : "off");

    auto t0 = std::chrono::steady_clock::now();

    int total = 0, passed = 0;
    std::vector<std::pair<std::string, bool>> results;

    for (int i = 0; i < g_test_suite_count; i++) {
        const auto& s = g_test_suites[i];
        if (!wanted.empty()) {
            bool match = false;
            for (auto& w : wanted) if (w == s.key) { match = true; break; }
            if (!match) continue;
        }
        total++;
        log_section(s.desc);
        bool ok = use_fork ? run_suite_isolated(s) : run_suite_inline(s);
        if (ok) passed++;
        results.emplace_back(s.key, ok);
    }

    if (total == 0) {
        LOGW("No suite matched. Use --list to see available suites.");
        return 1;
    }

    auto t1 = std::chrono::steady_clock::now();
    double sec = std::chrono::duration<double>(t1 - t0).count();

    // 末尾再列一次每个 suite 的结果
    log_section("Results");
    for (auto& r : results) {
        log_result(r.first.c_str(), r.second,
                   r.second ? "suite finished without crashing"
                            : "see logs above for failure reason");
    }

    log_summary(total, passed, total - passed, sec);

    return (passed == total) ? 0 : 1;
}