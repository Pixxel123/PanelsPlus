--[[
Panels+
File: tests/spec/spread_rotation_spec.lua
Name: Spread reading-page rotation specs
Description: Verifies screen rotation for double-page spreads on the reading page and the hand-over to the panel viewer.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Specs for `src/spread_rotation.lua`.

local framework = require("tests.PanelsPlusTestFramework")
local describe, it, assert, spy = framework.describe, framework.it, framework.assert, framework.spy

local PanelCollector = require("src._panelcollector")
local PanelViewer = require("src._panelviewer")
local Screen = require("device").screen
local Settings = require("src._settings")
local SpreadRotation = require("src.spread_rotation")
local UIManager = require("ui/uimanager")
local ViewerController = require("src.viewer_controller")

local PORTRAIT_PAGE = { w = 1050, h = 1522 }
local SPREAD_PAGE = { w = 1692, h = 1200 }

--- Plugin stub whose `SetRotationMode` broadcasts rotate the mock screen.
---
--- @param pages table<integer, table> Page number to `{w, h}`.
--- @param settings table|nil Partial settings, merged over the defaults.
--- @param start_mode integer|nil Screen rotation mode to start in.
--- @return table reader Plugin stub with the spread-rotation methods mixed in.
--- @return integer[] turns Every rotation mode the reader asked for, in order.
local function readerFor(pages, settings, start_mode)
    Screen:setRotationMode(start_mode or 0)
    local merged = Settings.withDefaults({})
    for key, value in pairs(settings or { auto_rotate_spreads = "cw" }) do
        merged[key] = value
    end
    local turns = {}
    local reader
    reader = setmetatable({
        settings = merged,
        saved = spy(),
        spread_rotation_ready = true,
        ui = {
            paging = { current_page = 1 },
            document = {
                getNativePageDimensions = function(_, page)
                    return pages[page]
                end,
                getPageDimensions = function(_, page)
                    return pages[page]
                end,
            },
        },
        isEnabled = function()
            return true
        end,
    }, {
        __index = function(_, key)
            return SpreadRotation[key] or ViewerController[key]
        end,
    })
    reader.ui.doc_settings = {
        saveSetting = function(_, key, value)
            reader.saved(key, value)
        end,
    }
    UIManager.broadcastEvent = function(_, event)
        if event.name == "SetRotationMode" then
            table.insert(turns, event.args[1])
            Screen:setRotationMode(event.args[1])
            -- ReaderUI passes the event on to the plugin as well.
            reader:onSetRotationMode(event.args[1])
        end
    end
    return reader, turns
end

--- Simulate the user picking a rotation in KOReader's menu.
local function userTurnsScreen(reader, mode)
    Screen:setRotationMode(mode)
    reader:onSetRotationMode(mode)
end

local PAGES = { [1] = PORTRAIT_PAGE, [2] = SPREAD_PAGE, [3] = SPREAD_PAGE, [4] = PORTRAIT_PAGE }
local WHOLE_SPREAD = { x = 0, y = 0, w = SPREAD_PAGE.w, h = SPREAD_PAGE.h }
local INNER_PANEL = { x = 40, y = 40, w = 600, h = 500 }

describe("SpreadRotation on the reading page", function()
    it("turns the screen when the reader lands on a spread", function()
        local reader, turns = readerFor(PAGES)

        reader:onPageUpdate(2)

        assert.equals(3, Screen:getRotationMode())
        assert.equals(1, #turns)
    end)

    it("turns the screen back on the next normal page", function()
        local reader, turns = readerFor(PAGES)

        reader:onPageUpdate(3)
        reader:onPageUpdate(4)

        assert.equals(0, Screen:getRotationMode())
        assert.equals("3,0", table.concat(turns, ","))
    end)

    it("stays turned from one spread to the next", function()
        local reader, turns = readerFor(PAGES)

        reader:onPageUpdate(2)
        reader:onPageUpdate(3)

        assert.equals(3, Screen:getRotationMode())
        assert.equals(1, #turns)
    end)

    it("restores the rotation the reader was in", function()
        local reader = readerFor(PAGES, nil, 2)

        reader:onPageUpdate(2)
        assert.equals(1, Screen:getRotationMode())
        reader:onPageUpdate(4)

        assert.equals(2, Screen:getRotationMode())
    end)

    it("leaves a landscape screen alone", function()
        local reader, turns = readerFor(PAGES, nil, 1)

        reader:onPageUpdate(2)
        reader:onPageUpdate(4)

        assert.equals(1, Screen:getRotationMode())
        assert.equals(0, #turns)
    end)

    it("does nothing while the setting is off", function()
        local reader, turns = readerFor(PAGES, { auto_rotate_spreads = "off" })

        reader:onPageUpdate(2)

        assert.equals(0, #turns)
    end)

    it("does nothing while Panels+ is disabled", function()
        local reader, turns = readerFor(PAGES)
        reader.isEnabled = function()
            return false
        end

        reader:onPageUpdate(2)

        assert.equals(0, #turns)
    end)

    it("does nothing in a reflowable document", function()
        local reader, turns = readerFor(PAGES)
        reader.ui.paging = nil

        reader:onPageUpdate(2)

        assert.equals(0, #turns)
    end)

    it("applies a change of the setting to the page being read", function()
        local reader, turns = readerFor(PAGES, { auto_rotate_spreads = "off" })
        reader.ui.paging.current_page = 2

        reader.settings.auto_rotate_spreads = "ccw"
        reader:applySpreadRotationSetting()
        reader.settings.auto_rotate_spreads = "off"
        reader:applySpreadRotationSetting()

        assert.equals("1,0", table.concat(turns, ","))
    end)
end)

describe("SpreadRotation while a book is opening", function()
    it("does not rotate before the reader is ready", function()
        -- KOReader sends the first PageUpdate while ReaderUI is still being built.
        local reader, turns = readerFor(PAGES)
        reader.spread_rotation_ready = nil

        reader:onPageUpdate(2)

        assert.equals(0, #turns)
        assert.is_nil(reader.spread_rotation)
    end)

    it("rotates the opening page once the reader is ready", function()
        local old_next_tick = UIManager.nextTick
        UIManager.nextTick = function(_, action)
            action()
        end
        local reader = readerFor(PAGES)
        reader.spread_rotation_ready = nil
        reader.ui.paging.current_page = 2
        reader:onPageUpdate(2)

        reader:startSpreadRotation()

        UIManager.nextTick = old_next_tick
        assert.equals(3, Screen:getRotationMode())
    end)

    it("drops the hold when the rotation request had no effect", function()
        local reader = readerFor(PAGES)
        UIManager.broadcastEvent = function() end

        reader:onPageUpdate(2)

        assert.equals(0, Screen:getRotationMode())
        assert.is_nil(reader.spread_rotation)
    end)

    it("stops when the document closes", function()
        local reader, turns = readerFor(PAGES)

        reader:onCloseDocument()
        reader:onPageUpdate(2)

        assert.equals(0, #turns)
    end)
end)

describe("SpreadRotation when the user rotates the screen", function()
    it("keeps the user's rotation on that spread", function()
        local reader, turns = readerFor(PAGES)
        reader:onPageUpdate(2)

        userTurnsScreen(reader, 0)
        -- A second update for the same page must not rotate it again.
        reader:onPageUpdate(2)

        assert.equals(0, Screen:getRotationMode())
        assert.equals(1, #turns)
    end)

    it("does not restore a rotation after the user changed it", function()
        local reader, turns = readerFor(PAGES)
        reader:onPageUpdate(2)
        userTurnsScreen(reader, 1)

        reader:onPageUpdate(4)

        assert.equals(1, Screen:getRotationMode())
        assert.equals(1, #turns)
    end)

    it("turns the next spread again", function()
        local reader = readerFor(PAGES)
        reader:onPageUpdate(2)
        userTurnsScreen(reader, 0)
        reader:onPageUpdate(4)

        reader:onPageUpdate(3)

        assert.equals(3, Screen:getRotationMode())
    end)
end)

describe("SpreadRotation and the book's saved rotation", function()
    it("keeps a temporary turn out of the document settings", function()
        local reader = readerFor(PAGES)
        reader:onPageUpdate(2)

        reader:keepSpreadRotationOutOfDocSettings()

        assert.equals(1, reader.saved:callCount())
        assert.equals("kopt_rotation_mode", reader.saved:lastCall()[1])
        assert.equals(0, reader.saved:lastCall()[2])
    end)

    it("leaves the document settings alone when nothing is turned", function()
        local reader = readerFor(PAGES)
        reader:onPageUpdate(1)

        reader:keepSpreadRotationOutOfDocSettings()

        assert.equals(0, reader.saved:callCount())
    end)

    it("turns the screen back when the document closes", function()
        local reader = readerFor(PAGES)
        reader:onPageUpdate(2)

        reader:onCloseDocument()

        assert.equals(0, Screen:getRotationMode())
        assert.is_nil(reader.spread_rotation)
    end)
end)

describe("SpreadRotation and the panel viewer", function()
    it("does nothing while a viewer is open", function()
        local reader, turns = readerFor(PAGES)
        reader.active_panel_viewer = {}

        reader:onPageUpdate(2)

        assert.equals(0, #turns)
    end)

    it("keeps the turned screen for a viewer that only shows that spread whole", function()
        local reader, turns = readerFor(PAGES)
        reader:onPageUpdate(2)

        reader:prepareSpreadRotationForViewer(2, { WHOLE_SPREAD })

        assert.equals(3, Screen:getRotationMode())
        assert.equals(1, #turns)
    end)

    it("turns the screen back for a viewer that zooms into the spread's panels", function()
        local reader = readerFor(PAGES)
        reader:onPageUpdate(2)

        reader:prepareSpreadRotationForViewer(2, { INNER_PANEL, WHOLE_SPREAD })

        assert.equals(0, Screen:getRotationMode())
        assert.is_nil(reader.spread_rotation)
    end)

    it("turns the screen back before a viewer opens on a normal page", function()
        local reader = readerFor(PAGES)
        reader:onPageUpdate(3)

        reader:prepareSpreadRotationForViewer(4, { INNER_PANEL })

        assert.equals(0, Screen:getRotationMode())
        assert.is_nil(reader.spread_rotation)
    end)

    it("turns the reading page once the viewer has closed on a spread", function()
        local old_next_tick = UIManager.nextTick
        UIManager.nextTick = function(_, action)
            action()
        end
        local reader = readerFor(PAGES)
        local viewer = {}
        reader.active_panel_viewer = viewer
        reader.ui.paging.current_page = 2

        viewer._panels_plus_closed = true
        reader:onPanelViewerClosed(viewer)

        UIManager.nextTick = old_next_tick
        assert.is_nil(reader.active_panel_viewer)
        assert.equals(3, Screen:getRotationMode())
    end)

    it("ignores the close of a viewer that was only being replaced", function()
        local reader, turns = readerFor(PAGES)
        local old_viewer, new_viewer = { _panels_plus_closed = true }, {}
        reader.active_panel_viewer = new_viewer
        reader.ui.paging.current_page = 2

        reader:onPanelViewerClosed(old_viewer)

        assert.equals(new_viewer, reader.active_panel_viewer)
        assert.equals(0, #turns)
    end)
end)

describe("SpreadRotation wiring in the viewer controller", function()
    --- Run `callback` with `buildImages` and `PanelViewer.new` stubbed.
    local function withStubbedViewer(callback)
        local old_build, old_new, old_show = PanelCollector.buildImages, PanelViewer.new, UIManager.show
        local seen = {}
        PanelCollector.buildImages = function(_, _, panels)
            seen.rotation_when_built = Screen:getRotationMode()
            return { {} }, panels, { true }
        end
        PanelViewer.new = function(_, options)
            seen.options = options
            seen.viewer = {}
            return seen.viewer
        end
        UIManager.show = function() end
        local ok, err = pcall(callback, seen)
        PanelCollector.buildImages, PanelViewer.new, UIManager.show = old_build, old_new, old_show
        if not ok then
            error(err, 0)
        end
    end

    it("hands the screen back before it builds a viewer for a normal page", function()
        withStubbedViewer(function(seen)
            local reader = readerFor(PAGES)
            reader:onPageUpdate(3)

            reader:showPanelViewerForPage(4, { { x = 0, y = 0, w = 10, h = 10 } }, 1, { defer_preload = true })

            assert.equals(0, seen.rotation_when_built)
        end)
    end)

    it("remembers the viewer it opened and hears about its close", function()
        withStubbedViewer(function(seen)
            local reader = readerFor(PAGES)

            reader:showPanelViewerForPage(1, { { x = 0, y = 0, w = 10, h = 10 } }, 1, { defer_preload = true })
            assert.equals(seen.viewer, reader.active_panel_viewer)
            assert.is_true(reader:isPanelViewerOpen())

            seen.viewer._panels_plus_closed = true
            seen.options.closed_callback(seen.viewer)

            assert.is_nil(reader.active_panel_viewer)
        end)
    end)
end)

describe("PanelViewer closed_callback", function()
    it("tells its owner once it has closed", function()
        local closed = spy()
        local viewer = PanelViewer:new({ closed_callback = closed })

        viewer:onCloseWidget()

        assert.equals(1, closed:callCount())
        assert.equals(viewer, closed:lastCall()[1])
        assert.is_true(viewer._panels_plus_closed)
    end)
end)

describe("SpreadRotation wiring in the plugin", function()
    local PanelsPlus = require("main")

    --- Plugin instance on page 2 (a spread) with the given `auto_rotate_spreads`.
    local function pluginOnSpread(mode)
        Screen:setRotationMode(0)
        local saved = {}
        local plugin = setmetatable({
            settings = Settings.withDefaults({ auto_rotate_spreads = mode }),
            spread_rotation_ready = true,
            saveSettings = function() end,
            saveDocSettings = function() end,
            loadDocSettings = function() end,
            applyPanelGesture = function() end,
            ui = {
                paging = { current_page = 2 },
                document = {
                    getNativePageDimensions = function()
                        return SPREAD_PAGE
                    end,
                },
                doc_settings = {
                    saveSetting = function(_, key, value)
                        saved[key] = value
                    end,
                },
            },
        }, { __index = PanelsPlus })
        UIManager.broadcastEvent = function(_, event)
            if event.name == "SetRotationMode" then
                Screen:setRotationMode(event.args[1])
            end
        end
        return plugin, saved
    end

    it("turns the page being read as soon as the setting is switched on", function()
        local plugin = pluginOnSpread("off")

        plugin:setAutoRotateSpreads("cw")

        assert.equals(3, Screen:getRotationMode())
    end)

    it("brings the page a book opens on in line", function()
        local old_next_tick = UIManager.nextTick
        UIManager.nextTick = function(_, action)
            action()
        end
        local plugin = pluginOnSpread("ccw")
        plugin.spread_rotation_ready = nil

        plugin:onReaderReady()

        UIManager.nextTick = old_next_tick
        assert.equals(1, Screen:getRotationMode())
    end)

    it("saves the book with the rotation it had before the spread", function()
        local plugin, saved = pluginOnSpread("cw")
        plugin:onPageUpdate(2)

        plugin:onSaveSettings()

        assert.equals(0, saved.kopt_rotation_mode)
    end)
end)
