- The documentation citation suite now checks in-page anchors. It read line
  numbers, relative link targets, `fn()` citations and package README
  coverage, and threw the fragment away on every link it resolved: replacing
  a real `](#winget_bootstrapps1)` in `windows/setup/README.md` with
  `](#this-anchor-does-not-exist)` left the whole suite green. Twenty
  documents now carry a Contents list built from generated slugs, and a
  renamed heading orphaned every link to it in silence, because a dead anchor
  renders as an ordinary link that scrolls nowhere rather than as a broken
  one. Each heading outside a fenced code block is slugged the way GitHub
  does it — deleting the punctuation instead of replacing it, and numbering a
  repeated heading — and a link to an anchor no heading generates now fails
  the suite by name. Like every other section here it has a floor: collecting
  no headings, or no links, is reported as the check having stopped checking
  rather than as a pass.
