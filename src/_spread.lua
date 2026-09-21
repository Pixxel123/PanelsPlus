--[[
Panels+
File: src/_spread.lua
Name: Spread
Description: Decides whether a page is a double-page spread and which zoomed-view rotation it should get.
Author: KristanLaimon
Year: 2026
Copyright (c) 2026 KristanLaimon
License: MIT; see the repository LICENSE file.
SPDX-License-Identifier: MIT
]]
--- Double-page spread detection and the rotation angles used for it.
---
--- No KOReader requires, so it can be unit-tested with plain page and screen sizes.
---
--- @class PPSpreadModule
local Spread = {}

--- `ImageWidget.rotation_angle` turns the bitmap counter-clockwise: `BlitBuffer:rotatedCopy(90)`
--- maps displayed `(x, y)` to source `(w - y - 1, x)`, which puts the source's right edge at the
--- top. Clockwise is 270.
Spread.COUNTER_CLOCKWISE = 90
Spread.CLOCKWISE = 270

--- Angle for one panel of a page.
---
--- An angle picked by hand applies to every panel. The spread angle applies only to a panel that
--- covers the whole page. Panels inside a spread stay upright.
---
--- @param hand_rotation number|boolean|nil `image_rotation` from the rotation picker (`false` is its "no rotation").
--- @param spread_rotation number|nil Automatic angle for this page, from `rotationFor`.
--- @param is_full_page boolean|nil Whether the panel spans nearly the whole page.
--- @return number|boolean|nil rotation Angle, `false` for none, or `nil` for the document default.
function Spread.panelRotation(hand_rotation, spread_rotation, is_full_page)
    if type(hand_rotation) == "number" then
        return hand_rotation
    end
    if is_full_page and spread_rotation then
        return spread_rotation
    end
    return hand_rotation
end

--- Whether an angle swaps width and height. Such a view is rendered and laid out for the turned
--- screen (see `PanelCollector.drawPart`).
---
--- @param rotation number|boolean|nil Angle a view is shown at.
--- @return boolean quarter_turn `true` for 90 and 270 only.
function Spread.isQuarterTurn(rotation)
    return rotation == 90 or rotation == 270
end

--- Whether a page is wide enough to count as a double-page spread.
---
--- @param page_w number|nil Native page width.
--- @param page_h number|nil Native page height.
--- @param min_ratio number Width/height at or above which the page is a spread.
--- @return boolean is_spread `true` when the page is landscape enough.
function Spread.isSpread(page_w, page_h, min_ratio)
    if type(page_w) ~= "number" or type(page_h) ~= "number" then
        return false
    end
    if page_w <= 0 or page_h <= 0 then
        return false
    end
    return (page_w / page_h) >= min_ratio
end

--- Image angle for a page in the viewer, or `nil`.
---
--- Returns `nil` when the setting does not apply. `false` is reserved for the picker's "no
--- rotation". A landscape screen already fits a spread and gets `nil`.
---
--- @param opts table `{ mode, page_w, page_h, screen_w, screen_h, min_ratio }`.
--- @return number|nil angle `90`, `270`, or `nil` when no rotation applies.
function Spread.rotationFor(opts)
    opts = opts or {}
    local mode = opts.mode or "off"
    if mode ~= "cw" and mode ~= "ccw" then
        return nil
    end
    if not Spread.isSpread(opts.page_w, opts.page_h, opts.min_ratio or 1.2) then
        return nil
    end
    local screen_w, screen_h = opts.screen_w, opts.screen_h
    if type(screen_w) == "number" and type(screen_h) == "number" and screen_w > screen_h then
        return nil
    end
    if mode == "cw" then
        return Spread.CLOCKWISE
    end
    return Spread.COUNTER_CLOCKWISE
end

--- Screen rotation mode for a page on the reading page, or `nil` for the base mode.
---
--- The direction matches the viewer's image rotation, so the device is held the same way for both.
--- In KOReader's mode 1 the page's top is on the device's left edge (the Up key maps to Right
--- there), which corresponds to the viewer's 90. Clockwise is mode 3.
---
--- `base_mode` is the reader's rotation when no spread is shown. A landscape base gets `nil`.
---
--- @param opts table `{ mode, page_w, page_h, min_ratio, base_mode }`.
--- @return integer|nil rotation_mode `Screen` rotation mode for this page, or `nil` for the base mode.
function Spread.deviceRotationFor(opts)
    opts = opts or {}
    local mode = opts.mode or "off"
    if mode ~= "cw" and mode ~= "ccw" then
        return nil
    end
    local base_mode = opts.base_mode or 0
    if base_mode % 2 == 1 then
        return nil
    end
    if not Spread.isSpread(opts.page_w, opts.page_h, opts.min_ratio or 1.2) then
        return nil
    end
    return (base_mode + (mode == "cw" and 3 or 1)) % 4
end

return Spread
