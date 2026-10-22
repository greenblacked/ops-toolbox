- The documentation site answers `/robots.txt` and
  `/.well-known/security.txt` instead of a 404. Production's robots file
  points crawlers at the sitemap MkDocs already builds; stage's allows
  crawling but names no sitemap, so its noindex header keeps working. The
  security file (RFC 9116) points researchers at the private advisory form
  that `SECURITY.md` describes. The Worker writes them only when the site
  ships no file of that name, so a real file always wins.
