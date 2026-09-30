# Task: notes (CRUD)

A JSON API for notes. A note is `{"id": <int>, "title": <str>, "body": <str>}`.
Ids start at 1 and increase by one per created note; they are never reused.

- `POST /notes` with `{"title": ..., "body": ...}` creates a note: `201` and
  the note. `title` must be a string of 1 to 100 characters and `body` a
  string (empty allowed); otherwise `400` with code `invalid`, and the
  message names the offending field.
- `GET /notes`: `200` and a JSON array of every note, oldest first.
- `GET /notes/<id>`: `200` and the note, or `404` with code `not_found`.
- `PUT /notes/<id>` with `{"title": ..., "body": ...}` replaces title and
  body (same validation as POST): `200` and the note, `400` `invalid`, or
  `404` `not_found`.
- `DELETE /notes/<id>`: `204` with no body, or `404` `not_found`.
- A body that is not valid JSON: `400` with code `invalid`.
