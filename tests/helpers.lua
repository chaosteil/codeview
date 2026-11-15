-- Shared helpers for the test suite.

local M = {}

---Absolute path of the repository root.
---@type string
M.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

---Drop the cached modules of the plugin, so that the next `require` reloads them.
function M.unload()
  for name, _ in pairs(package.loaded) do
    if name == "codeview" or name:match("^codeview%.") then
      package.loaded[name] = nil
    end
  end
end

---Reload the plugin with the default configuration.
---@return table codeview
function M.fresh()
  M.unload()
  return require("codeview")
end

---Run Lua code in a separate Neovim process with an empty configuration.
---
--- The process loads only this plugin. Startup plugins run, so the code sees
--- the same state as a user with a clean Neovim.
---@param lua string Lua code. Print the result to stdout.
---@param pre? string Lua code that runs before the startup plugins.
---@return vim.SystemCompleted
function M.clean_nvim(lua, pre)
  local cmd = {
    vim.v.progpath,
    "--headless",
    "-u",
    "NORC", -- NORC skips the user config but keeps 'loadplugins' on.
    "-i",
    "NONE",
    "--cmd",
    "set runtimepath^=" .. vim.fn.escape(M.root, " \\"),
  }
  if pre then
    vim.list_extend(cmd, { "--cmd", "lua " .. pre })
  end
  vim.list_extend(cmd, { "-c", "lua " .. lua, "-c", "quit" })
  local res = vim.system(cmd, { text = true }):wait(30000)
  -- A headless `print()` writes to stderr. Give the specs one text to match.
  res.output = (res.stdout or "") .. (res.stderr or "")
  return res
end

---True when the markdown filetype of Neovim starts the treesitter highlighter.
---
--- The markdown ftplugin of Neovim 0.12 starts it. On Neovim 0.11, the
--- configuration of the user starts it, for example nvim-treesitter. Without
--- it, the syntax file of Vim colors the markdown.
---@type boolean
M.markdown_treesitter = vim.fn.has("nvim-0.12") == 1

---Start the treesitter highlighter of a markdown buffer, as a user configuration does.
---
--- On Neovim 0.12 and later, the call does nothing. A spec then still finds
--- no highlighter when the filetype does not start it.
---@param buf integer
function M.start_markdown_treesitter(buf)
  if not M.markdown_treesitter then
    vim.treesitter.start(buf, "markdown")
  end
end

---Highlight captures at a position of a buffer, with the injected languages.
---
--- The treesitter highlighter parses only the rows that a window draws. A
--- headless test draws no row. Before Neovim 0.13,
--- `vim.treesitter.get_captures_at_pos()` then finds no capture of an
--- injected language, for example the code span of markdown. The call parses
--- the whole buffer with its injections first.
---@param buf integer
---@param row integer Row from 0.
---@param col integer Column from 0.
---@return table[] captures Empty when the buffer has no highlighter.
function M.captures_at(buf, row, col)
  local highlighter = vim.treesitter.highlighter.active[buf]
  if highlighter then
    highlighter.tree:parse(true)
  end
  return vim.treesitter.get_captures_at_pos(buf, row, col)
end

---Number of fake language servers of this test process.
---@type integer
local fake_count = 0

---@class tests.FakeLsp
---@field name string Name of the client.
---@field root string Root directory of the client.
---@field requests { method: string, params: table }[] Requests that the server got, oldest first.
---@field notifications { method: string, params: table }[] Notifications that the server got, oldest first.
---@field docs table<string, string> Text of each open document, by URI.
---@field handlers table<string, fun(params: table, server: tests.FakeLsp): any> Answer of each method.
---@field capabilities table Capabilities that the server reports.
---@field dispatchers table? Dispatchers of the client, after the start.
---@field group integer? Autocmd group of the attach.

---Language server in the test process.
---
--- `vim.lsp.start()` takes a function as `cmd`. The function gives the RPC
--- object, so the server needs no process. Each method in `handlers` gives
--- the result of a request. The server keeps the text of each document that
--- the client opens or changes.
---@param opts { root: string, handlers?: table<string, fun(params: table, server: tests.FakeLsp): any>, capabilities?: table, filetypes?: string[], name?: string }
---@return tests.FakeLsp
function M.fake_lsp(opts)
  -- Each server takes a name of its own. `vim.lsp.start()` reuses a client
  -- with the same name and root, also one of an earlier test that stops.
  fake_count = fake_count + 1
  ---@type tests.FakeLsp
  local server = {
    name = opts.name or ("codeview-fake-" .. fake_count),
    root = opts.root,
    requests = {},
    notifications = {},
    docs = {},
    handlers = opts.handlers or {},
    capabilities = opts.capabilities or {
      textDocumentSync = 1,
      definitionProvider = true,
      declarationProvider = true,
      typeDefinitionProvider = true,
      implementationProvider = true,
      referencesProvider = true,
      hoverProvider = true,
      renameProvider = true,
      codeActionProvider = true,
      executeCommandProvider = { commands = { "fake.command" } },
    },
  }

  local function cmd(dispatchers)
    server.dispatchers = dispatchers
    local closing = false
    local id = 0
    ---End the server. The client removes itself after the exit callback.
    ---@param signal integer
    local function stop(signal)
      if closing then
        return
      end
      closing = true
      vim.schedule(function()
        dispatchers.on_exit(0, signal)
      end)
    end
    return {
      request = function(method, params, callback, notify_reply)
        id = id + 1
        local request_id = id
        server.requests[#server.requests + 1] = { method = method, params = params }
        -- A handler can give an error as its second value. The client then
        -- gets the error and no result.
        local result, err
        if method == "initialize" then
          result = { capabilities = server.capabilities }
        elseif method == "shutdown" then
          result = vim.NIL
        elseif server.handlers[method] then
          result, err = server.handlers[method](params, server)
        end
        vim.schedule(function()
          callback(err, result)
          if notify_reply then
            notify_reply(request_id)
          end
        end)
        return true, request_id
      end,
      notify = function(method, params)
        server.notifications[#server.notifications + 1] = { method = method, params = params }
        if method == "textDocument/didOpen" then
          server.docs[params.textDocument.uri] = params.textDocument.text
        elseif method == "textDocument/didChange" then
          local changes = params.contentChanges
          server.docs[params.textDocument.uri] = changes[#changes].text
        elseif method == "textDocument/didClose" then
          server.docs[params.textDocument.uri] = nil
        elseif method == "exit" then
          stop(0)
        end
        return true
      end,
      is_closing = function()
        return closing
      end,
      terminate = function()
        stop(15)
      end,
    }
  end

  ---Start the client for one buffer.
  ---@param buf integer
  ---@return integer? client_id
  function server.start(buf)
    return vim.lsp.start({ name = server.name, cmd = cmd, root_dir = server.root }, { bufnr = buf })
  end

  ---Start the client for every buffer below the root that takes a filetype.
  ---
  --- This is what the configuration of a user does, for example with
  --- `vim.lsp.enable()`.
  function server.attach_on_filetype()
    server.group = vim.api.nvim_create_augroup("tests.fake_lsp." .. server.name, { clear = true })
    vim.api.nvim_create_autocmd("FileType", {
      group = server.group,
      pattern = opts.filetypes or { "lua" },
      callback = function(args)
        local name = vim.api.nvim_buf_get_name(args.buf)
        local real_root = vim.uv.fs_realpath(server.root) or server.root
        local real_name = vim.uv.fs_realpath(name) or name
        if vim.bo[args.buf].buftype == "" and vim.startswith(real_name, real_root) then
          server.start(args.buf)
        end
      end,
    })
  end

  ---Wait until a client of the server serves a buffer.
  ---@param buf integer
  ---@return boolean ready
  function server.wait(buf)
    return vim.wait(2000, function()
      for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf, name = server.name })) do
        if client.initialized then
          return true
        end
      end
      return false
    end, 10)
  end

  ---Requests of one method.
  ---@param method string
  ---@return table[] params
  function server.calls(method)
    local out = {}
    for _, request in ipairs(server.requests) do
      if request.method == method then
        out[#out + 1] = request.params
      end
    end
    return out
  end

  ---Send diagnostics of one file to the client.
  ---@param uri string
  ---@param diagnostics table[]
  function server.publish(uri, diagnostics)
    assert(server.dispatchers, "the server runs")
    server.dispatchers.notification("textDocument/publishDiagnostics", { uri = uri, diagnostics = diagnostics })
  end

  ---Stop the clients of the server and the attach.
  function server.stop()
    if server.group then
      pcall(vim.api.nvim_del_augroup_by_id, server.group)
      server.group = nil
    end
    for _, client in ipairs(vim.lsp.get_clients({ name = server.name })) do
      client:stop(true)
    end
    vim.wait(1000, function()
      return #vim.lsp.get_clients({ name = server.name }) == 0
    end, 10)
  end

  return server
end

return M
