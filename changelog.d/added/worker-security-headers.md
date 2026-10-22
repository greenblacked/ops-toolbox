- The documentation site sends a narrow Content-Security-Policy, a
  Permissions-Policy, Cross-Origin-Opener-Policy,
  X-Permitted-Cross-Domain-Policies and, over https, Strict-Transport-Security
  for its own host. The policy restricts only what the theme never does
  inline (base URLs, form targets, framing and plugins), so it blocks base-tag
  injection, form hijacking and clickjacking without touching Material's
  inline scripts and styles; the tests fail if a script or style directive is
  ever added. The three headers it sent before are unchanged.
