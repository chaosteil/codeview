-- Edge cases of the LSP view: the diagnostics, the layouts with the option
-- on, races, and the quickfix list. See `tests/lsp_edge_suite.lua`.

require("tests.lsp_edge_suite")({
  "diagnostics",
  "the layouts with the option on",
  "races and the quickfix list",
})
