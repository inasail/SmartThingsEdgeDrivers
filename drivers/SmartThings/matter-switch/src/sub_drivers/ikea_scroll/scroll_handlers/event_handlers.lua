-- Copyright © 2025 SmartThings, Inc.
-- Licensed under the Apache License, Version 2.0

local st_utils = require "st.utils"
local capabilities = require "st.capabilities"
local switch_utils = require "switch_utils.utils"
local generic_event_handlers = require "switch_handlers.event_handlers"
local scroll_fields = require "sub_drivers.ikea_scroll.scroll_utils.fields"

local IkeaScrollEventHandlers = {}
local log = require "log"


-- Per-endpoint field key helpers for accumulated scroll data and throttle timer
local function scroll_accumulated_field(endpoint_id)
  return "__scroll_accumulated_" .. tostring(endpoint_id)
end

local function scroll_timer_field(endpoint_id)
  return "__scroll_timer_" .. tostring(endpoint_id)
end

-- Emit the accumulated scroll amount for an endpoint and clear the throttle state
local function emit_accumulated_scroll(device, endpoint_id)
  local accumulated = device:get_field(scroll_accumulated_field(endpoint_id)) or 0
  local timer = device:get_field(scroll_timer_field(endpoint_id))
  if timer ~= nil then
    device.thread:cancel_timer(timer)
  end
  device:set_field(scroll_accumulated_field(endpoint_id), nil)
  device:set_field(scroll_timer_field(endpoint_id), nil)
  if accumulated ~= 0 then
    device:emit_event_for_endpoint(endpoint_id, capabilities.knob.rotateAmount(accumulated, {state_change = true}))
  end
end

local function accumulate_rotate_amount_event_helper(device, endpoint_id, num_presses_to_handle)
  -- to cut down on checks, we can assume that if the endpoint is not in ENDPOINTS_UP_SCROLL, it is in ENDPOINTS_DOWN_SCROLL
  local scroll_direction = switch_utils.tbl_contains(scroll_fields.ENDPOINTS_UP_SCROLL, endpoint_id) and 1 or -1
  local scroll_amount = scroll_direction * scroll_fields.PER_SCROLL_EVENT_ROTATION * num_presses_to_handle

  -- Accumulate the scroll amount for this endpoint
  local accumulated = device:get_field(scroll_accumulated_field(endpoint_id)) or 0
  accumulated = st_utils.clamp_value(accumulated + scroll_amount, -100, 100)
  log.info_with({hub_logs = true}, string.format("[TWT] accumulate_rotate_amount_event_helper - Total cumulated amount: %d", accumulated))
  device:set_field(scroll_accumulated_field(endpoint_id), accumulated)

  -- If no throttle timer is running for this endpoint, start one
  local existing_timer = device:get_field(scroll_timer_field(endpoint_id))
  if existing_timer == nil then
    local timer = device.thread:call_with_delay(scroll_fields.SCROLL_EVENT_THROTTLE_INTERVAL, function()
      emit_accumulated_scroll(device, endpoint_id)
    end)
    device:set_field(scroll_timer_field(endpoint_id), timer)
  end
end

-- Used by ENDPOINTS_UP_SCROLL and ENDPOINTS_DOWN_SCROLL, not ENDPOINTS_PUSH
function IkeaScrollEventHandlers.multi_press_ongoing_handler(driver, device, ib, response)
  log.info_with({hub_logs = true}, string.format("[TWT] multi_press_ongoing_handler"))
  if switch_utils.tbl_contains(scroll_fields.ENDPOINTS_PUSH, ib.endpoint_id) then
    -- Ignore MultiPressOngoing events from push endpoints.
    device.log.debug("Received MultiPressOngoing event from push endpoint, ignoring.")
  else
    local cur_num_presses_counted = ib.data and ib.data.elements and ib.data.elements.current_number_of_presses_counted.value or 0
    local num_presses_to_handle = cur_num_presses_counted - (device:get_field(scroll_fields.LATEST_NUMBER_OF_PRESSES_COUNTED) or 0)
    if num_presses_to_handle > 0 then
      device:set_field(scroll_fields.LATEST_NUMBER_OF_PRESSES_COUNTED, cur_num_presses_counted)
      accumulate_rotate_amount_event_helper(device, ib.endpoint_id, num_presses_to_handle)
    end
  end
end

function IkeaScrollEventHandlers.multi_press_complete_handler(driver, device, ib, response)
  log.info_with({hub_logs = true}, string.format("[TWT] multi_press_complete_handler"))
  if switch_utils.tbl_contains(scroll_fields.ENDPOINTS_PUSH, ib.endpoint_id) then
    generic_event_handlers.multi_press_complete_handler(driver, device, ib, response)
  else
    local total_num_presses_counted = ib.data and ib.data.elements and ib.data.elements.total_number_of_presses_counted.value or 0
    local num_presses_to_handle = total_num_presses_counted - (device:get_field(scroll_fields.LATEST_NUMBER_OF_PRESSES_COUNTED) or 0)
    if num_presses_to_handle > 0 then
      accumulate_rotate_amount_event_helper(device, ib.endpoint_id, num_presses_to_handle)
    end
    emit_accumulated_scroll(device, ib.endpoint_id) -- If there are InitialPress|MultiPressOngoing|MultiPressComplete in one packet, send cummulated amount in MultiPressComplete
    -- reset the LATEST_NUMBER_OF_PRESSES_COUNTED to nil at the end of a MultiPress chain.
    device:set_field(scroll_fields.LATEST_NUMBER_OF_PRESSES_COUNTED, nil)
  end
end

function IkeaScrollEventHandlers.initial_press_handler(driver, device, ib, response)
  log.info_with({hub_logs = true}, string.format("[TWT] initial_press_handler"))
  if switch_utils.tbl_contains(scroll_fields.ENDPOINTS_PUSH, ib.endpoint_id) then
    generic_event_handlers.initial_press_handler(driver, device, ib, response)
  else
    -- the magic number "1" occurs in this handler since the InitialPress event represents the first press.
    local latest_presses_counted = device:get_field(scroll_fields.LATEST_NUMBER_OF_PRESSES_COUNTED) or 0
    if latest_presses_counted == 0 then
      device:set_field(scroll_fields.LATEST_NUMBER_OF_PRESSES_COUNTED, 1)
      accumulate_rotate_amount_event_helper(device, ib.endpoint_id, 1)
    end
  end
end

return IkeaScrollEventHandlers
