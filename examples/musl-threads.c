/* Actual pthread implementation runs as guest code; no host threads execute it. */
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
#include <stdatomic.h>
#include <errno.h>
#include <time.h>
#include <string.h>
#ifdef __linux__
#include <unistd.h>
#include <sys/syscall.h>
#include <linux/futex.h>
_Static_assert(FUTEX_WAIT_BITSET == 9 && FUTEX_WAKE_BITSET == 10, "Linux futex opcode ABI");
#endif
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready = PTHREAD_COND_INITIALIZER;
static unsigned arrivals, total;
static _Thread_local unsigned local;
static _Atomic unsigned phase;
static void *sleep_worker(void *unused) {
    (void)unused;
    const struct timespec pause = { 0, 1000000 };
    for (unsigned i = 0; i != 1000; ++i) {
        if (nanosleep(&pause, 0)) return (void *)2;
        if (atomic_load(&phase)) return (void *)1;
    }
    return (void *)3; /* Other guests must run while this thread sleeps. */
}
static void *spin_worker(void *value) {
    unsigned id = (uintptr_t)value;
    local = id + 10;
    if (id == 1) while (!atomic_load(&phase)) { }
    else atomic_store(&phase, 1);
    return (void *)(uintptr_t)local;
}
static void *worker(void *value) {
    unsigned id = (uintptr_t)value;
    local = id;
    if (pthread_mutex_lock(&mutex)) return (void *)1;
    ++arrivals;
    if (pthread_cond_broadcast(&ready)) return (void *)2;
    while (arrivals != 2) if (pthread_cond_wait(&ready, &mutex)) return (void *)3;
    if (pthread_mutex_unlock(&mutex)) return (void *)4;
    for (unsigned i = 0; i != 4000; ++i) {
        if (pthread_mutex_lock(&mutex)) return (void *)5;
        total += id;
        if (pthread_mutex_unlock(&mutex)) return (void *)6;
        if (local != id) return (void *)7;
    }
    return (void *)(uintptr_t)(local * 10);
}
int main(int argc, char **argv) {
    pthread_t first, second;
    void *a, *b;
    if (argc > 1 && !strcmp(argv[1], "sleeping")) {
        const struct timespec pause = { 2, 0 };
        return nanosleep(&pause, 0) != 0;
    }
    if (argc > 1 && !strcmp(argv[1], "blocked")) {
        pthread_mutex_lock(&mutex);
        for (;;) pthread_cond_wait(&ready, &mutex);
    }
    local = 99;
    if (pthread_create(&first, 0, worker, (void *)1) || pthread_create(&second, 0, worker, (void *)2)) return 1;
    if (pthread_join(first, &a) || pthread_join(second, &b)) return 2;
    if (a != (void *)10 || b != (void *)20 || total != 12000 || local != 99) return 3;
    puts("pthread: TLS, mutex, condition wait, joins and shared total=12000 ok");
    if (pthread_create(&first, 0, spin_worker, (void *)1) || pthread_create(&second, 0, spin_worker, (void *)2)) return 4;
    if (pthread_join(first, &a) || pthread_join(second, &b) || a != (void *)11 || b != (void *)12 || local != 99) return 5;
    struct timespec deadline;
    if (clock_gettime(CLOCK_REALTIME, &deadline) || pthread_mutex_lock(&mutex)) return 6;
    deadline.tv_nsec += 10000000;
    if (deadline.tv_nsec >= 1000000000) { ++deadline.tv_sec; deadline.tv_nsec -= 1000000000; }
    if (pthread_cond_timedwait(&ready, &mutex, &deadline) != ETIMEDOUT || pthread_mutex_unlock(&mutex)) return 7;
#ifdef __linux__
    struct timespec past = { 0, 0 };
    if (syscall(SYS_futex, &phase, FUTEX_WAIT_BITSET, 1, &past, 0, FUTEX_BITSET_MATCH_ANY) != -1 || errno != ETIMEDOUT) return 8;
    if (syscall(SYS_futex, &phase, FUTEX_WAKE_BITSET, 1, 0, 0, FUTEX_BITSET_MATCH_ANY) != 0) return 9;
#endif
    puts("pthread: CPU preemption, reused slots, TLS and timed condition wait ok");
    atomic_store(&phase, 0);
    if (pthread_create(&first, 0, sleep_worker, 0) || pthread_create(&second, 0, spin_worker, (void *)2)) return 10;
    if (pthread_join(first, &a) || pthread_join(second, &b) || a != (void *)1 || b != (void *)12 || local != 99) return 11;
#ifdef __linux__
    struct timespec remainder = { 123, 456 }, zero = { 0, 0 };
    if (syscall(SYS_nanosleep, &zero, &remainder) || remainder.tv_sec != 123 || remainder.tv_nsec != 456) return 12;
    for (int clock = CLOCK_REALTIME; clock <= CLOCK_MONOTONIC; ++clock) {
        struct timespec now, until;
        if (clock_gettime(clock, &until)) return 13;
        until.tv_nsec += 5000000;
        if (until.tv_nsec >= 1000000000) { ++until.tv_sec; until.tv_nsec -= 1000000000; }
        if (clock_nanosleep(clock, TIMER_ABSTIME, &until, &remainder) || clock_gettime(clock, &now)) return 14;
        if (now.tv_sec < until.tv_sec || (now.tv_sec == until.tv_sec && now.tv_nsec < until.tv_nsec)) return 15;
        if (remainder.tv_sec != 123 || remainder.tv_nsec != 456) return 16;
    }
#endif
    puts("pthread: scheduler sleeps and timed wakeups ok");
    return 0;
}
