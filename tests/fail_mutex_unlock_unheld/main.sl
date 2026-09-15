// unlocking a mutex nobody holds is a bug that otherwise surfaces much
// later as corruption in whatever the lock was protecting
let m = make_mutex();
mutex_unlock(m);
