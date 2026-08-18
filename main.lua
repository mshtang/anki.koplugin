local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local CustomContextMenu = require("customcontextmenu")
local Event = require("ui/event")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local LuaSettings = require("luasettings")
local MenuBuilder = require("menubuilder")
local NetworkMgr = require("ui/network/manager")
local RadioButtonWidget = require("ui/widget/radiobuttonwidget")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local lfs = require("libs/libkoreader-lfs")
local AnkiConnect = require("ankiconnect")
local AnkiNote = require("ankinote")
local Configuration = require("anki_configuration")
local NotesViewer = require("notesviewer")

local QUEUED_NOTE_HIGHLIGHT_SECONDS = 2
local AnkiWidget = WidgetContainer:extend {
    name = "anki_widget",
    known_document_profiles = LuaSettings:open(DataStorage:getSettingsDir() .. "/anki_profiles.lua"),
}

function AnkiWidget:show_profiles_widget(opts)
    local buttons = {}
    for name, _ in pairs(Configuration.profiles) do
        table.insert(buttons, { { text = name, provider = name, checked = Configuration:is_active(name) } })
    end
    if #buttons == 0 then
        local msg = [[Failed to load profiles, there are none available, create a profile first. See the README on GitHub for more details.]]
        return UIManager:show(InfoMessage:new { text = msg, timeout = 4 })
    end

    self.profile_change_widget = RadioButtonWidget:new{
        title_text = opts.title_text,
        info_text = opts.info_text,
        cancel_text = "Cancel",
        ok_text = "Accept",
        width_factor = 0.9,
        radio_buttons = buttons,
        callback = function(radio)
            local profile = radio.provider:gsub(".lua$", "", 1)
            Configuration:load_profile(profile)
            self.profile_change_widget:onClose()
            local _, file_name = util.splitFilePathName(self.ui.document.file)
            self.known_document_profiles:saveSetting(file_name, profile)
            opts.cb()
        end,
    }
    UIManager:show(self.profile_change_widget)
end

--[[
-- The note's fingerprint if the book already has this note, nil otherwise. Working it
-- out means building the note, which is why it happens here and not when a dictionary
-- popup is merely opened: asking for this widget is a deliberate act, and the note that
-- gets built is the very one an add or update goes on to use.
--]]
function AnkiWidget:existing_note_fingerprint(note)
    local ok, built = pcall(note.build, note)
    if not ok then
        logger.warn("Could not build the note to look it up:", built)
        return nil
    end
    local fingerprint = AnkiConnect:note_fingerprint(built)
    return AnkiConnect.known_fingerprints[fingerprint] and fingerprint or nil
end

--[[
-- Three states, and the widget is where the user gets to see which one they are in: a
-- word the book hasn't given yet is added, one still waiting in the queue is opened in
-- its source book, and
-- one that has been synced is neither - it belongs to Anki now, and is edited there.
--]]
function AnkiWidget:show_config_widget()
    local existing = self:existing_note_fingerprint(self.current_note)
    local editable = existing ~= nil and AnkiConnect:queued_note(existing) ~= nil
    local context_text = "Add with custom context"
    if existing then
        context_text = editable and "Update context" or "Update context (already synced)"
    end
    local with_custom_tags_cb = function()
        self.current_note:add_tags(Configuration.custom_tags:get_value())
        AnkiConnect:add_note(self.current_note)
        self.config_widget:onClose()
    end
    self.config_widget = ButtonDialog:new {
        buttons = {
            {{ text = "Add with custom tags", id = "custom_tags", callback = with_custom_tags_cb }},
            {{
                text = context_text,
                id = "custom_context",
                enabled = self.current_note.contextual_lookup and (existing == nil or editable),
                callback = function() self:set_profile(function() return self:show_custom_context_widget(existing) end) end
            }},
            {{
                text = "Change profile",
                id = "profile_change",
                callback = function()
                    self:show_profiles_widget {
                        title_text = "Change user profile",
                        info_text  = "Use a different profile",
                        cb = function() end
                    }
                end
            }}
        },
    }
    UIManager:show(self.config_widget)
end

-- @param existing: fingerprint of the note the book already has, when there is one: the
-- passage that note was made from is then rewritten instead of a second note being added
function AnkiWidget:show_custom_context_widget(existing)
    local function on_save_cb()
        local m = self.context_menu
        self.current_note:set_custom_context(m.prev_s_cnt, m.prev_c_cnt, m.next_s_cnt, m.next_c_cnt)
        if existing then
            AnkiConnect:update_note_context(existing, self.current_note)
        else
            AnkiConnect:add_note(self.current_note)
        end
        self.context_menu:onClose()
        self.config_widget:onClose()
    end
    self.context_menu = CustomContextMenu:new{
        note = self.current_note, -- to extract context out of
        on_save_cb = on_save_cb,  -- called when saving note with updated context
    }
    UIManager:show(self.context_menu)
end

function AnkiWidget:show_connection_widget()
    self.conn_settings = MultiInputDialog:new{
        title = _("Connection Settings"),
        fields = {
            {
                text = Configuration.url:get_value_nodefault() or '',
                description = "The anki-connect URL.",
                hint = "http://192.168.1.xxx:8765"
            },
            {
                text = Configuration.api_key:get_value_nodefault() or '',
                description = "The (optional) anki-connect API key.",
                hint = "You can leave me blank"
            },
        },
        buttons = {
            {
                {
                    text = _("Cancel"),
                    id = "close",
                    callback = function()
                        UIManager:close(self.conn_settings)
                    end
                },
                {
                    text = _("Test"),
                    callback = function()
                        local function err(msg) return UIManager:show(InfoMessage:new { text = msg, timeout = 4 }) end
                        local fields = self.conn_settings:getFields()
                        local new_url, is_https = fields[1], false
                        local new_api_key = fields[2]
                        if #new_url == 0 then return UIManager:show(InfoMessage:new { text = "Empty URL", timeout = 4 }) end
                        new_url, is_https = AnkiConnect.sanitize_url(new_url)

                        local function when_connected()
                            local result, error = AnkiConnect:is_running(new_url)
                            if error then
                                local extra_info
                                if is_https then
                                    extra_info = "\nYou probably want to use http instead of https."
                                end
                                return err(("Failed to connect to '%s': %s%s"):format(new_url, error, extra_info or ''))
                            end
                            if result.permission ~= "granted" then
                                return err("Permission not granted")
                            elseif result.requireApikey then
                                if #new_api_key == 0 then
                                    return err("API key required but not provided!")
                                end
                                result, error = AnkiConnect:get_decknames(new_url, new_api_key)
                                if error then
                                    return err(("Could not connect: %s"):format(error))
                                end
                            end
                            return UIManager:show(InfoMessage:new { text = "Connection succesful!", timeout = 4 })
                        end

                        if NetworkMgr:willRerunWhenOnline(function() when_connected() end) then return end
                        when_connected()
                    end
                },
                {
                    text = _("Save"),
                    callback = function()
                        local fields = self.conn_settings:getFields()
                        local new_url = fields[1]
                        if #new_url == 0 then
                            Configuration.url:delete()
                        elseif new_url ~= Configuration.url:get_value_nodefault() then
                            Configuration.url:update_value(AnkiConnect.sanitize_url(new_url))
                        end
                        local new_api_key = fields[2]
                        if new_api_key ~= Configuration.api_key:get_value_nodefault() then
                            Configuration.api_key:update_value(new_api_key)
                        end
                        UIManager:close(self.conn_settings)
                    end
                },
            },
        },
    }
    UIManager:show(self.conn_settings)
    self.conn_settings:onShowKeyboard()
end

-- [[
-- This function name is not chosen at random. There are 2 places where this function is called:
--  - frontend/apps/filemanager/filemanagermenu.lua
--  - frontend/apps/reader/modules/readermenu.lua
-- These call the function `pcall(widget.addToMainMenu, widget, self.menu_items)` which lets other widgets add
-- items to the dictionary menu
-- ]]
function AnkiWidget:addToMainMenu(menu_items)
    menu_items.anki_settings = { text = ("Anki Settings"), sorting_hint = "search_settings", sub_item_table = self:buildSettings() }
end

function AnkiWidget:buildSettings()
    local builder = MenuBuilder:new{
        extensions = self.extensions,
        ui = self.ui
    }
    local function make_new_profile(start_data)
        return function()
            local input_dialog = MenuBuilder.build_single_dialog("Profile name", "", "", "Choose a name for the profile", function(obj)
                local profile = obj:getInputText()
                if Configuration.profiles[profile] then
                    return UIManager:show(InfoMessage:new { text = "Profile already exists! Pick another name.", timeout = 4 })
                end
                Configuration.profiles[profile] = LuaSettings:open(DataStorage:getFullDataDir() .. "/plugins/anki.koplugin/profiles/" .. profile .. ".lua")
                Configuration.profiles[profile].data = start_data
                if self.ui.menu.menu_items.anki_settings then
                    self.ui.menu.menu_items.anki_settings.sub_item_table = self:buildSettings()
                else
                    -- TODO this can be removed again after a while, it prevents crashes for old users that still have the patch enabled.
                    UIManager:show(InfoMessage:new { text = "Please disable the custom userpatch. Anki Settings are now available by default under Search (looking glass icon) - Settings", timeout = 20 })
                end
                UIManager:close(obj)
            end)
            UIManager:show(input_dialog)
            input_dialog:onShowKeyboard()
        end
    end
    local profile_names = {}
    for pname,_ in pairs(Configuration.profiles) do table.insert(profile_names, {
        text = pname,
        callback = make_new_profile(util.tableDeepCopy(Configuration.profiles[pname].data))
    })
    end
    local profiles = builder:build()
    local has_profiles = #profiles > 0
    for _, menu_item in ipairs(profiles) do
        menu_item.hold_callback = function()
            UIManager:show(ConfirmBox:new{
                text = "Do you want to delete this profile? This cannot be undone.",
                ok_callback = function()
                    local profile_name = menu_item.text
                    Configuration.profiles[profile_name]:purge()
                    Configuration.profiles[profile_name] = nil
                    if self.ui.menu.menu_items.anki_settings then
                        self.ui.menu.menu_items.anki_settings.sub_item_table = self:buildSettings()
                    else
                        -- TODO this can be removed again after a while, it prevents crashes for old users that still have the patch enabled.
                        UIManager:show(InfoMessage:new { text = "Please disable the custom userpatch. Anki Settings are now available by default under Search (looking glass icon) - Settings", timeout = 20 })
                    end
                    if self.ui.menu.onTapCloseMenu then self.ui.menu:onTapCloseMenu()
                    elseif self.ui.menu.onCloseFileManagerMenu then self.ui.menu:onCloseFileManagerMenu() end
                end
            })
        end
    end
    table.insert(profiles, #profiles+1, { text = "Clone profile from ...", enabled_func = function() return has_profiles end, sub_item_table = profile_names })
    table.insert(profiles, #profiles+1, { text = "Create new profile", callback = make_new_profile({}) })
    return {
        { text = ("Edit profiles"), sub_item_table = profiles },
        { text = ("anki-connect settings"), keep_menu_open = true, callback = function() self:show_connection_widget() end },
        {
            -- where the queue is looked over before it goes anywhere, so it says how
            -- much is in it: this is the one route to Anki, and the count is the nudge
            text_func = function() return ("View notes (%d)"):format(AnkiConnect.notes_count) end,
            enabled_func = function() return AnkiConnect.notes_count > 0 end,
            keep_menu_open = true,
            callback = function() self:show_notes_viewer() end
        },
    }
end

--[[
-- Opens the queue for inspection, under a profile. Which fields make up a note's identity
-- is the profile's business, and the view is where notes are removed or opened in their
-- source book - so
-- without one loaded, a note queued before it carried its own identity would be worked
-- out differently here than it was when it was made, and removing it would release the
-- wrong fingerprint (or none), leaving the word refused as a duplicate ever after.
-- Every other way into the plugin loads a profile for its own reasons; from the file
-- browser there is no document to take one from, and notes made since carry their own.
--]]
function AnkiWidget:show_notes_viewer()
    local function open()
        NotesViewer:show(
            function() self:check_conn(function() AnkiConnect:sync_notes() end) end,
            function() self:refresh_notes_menu() end,
            function(note) self:open_queued_note(note) end
        )
    end
    if self.ui and self.ui.document then
        self:set_profile(open)
    else
        open()
    end
end

function AnkiWidget:clear_queued_note_highlight()
    local active = self.queued_note_highlight
    if not active then
        return
    end
    if active.clear_callback then
        UIManager:unschedule(active.clear_callback)
    end
    self.queued_note_highlight = nil

    local ui = active.ui
    if not ui or ui.document ~= active.document then
        return
    end
    -- Do not remove a selection the reader made after our jump.
    if ui.highlight and ui.highlight.selected_text ~= active.previous_selection then
        return
    end
    if active.mode == "rolling" then
        ui.document:clearSelection()
    elseif active.highlight and active.highlight.temp == active.temp then
        -- ReaderView clears this table on page turns, but also clear it when our
        -- short-lived marker expires while the reader stays on the same page.
        active.highlight.temp = active.previous_temp
    end
    UIManager:setDirty(ui.dialog or ui, "ui")
end

function AnkiWidget:highlight_queued_note_position(ui, position)
    local active = {
        ui = ui,
        document = ui.document,
        mode = position.mode == "paging" and "paging" or "rolling",
    }

    if active.mode == "rolling" then
        if not position.pos1 or not ui.document.getTextFromXPointers then
            return
        end
        active.previous_selection = ui.highlight and ui.highlight.selected_text
        -- This creates KOReader's native, segmented selection for the exact
        -- xpointer range. It is deliberately done after the jump so the range
        -- is drawn on the newly visible text.
        local selected_text = ui.document:getTextFromXPointers(
            position.pos0, position.pos1, true)
        if not selected_text then
            return
        end
    else
        local view_highlight = ui.view and ui.view.highlight
        if not view_highlight or not ui.document.getPageBoxesFromPositions then
            return
        end
        local page_position = position.pos0
        local page = type(page_position) == "table" and page_position.page or page_position
        local boxes = ui.document:getPageBoxesFromPositions(page, position.pos0, position.pos1)
        if not boxes or #boxes == 0 then
            return
        end
        active.highlight = view_highlight
        active.previous_selection = ui.highlight and ui.highlight.selected_text
        active.previous_temp = view_highlight.temp
        active.temp = { [page] = boxes }
        view_highlight.temp = active.temp
    end

    local function clear_callback()
        if self.queued_note_highlight == active then
            self:clear_queued_note_highlight()
        end
    end
    active.clear_callback = clear_callback
    self.queued_note_highlight = active
    UIManager:scheduleIn(QUEUED_NOTE_HIGHLIGHT_SECONDS, clear_callback)
    UIManager:setDirty(ui.dialog or ui, "ui")
end
function AnkiWidget:open_queued_note(note)
    local ReaderUI = require("apps/reader/readerui")
    local position = note and note.position
    if not note or not note.doc_path or not position or not position.pos0 then
        return UIManager:show(InfoMessage:new{
            text = "This note has no saved position in its book.",
            timeout = 4,
        })
    end

    local function jump(ui)
        ui = ui or ReaderUI
        self:clear_queued_note_highlight()
        if position.mode == "paging" then
            local page_position = position.pos0
            local page = type(page_position) == "table" and page_position.page or page_position
            ui:handleEvent(Event:new("GotoPage", page, page_position))
        else
            -- The exact range is highlighted below; omitting the second event
            -- argument also suppresses KOReader's transient margin marker.
            ui:handleEvent(Event:new("GotoXPointer", position.pos0))
        end
        self:highlight_queued_note_position(ui, position)
    end

    if self.ui and self.ui.document and self.ui.document.file == note.doc_path then
        return jump(self.ui)
    end
    if self.ui and self.ui.document and self.ui.switchDocument then
        return self.ui:switchDocument(note.doc_path, nil, jump)
    end
    ReaderUI:showReader(note.doc_path, nil, nil, nil, jump)
end

-- Refresh only an open menu. A newly opened menu evaluates the dynamic text itself.
function AnkiWidget:refresh_notes_menu()
    local menu = self.ui and self.ui.menu
    local menu_container = menu and menu.menu_container
    local menu_widget = menu_container and menu_container[1]
    if menu_widget and menu_widget.updateItems then
        menu_widget:updateItems()
    end
end

function AnkiWidget:check_conn(callback)
    local url = Configuration.url:get_value()
    logger.info("url is:", url)
    if url == nil or #url == 0 then
        return UIManager:show(ConfirmBox:new{
            text = "The anki-connect url does not seem to be configured yet, do you want to open the settings window?",
            ok_callback = function()
                -- TODO maybe this could take the callback and try it again on save
                return self:show_connection_widget()
            end
        })
    end
    callback()
end

function AnkiWidget:load_extensions()
    self.extensions = {} -- contains filenames by numeric index, loaded modules by value
    local ext_directory = DataStorage:getFullDataDir() .. "/plugins/anki.koplugin/extensions/"

    for file in lfs.dir(ext_directory) do
        if file:match("^EXT_.*%.lua") then
            table.insert(self.extensions, file)
            local ext_module = assert(loadfile(ext_directory .. file))()
            self.extensions[file] = ext_module
        end
    end
    table.sort(self.extensions)
end

-- This function is called automatically for all tables extending from Widget
function AnkiWidget:init()
    self:load_extensions()
    -- allow propagating events to ankiconnect, we handle wifi related stuff in there
    table.insert(self, AnkiConnect)
    AnkiConnect.notes_changed_callback = function() self:refresh_notes_menu() end
    AnkiConnect:load_notes()
    AnkiNote:extend {
        ui = self.ui,
        ext_modules = self.extensions
    }

    -- this holds the latest note created by the user!
    self.current_note = nil

    self.ui.menu:registerToMainMenu(self)
    self:handle_events()
    self:register_dict_buttons()
end

function AnkiWidget:extend_doc_settings(filepath, document_properties)
    local _, file = util.splitFilePathName(filepath)
    local file_pattern = "^%[([^%]]-)%]_(.-)_%[([^%]]-)%]%.[^%.]+"
    local f_author, f_title, f_extra = file:match(file_pattern)
    local file_properties = {
        title = f_title,
        author = f_author,
        description = f_extra,
    }
    local get_prop = function(property)
        local d_p, f_p = document_properties[property], file_properties[property]
        local d_len, f_len = d_p and #d_p or 0, f_p and #f_p or 0
        -- if our custom f_p match is more exact, pick that one
        -- e.g. for PDF the title is usually the full filename
        local f_p_more_precise = d_len == 0 or d_len > f_len and f_len ~= 0
        return f_p_more_precise and f_p or d_p
    end
    local metadata = {
        title = get_prop('display_title') or get_prop('title'),
        author = get_prop('author') or get_prop('authors'),
        description = get_prop('description'),
        current_page = function() return self.ui.view.state.page end,
        language = document_properties.language,
        pages = function() return document_properties.pages or self.ui.doc_settings:readSetting("doc_pages") end
    }
    local metadata_mt = {
        __index = function(t, k) return rawget(t, k) or "N/A" end
    }
    logger.dbg("AnkiWidget:extend_doc_settings#", filepath, document_properties, metadata)
    self.ui.document._anki_metadata = setmetatable(metadata, metadata_mt)
end

function AnkiWidget:set_profile(callback)
    local _, file_name = util.splitFilePathName(self.ui.document.file)
    local user_profile = self.known_document_profiles:readSetting(file_name)
    if user_profile and Configuration.profiles[user_profile] then
        local ok, err = pcall(Configuration.load_profile, Configuration, user_profile)
        if not ok then
            return UIManager:show(InfoMessage:new { text = ("Could not load profile %s: %s"):format(user_profile, err), timeout = 4 })
        end
        return callback()
    end

    local info_text = "Choose the profile to link with this document."
    if user_profile then
        info_text = ("Document was associated with the non-existing profile '%s'.\nPlease pick a different profile to link with this document."):format(user_profile)
    end

    self:show_profiles_widget {
        title_text = "Set user profile",
        info_text = info_text,
        cb = function()
            callback()
        end
    }
end

--[[
-- The dictionary popup stays open after a note was made, so relabel its button and grey
-- it out: that is the confirmation the add gets, and it says that tapping again would do
-- nothing. It says queued rather than added because that is what happened - the note goes
-- to Anki when the user syncs. Holding keeps working: the config widget is how the note
-- that was just made is edited, which is what one wants right afterwards. Queued notes
-- can be removed from the notes viewer.
--]]
function AnkiWidget:mark_add_to_anki_button(popup_dict)
    local button = popup_dict.button_table and popup_dict.button_table:getButtonById("add_to_anki")
    if not button then
        return
    end
    button.allow_hold_when_disabled = true
    button:setText(_("Queued for Anki"), button.width)
    button:disable()
    UIManager:setDirty(popup_dict, function()
        return "ui", button.dimen
    end)
end

-- the note goes into the local queue, so the anki-connect settings are not consulted
-- here: they are what the sync needs, and the sync is where the user is asked for them
function AnkiWidget:add_note_with_feedback(note_builder, on_added)
    self:set_profile(function()
        local note = note_builder()
        if not note then
            return
        end
        local ok, status = AnkiConnect:add_note(note)
        -- A refused duplicate is a note the book has already given, which is just what
        -- the disabled button says. Only a note that failed to be built at all leaves
        -- nothing behind, and keeps the button tappable. The status is passed on because
        -- confirming an add and confirming a duplicate are not the same message.
        if on_added and (ok or status == "duplicate_note") then
            on_added(status)
        end
    end)
end

-- Registers the "Add to Anki" button with the dictionary popup. The popup owns the
-- layout: the button lands in the user configurable set, and can be moved or hidden
-- through the dictionary's "Customize buttons" menu.
function AnkiWidget:register_dict_buttons()
    if not self.ui or not self.ui.dictionary then
        return
    end
    self.ui.dictionary:addToDictButtons {
        id = "add_to_anki",
        menu_text = _("Add to Anki"),
        text = _("Add to Anki"),
        font_bold = true,
        insert_first = true,
        show_func = function()
            -- notes are built from the surrounding text, which only exists while reading
            if not self.ui.document then
                return false
            end
            -- lookups made from within the vocabulary builder have no reading context
            if self.ui.vocabbuilder and UIManager:isWidgetShown(self.ui.vocabbuilder.widget) then
                return false
            end
            return true
        end,
        callback = function(popup_dict)
            self:add_note_with_feedback(function()
                self.current_note = AnkiNote:new(popup_dict)
                return self.current_note
            end, function()
                self:mark_add_to_anki_button(popup_dict)
            end)
        end,
        hold_callback = function(popup_dict)
            self:set_profile(function()
                self.current_note = AnkiNote:new(popup_dict)
                self:show_config_widget()
            end)
        end,
    }
end

function AnkiWidget:handle_events()
    -- these all return false so that the event goes up the chain, other widgets might wanna react to these events
    self.onCloseWidget = function()
        self:clear_queued_note_highlight()
        self.known_document_profiles:close()
        Configuration:save()
        -- the reader has flushed the book's settings by now, let go of them
        AnkiConnect:unload_fingerprints()
        AnkiConnect.notes_changed_callback = nil
    end

    self.onSuspend = function()
        self:clear_queued_note_highlight()
        Configuration:save()
    end

    self.onReaderReady = function(obj, doc_settings)
        if self.ui.highlight and self.ui.highlight.addToHighlightDialog then
            self.ui.highlight:addToHighlightDialog("20_add_to_anki", function(highlight)
                return {
                    text = _("Add to Anki"),
                    enabled = highlight.selected_text ~= nil,
                    callback = function()
                        self:add_note_with_feedback(function()
                            if not highlight.selected_text or #highlight.selected_text.text == 0 then
                                UIManager:show(InfoMessage:new { text = "No text selected.", timeout = 3 })
                                return nil
                            end
                            self.current_note = AnkiNote:new_from_highlight(highlight.selected_text)
                            return self.current_note
                        end, function(status)
                            -- a highlight has no button to grey out, and the dialog it
                            -- was made from is about to close, so this is the only place
                            -- it can be confirmed. A duplicate has said its piece already.
                            if status ~= "duplicate_note" then
                                UIManager:show(InfoMessage:new { text = "Queued for Anki.", timeout = 2 })
                            end
                        end)
                        highlight:onClose()
                    end,
                }
            end)
        end
        local filepath = doc_settings.data.doc_path
        AnkiConnect:load_fingerprints(doc_settings, filepath)
        self:extend_doc_settings(filepath, self.ui.bookinfo:getDocProps(filepath, doc_settings.doc_props))
    end

    self.onBookMetadataChanged = function(obj, updated_props)
        -- no need to try doing this when a doc was modified from the file browser, we'll redo this on doc load
        if not self.ui.document then return end
        local filepath = updated_props.filepath
        self:extend_doc_settings(filepath, self.ui.bookinfo:getDocProps(filepath, updated_props.doc_props))
    end
end

return AnkiWidget
