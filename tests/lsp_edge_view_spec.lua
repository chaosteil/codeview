-- Edge cases of the LSP view: the sides, the kinds of files, odd content, a
-- working copy that differs, and a review of files. See
-- `tests/lsp_edge_suite.lua`.

require("tests.lsp_edge_suite")({
  "sides and styles",
  "kinds of files",
  "odd content",
  "a working copy that differs from the review",
  "a review of files with no repository",
})
