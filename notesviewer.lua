local ButtonDialog = require("ui/widget/buttondialog")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local Menu = require("ui/widget/menu")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextViewer = require("ui/widget/textviewer")
local UIManager = require("ui/uimanager")
local util = require("util")
local AnkiConnect = require("ankiconnect")
local conf = require("anki_configuration")

--[[
-- The queue of notes waiting for Anki, as a compact list grouped by source book. It is
-- the one place where what is about to be sent can be looked over, opened in its source
-- book or thrown out, which matters because the queue is where a note lives its whole
-- life until the user syncs.
--
-- Notes from every book are in here, not only the one being read: it is one queue, and a
-- reader who moves between books would otherwise not find half of what they made.
--]]
local NotesViewer = {}

-- How much of the passage a row carries. The word can sit anywhere in a sentence, so the
-- row is a window around it rather than its first n characters, and both ends are cut.
-- The menu wraps this into a compact two-to-three-line row.
local PREVIEW_BEFORE, PREVIEW_AFTER = 40, 60
local PREVIEW_TOTAL = PREVIEW_BEFORE + PREVIEW_AFTER
local ELLIPSIS = "…"
local SENTENCE_ENDINGS = { ".", "!", "?", "。", "！", "？" }

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
local function last_sentence_end(text)
    local last = 0
    for _, ending in ipairs(SENTENCE_ENDINGS) do
        local start = 1
        while true do
            local found = text:find(ending, start, true)
            if not found then break end
            last = math.max(last, found + #ending - 1)
            start = found + #ending
        end
    end
    return last
end

local function first_sentence_end(text)
    local first
    for _, ending in ipairs(SENTENCE_ENDINGS) do
        local found = text:find(ending, 1, true)
        if found and (not first or found < first) then
            first = found + #ending - 1
        end
    end
    return first
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
    local word_field = note.identifier or conf.word_field:get_value()
    local context_field = note.context_field
        or infer_context_field(note, word_field)
        or conf.context_field:get_value()
    return word_field, context_field
end

local function field_value(note, field_name)
    return field_name and note.data.fields[field_name] or nil
end

-- The passage cut down to a few wrapped lines, centred on the word and kept within its
-- sentence where possible. PTF is KOReader's lightweight bold markup for TextBoxWidget.
local function context_preview(context)
    if not context or #context == 0 then
        return ""
    end
    local before, word, after = context:match("^(.-)<b>(.-)</b>(.*)$")
    if not word then
        -- A highlight carries no looked-up word. Keep the beginning of its selected text,
        -- but do not cut a short first sentence in half.
        local text = trim(to_plain_text(context))
        local sentence_end = first_sentence_end(text)
        if sentence_end and text_width(text:sub(1, sentence_end)) <= PREVIEW_TOTAL
            and sentence_end < #text then
            return text:sub(1, sentence_end) .. ELLIPSIS
        end
        return trim(first_columns(text, PREVIEW_TOTAL))
    end
    local head, tail = to_plain_text(before), to_plain_text(after)
    local sentence_start = last_sentence_end(head)
    local sentence_end = first_sentence_end(tail)
    local sentence_head = head:sub(sentence_start + 1)
    local sentence_tail = sentence_end and tail:sub(1, sentence_end) or tail
    local omitted_before = sentence_start > 0
    local omitted_after = sentence_end and sentence_end < #tail
    local marked_word = TextBoxWidget.PTF_BOLD_START .. to_plain_text(word)
        .. TextBoxWidget.PTF_BOLD_END

    -- Show the whole containing sentence when it is reasonably short. Otherwise, keep
    -- the cut centred on the word and visibly mark omitted neighbouring sentences.
    local sentence_text = sentence_head .. marked_word .. sentence_tail
    if text_width(sentence_head .. to_plain_text(word) .. sentence_tail) <= PREVIEW_TOTAL then
        return trim((omitted_before and ELLIPSIS or "") .. sentence_text
            .. (omitted_after and ELLIPSIS or ""))
    end

    local head_preview = last_columns(sentence_head, PREVIEW_BEFORE)
    local tail_preview = first_columns(sentence_tail, PREVIEW_AFTER)
    return trim(head_preview .. marked_word .. tail_preview)
end

function NotesViewer:rows()
    local entries = {}
    local latest_by_book = {}
    for i, note in ipairs(AnkiConnect.local_notes) do
        local word_field, context_field = note_fields(note)
        local word = field_value(note, word_field) or ""
        local word_text = trim(to_plain_text(word))
        local entry = {
            index = i,
            book = file_name(note.doc_path) or "Unknown book",
            book_key = note.doc_path or ("unknown:" .. i),
            word = word_text,
            context = context_preview(field_value(note, context_field)),
        }
        table.insert(entries, entry)
        if not latest_by_book[entry.book_key] or entry.index > latest_by_book[entry.book_key] then
            latest_by_book[entry.book_key] = entry.index
        end
    end

    -- Keep notes grouped by source book, while putting the book containing the newest
    -- queued note first and showing that book's newest note at the top of its group.
    table.sort(entries, function(a, b)
        if a.book_key == b.book_key then
            return a.index > b.index
        end
        if latest_by_book[a.book_key] == latest_by_book[b.book_key] then
            return a.book < b.book
        end
        return latest_by_book[a.book_key] > latest_by_book[b.book_key]
    end)

    local rows = {}
    local current_book_key
    for _, entry in ipairs(entries) do
        if entry.book_key ~= current_book_key then
            current_book_key = entry.book_key
            table.insert(rows, {
                text = entry.book,
                dim = true,
                select_enabled = false,
            })
        end

        local label = entry.word
        table.insert(rows, {
            -- Menu uses TextBoxWidget internally, so the looked-up word remains bold
            -- while the context can wrap into the following lines.
            text = TextBoxWidget.PTF_HEADER .. TextBoxWidget.PTF_BOLD_START .. label
                .. TextBoxWidget.PTF_BOLD_END .. "  " .. entry.context,
            note_index = entry.index,
            callback = function()
                -- Menu invokes close_callback after this callback, but that callback
                -- only clears self.page. Close the actual menu before putting the
                -- details viewer on top, otherwise the overview can remain underneath
                -- and reappear when the details viewer is closed.
                self:close()
                self:show_note_details(entry.index)
            end,
        })
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
    local content = {}
    local function append_content(value)
        if value and #value > 0 then
            table.insert(content, value)
        end
    end
    local function append_break()
        if #content > 0 and content[#content] ~= "<hr/>" then
            append_content("<hr/>")
        end
    end
    if context and #context > 0 then
        append_content("<div>" .. context .. "</div>")
    end

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
    if #info > 0 then
        append_break()
        append_content("<div>" .. table.concat(info, "<br/>") .. "</div>")
        append_break()
    end

    append_content(detail_section("Definition", field_value(note, definition_field), true))
    append_content(detail_section("Translated context", field_value(note, translated_field), false))
    append_content(detail_section("Metadata", field_value(note, metadata_field), false))
    for _, name in ipairs(extra_fields) do
        append_content(detail_section(name, fields[name], false))
    end
    local source = file_name(note.doc_path)
    if source then
        append_break()
        append_content("<div>Source: " .. plain_field_html(source) .. "</div>")
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
                    -- Keep the confirmation above the details view.  Closing the
                    -- viewer here left nothing to return to when removal was
                    -- cancelled.
                    self:confirm_remove(index, function()
                        UIManager:close(details)
                    end)
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

-- `after_remove` is used by the details view, which must stay open beneath the
-- confirmation until the user actually removes the note.
function NotesViewer:confirm_remove(index, after_remove)
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
            if AnkiConnect:remove_queued_note(index) then
                if after_remove then after_remove() end
                self:refresh()
            end
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
    local note_count = #AnkiConnect.local_notes
    local rows = self:rows()
    if note_count == 0 then
        return self:close()
    end
    self.page = Menu:new {
        title = ("Notes waiting for Anki (%d)"):format(note_count),
        item_table = rows,
        items_max_lines = 3,
        multilines_forced = true,
        is_popout = false,
        onMenuHold = function(_, item)
            if item.note_index then
                self:show_actions(item.note_index)
            end
        end,
        -- the title bar carries the two things done to the queue as a whole: send it
        -- off (the tick, on the left) or leave it be (the close button, on the right)
        title_bar_left_icon = "check",
        onLeftButtonTap = function()
            self:close()
            if self.on_sync then self.on_sync() end
        end,
        onLeftButtonHold = function()
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
