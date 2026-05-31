#pragma once

struct TestSuite {
    const char* key;
    const char* desc;
    void (*func)();
};

extern const TestSuite g_test_suites[];
extern const int       g_test_suite_count;

bool run_suite_isolated(const TestSuite& s);
bool run_suite_inline  (const TestSuite& s);