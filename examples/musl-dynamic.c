/* Linked against a separate guest DSO and an upstream guest musl interpreter. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
extern int universe_probe(int);
int main(int argc, char **argv) {
    const char *env = getenv("UNIVERSE_TEST");
    if (argc != 2 || strcmp(argv[1], "check") || !env || strcmp(env, "dynamic")) return 1;
    if (universe_probe(4) != 35 || universe_probe(5) != 37) return 2;
    char *buffer = calloc(8192, 1);
    if (!buffer) return 3;
    for (int i = 0; i < 8192; i++) if (buffer[i]) return 4;
    memset(buffer, 'x', 8192);
    if (buffer[0] != 'x' || buffer[8191] != 'x') return 5;
    free(buffer);
    puts("dynamic musl: imports, constructors and TLS ok");
    return 0;
}
