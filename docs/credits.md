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

## Libraries inside the theme bundles

Material's built files carry the code of several libraries. This list was
made from the source maps of the built site (`bundle.*.min.js.map`,
`main.*.min.css.map`, `palette.*.min.css.map` and the search worker map): every
`node_modules` package named in a map's `sources` is listed, and no other.
The maps ship with the site, so a reader can check the list against them.
Versions come from the package lock of Material 9.7.7. Licence and copyright
holder come from the file header where the map carries one, otherwise from the
package's entry in the npm registry.

| Library | Version | Licence | Copyright holder and source of the fact |
| --- | --- | --- | --- |
| [clipboard.js](https://clipboardjs.com/) | 2.0.11 | MIT | "Licensed MIT © Zeno Rocha", from the file header. Powers the copy button on code blocks. |
| [escape-html](https://github.com/component/escape-html) | 1.0.3 | MIT | "Copyright(c) 2012-2013 TJ Holowaychuk, Copyright(c) 2015 Andreas Lubbe, Copyright(c) 2015 Tiancheng \"Timothy\" Gu, MIT Licensed", from the file header. |
| [focus-visible](https://github.com/WICG/focus-visible) | 5.2.1 | W3C Software and Document License | The npm registry gives the licence as "W3C" and the author as WICG. The bundled file has no header. |
| [RxJS](https://rxjs.dev/) | 7.8.2 | Apache-2.0 | The npm registry gives the licence as Apache-2.0 and the author as Ben Lesh. The maps list its source files without a header. |
| [tslib](https://github.com/Microsoft/tslib) | 2.7.0 | 0BSD | "Copyright (c) Microsoft Corporation", from the file header. The npm registry also gives 0BSD. |
| [material-design-color](https://github.com/mrmlnc/material-color) | 2.3.2 | MIT | The npm registry gives the licence as MIT and the author as Denis Malinochkin. It is a build-time Sass source of colour values and appears only in the stylesheet map. |

lunr.js, the one library in the search worker map, is listed under Search
below.

## Search

| Component | Licence | Notice in the file |
| --- | --- | --- |
| [lunr.js](https://lunrjs.com/) 2.3.9 | MIT | The search worker header reads "Copyright (C) 2020 Oliver Nightingale" and "@license MIT". |
| [lunr-languages](https://github.com/MihaiValentin/lunr-languages) | See note | Headers read "Copyright 2014, Mihai Valentin" and link `http://www.mozilla.org/MPL/`. They are built on the Snowball JavaScript library, "Copyright 2010, Oleg Mazko". |
| TinySegmenter (Japanese tokenizer, `tinyseg.js`) | BSD | "(c) 2008 Taku Kudo", "freely distributable under the terms of a new BSD licence". |
| wordcut (Thai segmenter, `lunr/wordcut.js`) | MIT (bundled notices) | The file carries no notice for wordcut itself. It carries these bundled notices: Underscore.js 1.8.3, "(c) 2009-2015 Jeremy Ashkenas, DocumentCloud and Investigative Reporters & Editors", "freely distributed under the MIT license"; narwhal.js, "Copyright (c) 2009 Thomas Robinson"; and "Copyright Joyent, Inc. and other Node contributors", each followed by MIT permission text. |

Material copies the lunr language files, `tinyseg.js` and `wordcut.js` into
the site whether or not a page loads them. The site is English only, so they are not used in a normal visit.
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
