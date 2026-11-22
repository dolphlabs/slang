# smtp

> Package smtp.

Sending mail: an SMTP client (RFC 5321) with STARTTLS or implicit TLS and
AUTH PLAIN, and a MIME builder for text, HTML and attachments.

```slang
import "proc";
import "smtp";

let cfg = smtp.config("smtp.example.com", 587);      // STARTTLS on 587
cfg.username = "app@example.com";
cfg.password = proc.getenv("SMTP_PASSWORD") ?? "";
let m = smtp.message("App <app@example.com>", ["ada@example.com"], "Welcome");
m.text = "Hello Ada";
m.html = "<p>Hello <b>Ada</b></p>";
let r = smtp.send(cfg, m, deadline);
```

- `config(host, port)` uses STARTTLS, or implicit TLS on port 465. A
  server that does not offer STARTTLS is refused before any password is
  sent; `security: "none"` is for a local relay only.
- A `Message` has `from`, `to`, `cc`, `bcc` (sent to, never shown),
  `reply_to`, `subject`, `text`, `html`, `attachments` and extra
  `headers`. Text and HTML go in `multipart/alternative`, and
  attachments make it `multipart/mixed`. Parts are base64 in 76-column
  lines, and non-ASCII names and subjects use RFC 2047 encoded words.
- `build(m)` gives the message bytes, and `send_raw` sends prepared
  ones. Lines starting with `.` are dot-stuffed. A CR or LF in a header
  value is replaced, so a subject cannot add headers.

## API

### `struct Config`

### `fn config(host: str, port: int) -> Config`

### `struct Attachment`

### `struct Message`

### `fn message(from: str, to: [str], subject: str) -> Message`

### `fn send(cfg: Config, m: Message, deadline: until) -> result[bool, str]`

Sends m: one SMTP transaction to every recipient in to, cc and bcc.

### `fn build(m: Message) -> bytes`

The RFC 5322 message for m, with CRLF line endings: what send puts after DATA (before dot-stuffing).

### `fn send_raw(cfg: Config, from: str, rcpts: [str], data: bytes, deadline: until) -> result[bool, str]`

### `fn address_of(a: str) -> str`

The bare address of "Name <addr>" or "addr".

---

slang is built and maintained by **Dolphlabs** (Dolph Tech Limited) — https://dolphlabs.com
