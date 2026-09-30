#include "guest.h"
long guest_main(long *sp){long argc=sp[0];char **argv=(char **)(sp+1);char **env=argv+argc+1;
    text("argc=",5);char digit='0'+argc;text(&digit,1);text("\n",1);
    for(long i=1;i<argc;i++){text(argv[i],length(argv[i]));text("\n",1);}
    for(long i=0;env[i];i++){text(env[i],length(env[i]));text("\n",1);}
    unsigned long *aux=(unsigned long *)(env);while(*aux)aux++;aux++;
    long pages=0;while(aux[0]){if(aux[0]==6)pages=aux[1];aux+=2;}return pages==4096?0:5;
}
