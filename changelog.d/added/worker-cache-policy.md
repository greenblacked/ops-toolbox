- The documentation site's Worker sets caching per file. Material's bundle,
  stylesheets and search worker carry a content hash in their names, so they
  are now cached for a year instead of being revalidated on every page view,
  which makes repeat visits and page changes faster. Fonts are cached for a
  week and images for a day. `version.txt`, which the deploy checks read to
  tell a new deploy from the old one, is marked never to be cached. Pages and
  the search index keep revalidating, so a deploy still shows at once, and a
  missing file is never cached.
