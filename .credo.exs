%{
  configs: [
    %{
      name: "default",
      checks: %{
        enabled: [
          {Credo.Check.Readability.StrictModuleLayout, ignore: [:module_attribute]}
        ]
      }
    }
  ]
}
