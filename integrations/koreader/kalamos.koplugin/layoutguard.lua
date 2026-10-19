-- Keep background EPUB rendering independent of the live native writing owner.
local UIManager = require("ui/uimanager")
return function(Kalamos)
function Kalamos:isWritingLayoutPinned()
    return self.ink_mode ~= nil or self.pending_canvas_start ~= nil
        or self.writing_spaces and self.writing_spaces.layout_changing == true or false
end
function Kalamos:installWritingLayoutGuard()
    local rolling = self.ui.rolling
    if not rolling or not rolling.setupRerenderingAutomation or self.layout_guard_installed then return end
    self.layout_guard_installed = true
    local setup = rolling.setupRerenderingAutomation
    self.layout_setup_previous = setup
    local function wrapStep()
        local previous = rolling._stepRerenderingAutomation
        if not previous or previous == self.layout_step_wrapper then return end
        local wrapper
        wrapper = function(next_step)
            if not self.layout_guard_installed then return end
            local states = rolling.RENDERING_STATE
            if self:isWritingLayoutPinned() then
                -- The worker may finish while ink continues. Keep its prepared cache
                -- waiting; committing it via reloadDocument would retire the writer.
                if next_step == states.FULL_RENDERING_READY then
                    UIManager:unschedule(wrapper)
                    rolling.rendering_state = states.FULL_RENDERING_READY
                    UIManager:scheduleIn(1, wrapper)
                    return
                end
                if next_step == states.RELOADING_DOCUMENT or next_step == nil and
                    (rolling.rendering_state == states.FULL_RENDERING_READY or
                     rolling.rendering_state == states.RELOADING_DOCUMENT) then
                    UIManager:unschedule(wrapper)
                    UIManager:scheduleIn(1, wrapper)
                    return
                end
            end
            return previous(next_step)
        end
        self.layout_step_previous, self.layout_step_wrapper = previous, wrapper
        rolling._stepRerenderingAutomation = wrapper
    end
    self.layout_setup_wrapper = function(owner, ...)
        local result = setup(owner, ...)
        wrapStep()
        return result
    end
    rolling.setupRerenderingAutomation = self.layout_setup_wrapper
    wrapStep()
    local flipping = self.ui.view and self.ui.view.flipping
    if flipping and flipping.getRollingRenderingStateIconWidget then
        self.layout_icon_previous = flipping.getRollingRenderingStateIconWidget
        self.layout_icon_wrapper = function(owner, ...)
            if self:isWritingLayoutPinned() then return nil end
            return self.layout_icon_previous(owner, ...)
        end
        flipping.getRollingRenderingStateIconWidget = self.layout_icon_wrapper
    end
end
function Kalamos:restoreWritingLayoutGuard()
    self.layout_guard_installed = nil
    local rolling = self.ui.rolling
    if rolling then
        if rolling.setupRerenderingAutomation == self.layout_setup_wrapper then
            rolling.setupRerenderingAutomation = self.layout_setup_previous
        end
        if rolling._stepRerenderingAutomation == self.layout_step_wrapper then
            UIManager:unschedule(self.layout_step_wrapper)
            rolling._stepRerenderingAutomation = self.layout_step_previous
        end
    end
    local flipping = self.ui.view and self.ui.view.flipping
    if flipping and flipping.getRollingRenderingStateIconWidget == self.layout_icon_wrapper then
        flipping.getRollingRenderingStateIconWidget = self.layout_icon_previous
    end
end
end
