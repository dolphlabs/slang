// integer division by zero must be a checked runtime error (SIGFPE
// would be uncatchable and would defeat spawned-task failure
// isolation), not a raw hardware trap
let z = 0;
println(10 / z);
