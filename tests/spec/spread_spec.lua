--[[
Panels+
File: tests/spec/spread_spec.lua
Name: Spread rotation specs
Description: Verifies double-page spread detection, the viewer's per-panel rotation, and rendering and navigation of turned views.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Specs for `src/_spread.lua` and the viewer side of `auto_rotate_spreads`.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local Memory = require("src._memory")
local PanelCollector = require("src._panelcollector")
local PanelViewer = require("src._panelviewer")
local PanelViewport = require("src._panelviewport")
local Screen = require("device").screen
local Settings = require("src._settings")
local Spread = require("src._spread")
local UIManager = require("ui/uimanager")
local ViewerController = require("src.viewer_controller")

local PORTRAIT_PAGE = { w = 1113, h = 1600 }
local SPREAD_PAGE = { w = 2226, h = 1600 }

--- Controller stub whose document reports fixed page sizes.
---
--- @param pages table<integer, table|nil> Page number to `{w, h}`, or a page left out to report nothing.
--- @param settings table Partial settings, merged over the defaults.
local function controllerFor(pages, settings)
    local merged = Settings.withDefaults({})
    for key, value in pairs(settings or {}) do
        merged[key] = value
    end
    return setmetatable({
        settings = merged,
        ui = {
            document = {
                getNativePageDimensions = function(_, page)
                    return pages[page]
                end,
            },
        },
    }, { __index = ViewerController })
end

--- Stub bitmap with the methods the no-crop compositor calls.
---
--- @param tag string Label the specs use to tell renders apart.
local function bitmap(tag)
    return {
        tag = tag,
        getType = function()
            return 1
        end,
        getWidth = function()
            return 10
        end,
        getHeight = function()
            return 10
        end,
    }
end

--- Document stub that records render calls. `drawPagePart` is KOReader's
--- fit-to-screen render, `renderPage` a render at the caller's zoom.
---
--- @return table document Stub document.
--- @return table calls `{ draw = {...}, render = {...} }`, one entry per call.
local function renderingDocument()
    local calls = { draw = {}, render = {} }
    local document = {
        drawPagePart = function(_, page, rect)
            table.insert(calls.draw, { page = page, rect = rect })
            return bitmap("fitted upright"), false
        end,
        transformRect = function(_, rect, zoom)
            return { x = rect.x * zoom, y = rect.y * zoom, w = rect.w * zoom, h = rect.h * zoom }
        end,
        getPageDimensions = function()
            return { w = 1600, h = 1000 }
        end,
        renderPage = function(_, page, rect, zoom)
            table.insert(calls.render, { page = page, rect = rect, zoom = zoom })
            return { bb = bitmap("fitted turned") }
        end,
    }
    return document, calls
end

describe("Spread.rotationFor", function()
    it("leaves everything alone when the mode is off", function()
        assert.is_nil(Spread.rotationFor({
            mode = "off",
            page_w = SPREAD_PAGE.w,
            page_h = SPREAD_PAGE.h,
            screen_w = 1272,
            screen_h = 1696,
        }))
    end)

    it("turns a spread clockwise on a portrait screen", function()
        assert.equals(
            Spread.CLOCKWISE,
            Spread.rotationFor({
                mode = "cw",
                page_w = SPREAD_PAGE.w,
                page_h = SPREAD_PAGE.h,
                screen_w = 1272,
                screen_h = 1696,
            })
        )
    end)

    it("turns a spread counter-clockwise when asked", function()
        assert.equals(
            Spread.COUNTER_CLOCKWISE,
            Spread.rotationFor({
                mode = "ccw",
                page_w = SPREAD_PAGE.w,
                page_h = SPREAD_PAGE.h,
                screen_w = 1272,
                screen_h = 1696,
            })
        )
    end)

    it("ignores a normal portrait page", function()
        assert.is_nil(Spread.rotationFor({
            mode = "cw",
            page_w = PORTRAIT_PAGE.w,
            page_h = PORTRAIT_PAGE.h,
            screen_w = 1272,
            screen_h = 1696,
        }))
    end)

    it("leaves a spread alone on a screen that is already landscape", function()
        assert.is_nil(Spread.rotationFor({
            mode = "cw",
            page_w = SPREAD_PAGE.w,
            page_h = SPREAD_PAGE.h,
            screen_w = 1696,
            screen_h = 1272,
        }))
    end)

    it("treats a slightly wide page as a normal page", function()
        -- Scans are often padded a few percent wider than the artwork.
        assert.is_false(Spread.isSpread(1650, 1600, 1.2))
        assert.is_true(Spread.isSpread(2226, 1600, 1.2))
    end)

    it("refuses missing or degenerate page sizes", function()
        assert.is_false(Spread.isSpread(nil, 1600, 1.2))
        assert.is_false(Spread.isSpread(0, 1600, 1.2))
        assert.is_false(Spread.isSpread(2226, 0, 1.2))
    end)
end)

-- KOReader's screen rotation modes: 0 upright, 1 device turned clockwise,
-- 2 upside down, 3 device turned counter-clockwise. In mode 1 the page's top
-- is on the device's left edge (the Up key maps to Right). The viewer's 270
-- puts the top on the right edge, which is mode 3.
describe("Spread.deviceRotationFor", function()
    it("turns a spread's reading page the same way the viewer turns its image", function()
        assert.equals(3, Spread.deviceRotationFor({ mode = "cw", page_w = 2226, page_h = 1600, base_mode = 0 }))
        assert.equals(1, Spread.deviceRotationFor({ mode = "ccw", page_w = 2226, page_h = 1600, base_mode = 0 }))
    end)

    it("turns relative to a device held upside down", function()
        assert.equals(1, Spread.deviceRotationFor({ mode = "cw", page_w = 2226, page_h = 1600, base_mode = 2 }))
        assert.equals(3, Spread.deviceRotationFor({ mode = "ccw", page_w = 2226, page_h = 1600, base_mode = 2 }))
    end)

    it("has no opinion on a normal page, with the setting off, or on a screen already in landscape", function()
        assert.is_nil(Spread.deviceRotationFor({ mode = "cw", page_w = 1113, page_h = 1600, base_mode = 0 }))
        assert.is_nil(Spread.deviceRotationFor({ mode = "off", page_w = 2226, page_h = 1600, base_mode = 0 }))
        assert.is_nil(Spread.deviceRotationFor({ mode = "cw", page_w = 2226, page_h = 1600, base_mode = 1 }))
        assert.is_nil(Spread.deviceRotationFor({ mode = "cw", page_w = nil, page_h = nil, base_mode = 0 }))
    end)
end)

describe("Spread.panelRotation", function()
    it("turns the whole-page view of a spread and leaves its panels upright", function()
        assert.equals(270, Spread.panelRotation(nil, 270, true))
        assert.is_nil(Spread.panelRotation(nil, 270, false))
    end)

    it("applies a rotation chosen by hand to every panel", function()
        assert.equals(90, Spread.panelRotation(90, 270, true))
        assert.equals(90, Spread.panelRotation(90, 270, false))
        assert.equals(180, Spread.panelRotation(180, nil, false))
    end)

    it("keeps the picker's no rotation for panels inside a spread", function()
        assert.equals(270, Spread.panelRotation(false, 270, true))
        assert.is_false(Spread.panelRotation(false, 270, false))
        assert.is_false(Spread.panelRotation(false, nil, true))
    end)
end)

describe("Spread.isQuarterTurn", function()
    it("is true only for the two angles that swap a view's width and height", function()
        assert.is_true(Spread.isQuarterTurn(90))
        assert.is_true(Spread.isQuarterTurn(270))
        assert.is_false(Spread.isQuarterTurn(180))
        assert.is_false(Spread.isQuarterTurn(false))
        assert.is_false(Spread.isQuarterTurn(nil))
        -- `true` is ImageViewer's auto-rotation flag, not an angle.
        assert.is_false(Spread.isQuarterTurn(true))
    end)
end)

describe("ViewerController:resolveSpreadImageRotation", function()
    it("gives a spread page an angle and its neighbours none", function()
        Screen:setRotationMode(0)
        local controller = controllerFor({ [1] = PORTRAIT_PAGE, [2] = SPREAD_PAGE }, {
            auto_rotate_spreads = "cw",
        })

        assert.is_nil(controller:resolveSpreadImageRotation(1))
        assert.equals(Spread.CLOCKWISE, controller:resolveSpreadImageRotation(2))
    end)

    it("returns nothing while a hand rotation is set", function()
        Screen:setRotationMode(0)
        local controller = controllerFor({ [2] = SPREAD_PAGE }, {
            auto_rotate_spreads = "cw",
            image_rotation = 180,
        })

        assert.is_nil(controller:resolveSpreadImageRotation(2))
    end)

    it("still turns a spread when the picker's no rotation is saved", function()
        -- The picker cannot reset to nil, so `false` stays saved after any hand
        -- rotation is undone. It must not disable the setting.
        Screen:setRotationMode(0)
        local controller = controllerFor({ [2] = SPREAD_PAGE }, {
            auto_rotate_spreads = "cw",
            image_rotation = false,
        })

        assert.equals(Spread.CLOCKWISE, controller:resolveSpreadImageRotation(2))
    end)

    it("returns nothing when the document cannot report page dimensions", function()
        Screen:setRotationMode(0)
        local controller = controllerFor({}, { auto_rotate_spreads = "cw" })

        assert.is_nil(controller:resolveSpreadImageRotation(7))
    end)

    it("survives a document that has no getNativePageDimensions at all", function()
        Screen:setRotationMode(0)
        local controller = controllerFor({}, { auto_rotate_spreads = "cw" })
        controller.ui.document = {}

        assert.is_nil(controller:resolveSpreadImageRotation(1))
    end)

    it("is off by default", function()
        Screen:setRotationMode(0)
        local controller = controllerFor({ [2] = SPREAD_PAGE }, {})

        assert.is_nil(controller:resolveSpreadImageRotation(2))
    end)
end)

-- The mock screen is 600x800, so a 1600x800 part fits upright at 0.375 and
-- turned a quarter turn at 0.5.
local WIDE_PART = { x = 0, y = 100, w = 1600, h = 800 }

describe("PanelCollector.drawPart", function()
    it("renders a quarter-turned part at the zoom that fits the turned view", function()
        local document, calls = renderingDocument()

        local image = PanelCollector.drawPart(document, 2, WIDE_PART, 270)

        assert.equals(0, #calls.draw)
        assert.equals(1, #calls.render)
        assert.equals(2, calls.render[1].page)
        assert.equals(0.5, calls.render[1].zoom)
        assert.equals(800, calls.render[1].rect.scaled_rect.w)
        assert.equals("fitted turned", image.tag)
    end)

    it("leaves the caller's rectangle as it was", function()
        local document = renderingDocument()
        local part = { x = 0, y = 100, w = 1600, h = 800 }

        PanelCollector.drawPart(document, 2, part, 90)

        assert.is_nil(part.scaled_rect)
    end)

    it("leaves an upright or half-turned view to KOReader's own fit", function()
        for _, rotation in ipairs({ false, 180 }) do
            local document, calls = renderingDocument()

            local image = PanelCollector.drawPart(document, 2, WIDE_PART, rotation)

            assert.equals(1, #calls.draw)
            assert.equals(0, #calls.render)
            assert.equals("fitted upright", image.tag)
        end
        local document, calls = renderingDocument()
        PanelCollector.drawPart(document, 2, WIDE_PART, nil)
        assert.equals(1, #calls.draw)
    end)
end)

describe("PanelCollector.buildImages for a turned page", function()
    it("sizes a cropped panel for the turned view", function()
        local document, calls = renderingDocument()
        local images = PanelCollector.buildImages(
            { document = document },
            2,
            { WIDE_PART },
            Settings.withDefaults({}),
            270
        )

        local image = images[1]()

        assert.equals(0, #calls.draw)
        assert.equals(0.5, calls.render[1].zoom)
        assert.equals("fitted turned", image.tag)
    end)

    it("sizes only the whole-page view of a spread for the turned screen", function()
        local document, calls = renderingDocument()
        local whole_page = { x = 0, y = 0, w = 1600, h = 1000 }
        local images, _, full_page_flags = PanelCollector.buildImages(
            { document = document },
            2,
            { whole_page, WIDE_PART },
            Settings.withDefaults({}),
            nil,
            270
        )

        images[1]()
        images[2]()

        assert.is_true(full_page_flags[1])
        assert.is_false(full_page_flags[2])
        assert.equals(1, #calls.render)
        assert.equals(whole_page.h, calls.render[1].rect.h)
        assert.equals(1, #calls.draw)
        assert.equals(WIDE_PART, calls.draw[1].rect)
    end)

    it("keeps KOReader's own fit for a page shown upright", function()
        local document, calls = renderingDocument()
        local images = PanelCollector.buildImages({ document = document }, 2, { WIDE_PART }, Settings.withDefaults({}))

        images[1]()

        assert.equals(1, #calls.draw)
        assert.equals(0, #calls.render)
    end)

    it("builds the no-crop canvas in the turned screen's shape", function()
        local document = renderingDocument()
        local settings = Settings.withDefaults({})
        settings.crop_mode = "none"
        local images = PanelCollector.buildImages({ document = document }, 2, { WIDE_PART }, settings, 270)

        local canvas = images[1]()

        -- Turned a quarter turn, an 800x600 canvas fills the 600x800 screen.
        assert.equals(800, canvas.w)
        assert.equals(600, canvas.h)
    end)
end)

describe("PanelViewport.noCrop", function()
    it("fits a panel to the turned screen for a quarter-turned view", function()
        local viewport = PanelViewport.noCrop(WIDE_PART, { w = 1600, h = 1000 }, 270)

        assert.equals(0.5, viewport.scale)
    end)

    it("fits a panel to the screen as it stands otherwise", function()
        assert.equals(0.375, PanelViewport.noCrop(WIDE_PART, { w = 1600, h = 1000 }).scale)
        assert.equals(0.375, PanelViewport.noCrop(WIDE_PART, { w = 1600, h = 1000 }, 180).scale)
    end)
end)

describe("ViewerController renders a page for the angle it opens at", function()
    it("builds a spread's images for the same angles its viewer gets", function()
        Screen:setRotationMode(0)
        local old_build, old_new, old_show = PanelCollector.buildImages, PanelViewer.new, UIManager.show
        local built_for, opened_at = "not built", "not opened"
        local built_by_hand, opened_by_hand = "not built", "not opened"
        PanelCollector.buildImages = function(_, _, panels, _, rotation, spread_rotation)
            built_by_hand, built_for = rotation, spread_rotation
            return { {} }, panels, { true }
        end
        PanelViewer.new = function(_, options)
            opened_by_hand, opened_at = options.image_rotation, options.spread_image_rotation
            return {}
        end
        UIManager.show = function() end
        local controller = controllerFor({ [2] = SPREAD_PAGE }, { auto_rotate_spreads = "cw" })

        controller:showPanelViewerForPage(2, { WIDE_PART }, 1, { defer_preload = true })

        PanelCollector.buildImages, PanelViewer.new, UIManager.show = old_build, old_new, old_show
        assert.equals(Spread.CLOCKWISE, built_for)
        assert.equals(Spread.CLOCKWISE, opened_at)
        assert.is_nil(built_by_hand)
        assert.is_nil(opened_by_hand)
    end)

    it("reports no angle for a crossing that lands on a panel inside a spread", function()
        Screen:setRotationMode(0)
        local old_build = PanelCollector.buildImages
        PanelCollector.buildImages = function(_, _, panels)
            return { {} }, panels, { false }
        end
        local controller = controllerFor({ [2] = SPREAD_PAGE }, { auto_rotate_spreads = "cw" })
        controller.ui.document.getNextPage = function()
            return 2
        end
        controller.getCachedPanels = function()
            return { WIDE_PART }
        end

        local resolved = controller:resolveBoundaryTarget("next", { page = 1 })

        PanelCollector.buildImages = old_build
        assert.is_nil(resolved.target_image_rotation)
    end)

    it("builds the next page's images for the angle it will open at", function()
        Screen:setRotationMode(0)
        local old_build = PanelCollector.buildImages
        local built_for = "not built"
        PanelCollector.buildImages = function(_, _, panels, _, _, spread_rotation)
            built_for = spread_rotation
            return { {} }, panels, { true }
        end
        local controller = controllerFor({ [2] = SPREAD_PAGE }, { auto_rotate_spreads = "cw" })
        controller.ui.document.getNextPage = function()
            return 2
        end
        controller.getCachedPanels = function()
            return { WIDE_PART }
        end

        local resolved = controller:resolveBoundaryTarget("next", { page = 1 })

        PanelCollector.buildImages = old_build
        assert.equals(Spread.CLOCKWISE, built_for)
        assert.equals(Spread.CLOCKWISE, resolved.target_image_rotation)
    end)

    it("warms the render a turned view will ask for", function()
        local old_schedule = UIManager.scheduleIn
        UIManager.scheduleIn = function(_, _, action)
            action()
        end
        local document, calls = renderingDocument()
        local controller = setmetatable({
            settings = Settings.withDefaults({}),
            ui = { document = document },
            hasMemoryForPrerender = function()
                return true
            end,
        }, { __index = ViewerController })

        local viewer = PanelViewer:new({ page = 2, image_rects = { WIDE_PART, WIDE_PART }, image_rotation = 270 })

        controller:prerenderNextPanel(viewer, 1)

        UIManager.scheduleIn = old_schedule
        assert.equals(0, #calls.draw)
        assert.equals(0.5, calls.render[1] and calls.render[1].zoom)
    end)

    it("warms an upright render for a panel inside a spread", function()
        local old_schedule = UIManager.scheduleIn
        UIManager.scheduleIn = function(_, _, action)
            action()
        end
        local document, calls = renderingDocument()
        local controller = setmetatable({
            settings = Settings.withDefaults({}),
            ui = { document = document },
            hasMemoryForPrerender = function()
                return true
            end,
        }, { __index = ViewerController })
        local viewer = PanelViewer:new({
            page = 2,
            image_rects = { WIDE_PART, WIDE_PART, WIDE_PART },
            panel_is_full_page = { false, false, true },
            spread_image_rotation = 270,
        })

        controller:prerenderNextPanel(viewer, 1)
        controller:prerenderNextPanel(viewer, 2)

        UIManager.scheduleIn = old_schedule
        assert.equals(1, #calls.draw)
        assert.equals(1, #calls.render)
    end)
end)

describe("PanelViewer turns only the whole-page view of a spread", function()
    it("gives each panel its own angle", function()
        local viewer = PanelViewer:new({ spread_image_rotation = 270, panel_is_full_page = { true, false } })

        assert.equals(270, viewer:imageRotationFor(1))
        assert.is_nil(viewer:imageRotationFor(2))
    end)

    it("applies the angle of the panel it switches to", function()
        local images = {
            function()
                return {}
            end,
            function()
                return {}
            end,
        }
        local viewer = PanelViewer:new({
            spread_image_rotation = 270,
            panel_is_full_page = { false, true },
            _images_list = images,
            _images_list_cur = 1,
            _images_list_nb = 2,
        })
        viewer.requestPanelPrerender = function() end

        viewer:switchToImageNum(2)
        assert.equals(270, viewer.rotated)

        viewer:switchToImageNum(1)
        assert.is_true(not viewer.rotated)
    end)
end)

-- Smooth pans are computed for an upright bitmap, so a turned view cuts.
describe("PanelViewer smooth pans in a turned view", function()
    --- Smooth-mode viewer on page 2, showing the first of two panels.
    local function smoothViewer(options, document)
        options.nav_transition_mode = "smooth"
        options.nav_transition_cross_page = true
        local viewer = PanelViewer:new(options)
        viewer.rotated = options.image_rotation
        viewer.page = 2
        viewer.image_rects = { WIDE_PART, WIDE_PART }
        viewer._images_list_cur = 1
        viewer.reader_ui = { document = document }
        return viewer
    end

    it("swaps to the next panel at once instead of panning", function()
        -- The mocks report no free memory, which alone would cancel the pan.
        local old_headroom, old_allocation = Memory.hasHeadroom, Memory.hasAllocationHeadroom
        Memory.hasHeadroom = function()
            return true
        end
        Memory.hasAllocationHeadroom = function()
            return true
        end
        local document, calls = renderingDocument()
        local viewer = smoothViewer({ image_rotation = 270 }, document)
        local switched = spy()
        viewer.switchToImageNum = switched

        pcall(viewer.animateSwitchToImageNum, viewer, 2)

        Memory.hasHeadroom, Memory.hasAllocationHeadroom = old_headroom, old_allocation
        assert.equals(1, switched:callCount())
        assert.equals(2, switched:lastCall()[2])
        assert.equals(0, #calls.draw)
    end)

    it("swaps at once from an upright panel to the turned whole-spread view", function()
        local old_headroom, old_allocation = Memory.hasHeadroom, Memory.hasAllocationHeadroom
        Memory.hasHeadroom = function()
            return true
        end
        Memory.hasAllocationHeadroom = function()
            return true
        end
        local document, calls = renderingDocument()
        local viewer = smoothViewer({ spread_image_rotation = 270, panel_is_full_page = { false, true } }, document)
        local switched = spy()
        viewer.switchToImageNum = switched

        pcall(viewer.animateSwitchToImageNum, viewer, 2)

        Memory.hasHeadroom, Memory.hasAllocationHeadroom = old_headroom, old_allocation
        assert.equals(1, switched:callCount())
        assert.equals(0, #calls.draw)
    end)

    it("cuts across a page boundary between two pages turned the same way", function()
        local document, calls = renderingDocument()
        local boundary = spy()
        boundary.return_value = true
        local viewer = smoothViewer({
            image_rotation = 270,
            boundary_callback = boundary,
            nav_boundary_peek_callback = function()
                return { next_page = 3, start_idx = 1, target_rect = WIDE_PART, target_image_rotation = 270 }
            end,
        }, document)

        assert.is_true(viewer:animateBoundaryTransition("next"))

        assert.equals(1, boundary:callCount())
        assert.equals(0, #calls.draw)
    end)

    it("cuts across a page boundary from an upright page into a turned one", function()
        local document, calls = renderingDocument()
        local boundary = spy()
        boundary.return_value = true
        local viewer = smoothViewer({
            boundary_callback = boundary,
            nav_boundary_peek_callback = function()
                return { next_page = 3, start_idx = 1, target_rect = WIDE_PART, target_image_rotation = 270 }
            end,
        }, document)

        assert.is_true(viewer:animateBoundaryTransition("next"))

        assert.equals(1, boundary:callCount())
        assert.equals(0, #calls.draw)
    end)
end)

describe("More Panel Viewer Settings: auto-rotate spreads", function()
    --- Controller stub that saves the mode and records viewer rebuilds.
    local function menuController(pages, settings)
        local controller = controllerFor(pages, settings)
        controller.setAutoRotateSpreads = function(self, mode)
            self.settings.auto_rotate_spreads = mode
        end
        controller.rebuilt = spy()
        controller.showPanelViewerForPage = function(self, page, panels, start_idx, options)
            self.rebuilt(page, panels, start_idx, options)
            return { page = page, panels = panels, rebuilt = true }
        end
        return controller
    end

    local function spreadItem()
        for _, item in ipairs(UIManager._last_shown.item_table) do
            if item.text:find("Auto-rotate spreads", 1, true) then
                return item
            end
        end
    end

    it("lists the setting with its current mode", function()
        local controller = menuController({}, { auto_rotate_spreads = "cw" })

        controller:showMoreConfigMenu({ page = 1 })

        assert.equals("[Rotation]: Auto-rotate spreads (Actual: Clockwise)", spreadItem().text)
    end)

    it("steps through Off, Clockwise and Counter-clockwise", function()
        local controller = menuController({}, {})
        local seen = {}
        for _ = 1, 3 do
            controller:showMoreConfigMenu({ page = 1 })
            spreadItem().callback()
            table.insert(seen, controller.settings.auto_rotate_spreads)
        end

        assert.equals("cw,ccw,off", table.concat(seen, ","))
    end)

    it("reopens the viewer at the same panel when the change turns the page it shows", function()
        Screen:setRotationMode(0)
        local old_close = UIManager.close
        local closed = {}
        UIManager.close = function(_, widget)
            table.insert(closed, widget)
        end
        local controller = menuController({ [2] = SPREAD_PAGE }, {})
        local viewer = { page = 2, panels = { WIDE_PART, WIDE_PART }, _images_list_cur = 2 }

        controller:showMoreConfigMenu(viewer)
        spreadItem().callback()

        UIManager.close = old_close
        assert.equals(viewer, closed[#closed])
        assert.equals(1, controller.rebuilt:callCount())
        assert.equals(2, controller.rebuilt:lastCall()[1])
        assert.equals(2, controller.rebuilt:lastCall()[3])
        assert.is_true(controller.rebuilt:lastCall()[4].buttons_visible)
    end)

    it("leaves the viewer alone on a page the change does not turn", function()
        Screen:setRotationMode(0)
        local controller = menuController({ [1] = PORTRAIT_PAGE }, {})

        controller:showMoreConfigMenu({ page = 1, panels = { WIDE_PART } })
        spreadItem().callback()

        assert.equals(0, controller.rebuilt:callCount())
    end)

    it("is not offered for an embedded image", function()
        local controller = menuController({}, {})

        controller:showMoreConfigMenu({ embedded_source_image = {} })

        assert.is_nil(spreadItem())
    end)
end)
