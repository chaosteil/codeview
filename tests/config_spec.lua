local helpers = require("tests.helpers")

describe("codeview.config", function()
  local config

  before_each(function()
    helpers.unload()
    config = require("codeview.config")
  end)

  after_each(function()
    helpers.unload()
  end)

  it("starts with the defaults", function()
    assert.are.same(config.defaults, config.options)
  end)

  it("merges nested tables and keeps the other defaults", function()
    local cfg = assert(config.setup({ sidebar = { width = 60 } }))
    assert.are.equal(60, cfg.sidebar.width)
    assert.are.equal("left", cfg.sidebar.position)
    assert.are.equal(true, cfg.sidebar.auto_open)
    assert.are.equal("inline", cfg.diff.style)
  end)

  it("does not change the defaults table", function()
    config.setup({ sidebar = { width = 60 }, keymaps = { close = "<Esc>" } })
    assert.are.equal(40, config.defaults.sidebar.width)
    assert.are.equal("q", config.defaults.keymaps.close)
  end)

  it("stores the merged table in options", function()
    local cfg = assert(config.setup({ backend = "jj" }))
    assert.are.equal(cfg, config.get())
    assert.are.equal("jj", config.options.backend)
  end)

  it("resets to the defaults", function()
    config.setup({ backend = "git" })
    config.reset()
    assert.are.same(config.defaults, config.options)
  end)

  it("accepts false for a keymap", function()
    local cfg = assert(config.setup({ keymaps = { close = false } }))
    assert.is_false(cfg.keymaps.close)
  end)

  it("accepts a list of keys for one action", function()
    local cfg = assert(config.setup({ keymaps = { comment_insert = { "gc", "gC" } } }))
    assert.are.same({ "gc", "gC" }, cfg.keymaps.comment_insert)
    -- A list from the user replaces the default list. It does not merge into it.
    assert.are.same({ "I", "A", "c" }, cfg.keymaps.comment_visual)

    local short = assert(config.setup({ keymaps = { comment_insert = { "gc" } } }))
    assert.are.same({ "gc" }, short.keymaps.comment_insert)
  end)

  it("reads the keys of one action", function()
    assert.are.same({ "]f" }, config.keys("]f"))
    assert.are.same({ "i", "a" }, config.keys({ "i", "a" }))
    assert.are.same({}, config.keys(false))
    assert.are.same({}, config.keys(nil))
    assert.are.same({}, config.keys(""))
    assert.are.same({ "gc" }, config.keys({ "gc", "", 1 }))
  end)

  it("rejects a key that is not a string", function()
    local cfg, err = config.setup({ keymaps = { comment_insert = { 1 } } })
    assert.is_nil(cfg)
    assert.is_truthy(err:find("keymaps.comment_insert", 1, true), err)
  end)

  it("keeps the comment overview options apart from the sidebar options", function()
    local cfg = assert(config.setup({ overview = { width = 60, auto_open = true } }))
    assert.are.equal(60, cfg.overview.width)
    assert.are.equal("right", cfg.overview.position)
    assert.is_true(cfg.overview.auto_open)
    assert.are.equal(40, cfg.sidebar.width)
    assert.are.equal("left", cfg.sidebar.position)
  end)

  it("rejects an invalid overview option", function()
    local cfg, err = config.setup({ overview = { position = "top" } })
    assert.is_nil(cfg)
    assert.is_truthy(err:find("overview.position", 1, true), err)

    cfg, err = config.setup({ overview = { size = 10 } })
    assert.is_nil(cfg)
    assert.is_truthy(err:find("unknown option: overview.size", 1, true), err)
  end)

  it("holds a sign for each comment state", function()
    local cfg = assert(config.setup({}))
    assert.are.equal("▌", cfg.comments.sign)
    assert.are.equal("✓", cfg.comments.resolved_sign)
  end)

  it("accepts a template function", function()
    local fn = function()
      return "review"
    end
    local cfg = assert(config.setup({ export = { template = fn } }))
    assert.are.equal(fn, cfg.export.template)
  end)

  it("rejects an unknown top-level option", function()
    local cfg, err = config.setup({ colour = "red" })
    assert.is_nil(cfg)
    assert.is_truthy(err:find("unknown option: colour", 1, true), err)
  end)

  it("rejects an unknown nested option", function()
    local cfg, err = config.setup({ diff = { styles = "inline" } })
    assert.is_nil(cfg)
    assert.is_truthy(err:find("unknown option: diff.styles", 1, true), err)
  end)

  it("rejects a wrong type", function()
    local cfg, err = config.setup({ sidebar = { width = "wide" } })
    assert.is_nil(cfg)
    assert.is_truthy(err:find("sidebar.width", 1, true), err)
  end)

  it("rejects a value outside the enum", function()
    local cfg, err = config.setup({ backend = "hg" })
    assert.is_nil(cfg)
    assert.is_truthy(err:find("backend", 1, true), err)
  end)

  it("rejects a negative number", function()
    local cfg, err = config.setup({ diff = { context = -1 } })
    assert.is_nil(cfg)
    assert.is_truthy(err:find("diff.context", 1, true), err)
  end)

  it("rejects a non-table argument", function()
    for _, value in ipairs({ false, true, 5, "opts" }) do
      local cfg, err = config.setup(value)
      assert.is_nil(cfg)
      assert.is_truthy(err and err:find("expected table, got " .. type(value), 1, true), tostring(err))
    end
  end)

  it("keeps the previous options after an error", function()
    config.setup({ backend = "git" })
    config.setup({ backend = "hg" })
    assert.are.equal("git", config.get().backend)
  end)

  it("validates its own defaults", function()
    assert.is_nil(config.validate(config.defaults))
  end)

  it("builds one store directory per repository", function()
    config.setup({ comments = { dir = "/tmp/codeview-store" } })
    local dir = config.store_dir("/home/user/code/project")
    assert.are.equal(dir, config.store_dir("/home/user/code/project"))
    assert.are_not.equal(dir, config.store_dir("/home/user/code/other"))
    assert.is_truthy(dir:find("/tmp/codeview-store", 1, true), dir)
  end)

  it("separates roots with the same slug", function()
    config.setup({ comments = { dir = "/tmp/codeview-store" } })
    assert.are_not.equal(config.store_dir("/a/b.c"), config.store_dir("/a/b/c"))
    assert.are_not.equal(config.store_dir("/code/проект1"), config.store_dir("/code/项目1"))
  end)
end)
