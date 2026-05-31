/*
 * test_box64.c — box64 on HarmonyOS NEXT 功能验收
 *
 * 每个测试一个 BEGIN..END 块, PASS/FAIL/INFO 计数,
 * 任何一项崩了不影响后面继续跑.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <sys/time.h>
#include <time.h>
#include <errno.h>
#include <signal.h>
#include <math.h>
#include <pthread.h>

static int g_total = 0, g_pass = 0, g_fail = 0;

#define BEGIN(name) do { g_total++; \
    printf("\n┌─[ %s ]\n", name); fflush(stdout); } while(0)
#define PASS(...)   do { g_pass++; \
    printf("│  [PASS] "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)
#define FAIL(...)   do { g_fail++; \
    printf("│  [FAIL] "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)
#define INFO(...)   do { \
    printf("│  [INFO] "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while(0)
#define END()       do { printf("└─\n"); fflush(stdout); } while(0)

/* ---------------- tests ---------------- */

static void t_stdio(void) {
    BEGIN("stdio");
    printf("│  hello via printf\n");
    fputs("│  hello via fputs(stdout)\n", stdout);
    fputs("│  hello via fputs(stderr)\n", stderr);
    PASS("stdout/stderr 都能写");
    END();
}

static void t_args(int argc, char **argv) {
    BEGIN("argv");
    INFO("argc=%d", argc);
    for (int i = 0; i < argc; i++) INFO("argv[%d]=%s", i, argv[i]);
    PASS("argv 解析");
    END();
}

static void t_env(void) {
    BEGIN("env");
    const char *p = getenv("PATH"), *h = getenv("HOME");
    INFO("PATH=%s", p ? p : "(unset)");
    INFO("HOME=%s", h ? h : "(unset)");
    PASS("getenv");
    END();
}

static void t_uname(void) {
    BEGIN("uname");
    struct utsname u;
    if (uname(&u) != 0) { FAIL("uname: %s", strerror(errno)); END(); return; }
    INFO("sysname  = %s", u.sysname);
    INFO("nodename = %s", u.nodename);
    INFO("release  = %s", u.release);
    INFO("version  = %s", u.version);
    INFO("machine  = %s", u.machine);
    PASS("uname");
    END();
}

static void t_ids(void) {
    BEGIN("pid/uid");
    INFO("pid=%d ppid=%d uid=%d gid=%d",
         (int)getpid(), (int)getppid(), (int)getuid(), (int)getgid());
    PASS("身份系列调用");
    END();
}

static void t_time(void) {
    BEGIN("time");
    INFO("time()  = %ld", (long)time(NULL));
    struct timeval tv; gettimeofday(&tv, NULL);
    INFO("gtod    = %ld.%06ld", (long)tv.tv_sec, (long)tv.tv_usec);
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    INFO("MONO    = %ld.%09ld", (long)ts.tv_sec, ts.tv_nsec);
    clock_gettime(CLOCK_REALTIME, &ts);
    INFO("REAL    = %ld.%09ld", (long)ts.tv_sec, ts.tv_nsec);
    PASS("time/gettimeofday/clock_gettime");
    END();
}

static void t_malloc(void) {
    BEGIN("malloc");
    void *p1 = malloc(64), *p2 = malloc(4096), *p3 = malloc(1 << 20);
    if (!p1 || !p2 || !p3) { FAIL("malloc NULL"); END(); return; }
    INFO("64=%p 4K=%p 1M=%p", p1, p2, p3);
    memset(p1, 0xab, 64);
    memset(p2, 0xcd, 4096);
    memset(p3, 0xef, 1 << 20);
    if (((unsigned char*)p3)[(1<<20)-1] != 0xef) {
        FAIL("内容校验失败"); free(p1); free(p2); free(p3); END(); return;
    }
    free(p1); free(p2); free(p3);

    char *s = malloc(16); strcpy(s, "abc");
    s = realloc(s, 1024);
    if (strcmp(s, "abc") != 0) { FAIL("realloc 丢内容"); free(s); END(); return; }
    free(s);
    PASS("malloc/free/realloc");
    END();
}

static void t_str(void) {
    BEGIN("string");
    char buf[64];
    strcpy(buf, "hello"); strcat(buf, ", world");
    INFO("strcpy/cat: %s", buf);
    int n = snprintf(buf, sizeof(buf), "n=%d s=%s f=%.2f", 42, "abc", 3.14);
    INFO("snprintf %d: %s", n, buf);
    if (!strstr(buf, "abc")) { FAIL("strstr"); END(); return; }
    PASS("字符串系列");
    END();
}

static void t_math(void) {
    BEGIN("libm");
    INFO("sqrt(2)    = %.10f", sqrt(2.0));
    INFO("sin(π/2)   = %.10f", sin(M_PI/2));
    INFO("exp(1)     = %.10f", exp(1.0));
    INFO("log(e)     = %.10f", log(M_E));
    INFO("pow(2,10)  = %.10f", pow(2.0, 10.0));
    if (fabs(sqrt(2.0) - 1.41421356) > 1e-6) { FAIL("sqrt(2)"); END(); return; }
    PASS("libm 基础函数");
    END();
}

static void t_fpu(void) {
    BEGIN("fpu/sse");
    double s = 0;
    for (int i = 1; i <= 1000; i++) s += 1.0 / (double)i;
    INFO("Σ(1/i) double = %.10f", s);
    float fs = 0;
    for (int i = 1; i <= 1000; i++) fs += 1.0f / (float)i;
    INFO("Σ(1/i) float  = %.6f", fs);
    if (fabs(s - 7.4854708606) > 1e-6) { FAIL("double 不准"); END(); return; }
    PASS("FPU/SSE 浮点");
    END();
}

static void t_file(void) {
    BEGIN("file_io");
    const char *path = "test_box64_tmp.txt";
    const char *want = "hello from box64\n第二行 utf-8\n";
    FILE *f = fopen(path, "w");
    if (!f) { FAIL("fopen w: %s", strerror(errno)); END(); return; }
    fwrite(want, 1, strlen(want), f); fclose(f);

    struct stat st;
    if (stat(path, &st) != 0) { FAIL("stat"); END(); return; }
    INFO("size=%ld", (long)st.st_size);

    f = fopen(path, "r");
    char buf[256] = {0};
    size_t r = fread(buf, 1, sizeof(buf)-1, f); fclose(f);
    INFO("read %zu", r);

    if (strcmp(buf, want) != 0) {
        FAIL("内容不一致"); INFO("got: %s", buf);
        unlink(path); END(); return;
    }
    unlink(path);
    PASS("fopen/fwrite/stat/fread/unlink");
    END();
}

static volatile sig_atomic_t g_sig = 0;
static void on_sig(int s) { g_sig = s; }

static void t_signal(void) {
    BEGIN("signal");
    struct sigaction sa = {0};
    sa.sa_handler = on_sig;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGUSR1, &sa, NULL) != 0) { FAIL("sigaction"); END(); return; }
    kill(getpid(), SIGUSR1);
    for (int i = 0; i < 200 && g_sig == 0; i++) usleep(1000);
    if (g_sig != SIGUSR1) { FAIL("信号未送达"); END(); return; }
    INFO("got signal %d (%s)", g_sig, strsignal(g_sig));
    PASS("sigaction + kill + handler");
    END();
}

struct targ { int id; long sum; };
static void *worker(void *p) {
    struct targ *a = p; long s = 0;
    for (long i = 0; i < 100000; i++) s += i;
    a->sum = s; return NULL;
}

static void t_pthread(void) {
    BEGIN("pthread");
    enum { N = 4 };
    pthread_t th[N]; struct targ a[N];
    for (int i = 0; i < N; i++) {
        a[i].id = i; a[i].sum = -1;
        if (pthread_create(&th[i], NULL, worker, &a[i]) != 0) {
            FAIL("pthread_create %d", i); END(); return;
        }
    }
    INFO("created %d threads", N);
    for (int i = 0; i < N; i++) {
        pthread_join(th[i], NULL);
        INFO("th[%d] sum=%ld", a[i].id, a[i].sum);
        if (a[i].sum != 4999950000L) { FAIL("th %d 计算错", i); END(); return; }
    }
    PASS("pthread create/join");
    END();
}

static pthread_mutex_t g_mtx = PTHREAD_MUTEX_INITIALIZER;
static long g_cnt = 0;
static void *incr(void *_) { (void)_;
    for (int i = 0; i < 50000; i++) {
        pthread_mutex_lock(&g_mtx); g_cnt++; pthread_mutex_unlock(&g_mtx);
    }
    return NULL;
}

static void t_mutex(void) {
    BEGIN("pthread_mutex");
    enum { N = 4 };
    pthread_t th[N]; g_cnt = 0;
    for (int i = 0; i < N; i++) pthread_create(&th[i], NULL, incr, NULL);
    for (int i = 0; i < N; i++) pthread_join(th[i], NULL);
    INFO("cnt=%ld 期望=%d", g_cnt, N * 50000);
    if (g_cnt == (long)N * 50000) PASS("mutex 正确序列化");
    else                          FAIL("mutex race");
    END();
}

/* ---------------- main ---------------- */

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    printf("\n=================================================\n");
    printf("  box64 functional test on HarmonyOS NEXT\n");
    printf("  built %s %s\n", __DATE__, __TIME__);
    printf("  ptr=%zu bytes\n", sizeof(void*));
#ifdef __x86_64__
    printf("  arch: x86_64\n");
#elif defined(__aarch64__)
    printf("  arch: aarch64\n");
#endif
#ifdef __GLIBC__
    printf("  libc: glibc %d.%d\n", __GLIBC__, __GLIBC_MINOR__);
#else
    printf("  libc: musl (or unknown)\n");
#endif
    printf("=================================================\n");

    t_stdio();
    t_args(argc, argv);
    t_env();
    t_uname();
    t_ids();
    t_time();
    t_malloc();
    t_str();
    t_math();
    t_fpu();
    t_file();
    t_signal();
    t_pthread();
    t_mutex();

    printf("\n=================================================\n");
    printf("  total=%d  pass=%d  fail=%d\n", g_total, g_pass, g_fail);
    printf("=================================================\n\n");
    return g_fail > 0 ? 1 : 0;
}