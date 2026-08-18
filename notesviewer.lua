local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local KeyValuePage = require("ui/widget/keyvaluepage")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local util = require("util")
local AnkiConnect = require("ankiconnect")
local conf = require("anki_configuration")

--[[
-- The queue of notes waiting for Anki, as a table one can go through: the word a note was
-- made from on the left, the passage it sits in on the right. It is the one place where
-- what is about to be sent can be looked over, opened in its source book or thrown out,
-- which matters
-- because the queue is where a note lives its whole life until the user syncs.
--
-- Notes from every book are in here, not only the one being read: it is one queue, and a
-- reader who moves between books would otherwise not find half of what they made.
--]]
local NotesViewer = {}

-- How much of the passage a row carries. The word can sit anywhere in a sentence, so the
-- row is a window around it rather than its first n characters, and both ends are cut.
-- Measured in the room a character takes rather than in bytes or characters; the widget
-- trims whatever still doesn't fit.
local PREVIEW_BEFORE, PREVIEW_AFTER = 24, 36
local ELLIPSIS = "…"

-- Japanese and Chinese glyphs take about twice the room a Latin one does, and a row that
-- counted them the same would come out twice as long for them. Same first byte test the
-- context extraction counts its words with.
local function char_width(ch)
    local b = ch:byte(1) or 0
    return ((b >= 0xE3 and b <= 0xE9) or b == 0xEF) and 2 or 1
end

-- one line of plain text out of a field: the tags are how it is laid out on the card, and
-- a paragraph break is worth a space here rather than nothing at all
local function to_plain_text(html)
    return (html:gsub("<br%s*/?>", " "):gsub("<[^>]*>", ""):gsub("%s+", " "))
end

local function trim(text)
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function escape_html(text)
    return tostring(text):gsub("&", "&amp;"):gsub("<", "&lt;")
        :gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&#39;")
end

local function plain_field_html(value)
    local text = tostring(value):gsub("\r\n?", "\n")
    return escape_html(text):gsub("\n", "<br/>")
end

local function file_name(path)
    return path and path:match("[^/\\]+$") or nil
end
local function text_width(text)
    local width = 0
    for _, ch in ipairs(util.splitToChars(text)) do width = width + char_width(ch) end
    return width
end

-- the end of a string, and the start of one, up to what fits in `budget` - always on a
-- character boundary, since the text is UTF-8 and half a character is rubbish
local function last_columns(text, budget)
    local chars = util.splitToChars(text)
    local used, i = 0, #chars
    while i >= 1 and used + char_width(chars[i]) <= budget do
        used = used + char_width(chars[i])
        i = i - 1
    end
    if i < 1 then return text end
    return ELLIPSIS .. table.concat(chars, "", i + 1, #chars)
end

local function first_columns(text, budget)
    local chars = util.splitToChars(text)
    local used, i = 0, 1
    while i <= #chars and used + char_width(chars[i]) <= budget do
        used = used + char_width(chars[i])
        i = i + 1
    end
    if i > #chars then return text end
    return table.concat(chars, "", 1, i - 1) .. ELLIPSIS
end

--[[
-- Which fields of a note hold the word and the passage.
--
-- The note is asked first, and is the only answer that can be trusted: the field names
-- belong to a profile, a note can be made under one profile and looked at under another,
-- and this view can be opened with no profile loaded at all - which is what a queue
-- shared by every book is bound to run into.
--
-- A note queued before the names were recorded is worked out instead. The passage is the
-- field the looked up word was marked up in, since that is what puts it in bold on the
-- card; the definition can carry marked up text of its own, so it is kept out of it by
-- the wrapper the plugin builds definitions with. Only a note with no word to go by (a
-- highlight) is left to the profile in force, which is right whenever there is one.
--]]
local DEFINITION_MARKER = '<div class="definition"'

local function infer_context_field(note, word_field)
    local word = word_field and note.data.fields[word_field]
    local marked = word and #word > 0 and ("<b>%s</b>"):format(word) or nil
    local fallback
    for name, value in pairs(note.data.fields) do
        if name ~= word_field and type(value) == "string"
            and not value:find(DEFINITION_MARKER, 1, true) then
            if marked and value:find(marked, 1, true) then
                return name
            end
            -- an extension is free to rewrite the word field after the passage was marked
            -- up, so a passage with any word marked up in it will do as a second best
            if not fallback and value:find("<b>", 1, true) then
                fallback = name
            end
        end
    end
    return fallback
end

local function note_fields(note)
    local word_field = note.identifier
    local context_field = note.context_field
        or infer_context_field(note, word_field)
        or conf.context_field:get_value()
    return word_field, context_field
end

local function field_value(note, field_name)
    return field_name and note.data.fields[field_name] or nil
end

--[[
-- The passage cut down to one row, centred on the word. The word is marked up in the
-- field (it is what is bold on the card), which is also how we find where it sits.
--]]
local function context_preview(context)
    if not context or #context == 0 then
        return ""
    end
    local before, word, after = context:match("^(.-)<b>(.-)</b>(.*)$")
    if not word then
        -- a highlight carries no looked up word, so there is nothing to centre on: the
        -- row is the start of the passage, and gets the whole budget to itself
        return trim(first_columns(to_plain_text(context), PREVIEW_BEFORE + PREVIEW_AFTER))
    end
    local head, tail = to_plain_text(before), to_plain_text(after)
    -- what the text in front of the word did not need is given to the text after it, so
    -- a word at the start of its sentence still fills the row rather than half of it
    local slack = math.max(0, PREVIEW_BEFORE - text_width(head))
    return trim(last_columns(head, PREVIEW_BEFORE)
             .. to_plain_text(word)
             .. first_columns(tail, PREVIEW_AFTER + slack))
end

function NotesViewer:rows()
    local rows = {}
    for i, note in ipairs(AnkiConnect.local_notes) do
        local word_field, context_field = note_fields(note)
        local word = field_value(note, word_field) or ""
        rows[i] = {
            trim(to_plain_text(word)),
            context_preview(field_value(note, context_field)),
            callback = function() self:show_note_details(i) end,
            hold_callback = function() self:show_actions(i) end,
        }
    end
    return rows
end

-- the queue changed under it, so the page is built again from what is there now
function NotesViewer:refresh()
    if #AnkiConnect.local_notes == 0 then
        return self:close()
    end
    if self.page then
        UIManager:close(self.page)
        self.page = nil
    end
    self:show()
end

function NotesViewer:close()
    if self.page then
        UIManager:close(self.page)
        self.page = nil
    end
end

local function detail_section(title, value, is_html)
    if not value or #value == 0 then
        return ""
    end
    local content = is_html and value or plain_field_html(value)
    return ("<h2>%s</h2><p>%s</p>"):format(escape_html(title), content)
end

function NotesViewer:show_note_details(index)
    local note = AnkiConnect.local_notes[index]
    if not note then
        return self:refresh()
    end

    local fields = note.data and note.data.fields or {}
    local word_field, context_field = note_fields(note)
    local word = field_value(note, word_field) or ""
    local context = field_value(note, context_field)
    local definition_field = conf.def_field:get_value()
    local metadata_field = conf.meta_field:get_value()
    local translated_field = conf.translated_context_field:get_value()
    local title = trim(to_plain_text(word))
    local content = {
        detail_section("Context", context, true),
        detail_section("Definition", field_value(note, definition_field), true),
        detail_section("Translated context", field_value(note, translated_field), false),
        detail_section("Metadata", field_value(note, metadata_field), false),
    }

    -- Keep fields added by extensions visible without duplicating the standard ones.
    local shown_fields = {}
    for _, name in ipairs({ word_field, context_field, definition_field,
        metadata_field, translated_field }) do
        if name then
            shown_fields[name] = true
        end
    end
    local extra_fields = {}
    for name, value in pairs(fields) do
        if not shown_fields[name] and type(value) == "string" and #value > 0 then
            table.insert(extra_fields, name)
        end
    end
    table.sort(extra_fields)
    for _, name in ipairs(extra_fields) do
        table.insert(content, detail_section(name, fields[name], false))
    end

    local info = {}
    if note.data.deckName then
        table.insert(info, "Deck: " .. plain_field_html(note.data.deckName))
    end
    if note.data.modelName then
        table.insert(info, "Note type: " .. plain_field_html(note.data.modelName))
    end
    if note.data.tags and #note.data.tags > 0 then
        table.insert(info, "Tags: " .. plain_field_html(table.concat(note.data.tags, ", ")))
    end
    local source = file_name(note.doc_path)
    if source then
        table.insert(info, "Source: " .. plain_field_html(source))
    end
    if #info > 0 then
        table.insert(content, 1, "<p>" .. table.concat(info, "<br/>") .. "</p>")
    end

    local details
    details = TextViewer:new {
        title = #title > 0 and title or "Queued note",
        text = table.concat(content),
        text_format = "html",
        text_type = "book_info",
        buttons_table = {
            { {
                text = "Open in book",
                enabled = note.position and note.position.pos0 ~= nil and self.on_open ~= nil,
                callback = function()
                    UIManager:close(details)
                    self:close()
                    if self.on_open then self.on_open(note) end
                end,
            }, {
                text = "Remove note",
                callback = function()
                    UIManager:close(details)
                    self:confirm_remove(index)
                end,
            }, {
                text = "Close",
                callback = function() UIManager:close(details) end,
            } },
        },
    }
    UIManager:show(details)
end
-- what can be done to one row, as the button rows a ButtonDialog takes
function NotesViewer:actions_for(index, close)
    local note = AnkiConnect.local_notes[index]
    if not note then
        return {}
    end
    local function act(fn)
        return function()
            close()
            fn()
        end
    end
    return {
        {{
            text = "Open in book",
            id = "open_in_book",
            enabled = note.position and note.position.pos0 ~= nil and self.on_open ~= nil,
            callback = act(function()
                self:close()
                if self.on_open then self.on_open(note) end
            end),
        }},
        {{
            text = "Remove note",
            id = "remove_note",
            callback = act(function() self:confirm_remove(index) end),
        }},
    }
end

function NotesViewer:show_actions(index)
    if not AnkiConnect.local_notes[index] then
        return self:refresh()
    end
    local dialog
    dialog = ButtonDialog:new{
        buttons = self:actions_for(index, function() UIManager:close(dialog) end),
    }
    UIManager:show(dialog)
end

function NotesViewer:confirm_remove(index)
    local note = AnkiConnect.local_notes[index]
    if not note then
        return self:refresh()
    end
    local word_field = note_fields(note)
    local word = trim(to_plain_text(field_value(note, word_field) or ""))
    UIManager:show(ConfirmBox:new{
        text = #word > 0 and ("Remove the note for '%s'?"):format(word) or "Remove this note?",
        ok_text = "Remove",
        ok_callback = function()
            AnkiConnect:remove_queued_note(index)
            self:refresh()
        end,
    })
end

--[[
-- @param on_sync: called when the user asks for the queue to go to Anki. Syncing needs
-- the connection settings, which the plugin's widget is the one that knows how to ask
-- for, so where the notes go is its business rather than this view's.
-- @param on_open: opens a queued note at its saved source position.
--]]
function NotesViewer:show(on_sync, on_close, on_open)
    self.on_sync = on_sync or self.on_sync
    self.on_close = on_close or self.on_close
    self.on_open = on_open or self.on_open
    local rows = self:rows()
    if #rows == 0 then
        return self:close()
    end
    self.page = KeyValuePage:new{
        title = ("Notes waiting for Anki (%d)"):format(#rows),
        kv_pairs = rows,
        -- the title bar carries the two things done to the queue as a whole: send it
        -- off (the tick, on the left) or leave it be (the close button, on the right)
        title_bar_left_icon = "check",
        title_bar_left_icon_tap_callback = function()
            self:close()
            if self.on_sync then self.on_sync() end
        end,
        title_bar_left_icon_hold_callback = function()
            UIManager:show(InfoMessage:new{ text = "Send these notes to Anki.", timeout = 3 })
        end,
        close_callback = function()
            self.page = nil
            if self.on_close then self.on_close() end
        end,
    }
    UIManager:show(self.page)
end

return NotesViewer
