#ifndef UNIVERSE_WINDOWS_TLS_H
#define UNIVERSE_WINDOWS_TLS_H

#include "windows-guest.h"

typedef void (*TlsCallback)(HANDLE, DWORD, void *);
typedef struct {
    void *start;
    void *end;
    DWORD *index;
    TlsCallback *callbacks;
    DWORD zero_fill;
    DWORD characteristics;
} TlsDirectory;

__thread volatile DWORD universe_tls_value = UNIVERSE_TLS_INITIAL_VALUE;
DWORD _tls_index;
__attribute__((section(".tls"), used)) void *__tls_start;
__attribute__((section(".tls$ZZZ"), used)) void *__tls_end;
__attribute__((section(".CRT$XLA"), used)) TlsCallback __xl_a;
__attribute__((section(".CRT$XLZ"), used)) TlsCallback __xl_z;
__attribute__((section(".rdata$T"), used)) const TlsDirectory _tls_used = {
    &__tls_start, &__tls_end, &_tls_index, &__xl_a + 1, 0, 0,
};

#endif
