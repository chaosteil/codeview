local helpers = require("tests.helpers")

local api = vim.api

---Press a key in the current window.
---@param lhs string
local function press(lhs)
  api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, false, true), "x", false)
end

---Extmarks of one line, with their details.
---@param buf integer
---@param ns integer
---@param lnum integer Line, from 1.
---@return table[] marks
local function marks_of(buf, ns, lnum)
  return api.nvim_buf_get_extmarks(buf, ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })
end

---Report whether an autocmd group exists.
---@param name string
---@return boolean
local function group_exists(name)
  return (pcall(api.nvim_get_autocmds, { group = name }))
end

describe("codeview.panel", function()
  local panel
  ---@type codeview.Panel[]
  local made = {}

  ---Build a panel and close it after the test.
  ---@param opts table
  ---@return codeview.Panel
  local function new(opts)
    local built = panel.new(opts)
    made[#made + 1] = built
    return built
  end

  ---A panel with three lines: a title and two entries.
  ---@param opts? table
  ---@return codeview.Panel
  local function demo(opts)
    return new(vim.tbl_extend("force", {
      title = "demo",
      width = 30,
      render = function()
        return {
          { text = "title", hl = "Title" },
          { text = "  one", marks = { { hl = "Comment", from = 2, to = 5 } }, data = { index = 1 } },
          { text = "  two", data = { index = 2 } },
        }
      end,
    }, opts or {}))
  end

  before_each(function()
    helpers.unload()
    panel = require("codeview.panel")
  end)

  after_each(function()
    for _, built in ipairs(made) do
      pcall(built.close, built)
    end
    made = {}
    helpers.unload()
  end)

  describe("new", function()
    it("keeps the options of the caller", function()
      local built = new({
        title = "list",
        width = 25,
        position = "right",
        filetype = "codeview-list",
        render = function()
          return {}
        end,
      })
      assert.are.equal("list", built.title)
      assert.are.equal(25, built.width)
      assert.are.equal("right", built.position)
      assert.are.equal("codeview-list", built.filetype)
      assert.is_false(built:is_open())
    end)

    it("falls back to the left side and a width of 40", function()
      local built = new({
        title = "list",
        render = function()
          return {}
        end,
      })
      assert.are.equal("left", built.position)
      assert.are.equal(40, built.width)
      assert.are.equal("codeview", built.filetype)
    end)

    it("rejects a panel without a render function", function()
      assert.is_false(pcall(panel.new, { title = "list" }))
    end)
  end)

  describe("open", function()
    it("opens a split with the width of the panel", function()
      local built = demo()
      local win = built:open()
      assert.is_true(built:is_open())
      assert.are.equal(win, built:window())
      assert.are.equal(30, api.nvim_win_get_width(win))
      assert.are.equal(0, api.nvim_win_get_position(win)[2])
    end)

    it("opens on the right side", function()
      local win = demo({ position = "right" }):open()
      assert.is_true(api.nvim_win_get_position(win)[2] > 0)
    end)

    it("keeps the cursor outside the panel by default", function()
      local before = api.nvim_get_current_win()
      local built = demo()
      built:open()
      assert.are.equal(before, api.nvim_get_current_win())

      built:open({ focus = true })
      assert.are.equal(built:window(), api.nvim_get_current_win())
      api.nvim_set_current_win(before)
    end)

    it("sets the buffer options", function()
      local built = demo({ filetype = "codeview-demo" })
      built:open()
      local buf = assert(built:buffer())
      assert.are.equal("nofile", vim.bo[buf].buftype)
      assert.are.equal("codeview-demo", vim.bo[buf].filetype)
      assert.is_false(vim.bo[buf].modifiable)
      assert.is_false(vim.bo[buf].buflisted)
      assert.is_false(vim.bo[buf].swapfile)
    end)

    it("sets the window options", function()
      local built = demo()
      local win = built:open()
      assert.is_true(vim.wo[win][0].winfixwidth)
      assert.is_false(vim.wo[win][0].number)
      assert.is_false(vim.wo[win][0].wrap)
      assert.is_true(vim.wo[win][0].cursorline)
      assert.are.equal("no", vim.wo[win][0].signcolumn)
    end)

    it("marks the window as a panel window", function()
      local built = demo()
      local win = built:open()
      assert.is_true(panel.is_panel_win(win))
      assert.is_false(panel.is_panel_win(api.nvim_get_current_win()))
    end)

    it("renders again on a second open", function()
      local built = demo()
      local first = built:open()
      assert.are.equal(first, built:open())
    end)
  end)

  describe("render", function()
    it("writes the text of every line", function()
      local built = demo()
      built:open()
      assert.are.same({ "title", "  one", "  two" }, api.nvim_buf_get_lines(assert(built:buffer()), 0, -1, false))
      assert.are.same({ "title", "  one", "  two" }, built:lines())
      assert.are.equal(3, built:line_count())
    end)

    it("writes a highlight for the whole line", function()
      local built = demo()
      built:open()
      local found = marks_of(assert(built:buffer()), panel.ns, 1)
      assert.are.equal(1, #found)
      assert.are.equal("Title", found[1][4].line_hl_group)
    end)

    it("writes a highlight for a part of a line", function()
      local built = demo()
      built:open()
      local found = marks_of(assert(built:buffer()), panel.ns, 2)
      assert.are.equal(1, #found)
      assert.are.equal("Comment", found[1][4].hl_group)
      assert.are.equal(2, found[1][3])
      assert.are.equal(5, found[1][4].end_col)
    end)

    it("drops the marks of the last render", function()
      local lines = { { text = "one", hl = "Title" } }
      local built = new({
        title = "demo",
        render = function()
          return lines
        end,
      })
      built:open()
      lines = { { text = "one" } }
      built:render()
      assert.are.equal(0, #marks_of(assert(built:buffer()), panel.ns, 1))
    end)

    it("keeps the buffer unmodifiable", function()
      local built = demo()
      built:open()
      local buf = assert(built:buffer())
      assert.is_false(vim.bo[buf].modifiable)
      assert.is_false(vim.bo[buf].modified)
    end)

    it("keeps a line break inside a line on one line", function()
      local built = new({
        title = "demo",
        render = function()
          return { { text = "we\nird.txt M", marks = { { hl = "Comment", from = 0, to = 12 } } } }
        end,
      })
      built:open()
      local buf = assert(built:buffer())
      assert.are.same({ "we ird.txt M" }, api.nvim_buf_get_lines(buf, 0, -1, false))
      assert.are.same({ "we ird.txt M" }, built:lines())
      assert.is_false(vim.bo[buf].modifiable)
      assert.are.equal("Comment", marks_of(buf, panel.ns, 1)[1][4].hl_group)
    end)

    it("does nothing while the panel is closed", function()
      assert.is_false(demo():render())
    end)
  end)

  describe("lines and data", function()
    it("reads the data of a line", function()
      local built = demo()
      built:open()
      assert.is_nil(built:data(1))
      assert.are.equal(1, built:data(2).index)
      assert.is_nil(built:data(99))
    end)

    it("reads the data under the cursor", function()
      local built = demo()
      built:open()
      built:set_cursor(3)
      local data, lnum = built:cursor_data()
      assert.are.equal(2, data.index)
      assert.are.equal(3, lnum)
    end)

    it("finds the line of a value", function()
      local built = demo()
      built:open()
      assert.are.equal(
        3,
        built:find(function(data)
          return data.index == 2
        end)
      )
      assert.is_nil(built:find(function()
        return false
      end))
    end)

    it("clamps the cursor to the content", function()
      local built = demo()
      built:open()
      built:set_cursor(99)
      assert.are.equal(3, api.nvim_win_get_cursor(built:window())[1])
    end)
  end)

  describe("keymaps", function()
    it("runs an action of the keymap table", function()
      local seen = 0
      local built = demo({
        keymaps = {
          ["<CR>"] = function(p)
            seen = seen + 1
            assert.are.equal("demo", p.title)
          end,
          q = false,
        },
      })
      built:open({ focus = true })
      press("<CR>")
      assert.are.equal(1, seen)
      assert.are.equal(0, #vim.tbl_filter(function(map)
        return map.lhs == "q"
      end, api.nvim_buf_get_keymap(assert(built:buffer()), "n")))
    end)
  end)

  describe("close", function()
    it("closes the window and deletes the buffer", function()
      local built = demo()
      local win = built:open()
      local buf = assert(built:buffer())

      assert.is_true(built:close())
      assert.is_false(built:is_open())
      assert.is_false(api.nvim_win_is_valid(win))
      assert.is_false(api.nvim_buf_is_valid(buf))
      assert.is_nil(built:buffer())
      assert.is_nil(built:window())
    end)

    it("deletes the autocmd group", function()
      local built = demo()
      built:open()
      local group = "codeview.panel." .. built.id
      assert.is_true(group_exists(group))
      built:close()
      assert.is_false(group_exists(group))
    end)

    it("closes only once", function()
      local built = demo()
      built:open()
      assert.is_true(built:close())
      assert.is_false(built:close())
    end)

    it("runs the close handler", function()
      local seen = 0
      local built = demo({
        on_close = function()
          seen = seen + 1
        end,
      })
      built:open()
      built:close()
      built:close()
      assert.are.equal(1, seen)
    end)

    it("follows a window that the user closes", function()
      local built = demo()
      local win = built:open()
      local buf = assert(built:buffer())
      api.nvim_win_close(win, true)

      assert.is_false(built:is_open())
      assert.is_false(api.nvim_buf_is_valid(buf))
      assert.is_false(group_exists("codeview.panel." .. built.id))
    end)

    it("follows a buffer that another call deletes", function()
      local built = demo()
      local win = built:open()
      api.nvim_buf_delete(assert(built:buffer()), { force = true })

      assert.is_false(built:is_open())
      assert.is_false(api.nvim_win_is_valid(win))
      assert.is_false(group_exists("codeview.panel." .. built.id))
    end)

    it("opens again after a close", function()
      local built = demo()
      built:open()
      built:close()
      local win = built:open()
      assert.is_true(built:is_open())
      assert.are.same({ "title", "  one", "  two" }, api.nvim_buf_get_lines(assert(built:buffer()), 0, -1, false))
      assert.is_true(panel.is_panel_win(win))
    end)
  end)

  describe("toggle", function()
    it("opens and closes the panel", function()
      local built = demo()
      assert.is_true(built:toggle())
      assert.is_true(built:is_open())
      assert.is_false(built:toggle())
      assert.is_false(built:is_open())
    end)
  end)

  it("leaves no windows behind", function()
    assert.are.equal(1, #api.nvim_tabpage_list_wins(0))
  end)
end)
