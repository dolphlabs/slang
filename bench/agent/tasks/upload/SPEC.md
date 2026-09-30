# Task: upload (multipart files)

- `POST /files` with `multipart/form-data` holding one file in the field
  `file`: `201` and `{"id": "<str>", "name": "<file name>", "size": <int>}`.
  `name` is the uploaded file name reduced to its last path component
  (`../../etc/passwd` becomes `passwd`); the bytes are never written
  outside the service's own storage.
- A file larger than 1 MiB (1048576 bytes): `413` with code `too_large`.
- No `file` field, or a body that is not multipart: `400` with code
  `invalid`.
- `GET /files/<id>`: `200`, the exact bytes uploaded, with
  `Content-Type: application/octet-stream`. Unknown id: `404` with code
  `not_found`.
