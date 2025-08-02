# we export florist's locals_without_parens here
locals_without_parens = [
  set: 2,
  target: 2,
  project_module: 1,
  project_name: 1
]

[
  locals_without_parens: locals_without_parens,
  export: [locals_without_parens: locals_without_parens],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]
]
