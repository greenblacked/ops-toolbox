- `changelog.d/changelog.sh check` now reads the claims a fragment makes and
  not only the shape that would paste: a file named in backticks has to be in
  the tree, and a long flag standing alone in its span has to be one some
  script accepts — the scripts that entry names, or any script here when the
  entry names none. Two pull requests had shipped fragments for work nobody
  committed, one announcing an opt-in flag on
  `macos-initial-setup/v1_stay_fresh.sh` and one announcing two list flags on
  `macos-initial-setup/install_apps.sh`; both branches held nothing but the
  fragment, and both passed, because both would have pasted perfectly. A
  fragment was a promise nothing tested. The scoping is what makes it usable
  rather than noisy, and every form the fragments here already use stays
  quiet: a span with a space in it is a quoted command line, so the
  `brew --cache` and `apt-get --yes` they borrow belong to those tools and
  are not claims; an invocation such as `./x.sh` is prose about a usage line,
  not a file; runtime state like `last-run.json` is not a source file; and
  removal wording exempts the sentence it sits in, so an entry can still name
  what it deleted without exempting the next sentence with it. The check
  carries a canary through its own extractor, because one that quietly stops
  extracting reports a clean tree forever, and
  `test-env/static/test_changelog.sh` asserts each rejection alongside the
  true version of the same sentence.
