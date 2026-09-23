- `routeros_version.py record-hash` now refuses a body that does not open with
  a ZIP signature. The checks that stood between an error page and the CHR
  pin read only what the server said about the body — a `text/*` type and a
  size floor — so an `application/xml` error page from a CDN, or the wrong
  object, of any size above the floor would have been hashed and pinned as
  though it were the image. The type and a declared length below the floor are
  now judged from the headers before the body is read, so a mirror answering
  with a page no longer costs a download the size of the image on every
  attempt.
