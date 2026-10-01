/* Actual pthread implementation runs as guest code; no host threads execute it. */
#include <pthread.h>
#include <stdio.h>
#include <stdint.h>
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t ready = PTHREAD_COND_INITIALIZER;
static unsigned arrivals, total;
static _Thread_local unsigned local;
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
int main(void) {
    pthread_t first, second;
    void *a, *b;
    local = 99;
    if (pthread_create(&first, 0, worker, (void *)1) || pthread_create(&second, 0, worker, (void *)2)) return 1;
    if (pthread_join(first, &a) || pthread_join(second, &b)) return 2;
    if (a != (void *)10 || b != (void *)20 || total != 12000 || local != 99) return 3;
    puts("pthread: TLS, mutex, condition wait, joins and shared total=12000 ok");
    return 0;
}
