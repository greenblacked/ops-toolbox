- The documentation site's footer shows which commit it was built from,
  "Build 6a88b2e" linked to that commit, and stage's footer adds "Preview
  build", so a reader can tell stage from production and compare a page
  with their clone. It reads the `version.txt` every deploy already
  publishes, uses its content only when it is a full commit SHA, and stays
  empty when there is none, as under a local preview.
