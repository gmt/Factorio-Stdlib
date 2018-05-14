--- Makes working with events in Factorio a lot more simple.
-- <p>By default, Factorio allows you to register **only one listener** to an event.
-- <p>This module lets you easily register **multiple listeners** to an event.
-- <p>Using this module is as simple as replacing @{LuaBootstrap.on_event|script.on_event} with @{Event.register}.
-- <blockquote>
-- Due to the way that Factorio's event system works, it is not recommended to intermingle `script.on_event` and `Event.register` in a mod.
-- <br>This module hooks into Factorio's event system, and using `script.on_event` for the same event will change which events are registered.
-- </blockquote>
-- <blockquote>
-- This module does not have many of the multiplayer protections that `script.on_event` does.
-- <br>Due to this, great care should be taken when registering events conditionally.
-- </blockquote>
-- @module Event
-- @usage local Event = require('stdlib/event/event')

local LinkedList = require('stdlib/lists/linked_list')
local LinkedListNode = LinkedList._node_class
local Is = require('stdlib/utils/is')

local EventRegistrant = setmetatable(
    {
        _module = 'event_registry',
        _class_name = 'EventRegistrant',
        _mt = LinkedList:_mtcopy()
    },
    {
        __index = LinkedListNode
    }
)
EventRegistrant._class = EventRegistrant
function EventRegistrant._mt.__index(self, index)
    -- alias 'listener' to 'item'
    if index == 'listener' then
        return self.item
    else
        -- the following is a shortcut since LinkedListNode._mt.__index == LinkedListNode
        return LinkedListNode[index]
    end
end

function EventRegistrant._mt.__newindex(self, index, value)
    -- alias 'listener' to 'item'
    if index == 'listener' then
        rawset(self, 'item', value)
    else
        -- nb: LinkedListNode._mt.__setindex == nil
        rawset(self, index, value)
    end
end

local EventRegistry = setmetatable(
    {
        _module = 'event_registry',
        _class_name = 'EventRegistry',
        _node_class = EventRegistrant,
        stop_processing = {} -- arbitrary singleton value
    },
    {
        __index = LinkedList
    }
)
EventRegistry._class = EventRegistry

--- Creates a new EventRegistry instance object.
-- If a name is provided it will be automatically injected into event objects
-- which do not provide an explicit `name` field.  The name may be any Lua
-- type so long as it has a string representation (as this may be used during
-- error handling).
-- @param[opt] name An arbitrary value which may be used to distinguish between various EventRegistry instances.  If, during dispatch, no name field is provided, this name will be injected into the event table (@see EventRegistry:dispatch).
-- @usage
-- local somebody_farted_registry = EventRegistry:new('somebody_farted')
-- @return (<span class="types">@{EventRegistry}</span>) a new EventRegistry instance
function EventRegistry.new(self, name)
    Is.Assert.Not.Nil(self, 'EventRegistry:new invoked without self argument: perhaps you used a dot instead of a colon?', 2)
    local result = LinkedList.new(self)
    result.name = name
    -- this set holds a ongoing dispatch_id's in self and is used
    -- to ensure correct semantics when change occurs during dispatch
    result.live_dispatches = setmetatable({}, {__mode = 'k'})
    return result
end

--- Registers a listener for the given events.
-- If a `nil` listener is passed, remove the given events and stop listening to them.
-- <p>Events dispatch in the order they are registered.
-- <p>An *event ID* can be obtained via @{defines.events},
-- @{LuaBootstrap.generate_event_name|script.generate_event_name} which is in <span class="types">@{int}</span>,
-- and can be a custom input name which is in <span class="types">@{string}</span>.
-- @usage
-- registry:add_listener(function(event) print event.tick end)
-- -- Function call chaining (this will not invoke add_listener(event1, listener1)
-- -- twice because the Lua documentation tells a fib when it says that foo:bar(...)
-- -- is syntactic sugar for foo.bar(bar, ...); it uses a dedicated opcode in Lua IR)
-- registry:add_listener(event1, listener1):add_listener(event2, listener2)
-- @tparam function listener the Callable to invoke during event dispatch
-- @tparam[opt=nil] function matcher a Callable whose result, if not truthy, causes the listener invocation to be skipped.  Provided with event and pattern arguments.
-- @tparam[opt=nil] mixed pattern an invariant that is passed into the matcher function as its second parameter.  Any type is permitted.
-- @return (<span class="types">@{EventRegistry}</span>) the EventRegistry instance object itself, for call chaining purposes (see usage, above).
function EventRegistry:add_listener(listener, matcher, pattern)
    Is.Assert.Not.Nil(self, 'EventRegistry:add_listener invoked without self argument: perhaps you used a dot instead of a colon?', 2)
    Is.Assert.True(self._is_LinkedList, 'EventRegistry:add_listener self argument invalid: perhaps you used a dot instead of a colon?', 2)
    Is.Assert(Is.Callable(listener), 'listener missing or not callable')
    Is.Assert(Is.Nil(matcher) or Is.Callable(matcher), 'matcher must be callable')

    -- If listener is already registered for this event: move listener to the end of the list
    for registrant in self:nodes() do
        if registrant.listener == listener and registrant.pattern == pattern and registrant.matcher == matcher then
            if registrant.next == self then
                -- nothing to do, registrant already is at the end of the list
                return self
            end
            -- remember where the registrant was
            local oldnext = registrant.next
            -- prune registrant from its current location and graft it at the end of the registry
            registrant:prune()
            registrant:graft_before(self)
            -- find ongoing dispatches that may already have dispatched to registrant
            for live_dispatch in pairs(self.live_dispatches) do
                if live_dispatch.current_node then
                    -- If the live dispatch already processed registrant, we have to remember not
                    -- to repeat the dispatch when it encounters the grafted registrant at the end
                    -- We just scan through from the first node until we encounter either:
                    --
                    --  o oldnext, the node that followed registrant before the move (need to suppress)
                    --  o the node (live_dispatch.current_node) currently being dispatched (no need to suppress)
                    --
                    -- We use the dispatch_id object to record the suppression
                    --
                    -- Note: if live_dispatch.current_node == registrant then dispatch has already occured
                    -- (indeed it is ongoing).  To avoid special-casing, we have to check in the order above.
                    local i = self.next
                    local current = live_dispatch.current_node
                    while true do
                        if i == oldnext then
                            live_dispatch[registrant] = true
                            break
                        elseif i == current then
                            -- nothing to do, live_dispatch hasn't yet reached registrant
                            break
                        end
                        i = i.next
                        Is.Assert(i ~= self, "EventRegistry:add_listener: something impossible happened.  Theres a bug somewhere.")
                    end
                end
            end
            -- with the found duplicate pruned and grafted, and all
            -- any needed dispatch accounting complete, we are done.
            return self
        end
    end

    local new_registrant = self:append(listener)
    -- if registrant, these should be harmless noops
    new_registrant.matcher = matcher
    new_registrant.pattern = pattern

    return self
end

--- Removes a listener
-- @tparam function listener the listener to remove
-- @tparam[opt] function matcher
-- @tparam[opt] mixed pattern
-- @return (<span class="types">@{EventRegistry}</span>) EventRegistry object itself, for call chaining
function EventRegistry:remove_listener(listener, matcher, pattern)
    Is.Assert.Not.Nil(self, 'EventRegistry:remove_listener invoked without self argument: perhaps you used a dot instead of a colon?', 2)
    Is.Assert.True(self._is_LinkedList, 'EventRegistry:remove_listener self argument invalid: perhaps you used a dot instead of a colon?', 2)
    Is.Assert.Callable(listener, 'EventRegistry:remove_listener missing required listener argument or not Callable')

    local found_something = false
    for registrant in self:nodes() do
        if listener == registrant.listener then
            if not matcher and not pattern then
                registrant.remove()
                found_something = true
            elseif matcher then
                if matcher == registrant.matcher then
                    if not pattern then
                        registrant.remove()
                        found_something = true
                    elseif pattern and pattern == registrant.pattern then
                        registrant.remove()
                        found_something = true
                    end
                end
            elseif pattern and pattern == registrant.pattern then
                registrant.remove()
                found_something = true
            end
        end
    end

    if not found_something then
        log('EventRegistry.remove_listener: Attempt to deregister already non-registered listener')
    end
    return self
end

-- A dispatch helper function
--
-- Call any matcher and, as applicable, the event listener, in protected mode.  Errors are
-- caught and logged to stdout but event processing proceeds thereafter; errors are suppressed.
local function run_protected(registrant, event, force_crc)
    local success, err

    if registrant.matcher then
        success, err = pcall(registrant.matcher, event, registrant.pattern)
        if success and err then
            success, err = pcall(registrant.listener, event)
        end
    else
        success, err = pcall(registrant.listener, event)
    end

    -- If the listener errors lets make sure someone notices
    if not success then
        if not registrant.log_and_print(err) then
            -- no players received the message, force a real error so someone notices
            error(err)
        end
    end

    -- force a crc check if option is enabled. This is a debug option and will hamper performance if enabled
    if (force_crc or event.force_crc) and game then
        local event_description = Is.Not.Nil(event.name) and ' [' .. tostring(event.name) .. ']' or ''
        log('CRC check called for event' .. event_description)
        game.force_crc()
    end

    return success and err or nil
end

--- Dispatch an event to all registered listeners.
-- The caller may provide a table (or duck-type equivalent) to @{EventRegistry.dispatch}.
-- <p>It is presumed to be in a format similar to that used by Factorio for events.
--> It may include a b`name` field, which is used during error-handling, and any other fields which might be helpful for consumers of the event may require.
-- @field[opt] name event ID or description, preferably uniquely identifying.  Any type may be used; it may be converted to a string during error handling, however.  If not provided, the name property of the EventRegistry instance, if any, will be automatically added to the table before dispatch.
-- @field[opt] ... any # of additional fields with extra data, which are passed along to the registered listeners to an event that this table represents
-- @usage
-- local event_data = {
--   info = 'some information'
--   more_info = 42
--   name = 'FoundSomeInfoForYa'
-- }
-- registry.dispatch(event_data)
-- @table event_data

--- pure-virtual function which may be overridden to abort
-- processing of events according to subclass-determined criteria.
-- Called before dispatch to each individual event listener
-- @param event the event being dispatched
-- @tparam dispatch_id table singleton table to distinguish between iterations
-- @return boolean False, by default.  Subclasses may override to return True if they wish
-- to abort processing.
function EventRegistry:abort_dispatch(event, dispatch_id) -- luacheck: self ignore event dispatch_id
    return false
end


--- Calls the registered listeners, with the given event object, if provided.
-- @see https://forums.factorio.com/viewtopic.php?t=32039#p202158 Invalid Event Objects
-- <p>Listeners are dispatched in the order they were registered; if a listener is
-- re-registered it moves to the "end of the line".
-- @param[opt] event (<span class="types">@{event_data}</span>) the event data table.
-- @tparam[opt] protected_mode boolean if true, event listeners are invoked in
-- Lua protected mode.  Errors emitted in protected mode are logged but
-- otherwise ignored.  Event processing continues and dispatch always succeeds.
function EventRegistry:dispatch(event, protected_mode)
    Is.Assert.Not.Nil(self, 'EventRegistry:dispatch invoked without self argument: perhaps you used a dot instead of a colon?', 2)
    Is.Assert.True(self._is_LinkedList, 'EventRegistry:dispatch self argument invalid: perhaps you used a dot instead of a colon?', 2)

    event = event or {}

    -- protected_mode runs the listener and matcher in pcall; forcing crc can only be
    -- accomplished in protected_mode
    local protected = protected_mode or self.protected_mode

    -- per-dispatch singleton.  Allows to distinguish between iterations when
    -- event object is recycled (i.e. event "X" listener triggers self:dispatch(X))
    -- additionally serves as a set of nodes to skip during iteration; the skips are
    -- required to identify nodes that have been added to the registry while iteration
    -- it a set/bag of registrants (see _Programming_In_Lua_ 1st Ed. §11.5) with weak keys.
    local dispatch_id = setmetatable({}, {__mode = 'k'})

    -- all the dispatch id's are tracked in live_dispatches, which is also a set/bag.
    -- so we have to add this dispatch into the list
    self.live_dispatches[dispatch_id] = true

    if Is.Nil(event.name) then
        event.name = self.name
    end

    for registrant in self:nodes() do
        -- remember where we are in dispatch_id.current_node
        -- nb: this is just clever enough to be a bit confusing.
        -- dispatch_id here serves as both a unique identifier and a place to
        -- announce this "current node" information to interested consumers
        -- (ie :remove_listener())
        dispatch_id.current_node = registrant
        -- are we supposed to skip this node?
        if not dispatch_id[registrant] then
            if self:abort_dispatch(event, dispatch_id) then
                return
            end
            if protected then
                if run_protected(registrant, event) == EventRegistry.stop_processing then
                    return
                end
            elseif registrant.matcher then
                if registrant.matcher(event, registrant.pattern) then
                    if registrant.listener(event) == EventRegistry.stop_processing then
                        return
                    end
                end
            else
                if registrant.listener(event) == EventRegistry.stop_processing then
                    return
                end
            end
        end
    end

    -- Dispatch is no longer live so we can drop it from the set.
    self.live_dispatches[dispatch_id] = nil
    -- But just in case someone is still holding it, drop the node from the tracker
    dispatch_id.current_node = nil
end

return EventRegistry
