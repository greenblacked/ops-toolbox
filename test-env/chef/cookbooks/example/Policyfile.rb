# frozen_string_literal: true

name             "example"
default_source   :supermarket
run_list         "example::default"
cookbook         "example", path: "."
