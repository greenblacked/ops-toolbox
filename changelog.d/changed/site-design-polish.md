- The documentation site design is refined and split into a portable theme.
  The flat header carries a three-segment stage rule (report, preview,
  apply), and the site name, tabs and breadcrumbs are set in mono. Code
  blocks can take a stage-coloured title, and there are `report`, `preview`
  and `apply` admonitions with their own icons. The home page hero gets the
  stage rule and clearer buttons, and a missing page shows a themed 404.
  Control borders now reach 3:1 contrast, small screens get 44px touch
  targets, and print, reduced-motion and forced-colours styles are added. The
  design lives in a portable theme (`docs/stylesheets/theme/`, with a README)
  that other documentation repositories can copy, beside a small site
  stylesheet.
