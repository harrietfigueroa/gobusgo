[
  import_deps: [:phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter, Quokka],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  quokka: [
    only: [
      :autosort,
      :blocks,
      :configs,
      :defs,
      :deprecations,
      :module_directives,
      :pipes,
      :single_node,
      :tests
    ],
    exclude: [],
    autosort: []
  ]
]
