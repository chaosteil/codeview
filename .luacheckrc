-- luacheck configuration. Install luacheck with `luarocks install luacheck`.

std = "luajit"
cache = true
codes = true

exclude_files = {
  ".tests/",
}

-- `vim` is writable, because the tests replace fields such as `vim.notify`.
globals = {
  "vim",
}

ignore = {
  "212/_.*", -- unused argument with a leading underscore
  "631", -- line too long, stylua owns the width
}

files["tests/*.lua"] = {
  std = "+busted",
}
