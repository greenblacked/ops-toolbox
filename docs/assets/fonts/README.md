# Site fonts

[Ops Toolbox](../../../README.md) / **Site fonts**

The documentation site is set in IBM Plex, self-hosted so a visit makes no
request to a third-party font service. `theme.font` is `false` in
`mkdocs.yml`, and `docs/stylesheets/extra.css` declares the `@font-face` rules
(`font-display: swap`) and maps `--md-text-font` and `--md-code-font` onto them.

The files are the Latin subset woff2 files from the npm packages
`@fontsource/ibm-plex-sans` and `@fontsource/ibm-plex-mono`, both version
5.3.0, licensed under the SIL Open Font License 1.1. The license texts are
`OFL-IBM-Plex-Sans.txt` and `OFL-IBM-Plex-Mono.txt` in this folder.

| File | Package | SHA-256 |
| --- | --- | --- |
| `ibm-plex-sans-latin-400-normal.woff2` | `@fontsource/ibm-plex-sans@5.3.0` | `3b646991d30055a93a4ecc499713d4347953a74a947ecab435ab72070cbdab0e` |
| `ibm-plex-sans-latin-500-normal.woff2` | `@fontsource/ibm-plex-sans@5.3.0` | `0717336fb31fcdcde4b8deb3675bb4a0f7f6d484864afcd6751ac29975962203` |
| `ibm-plex-sans-latin-600-normal.woff2` | `@fontsource/ibm-plex-sans@5.3.0` | `8960851d691c054ed38e259bdcf1a6190d157b4203ed5bb32c632a863fb8ec2f` |
| `ibm-plex-mono-latin-400-normal.woff2` | `@fontsource/ibm-plex-mono@5.3.0` | `08949f728dc52d528e69b1667d15c89a5686a4ee9a296ff90983985f99c380f7` |
| `ibm-plex-mono-latin-500-normal.woff2` | `@fontsource/ibm-plex-mono@5.3.0` | `01d285447409c8a588692162439a038b8cbd7871309ee20267b0d2d91c6e8e22` |

## Updating

```bash
npm pack @fontsource/ibm-plex-sans@<version> @fontsource/ibm-plex-mono@<version>
```

Unpack both tarballs, copy the same five files from `package/files/`, copy each
package's `LICENSE` over the matching `OFL-*.txt`, then update the versions
and checksums above. Keep the set to these five files; each added weight is
another download on every first visit.

This README is excluded from the site (`exclude_docs` in `mkdocs.yml`).
