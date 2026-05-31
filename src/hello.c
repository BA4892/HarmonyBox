#include <stdio.h>
int main(int argc, char **argv) {
    printf("Hello from x86_64 dynamic glibc on HarmonyOS! argc=%d\n", argc);
    for (int i = 0; i < argc; i++) printf("  argv[%d]=%s\n", i, argv[i]);
    return 42;
}
