# Credits and third-party notices

The Ops Toolbox scripts and these pages are released under the
[MIT License](https://github.com/greenblacked/ops-toolbox/blob/master/LICENSE).
The built site also ships software and assets written by others, listed here
with the licence each one states. Licence texts are quoted from the files that
carry them; where a file does not state a licence, this page says so instead
of guessing.

## Site generator and theme

| Component | Licence | Notes |
| --- | --- | --- |
| [Material for MkDocs](https://squidfunk.github.io/mkdocs-material/) 9.7.7 | MIT | Copyright (c) 2016-2025 Martin Donath. The theme templates, styles and scripts. |
| [MkDocs](https://www.mkdocs.org/) 1.6.1 | BSD-2-Clause | Copyright © 2014-present, Tom Christie. Builds the site. |

The build also uses `mkdocs-git-revision-date-localized-plugin` 1.6.0
(Tim Vink) and `mkdocs-material-extensions` 1.3.1 (Isaac Muse), both MIT
licensed. They run at build time and ship no code in the site.

## Scripts in the theme bundle

Material's `bundle.*.min.js` carries the notices of two libraries it
includes.

| Library | Licence | Notice in the file |
| --- | --- | --- |
| [clipboard.js](https://clipboardjs.com/) 2.0.11 | MIT | "Licensed MIT © Zeno Rocha". Powers the copy button on code blocks. |
| [escape-html](https://github.com/component/escape-html) | MIT | "Copyright(c) 2012-2013 TJ Holowaychuk, Copyright(c) 2015 Andreas Lubbe, Copyright(c) 2015 Tiancheng \"Timothy\" Gu, MIT Licensed". |

The other libraries in the bundle carry no notice in the built file, so none
is claimed here.

## Search

| Component | Licence | Notice in the file |
| --- | --- | --- |
| [lunr.js](https://lunrjs.com/) 2.3.9 | MIT | The search worker header reads "Copyright (C) 2020 Oliver Nightingale". The header names no licence; MIT is the licence of the lunr project. |
| [lunr-languages](https://github.com/MihaiValentin/lunr-languages) | See note | Headers read "Copyright 2014, Mihai Valentin" and link `http://www.mozilla.org/MPL/`. They are built on the Snowball JavaScript library, "Copyright 2010, Oleg Mazko". |
| TinySegmenter (Japanese tokenizer, `tinyseg.js`) | BSD | "(c) 2008 Taku Kudo", "freely distributable under the terms of a new BSD licence". |

Material copies the lunr language files into the site whether or not a page
loads them. The site is English only, so they are not used in a normal visit.
The `lunr-languages` licence is whatever the project publishes at the link
above; the file headers alone do not settle it.

## Fonts

The site is set in IBM Plex Sans and IBM Plex Mono, self-hosted from the
`@fontsource` packages version 5.3.0 under the SIL Open Font License 1.1.
Copyright 2019 IBM Corp. for Plex Sans and 2017 IBM Corp. for Plex Mono. All
rights reserved. The full licence texts:
[IBM Plex Sans](assets/fonts/OFL-IBM-Plex-Sans.txt) and
[IBM Plex Mono](assets/fonts/OFL-IBM-Plex-Mono.txt).

## Icons

| Set | Licence | Used for |
| --- | --- | --- |
| [Material Design Icons](https://pictogrammers.com/library/mdi/) (Pictogrammers) | Apache 2.0 | The theme's interface icons: search, menu, navigation arrows, edit and view buttons, and the light and dark toggle. |
| [Font Awesome Free](https://fontawesome.com/license/free) 7.1.0 | Icons CC BY 4.0, fonts SIL OFL 1.1, code MIT | The GitHub mark in the header and the footer. Copyright 2025 Fonticons, Inc. |
