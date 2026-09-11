- Link fragments into other documents are checked now, and four were dead.
  `test_doc_citations.sh` checked the path of a `](../other.md#section)` link
  and the fragment of a same-file one, but nothing checked a fragment that
  named another file. Three links spelled `#development--docker-checks` with
  the two hyphens of an older `&`-era title, long after the heading became
  `## Development: Docker checks`, and one pointed at `#testing-docker` where
  the root README says `## Testing`. A dead fragment renders as an ordinary
  link that scrolls nowhere, so reading never found them.
