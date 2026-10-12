- The documentation site has its own look instead of stock Material. A flat
  graphite header carries a three-segment stage rule (report, preview, apply),
  the site name and tabs are set in mono, the active tab and sidebar item are
  marked in the accent colour, and code blocks are rounded terminal panels.
  Code blocks can take a stage-coloured title and there are `report`,
  `preview` and `apply` admonitions with their own icons. The home page gets a
  stage-led hero and a three-column stage strip, and a missing page shows a
  themed 404. Control borders now reach 3:1 contrast, small screens get 44px
  touch targets, breadcrumbs are on, and print, reduced-motion and
  forced-colours styles are added. The design is split into a portable theme
  (`docs/stylesheets/theme/`, with a README) that other documentation
  repositories can copy, and a small site stylesheet.
