#include "macos-guest.h"
long guest_main(unsigned long *stack) {
    long argc=stack[0];
    char **argv=(char **)(stack+1), **env=argv+argc+1;
    char **apple=env;
    while (*apple) apple++;
    apple++;
    const char *prefix="executable_path=";
    if (!apple[0] || apple[1]) return 1;
    for (long i=0;prefix[i];i++) if (apple[0][i]!=prefix[i]) return 2;
    for (long i=0;argv[0][i];i++) if (apple[0][16+i]!=argv[0][i]) return 3;
    if (apple[0][16+length(argv[0])]) return 4;
    for (long i=1;i<argc;i++) { text(argv[i],length(argv[i]));text("\n",1); }
    for (long i=0;env[i];i++) { text(env[i],length(env[i]));text("\n",1); }
    return 0;
}
