local helpers = require("tests.helpers")

describe("codeview.tree", function()
  local tree

  ---Changed files of the tests.
  ---@type codeview.vcs.FileChange[]
  local files = {
    { path = "README.md", status = "modified" },
    { path = "lua/codeview/vcs/git.lua", status = "added" },
    { path = "lua/codeview/init.lua", status = "modified" },
    { path = "tests/a_spec.lua", status = "deleted" },
    { path = "Makefile", status = "renamed", old_path = "Make" },
  }

  ---Name and depth of every visible node.
  ---@param root codeview.tree.Node
  ---@return string[]
  local function outline(root)
    local out = {}
    for _, node in ipairs(tree.visible(root)) do
      out[#out + 1] = string.rep("  ", node.depth) .. node.name
    end
    return out
  end

  before_each(function()
    helpers.unload()
    tree = require("codeview.tree")
  end)

  after_each(function()
    helpers.unload()
  end)

  describe("build", function()
    it("nests the files under their directories", function()
      local root = tree.build(files)
      assert.are.same({
        "lua/codeview",
        "  vcs",
        "    git.lua",
        "  init.lua",
        "tests",
        "  a_spec.lua",
        "Makefile",
        "README.md",
      }, outline(root))
    end)

    it("reads a virtual node with a lower order first", function()
      local root = tree.build({
        { path = "v://b", virtual = true, label = "b", group = "Zeta", group_path = "v://zeta", order = 1 },
        { path = "v://a", virtual = true, label = "a", group = "Alpha", group_path = "v://alpha", order = 2 },
      })
      assert.are.equal("Zeta", root.children[1].name)
    end)

    it("keeps the virtual files of one group in the order of the list", function()
      local function commit(id)
        return { path = "v://" .. id, virtual = true, label = id, group = "Commits", group_path = "v://c", order = 2 }
      end
      local root = tree.build({ commit("zz newest"), commit("aa middle"), commit("mm oldest") })
      local names = vim.tbl_map(function(node)
        return node.name
      end, root.children[1].children)
      assert.are.same({ "zz newest", "aa middle", "mm oldest" }, names)
    end)

    it("collapses a chain of directories with one child", function()
      local root = tree.build({ { path = "lua/codeview/vcs/git.lua", status = "added" } })
      assert.are.equal(1, #root.children)
      local dir = root.children[1]
      assert.are.equal("lua/codeview/vcs", dir.name)
      assert.are.equal("lua/codeview/vcs", dir.path)
      assert.are.equal(0, dir.depth)
      assert.are.equal("git.lua", dir.children[1].name)
      assert.are.equal(1, dir.children[1].depth)
    end)

    it("sorts the directories before the files", function()
      local root = tree.build(files)
      local names = vim.tbl_map(function(node)
        return node.name
      end, root.children)
      assert.are.same({ "lua/codeview", "tests", "Makefile", "README.md" }, names)
    end)

    it("keeps the path and the position of every file", function()
      local root = tree.build(files)
      local file = tree.visible(root)[3]
      assert.are.equal("file", file.kind)
      assert.are.equal("lua/codeview/vcs/git.lua", file.path)
      assert.are.equal(2, file.index)
      assert.are.equal(files[2], file.file)
      assert.are.same({ "added" }, file.statuses)
    end)

    it("names the parent of every node", function()
      local root = tree.build(files)
      local dir = root.children[1]
      assert.are.equal(root, dir.parent)
      assert.are.equal(dir, dir.children[1].parent)
    end)

    it("collects the statuses of a directory", function()
      local root = tree.build(files)
      assert.are.same({ "added", "modified" }, root.children[1].statuses)
      assert.are.same({ "added" }, root.children[1].children[1].statuses)
      assert.are.same({ "deleted" }, root.children[2].statuses)
    end)

    it("counts the comments of every node", function()
      local root = tree.build(files, {
        comments = { ["lua/codeview/vcs/git.lua"] = 2, ["lua/codeview/init.lua"] = 1, ["README.md"] = 3 },
      })
      local lua = root.children[1]
      assert.are.equal(3, lua.comments)
      assert.are.equal(2, lua.children[1].comments)
      assert.are.equal(0, root.children[2].comments)
      assert.are.equal(0, root.children[2].children[1].comments)
      assert.are.equal(3, root.children[4].comments)
      assert.are.equal(6, root.comments)
    end)

    it("counts no comments without the option", function()
      tree.each(tree.build(files), function(node)
        assert.are.equal(0, node.comments)
      end)
    end)

    it("expands every directory by default", function()
      local root = tree.build(files)
      for _, node in ipairs(tree.dirs(root)) do
        assert.is_true(node.expanded)
      end
    end)

    it("reads the expanded state of the caller", function()
      local root = tree.build(files, { expanded = { ["lua/codeview"] = false } })
      assert.is_false(root.children[1].expanded)
      assert.is_true(root.children[2].expanded)
      assert.are.same({
        "lua/codeview",
        "tests",
        "  a_spec.lua",
        "Makefile",
        "README.md",
      }, outline(root))
    end)

    it("builds an empty tree from an empty list", function()
      local root = tree.build({})
      assert.are.equal(0, #root.children)
      assert.are.same({}, tree.visible(root))
      assert.are.same({}, tree.order({}))
    end)
  end)

  describe("walk", function()
    it("visits every node", function()
      local root = tree.build(files, { expanded = { ["lua/codeview"] = false } })
      local seen = 0
      tree.each(root, function()
        seen = seen + 1
      end)
      assert.are.equal(8, seen)
      assert.are.equal(5, #tree.visible(root))
    end)

    it("lists the directories", function()
      local paths = vim.tbl_map(function(node)
        return node.path
      end, tree.dirs(tree.build(files)))
      assert.are.same({ "lua/codeview", "lua/codeview/vcs", "tests" }, paths)
    end)

    it("orders the files as the sidebar shows them", function()
      assert.are.same({ 2, 3, 4, 5, 1 }, tree.order(files))
    end)

    it("keeps the files of a collapsed directory in the order", function()
      local collapsed = { expanded = { ["lua/codeview"] = false, tests = false } }
      assert.are.same({ 2, 3, 4, 5, 1 }, tree.order(files, collapsed))
    end)

    it("leaves out the files of a collapsed node to skip", function()
      local opts = { expanded = { tests = false }, skip = { "tests" } }
      assert.are.same({ 2, 3, 5, 1 }, tree.order(files, opts))
      -- An expanded node to skip keeps its files.
      assert.are.same({ 2, 3, 4, 5, 1 }, tree.order(files, { skip = { "tests" } }))
    end)
  end)
end)
