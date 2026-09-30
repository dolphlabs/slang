## Rules that apply to every task

- Put the service in the current directory, and write `start.sh`: running
  `sh start.sh` must build (if needed) and start the service in the
  foreground, listening on `127.0.0.1` at the port in the `PORT`
  environment variable (8080 if unset). It is started once and stopped
  with SIGTERM.
- Request and response bodies are JSON (`Content-Type: application/json`)
  unless the task says otherwise.
- Every failure has this body, with the status the task gives:
  `{"error": {"code": "<code>", "message": "<human-readable text>"}}`
- State lives in memory; no database or external service is needed.
- The service is tested from outside, over HTTP only. You will not see the
  tests; the contract below is all of it.
