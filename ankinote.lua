local logger = require("logger")
local util = require("util")
local u = require("lua_utils/utils")
local conf = require("anki_configuration")
local WordContext = require("wordcontext")

local LANG_NOT_SET_ERROR = "Neither the dictionary, nor the document have its language set. See the FAQ section in the plugin's README."
local AnkiNote = {
}

--[[
-- Determine trimmed word context for consecutive lookups.
-- When a user updates the text in a dictionary popup window and thus gets a new popup
-- the word selected in the book won't reflect the word in the dictionary.
-- We want to know if last dict lookup is contained in first dict lookup.
-- e.g.: '広大な' -> trimmed to '広大' -> context is '' (before), 'な' (after)
--]]
function AnkiNote:set_word_trim()
    local list = self.popup_dict.window_list
    if #list == 1 then
        return
    end
    local orig, last = list[1].word, list[#list].word
    logger.dbg(("first popup dict: %s, last dict : %s"):format(orig, last))
    local s_idx, e_idx = orig:find(last, 1, true)
    if not s_idx then
        self.contextual_lookup = false
    else
        self.word_trim = { before = orig:sub(1, s_idx-1), after = orig:sub(e_idx+1, #orig) }
    end
end


function AnkiNote:convert_to_HTML(opts)
    local wrapper_template = opts.wrapper_template or "<div class=\"%s\"><ol>%s</ol></div>"
    local entry_template = opts.entry_template or "<li dict=\"%s\">%s</li>"
    local list_items = {}
    for _,entry in ipairs(opts.entries) do
        table.insert(list_items, opts.build(entry, entry_template))
    end
    return wrapper_template:format(opts.class, table.concat(list_items))
end

-- [[
-- Create metadata string about the document the word came from.
-- ]]
function AnkiNote:get_metadata()
    local meta = self.ui.document._anki_metadata
    return string.format("%s - %s (%d/%d)", meta.author, meta.title, meta:current_page(), meta.pages())
end

function AnkiNote:get_word_context()
    if not self.contextual_lookup then
        return self.popup_dict.word
    end
    local provider = self.ui.document.provider
    if self.ui.document.getSelectedWordContext then
        local before, after = self:build_context()
        return before .. "<b>" .. self.popup_dict.word .. "</b>" .. after
    elseif provider == "mupdf" then -- CBZ
        local ocr_text = self.ui['Mokuro'] and self.ui['Mokuro']:get_selection()
        logger.info("selected text: ", ocr_text)
        -- TODO is trim relevant here?
        return ocr_text or self.popup_dict.word
    end
end

-- character sets and limits the context extraction runs with, see the plugin settings
function AnkiNote:context_opts()
    if not self.cached_context_opts then
        self.cached_context_opts = {
            terminators = conf.sentence_terminators:get_value(),
            quotes = conf.quotation_marks:get_value(),
            abbreviations = conf.abbreviations:get_value(),
            min_words = conf.min_context_words:get_value(),
            max_sentences = conf.max_context_sentences:get_value(),
        }
    end
    return self.cached_context_opts
end

--[[
-- Runs an extraction, refilling the context buffer when it turned out to be too small.
-- Refilling means asking the document for more text, which is not cheap on an e-reader,
-- so the buffer starts out large enough for the usual case and grows in big steps.
--]]
function AnkiNote:run_extraction(extract)
    local before, after, need_more = extract()
    for _ = 1, 2 do
        if not need_more then break end
        local size_before = #self.prev_context + #self.next_context
        self.context_size = self.context_size * 3
        self:init_context_buffer(self.context_size)
        -- no growth means we're at the start/end of the document: this is all there is
        if #self.prev_context + #self.next_context <= size_before then break end
        before, after, need_more = extract()
    end
    -- these 2 variables can be used to detect if any content was prepended / appended
    self.has_prepended_content = #before > 0
    self.has_appended_content = #after > 0
    -- apparently the mupdf provider does not add the trailing/leading spaces, so we have to do it ourselves
    if self.ui.document.provider == 'mupdf' then
        if #before > 0 then before = before .. ' ' end
        if #after > 0 then after = ' ' .. after end
    end
    return before, after
end

function AnkiNote:build_context()
    -- a note may ask for its context more than once (context field, translation), and
    -- extracting it can involve reading from the document again: only do that once
    if self.cached_context then
        return self.cached_context[1], self.cached_context[2]
    end
    local before, after
    if self.context then -- the user picked the amount of context by hand
        before, after = self:get_custom_context(unpack(self.context))
    else
        local opts, word = self:context_opts(), self.popup_dict.word
        before, after = self:run_extraction(function()
            return WordContext.extract(self.prev_context, word, self.next_context, opts)
        end)
    end
    self.cached_context = { before, after }
    return before, after
end

--[[
-- Returns the context before and after the lookup word, the amount of context depends on the following parameters
-- @param pre_s: amount of sentences prepended
-- @param pre_c: amount of characters prepended
-- @param post_s: amount of sentences appended
-- @param post_c: amount of characters appended
--]]
function AnkiNote:get_custom_context(pre_s, pre_c, post_s, post_c)
    logger.info("AnkiNote#get_custom_context()", pre_s, pre_c, post_s, post_c)
    local opts, word = self:context_opts(), self.popup_dict.word
    return self:run_extraction(function()
        return WordContext.manual(self.prev_context, word, self.next_context, opts, pre_s, pre_c, post_s, post_c)
    end)
end

function AnkiNote:get_picture_context()
    local meta = self.ui.document._anki_metadata
    if not meta then
        return
    end
    local provider, plugin = self.ui.document.provider, self.ui['Mokuro']
    -- we only add pictures for CBZ (handled by ocr_popup widget)
    if provider == "mupdf" and plugin then
        local fn = string.format("%s/%s_%s.jpg", self.settings_dir, meta.title, os.date("%Y-%m-%d %H-%M-%S"))
        return plugin:get_context_picture(fn) and fn or nil
    end
end

function AnkiNote:run_extensions(note)
    for _, extension in ipairs(self.extensions) do
        note = extension:run(note)
    end
    return note
end

function AnkiNote:get_definition()
    return self:convert_to_HTML {
        entries = { self.popup_dict.results[self.popup_dict.dict_index] },
        class = "definition",
        build = function(entry, entry_template)
            local def = entry.definition
            if entry.is_html then -- try adding dict name to opening div tag (if present)
                -- gsub wrapped in () so it only gives us the first result, and discards the index (2nd arg.)
                return (def:gsub("(<div)( ?)", string.format("%%1 dict=\"%s\"%%2", entry.dict), 1))
            end
            return entry_template:format(entry.dict, (def:gsub("\n", "<br>")))
        end
    }
end

function AnkiNote:build()
    if self.is_highlight_note then
        return self:build_highlight_note()
    end
    local fields = {
        [conf.word_field:get_value()] = self.popup_dict.word,
        [conf.def_field:get_value()] = self:get_definition()
    }
    local optional_fields = {
        [conf.context_field] = function() return self:get_word_context() end,
        [conf.meta_field]    = function() return self:get_metadata() end,
    }
    for opt,fn in pairs(optional_fields) do
        local field_name = opt:get_value()
        if field_name then
            fields[field_name] = fn()
        end
    end
    local note = {
        deckName = conf.deckName:get_value(),
        modelName = conf.modelName:get_value(),
        fields = fields,
        options = {
            allowDuplicate = conf.allow_dupes:get_value(),
            duplicateScope = conf.dupe_scope:get_value(),
        },
        tags = self.tags,
    }
    return {
        -- actual table passed to anki-connect later
        data = self:run_extensions(note),
        -- some fields require an internet connection, which we may not have at this point
        -- all info needed to populate them is stored as a callback, which is called when a connection is available
        field_callbacks = {
            audio = {
                func = "set_forvo_audio",
                field_name = conf.audio_field:get_value(),
                args = { self.popup_dict.word, self:get_language() }
            },
            picture = {
                func = "set_image_data",
                field_name = conf.image_field:get_value(),
                args = { self:get_picture_context() }
            },
            fields = {
                func = "set_translated_context",
                field_name = conf.translated_context_field:get_value(),
                args = { fields[conf.context_field:get_value()] or self:get_word_context(), self:get_language() }
            },
        },
        -- used as id to detect duplicates when storing notes offline
        identifier = conf.word_field:get_value(),
        -- the book this came from: a queued note outlives the session that made it, and
        -- dropping it again means taking its fingerprint back out of that book's sidecar
        doc_path = self.ui.document.file,
    }
end

function AnkiNote:build_highlight_note()
    local context = self:get_word_context() or self.popup_dict.word
    local fields = {
        [conf.word_field:get_value()] = "",
        [conf.def_field:get_value()] = "",
    }
    local optional_fields = {
        [conf.context_field] = function() return context end,
        [conf.meta_field]    = function() return self:get_metadata() end,
    }
    for opt,fn in pairs(optional_fields) do
        local field_name = opt:get_value()
        if field_name then
            fields[field_name] = fn()
        end
    end
    local note = {
        deckName = conf.deckName:get_value(),
        modelName = conf.modelName:get_value(),
        fields = fields,
        options = {
            allowDuplicate = conf.allow_dupes:get_value(),
            duplicateScope = conf.dupe_scope:get_value(),
        },
        tags = self.tags,
    }
    return {
        data = note,
        field_callbacks = {},
        identifier = conf.word_field:get_value(),
        doc_path = self.ui.document.file,
    }
end

function AnkiNote:get_language()
    local ifo_lang = self.selected_dict.ifo_lang
    local language = ifo_lang and ifo_lang.lang_in or rawget(self.ui.document._anki_metadata, 'language')
    if not language then
        local selected_dict_name = self.popup_dict.results[self.popup_dict.dict_index].dict
        local document_title = rawget(self.ui.document._anki_metadata, "title")
        error(LANG_NOT_SET_ERROR:format(self.popup_dict.word, selected_dict_name, document_title), 0)
    end
    return language
end

--[[
-- Loads the text around the selection. Newlines are kept: a paragraph break tells us
-- where another speaker starts, which is the one boundary in a novel we can rely on.
--]]
function AnkiNote:init_context_buffer(size)
    logger.info(("(re)initializing context buffer with size: %d"):format(size))
    local prev_c, next_c = self.ui.highlight:getSelectedWordContext(size)
    -- pass trimmed word context along to be modified
    self.prev_context = WordContext.clean(prev_c) .. self.word_trim.before
    self.next_context = self.word_trim.after .. WordContext.clean(next_c)
    logger.info(("after reinit: prev context = %d bytes, next context = %d bytes"):format(#self.prev_context, #self.next_context))
end

function AnkiNote:set_custom_context(pre_s, pre_c, post_s, post_c)
    self.context = { pre_s, pre_c, post_s, post_c }
    self.cached_context = nil
end

function AnkiNote:add_tags(tags)
    for _,t in ipairs(tags) do
        table.insert(self.tags, t)
    end
end

-- each user extension gets access to the AnkiNote table as well
function AnkiNote:load_extensions()
    self.extensions = {}
    local extension_set = u.to_set(conf.enabled_extensions:get_value())
    for _, ext_filename in ipairs(self.ext_modules) do
        if extension_set[ext_filename] then
            local module = self.ext_modules[ext_filename]
            table.insert(self.extensions, setmetatable(module, { __index = function(t, v) return rawget(t, v) or self[v] end }))
        end
    end
end

-- This function should be called before using the 'class' at all
function AnkiNote:extend(opts)
    -- dict containing various settings about the current state
    self.ui = opts.ui
    -- used to save screenshots in (CBZ only)
    self.settings_dir = opts.settings_dir
    -- used to store extension functions to run
    self.ext_modules = opts.ext_modules
    return self
end

function AnkiNote:new(popup_dict)
    local new = {
        -- amount of words fetched on each side of the selection. The document walks
        -- one word at a time to find them, so this is not free: it is sized to hold
        -- the sentences we may need (see max_context_sentences) in a single fetch.
        context_size = 60,
        popup_dict = popup_dict,
        selected_dict = popup_dict.results[popup_dict.dict_index],
        -- indicates that popup_dict relates to word in book
        -- this can still be set to false later when the user looks up a word in a book, but then modifies the looked up word
        contextual_lookup = self.ui.highlight.selected_text ~= nil,
        word_trim = { before = "", after = "" },
        tags = { "KOReader" },
    }
    local new_mt = {}
    function new_mt.__index(t, v)
        return rawget(t, v) or self[v]
    end

    local note = setmetatable(new, new_mt)
    note:set_word_trim()
    note:load_extensions()
    -- TODO this can be delayed
    if note.contextual_lookup then
        note:init_context_buffer(note.context_size)
        -- note.context stays nil: the amount of context is worked out automatically
        -- until the user picks it by hand in the context menu
    end
    return note
end

function AnkiNote:new_from_highlight(selected_text)
    local selected = selected_text and util.cleanupSelectedText(selected_text.text) or ""
    local popup_dict = {
        word = selected,
        results = { {
            dict = "Highlight",
            definition = selected,
            is_html = false,
        } },
        dict_index = 1,
        window_list = { { word = selected } },
    }
    local note = self:new(popup_dict)
    note.is_highlight_note = true
    return note
end

return AnkiNote
