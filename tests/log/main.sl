import "log";

log.debug("debug message");
log.info("hello from log");
log.warn("warn message");
log.error("error message");
log.info(fault_io());
log.error("io failed: " + fault_timeout());
println("log ok");
println("fault concat: " + fault_reset());
println(to_str(fault_closed()));
