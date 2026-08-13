local helpers = require("tests.helpers")

describe("codeview", function()
  after_each(function()
    helpers.unload()
  end)

  it("loads the plugin file at startup", function()
    assert.are.equal(1, vim.g.loaded_codeview)
  end)

  it("exposes the public API", function()
    local codeview = helpers.fresh()
    assert.are.equal("table", type(codeview))
    assert.are.equal("function", type(codeview.setup))
    assert.are.equal("function", type(codeview.config))
    assert.are.equal("function", type(codeview.open))
    assert.are.equal("function", type(codeview.pick))
    assert.are.equal("function", type(codeview.session))
    assert.are.equal("function", type(codeview.close))
    assert.are.equal("string", type(codeview.version))
  end)

  it("reports no session before the first open", function()
    local codeview = helpers.fresh()
    assert.is_nil(codeview.session())
    assert.is_false(codeview.close())
  end)

  it("accepts a table in setup()", function()
    local codeview = helpers.fresh()
    local cfg, err = codeview.setup({ diff = { style = "split" } })
    assert.is_nil(err)
    assert.are.equal("split", cfg.diff.style)
    assert.is_true(codeview.did_setup)
  end)

  it("accepts an empty setup() call", function()
    local codeview = helpers.fresh()
    local cfg, err = codeview.setup()
    assert.is_nil(err)
    assert.are.equal("inline", cfg.diff.style)
  end)

  it("works without a setup() call", function()
    local codeview = helpers.fresh()
    assert.is_false(codeview.did_setup)
    assert.are.equal("auto", codeview.config().backend)
    assert.are.equal(3, codeview.config().diff.context)
  end)

  it("reports invalid options and keeps the defaults", function()
    local codeview = helpers.fresh()
    local notified = {}
    local notify = vim.notify
    vim.notify = function(msg, level) ---@diagnostic disable-line: duplicate-set-field
      notified[#notified + 1] = { msg = msg, level = level }
    end
    local cfg, err = codeview.setup({ diff = { style = "diagonal" } })
    vim.notify = notify

    assert.is_nil(cfg)
    assert.is_truthy(err)
    assert.are.equal(1, #notified)
    assert.are.equal(vim.log.levels.ERROR, notified[1].level)
    assert.are.equal("inline", codeview.config().diff.style)
    assert.is_false(codeview.did_setup)
  end)

  it("loads in a clean Neovim", function()
    local res = helpers.clean_nvim(
      'print(vim.g.loaded_codeview, require("codeview").version, require("codeview").config().backend)'
    )
    assert.are.equal(0, res.code)
    assert.is_truthy(res.output:find("1", 1, true), res.output)
    assert.is_truthy(res.output:find("auto", 1, true), res.output)
  end)

  it("registers the commands in a clean Neovim", function()
    local res = helpers.clean_nvim(
      'print(vim.fn.exists(":CodeView"), vim.fn.exists(":CodeViewClose"), package.loaded["codeview.session"] == nil)'
    )
    assert.are.equal(0, res.code)
    assert.is_truthy(res.output:find("2 2 true", 1, true), res.output)
  end)

  it("reads options from vim.g.codeview", function()
    local res = helpers.clean_nvim(
      'print(require("codeview").config().sidebar.width, require("codeview").did_setup)',
      "vim.g.codeview = { sidebar = { width = 25 } }"
    )
    assert.are.equal(0, res.code)
    assert.is_truthy(res.output:find("25", 1, true), res.output)
    assert.is_truthy(res.output:find("true", 1, true), res.output)
  end)
end)
