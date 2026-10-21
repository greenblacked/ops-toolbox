# Site theme

[Ops Toolbox](../../../README.md) / **Site theme**

`rpt-theme.css` is one portable stylesheet: "report, preview, apply" for
Material for MkDocs. It holds every generic rule
(tokens, header, headings, navigation, code, stage pills, stage code titles,
stage admonitions, home hero and cards, 404 page, the controls the optional
page scripts add, print, reduced motion and forced colours) and nothing that
names a site. A site adds its own tweaks in a
second stylesheet loaded after it.

The idea: the tools it documents work in three stages, and each stage owns a
colour, so a reader sees what a command does before reading it.

| Stage | Colour | Meaning |
| --- | --- | --- |
| Report | blue | Read-only: reads state and changes nothing. |
| Preview | amber | Prints what would change (a dry run). |
| Apply | red | Changes things. |

Tested against Material for MkDocs 9.7, MkDocs 1.6 and PyMdown Extensions 12.

## Files to copy

| From | What it is |
| --- | --- |
| `docs/stylesheets/theme/rpt-theme.css` | The theme. |
| `docs/assets/fonts/` | The self-hosted IBM Plex woff2 files and their licence texts. The `@font-face` URLs in the theme are `../../assets/fonts/...`; change those five lines if the folder moves. The fonts folder has its own `README.md` (provenance and checksums). |
| `overrides/404.html` | The themed 404 page. It extends `main.html`. |
| `overrides/assets/javascripts/rpt-404.js` (optional) | Fills the 404 page's "Did you mean" block: the three pages of the site's search index that best match the words of the missing address, and a link that opens the search with those words. `404.html` loads it; without it the block stays hidden. |
| `overrides/main.html` | Adds the PNG favicon fallback, a typed SVG icon and the iOS icon, and loads the page scripts below. Copy it if you provide those three icon files (and point the hrefs at yours) or want the page scripts; otherwise drop it, and `404.html` then extends Material's own `main.html`. |
| `overrides/assets/javascripts/rpt-table-filter.js` (optional) | Adds a live filter box above every Markdown table of 15 or more rows. MkDocs publishes the folder at `assets/javascripts/`; `main.html` loads the file. Drop the file and its `<script>` line to go without. |
| `overrides/assets/javascripts/rpt-checklist.js` (optional) | Turns Markdown task lists into checklists that keep their ticks across a reload (per page, in the browser), with a progress line and a Reset button. Needs `pymdownx.tasklist` (below). |
| `docs/assets/images/` (optional) | A logo and favicons. Material needs `theme.logo` and `theme.favicon` pointing at your own. |

## mkdocs.yml

```yaml
theme:
  name: material
  font: false            # the fonts are self-hosted
  custom_dir: overrides
  palette:
    # Dark first: with no media-query entries every visitor starts in dark.
    - scheme: slate
      primary: custom
      accent: custom
      toggle: { icon: material/brightness-4, name: Switch to light mode }
    - scheme: default
      primary: custom
      accent: custom
      toggle: { icon: material/brightness-7, name: Switch to dark mode }
  features:
    - navigation.tabs
    - navigation.tabs.sticky   # the stage rule sits under the tabs
    - navigation.path          # breadcrumbs
    - navigation.sections
    - content.code.copy

extra_css:
  - stylesheets/theme/rpt-theme.css
  - stylesheets/extra.css      # optional: your own tweaks, loaded last

plugins:
  - search:
      # Split terms at _ / . [ ] ( ) and camelCase too, not only at spaces
      # and hyphens; dots inside version numbers are kept.
      separator: '[\s\-_,:!=\[\]()"/]+|(?!\b)(?=[A-Z][a-z])|\.(?!\d)|&[lg]t;'

markdown_extensions:
  - admonition
  - attr_list
  - md_in_html
  - pymdownx.details
  - pymdownx.superfences
  - pymdownx.highlight:
      anchor_linenums: true
  - pymdownx.tasklist:          # only for checklists
      custom_checkbox: true
      clickable_checkbox: true
```

`primary: custom` and `accent: custom` stop Material from applying a colour of
its own. The search separator is optional but suits documentation about
tools: Material's default splits only at spaces and hyphens, so a file name
such as `disk_cleanup.sh` or a flag such as `--dry-run` would be one search
term that only its full spelling finds.

Add this file and the fonts folder's README to `exclude_docs` so they are not
built as pages:

```yaml
exclude_docs: |
  stylesheets/theme/README.md
  assets/fonts/README.md
```

Both README files open with a breadcrumb link into this repository's own
README. Excluded files are not link-checked, so a copy builds under
`mkdocs build --strict` as it is. If you keep them as notes, replace the
breadcrumb line with your own or delete it.

## Brand tokens

All brand values are CSS custom properties in section 2 of the theme, once for
the light scheme (which is also the `:root` fallback) and once for the dark
scheme. Components read only these tokens. To re-brand, override them in your
own stylesheet or edit the block. Override with the same selectors the theme
uses. Material puts the scheme attribute on `<body>`, so a bare `:root`
override is shadowed in both schemes. Use
`:root, [data-md-color-scheme="default"]` for light and
`@media not print { [data-md-color-scheme="slate"] }` for dark, and load your
stylesheet after the theme.

```css
:root,
[data-md-color-scheme="default"] {
  --rpt-accent: #0b5fff;
}

@media not print {
  [data-md-color-scheme="slate"] {
    --rpt-accent: #7aa7ff;
  }
}
```

The smallest set (about ten per scheme):

| Token | Role |
| --- | --- |
| `--rpt-bg`, `--rpt-surface`, `--rpt-code-bg`, `--rpt-header-bg` | Page, panel, code and header surfaces |
| `--rpt-text`, `--rpt-muted` | Body and secondary text |
| `--rpt-report`, `--rpt-preview`, `--rpt-apply` | The three stage colours |
| `--rpt-accent` | Links, focus ring, active tab and nav bar |

Keep these in step with a change: `--rpt-*-text` (text-safe variant of a stage
colour), `--rpt-*-tint` (background of pills and titles), `--rpt-accent-hover`,
`--rpt-accent-tint` (the accent behind hovered buttons), `--rpt-accent-fill`,
`--rpt-on-accent`, `--rpt-border`, `--rpt-control-border` and the
`--rpt-syn-*` syntax colours. Three derived tokens are plain colours that
follow the brand, so retune them if it changes a lot: `--rpt-neutral-tint`
(from the muted colour), `--rpt-grid-line` (the faint home page grid, from the
text colour) and `--rpt-underline`. The underline follows `--rpt-accent`
automatically in browsers with `color-mix()`; the value in the tokens block is
only the fallback. `--rpt-font-sans`
and `--rpt-font-mono` set the typefaces. The contrast table at the top of the
theme gives the targets: 4.5:1 for text, 3:1 for control borders and other
non-text parts.

## Classes

| Class | Use |
| --- | --- |
| `.stage` with `.stage-report`, `.stage-preview` or `.stage-apply` | Inline stage pill. |
| `.rpt-report`, `.rpt-preview`, `.rpt-apply` | On a fenced code block: stage-coloured title bar and left edge. |
| `.rpt-hero`, `.rpt-title`, `.rpt-lede`, `.rpt-actions` | Home page hero: block, h1, lede paragraph, button row. |
| `.rpt-rule` | The decorative three-segment stage rule. Add `aria-hidden="true"`. |
| `.rpt-stages`, `.rpt-stage`, `.rpt-stage--report`, `.rpt-stage--preview`, `.rpt-stage--apply` | Three-stage strip and its cards. |
| `.grid.cards.cols-2` | Material's card grid in two columns from 40em (one column below). |
| `.rpt-404`, `.rpt-steps`, `.rpt-step--report`, `.rpt-step--preview`, `.rpt-step--apply` | The 404 page and its three steps. |
| `.rpt-404__suggest` | The 404 page's "Did you mean" block, hidden until `rpt-404.js` fills it. Already in `404.html`. |
| `.rpt-filter`, `.rpt-filter__count` | The filter box above a long table and its status line. Added by `rpt-table-filter.js`; you do not write them. |
| `.rpt-progress`, `.rpt-progress__status`, `.rpt-progress__reset` | The checklist progress line and its Reset button. Added by `rpt-checklist.js`. Task lists themselves (`.task-list-indicator`) are restyled without a class: the box reaches 3:1 at rest, takes the accent when ticked and shows the focus ring. |

The admonition kinds `report`, `preview` and `apply` need no class. Material's
`.grid.cards` cards are restyled without extra markup.

## Authoring patterns

Stage pills are inline HTML spans (wrap tables that use them in
`<!-- markdownlint-disable MD033 -->` and its matching enable comment if you
run markdownlint):

```html
<span class="stage stage-report">read-only</span>
<span class="stage stage-preview">dry run</span>
<span class="stage stage-apply">changes things</span>
```

Stage-titled code blocks use the attribute-list fence (it needs `attr_list`
and `pymdownx.superfences`; the first class is the language, and the extra
class lands on the block's wrapper):

````markdown
```{ .bash .rpt-report title="Report" }
./tool.sh
```
````

Use `.rpt-preview` and `.rpt-apply` for the other stages. A block with a
`title` and no stage class gets a neutral title bar.

Stage admonitions:

```markdown
!!! report "Read-only"
    This command reads state and changes nothing.

!!! preview "Dry run"
    This prints what would change.

!!! apply "Changes things"
    This writes to the system.
```

Hero and strip on the home page (the h1 stays outside the hero block, so a
Markdown linter that wants the file to start with a heading is satisfied):

````markdown
# Short promise. { .rpt-title }

<div class="rpt-hero" markdown>

<div class="rpt-rule" aria-hidden="true"></div>

<p class="rpt-lede">One or two sentences.</p>

<div class="rpt-actions" markdown>

[Get started](https://example.com/getting-started/){ .md-button .md-button--primary }
[Browse](https://example.com/reference/){ .md-button }

</div>

</div>

<div class="rpt-stages" markdown>

<div class="rpt-stage rpt-stage--report" markdown>
<span class="stage stage-report">1 · Report</span>

```{ .bash .rpt-report title="Report" }
./tool.sh
```

</div>

<!-- rpt-stage--preview and rpt-stage--apply cards follow -->

</div>
````

The strip shows three columns from 60em, two from 45em and one below. The
faint grid behind the hero appears in browsers that support `:has()`.

Long tables need nothing from the author. Any Markdown table with 15 or more
body rows gets a "Filter rows" box: a row stays visible when it contains
every word typed, in any case and order. A link can open the page already
filtered with a `filter` query parameter, `scripts/?filter=linux+doctor`
for example. Filtered rows are hidden, not removed, so a printout shows
them all.

Checklists are Markdown task lists. With `pymdownx.tasklist` and the script
in place, write the steps as

```markdown
- [ ] Read the report output
- [ ] Run the preview and read every line
- [x] A step that starts ticked
```

Each box is named after its step, clicking the step text ticks it, and a
"Checklist: 1 of 3 steps done" line with a Reset button appears above the
first list on the page. The ticks are stored in the reader's browser only
(`localStorage`, one entry per page path holding the step positions and the
first 60 characters of each ticked step's text). Editing a step forgets its
tick and inserting one forgets the ticks after it; neither moves a tick to
a different step. Without JavaScript the boxes still toggle but are not
kept.
