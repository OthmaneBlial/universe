/* Guest DSO: initialized data, constructor and dynamic thread-local storage. */
int universe_bias = 21;
__thread int universe_counter = 7;
__attribute__((constructor)) static void initialize(void) { universe_bias += 3; }
int universe_probe(int value) { return value + universe_bias + universe_counter++; }
