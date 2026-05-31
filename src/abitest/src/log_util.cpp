#include "log_util.h"

#include <cstdio>
#include <cstdarg>
#include <cstring>
#include <unistd.h>

#ifdef HAVE_HILOG
#include <hilog/log.h>
#undef  LOG_DOMAIN
#undef  LOG_TAG
#define LOG_DOMAIN 0xC0DE
#define LOG_TAG    "ABITest"
#endif

static bool g_color = true;
static bool g_hilog = true;

#define A_RESET   "\033[0m"
#define A_BOLD    "\033[1m"
#define A_DIM     "\033[2m"
#define A_RED     "\033[31m"
#define A_GREEN   "\033[32m"
#define A_YELLOW  "\033[33m"
#define A_BLUE    "\033[34m"
#define A_MAGENTA "\033[35m"
#define A_CYAN    "\033[36m"
#define A_GRAY    "\033[90m"

void log_init(bool use_color, bool use_hilog) {
    g_color = use_color && isatty(STDOUT_FILENO);
    g_hilog = use_hilog;
}

static const char* lvl_color(AbiLogLevel l) {
    switch (l) {
        case ABI_LL_DEBUG: return A_GRAY;
        case ABI_LL_INFO:  return A_CYAN;
        case ABI_LL_WARN:  return A_YELLOW;
        case ABI_LL_ERROR: return A_RED;
        case ABI_LL_FATAL: return A_BOLD A_RED;
    }
    return "";
}

static const char* lvl_tag(AbiLogLevel l) {
    switch (l) {
        case ABI_LL_DEBUG: return "DBG";
        case ABI_LL_INFO:  return "INF";
        case ABI_LL_WARN:  return "WRN";
        case ABI_LL_ERROR: return "ERR";
        case ABI_LL_FATAL: return "FTL";
    }
    return "???";
}

void log_write(AbiLogLevel lvl, const char* tag, const char* fmt, ...) {
    char buf[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    FILE* f = (lvl >= ABI_LL_ERROR) ? stderr : stdout;
    if (g_color) {
        fprintf(f, "%s[%s]%s %s%-22s%s %s\n",
                lvl_color(lvl), lvl_tag(lvl), A_RESET,
                A_DIM, tag, A_RESET, buf);
    } else {
        fprintf(f, "[%s] %-22s %s\n", lvl_tag(lvl), tag, buf);
    }
    fflush(f);

#ifdef HAVE_HILOG
    if (g_hilog) {
        switch (lvl) {
            case ABI_LL_DEBUG: OH_LOG_Print(LOG_APP, LOG_DEBUG, LOG_DOMAIN, LOG_TAG, "[%{public}s] %{public}s", tag, buf); break;
            case ABI_LL_INFO:  OH_LOG_Print(LOG_APP, LOG_INFO,  LOG_DOMAIN, LOG_TAG, "[%{public}s] %{public}s", tag, buf); break;
            case ABI_LL_WARN:  OH_LOG_Print(LOG_APP, LOG_WARN,  LOG_DOMAIN, LOG_TAG, "[%{public}s] %{public}s", tag, buf); break;
            case ABI_LL_ERROR: OH_LOG_Print(LOG_APP, LOG_ERROR, LOG_DOMAIN, LOG_TAG, "[%{public}s] %{public}s", tag, buf); break;
            case ABI_LL_FATAL: OH_LOG_Print(LOG_APP, LOG_FATAL, LOG_DOMAIN, LOG_TAG, "[%{public}s] %{public}s", tag, buf); break;
        }
    }
#endif
}

void log_section(const char* title) {
    if (g_color) {
        printf("\n%s%s╔══════════════════════════════════════════════════════════════╗%s\n",
               A_BOLD, A_BLUE, A_RESET);
        printf("%s%s║%s  %s%-58s%s  %s%s║%s\n",
               A_BOLD, A_BLUE, A_RESET,
               A_BOLD, title, A_RESET,
               A_BOLD, A_BLUE, A_RESET);
        printf("%s%s╚══════════════════════════════════════════════════════════════╝%s\n\n",
               A_BOLD, A_BLUE, A_RESET);
    } else {
        printf("\n=================================================================\n");
        printf("  %s\n", title);
        printf("=================================================================\n\n");
    }
    fflush(stdout);
}

void log_banner(const char* title) {
    if (g_color) {
        printf("\n%s%s┌─[ %s ]%s\n",
               A_BOLD, A_MAGENTA, title, A_RESET);
    } else {
        printf("\n--- %s ---\n", title);
    }
    fflush(stdout);
}

void log_result(const char* name, bool ok, const char* detail) {
    if (g_color) {
        const char* badge = ok
            ? (A_GREEN A_BOLD "[ PASS ]" A_RESET)
            : (A_RED   A_BOLD "[ FAIL ]" A_RESET);
        printf("  %s  %-32s  %s%s%s\n",
               badge, name, A_DIM, detail ? detail : "", A_RESET);
    } else {
        printf("  [%s] %-32s  %s\n",
               ok ? "PASS" : "FAIL", name, detail ? detail : "");
    }
    fflush(stdout);
}

void log_summary(int total, int passed, int failed, double seconds) {
    bool ok = (failed == 0);
    if (g_color) {
        const char* color = ok ? A_GREEN : A_RED;
        printf("\n%s%s┌─────────────────── Summary ───────────────────┐%s\n",
               A_BOLD, color, A_RESET);
        printf("%s%s│%s  Suites:  %s%-3d total  %s%-3d passed  %s%-3d failed%s\n",
               A_BOLD, color, A_RESET,
               A_BOLD, total,
               A_GREEN, passed,
               failed ? A_RED : A_GRAY, failed,
               A_RESET);
        printf("%s%s│%s  Elapsed: %.2f s\n",
               A_BOLD, color, A_RESET, seconds);
        printf("%s%s│%s  Verdict: %s%s%s\n",
               A_BOLD, color, A_RESET,
               A_BOLD, ok ? (A_GREEN "ALL GOOD") : (A_RED "FAILURES PRESENT"),
               A_RESET);
        printf("%s%s└────────────────────────────────────────────────┘%s\n",
               A_BOLD, color, A_RESET);
    } else {
        printf("\n=== Summary ===\n");
        printf("  total=%d passed=%d failed=%d  elapsed=%.2fs  verdict=%s\n",
               total, passed, failed, seconds, ok ? "OK" : "FAIL");
    }
    fflush(stdout);
}