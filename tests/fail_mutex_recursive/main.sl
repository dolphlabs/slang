// slang mutexes are not recursive: locking one this task already holds
// would park it forever on itself, so it is a checked runtime error
// with a named cause instead of a hang.
let m = make_mutex();
mutex_lock(m);
mutex_lock(m);
