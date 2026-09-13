# Used by "mix format"
[
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  # Slipstream's assert_* and connect_* macros read as assertions, not calls.
  import_deps: [:slipstream]
]
