# log

> Package log.

Stderr logging with a timestamp and level. Each function accepts a
`str` or a `fault` (`to_str`/`+` already convert faults the same way),
so `err_of` bindings and `fault` values log without manual conversion.

```slang
import "log";

log.debug("cache miss for key foo");
log.info("listening on :8080");
log.warn("retrying dial after timeout");
log.error("could not load config: " + e);
log.warn(fault_timeout());
```

## API

### `log.debug(str)`

### `log.info(str)`

### `log.warn(str)`

### `log.error(str)`
