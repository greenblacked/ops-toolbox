# Site theme

[Ops Toolbox](../../../README.md) / **Site theme**

`rpt-theme.css` is the design of this site as one portable stylesheet:
"report, preview, apply" for Material for MkDocs. It holds every generic rule
(tokens, header, headings, navigation, code, stage pills, stage code titles,
stage admonitions, home hero and cards, 404 page, print, reduced motion and
forced colours) and nothing that names a site. A site adds its own tweaks in a
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
| `docs/assets/fonts/` | The self-hosted IBM Plex woff2 files and their licence texts. The `@font-face` URLs in the theme are `../../assets/fonts/...`; change those six lines if the folder moves. |
| `overrides/404.html` | The themed 404 page. It extends `main.html`. |
| `overrides/main.html` | Adds the PNG favicon fallback, a typed SVG icon and the iOS icon. Keep only the `extrahead` block if you have no such files, or drop the file (the 404 page extends Material's own `main.html` then). |
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

markdown_extensions:
  - admonition
  - attr_list
  - md_in_html
  - pymdownx.details
  - pymdownx.superfences
  - pymdownx.highlight:
      anchor_linenums: true
```

`primary: custom` and `accent: custom` stop Material from applying a colour of
its own. Add `stylesheets/theme/README.md` to `exclude_docs` so this file is
not built as a page.

## Brand tokens

All brand values are CSS custom properties in section 2 of the theme, once for
the light scheme (which is also the `:root` fallback) and once for the dark
scheme. Components read only these tokens. To re-brand, override them in your
own stylesheet or edit the block. The smallest set (about ten per scheme):

| Token | Role |
| --- | --- |
| `--rpt-bg`, `--rpt-surface`, `--rpt-code-bg`, `--rpt-header-bg` | Page, panel, code and header surfaces |
| `--rpt-text`, `--rpt-muted` | Body and secondary text |
| `--rpt-report`, `--rpt-preview`, `--rpt-apply` | The three stage colours |
| `--rpt-accent` | Links, focus ring, active tab and nav bar |

Keep these in step with a change: `--rpt-*-text` (text-safe variant of a stage
colour), `--rpt-*-tint` (background of pills and titles), `--rpt-accent-hover`,
`--rpt-accent-fill`, `--rpt-on-accent`, `--rpt-border`,
`--rpt-control-border` and the `--rpt-syn-*` syntax colours. `--rpt-font-sans`
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
| `.rpt-404`, `.rpt-steps`, `.rpt-step--report`, `.rpt-step--preview`, `.rpt-step--apply` | The 404 page and its three steps. |

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

[Get started](getting-started.md){ .md-button .md-button--primary }
[Browse](reference.md){ .md-button }

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
