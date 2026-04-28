local PageMapper = require("hardcover/lib/page_mapper")

describe("PageMapper", function()
  local ui = function(page_map, use_page_map)
    use_page_map = use_page_map == nil and true or use_page_map

    return {
      document = {
        getPageMap = function()
          return page_map
        end
      },
      pagemap = {
        wantsPageLabels = function()
          return use_page_map
        end
      }
    }
  end

  describe("cachePageMap", function()
    it("does not translate page map when document has no page map", function()
      local map = nil
      local state = {}

      local page_map = PageMapper:new {
        state = state,
        ui = ui(map, false)
      }

      page_map:cachePageMap()
      assert.is_nil(state.page_map)
    end)

    it("create a table of raw page numbers to canonical book page integers", function()
      local map = {
        {
          page = 1,
          label = "i",
        },
        {
          page = 2,
          label = "ii",
        },
        {
          page = 3,
          label = "iii"
        },
        {
          page = 4,
          label = "2"
        }
      }

      local state = {}

      local page_map = PageMapper:new {
        state = state,
        ui = ui(map)
      }
      page_map:cachePageMap()
      local expected = {
        [1] = 1,
        [2] = 1,
        [3] = 1,
        [4] = 2
      }
      assert.are.same(expected, state.page_map)
    end)

    it("fills gaps in raw page numbers", function()
      local map = {
        {
          page = 1,
          label = "i",
        },
        {
          page = 3,
          label = "ii",
        },
        {
          page = 5,
          label = "4"
        }
      }

      local state = {}

      local page_map = PageMapper:new {
        state = state,
        ui = ui(map)
      }
      page_map:cachePageMap()
      local expected = {
        [1] = 1,
        [2] = 1,
        [3] = 1,
        [4] = 1,
        [5] = 4
      }
      assert.are.same(expected, state.page_map)
    end)

    it("maps multiple pages to canonical page integers", function()
      local map = {
        {
          page = 1,
          label = "1",
        },
        {
          page = 2,
          label = "1",
        },
        {
          page = 3,
          label = "2"
        }
      }

      local state = {}

      local page_map = PageMapper:new {
        state = state,
        ui = ui(map)
      }
      page_map:cachePageMap()
      local expected = {
        [1] = 1,
        [2] = 1,
        [3] = 2,
      }
      assert.are.same(expected, state.page_map)
    end)
  end)

  describe("getMappedPage", function()
    it("returns the page mapped page if available", function()
      local page_map = PageMapper:new {
        state = {
          page_map = {
            [1] = 99
          }
        },
        ui = ui({})
      }
      page_map.use_page_map = true

      assert.are.equal(page_map:getMappedPage(1, 100, 50), 99)
    end)

    it("translates local pages to canonical pages", function()
      local page_map = PageMapper:new {
        state = {},
        ui = ui({})
      }
      local current_page = 1
      local document_pages = 2
      local canonical_pages = 20

      local expected = 10

      assert.are.equal(expected, page_map:getMappedPage(current_page, document_pages, canonical_pages))
    end)

    describe("when local page exceeds mapped pages", function()
      it("it returns the edition last page", function()
        local page_map = PageMapper:new {
          state = {
            page_map = {},
            page_map_range = {
              last_page = 10,
            }
          },
          ui = ui({})
        }
        page_map.use_page_map = true

        assert.are.equal(page_map:getMappedPage(20, 100, 1000), 1000)
      end)

      describe("when edition page is not available", function()
        it("returns the cached last page", function()
          local page_map = PageMapper:new {
            state = {
              page_map = {},
              page_map_range = {
                last_page = 10,
                real_page = 500
              }
            },
            ui = ui({})
          }
          page_map.use_page_map = true

          assert.are.equal(page_map:getMappedPage(20, 100, nil), 500)
        end)
      end)
    end)
  end)

  describe("getUnmappedPage", function()
    describe("when there is a page map", function()
      it("finds the first matching page for a canonical page", function()
        local page_map = PageMapper:new {
          state = {
            page_map = {
              [1] = 1,
              [2] = 5,
              [3] = 5,
              [4] = 5,
              [5] = 8,
              [6] = 9,
              [7] = 10,
            }
          },
          ui = ui({})
        }
        page_map.use_page_map = true

        assert.are.equal(page_map:getUnmappedPage(5, 100, 100), 2)
      end)

      describe("when there is no exact match", function()
        it("returns the first page over the canonical page", function()
          local page_map = PageMapper:new {
            state = {
              page_map = {
                [1] = 1,
                [2] = 2,
                [3] = 5,
                [4] = 6,
                [5] = 7,
              }
            },
            ui = ui({})
          }
          page_map.use_page_map = true

          assert.are.equal(page_map:getUnmappedPage(3, 100, 100), 3)
        end)
      end)
    end)

    describe("when there is no page map", function()
      it("returns the page as a percentage of the total local pages", function()
        local page_map = PageMapper:new {
          state = {},
          ui = ui({})
        }

        assert.are.equal(page_map:getUnmappedPage(50, 1000, 100), 500)
      end)
    end)
  end)

  describe("getRemotePagePercent", function()
    it("returns the percent of the equivalent floored remote page", function()
      local page_map = PageMapper:new {
        state = {},
        ui = ui({}, false)
      }

      local percent, page = page_map:getRemotePagePercent(10, 20, 29)

      assert.are.equal(15 / 29, percent)
      assert.are.equal(15, page)
    end)

    it("returns a simple percentage if remote page is unavailable", function()
      local page_map = PageMapper:new {
        state = {},
        ui = ui({}, false)
      }

      local percent, page = page_map:getRemotePagePercent(10, 20)

      assert.are.equal(0.5, percent)
      assert.are.equal(10, page)
    end)
    describe("when there is a page map", function()
      local map = {
        {
          page = 20,
          label = "50",
        },
        {
          page = 30,
          label = "200"
        }
      }

      it("returns the percent of mapped page to remote page", function()
        local page_map = PageMapper:new {
          state = {},
          ui = ui(map)
        }

        local percent, page = page_map:getRemotePagePercent(20, 20, 100)

        assert.are.equal(0.25, percent)
        assert.are.equal(25, page)
      end)

      it("returns the percent of mapped page to document pages if no remote page available", function()
        local page_map = PageMapper:new {
          state = {},
          ui = ui(map)
        }

        local percent, page = page_map:getRemotePagePercent(20, 20)

        assert.are.equal(0.25, percent)
        assert.are.equal(50, page)
      end)
    end)
  end)
end)
