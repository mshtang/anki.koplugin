local http = require("socket.http")
local socket = require("socket")
local socketutil = require("socketutil")
local logger = require("logger")
local json = require("rapidjson")
local ltn12 = require("ltn12")
local util = require("util")
local Font = require("ui/font")
local UIManager = require("ui/uimanager")
local ConfirmBox = require("ui/widget/confirmbox")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local Translator = require("ui/translator")
local forvo = require("forvo")
local u = require("lua_utils/utils")
local conf = require("anki_configuration")
local md5 = require("ffi/sha2").md5

-- key the fingerprints are kept under in the book's sidecar (.sdr) settings
local FINGERPRINTS_KEY = "anki_note_fingerprints"

--[[
-- Making a note never touches the network. Adding one writes it to a local queue,
-- editing or dropping one rewrites that queue, and the whole queue is handed to Anki
-- only when the user asks for it from the menu. Reading is what an e-reader is good at
-- and reaching Anki over a sleeping WiFi is what it is bad at, so nothing here waits on
-- a connection, nothing fails for the want of one, and there is a single moment - the
-- sync - at which the plugin talks to Anki at all.
--
-- The consequence, which the UI is careful to show, is that a note can be edited up
-- until it is synced. After that it is Anki's, and Anki is where it gets edited.
--]]
local AnkiConnect = require("ui/widget/widget"):extend{
    -- NetworkMgr func is device dependent, assume it's true when not implemented.
    wifi_connected = NetworkMgr.isWifiOn and NetworkMgr:isWifiOn() or true,
    -- notes waiting to be handed to Anki, in the order they were made
    local_notes = {},
    -- updated only when the queue length changes, for the menu entry
    notes_count = 0,
    notes_changed_callback = nil,
    --[[
    -- Fingerprints of the notes made from the book being read, whether they reached
    -- Anki or are still queued. A note whose fingerprint is in here is refused as a
    -- duplicate. This is the very table held in the book's sidecar settings, so adding
    -- to it is all it takes to have it saved with the rest of the book's metadata.
    -- Empty while no book is open, which is also when no note can be made.
    --
    -- They outlive the sync that empties the queue: a book keeps every word it gave,
    -- which is the whole point of them - otherwise the same word would be offered again
    -- as new after every sync, and Anki would end up with the card twice.
    --]]
    known_fingerprints = {},
    -- the queue on disk
    notes_filename = DataStorage:getSettingsDir() .. "/anki.koplugin_notes.json",
}

--[[
-- What makes two notes the same: the looked up word and the passage it sits in.
--
-- Not every field takes part. The definition is whatever dictionary tab happened to be
-- open, and the metadata carries the page the reader was on, so with either of them in,
-- the same word in the same passage would count as a new note each time. They are
-- dropped by name rather than the identity being picked by name on purpose: a note
-- built under a different profile then keeps its own fields and stays distinguishable,
-- instead of collapsing into one empty identity shared with every other foreign note.
--]]
local function fingerprint_fields(fields, ignored)
    local keys, parts = {}, {}
    for k in pairs(fields or {}) do
        if not ignored[k] then table.insert(keys, k) end
    end
    table.sort(keys)
    for _, k in ipairs(keys) do
        parts[#parts+1] = ("%s=%s"):format(k, tostring(fields[k] or ""))
    end
    -- Use a non-printable separator to avoid collisions with user text.
    return table.concat(parts, "\0")
end

--[[
LuaSocket returns somewhat cryptic errors sometimes
- user forgets to add the HTTP prefix -> schemedefs nil
- user uses HTTPS instead of HTTP -> wantread
We can prevent this by modifying/adding the scheme when it's wrong/missing
--]]
function AnkiConnect.sanitize_url(url)
    local valid_url = url
    local _, scheme_end_idx, scheme, ssl = url:find("^(http(s?)://)")
    if not scheme then
        valid_url = 'http://'..url
    elseif ssl and #ssl > 0 then
        valid_url = 'https://'..url:sub(scheme_end_idx+1, #url)
    end
    if url ~= valid_url then
        logger.info(("Corrected URL from '%s' to '%s'"):format(url, valid_url))
    end
    return valid_url, ssl ~= nil
end

function AnkiConnect.with_timeout(timeout, func)
    socketutil:set_timeout(timeout)
    local res = { func() } -- store all values returned by function
    socketutil:reset_timeout()
    return unpack(res)
end

--[[
-- A note's identity, as it was built from the document. It is deliberately taken
-- before handle_callbacks runs: audio, picture and translated context are derived
-- from the note, so letting them into the fingerprint would give one and the same
-- note a different identity offline (callbacks still pending) than online.
--]]
function AnkiConnect:note_fingerprint(note)
    local ignored = {}
    for _, setting in ipairs({ conf.def_field, conf.meta_field }) do
        local field_name = setting:get_value()
        if field_name then ignored[field_name] = true end
    end
    -- hashed: these are kept for as long as the book is, and the readable form is as
    -- long as the passage the note was made from
    return md5(fingerprint_fields(note.data and note.data.fields or {}, ignored))
end

--[[
-- Notes are remembered per book, in its sidecar settings, which is what the reader
-- already carries around: the fingerprints follow the book when it is renamed or moved,
-- and go away with it when it is deleted, so nothing has to be capped or swept up.
--
-- They are written by reference. The reader flushes the sidecar when the book is closed,
-- when KOReader is restarted or suspended, and on its own timer (15 minutes by default),
-- so there is nothing to write out here.
--]]
function AnkiConnect:load_fingerprints(doc_settings, doc_path)
    self.known_fingerprints = doc_settings:readSetting(FINGERPRINTS_KEY, {})
    self.fingerprints_doc_path = doc_path
    logger.dbg(("Loaded %d note fingerprint(s) for %s."):format(u.count(self.known_fingerprints), doc_path))
end

-- called when the book is closed, so a later edit cannot write into an orphaned table
function AnkiConnect:unload_fingerprints()
    self.known_fingerprints = {}
    self.fingerprints_doc_path = nil
end

--[[
-- The fingerprints of a book, plus the way to write them back. The book being read has
-- its table held open and the reader flushes it, so writing it back is a no-op; any
-- other book is opened just far enough to be looked at, and nothing else is going to
-- flush that, so the caller has to.
--]]
function AnkiConnect:fingerprints_for(doc_path)
    -- A note queued before the book it came from was recorded is taken to be the book
    -- being read: that is where it came from in all but the odd case, and it is the only
    -- book we could do anything about anyway. Being wrong costs nothing - a fingerprint
    -- is a word and the passage around it, so another book having the very same one
    -- means it really is the same note.
    if not doc_path or doc_path == self.fingerprints_doc_path then
        return self.known_fingerprints, function() end
    end
    local doc_settings = DocSettings:open(doc_path)
    return doc_settings:readSetting(FINGERPRINTS_KEY, {}), function() doc_settings:flush() end
end

function AnkiConnect:forget_fingerprint(fingerprint, doc_path)
    local fingerprints, flush = self:fingerprints_for(doc_path)
    if fingerprints and fingerprints[fingerprint] then
        fingerprints[fingerprint] = nil
        flush()
    end
end

function AnkiConnect:remember_fingerprint(fingerprint, doc_path)
    local fingerprints, flush = self:fingerprints_for(doc_path)
    if fingerprints and not fingerprints[fingerprint] then
        fingerprints[fingerprint] = true
        flush()
    end
end

function AnkiConnect:fingerprint_known(fingerprint, doc_path)
    local fingerprints = self:fingerprints_for(doc_path)
    return fingerprints ~= nil and fingerprints[fingerprint] ~= nil
end

--[[
-- The note stayed the same note but not the same identity: it is the passage which
-- identifies it, and that is exactly what an edit changes. The book it belongs to is
-- not always the one being read - the queue is shared by every book.
--]]
function AnkiConnect:move_fingerprint(old_fingerprint, fingerprint, doc_path)
    self:forget_fingerprint(old_fingerprint, doc_path)
    self:remember_fingerprint(fingerprint, doc_path)
end

--[[
-- A queued note's identity, which is carried with the note rather than worked out afresh.
--
-- Which fields take part in a fingerprint depends on the profile the note was made under
-- (the definition and the metadata are left out by name), and the queue is looked at from
-- places where a different profile - or none at all - is loaded. Working it out again
-- there gives a different answer for the very same note, and a note whose identity moved
-- can no longer be found in its book, so removing it would not release the word and
-- adding it again would be refused as a duplicate.
--
-- It is stamped on when the note is queued, where the profile is certainly the right one.
-- A note without one is worked out as before, and nothing is written back: without a
-- profile loaded the answer would be wrong, and wrong is worse when it is kept.
--]]
local MD5_PATTERN = ("^%s$"):format(("%x"):rep(32))

function AnkiConnect:queued_fingerprint(note)
    if type(note.fingerprint) == "string" and note.fingerprint:find(MD5_PATTERN) then
        return note.fingerprint
    end
    return self:note_fingerprint(note)
end

-- the queued note a fingerprint belongs to, when it is one that hasn't been synced yet
function AnkiConnect:queued_note(fingerprint)
    for i, note in ipairs(self.local_notes) do
        if self:queued_fingerprint(note) == fingerprint then
            return note, i
        end
    end
end

function AnkiConnect:is_running(url)
    if not self.wifi_connected then
        return false, "WiFi disconnected."
    end
    local anki_connect_request = { action = "requestPermission", version = 6 }
    local result, error = self:POST { payload = anki_connect_request, url = url }
    if error or result.permission == "denied" then
        return false, error or "Permission denied."
    end
    return result
end

function AnkiConnect:get_decknames(url, api_key)
    local anki_connect_request = { action = "deckNames", version = 6, key = api_key }
    return self:POST { payload = anki_connect_request, url = url }
end

function AnkiConnect:request_add_note(note)
    local anki_connect_request = { action = "addNote", params = { note = note }, version = 6, key = conf.api_key:get_value() }
    return self:POST { payload = anki_connect_request, url = conf.url:get_value() }
end

function AnkiConnect:POST(opts)
    local payload = assert(opts.payload, "Missing payload!")
    if type(payload) ~= "string" then
        if opts.api_key then
            payload.key = opts.api_key
        end
        payload = json.encode(payload)
    end
    local headers = {
        ["Content-Type"] = "application/json",
        ["Content-Length"] = #payload,
    }
    local url = assert(opts.url, "Missing URL!")
    local scheme, basic_auth, host = url:match("^(https?://)([^:]+:[^@]+)@(.+)")
    if basic_auth then
        headers["Authorization"] = "Basic " .. forvo.base64e(basic_auth)
        url = scheme .. host
    end
    local sink = {}
    local req = {
        url = url,
        method = "POST",
        headers = headers,
        sink = ltn12.sink.table(sink),
        source = ltn12.source.string(payload)
    }
    logger.dbg("AnkiConnect#POST request:", req)
    local status_code, response_headers, status = self.with_timeout(1, function() return socket.skip(1, http.request(req)) end)
    logger.dbg("AnkiConnect#POST response:", status_code, response_headers, status)

    if type(status_code) == "string" then return nil, status_code end
    if status_code ~= 200 then return nil, string.format("Invalid return code: %s.", status_code) end
    local response = json.decode(table.concat(sink))
    local json_err = response.error
    -- this turns a json NULL in a userdata instance, actual error will be a string
    if type(json_err) == "string" then
        return nil, json_err
    end
    return response.result
end

function AnkiConnect:set_translated_context(_, context)
    local result = Translator:translate(context, Translator:getTargetLanguage(), Translator:getSourceLanguage())
    logger.info(("Queried translation: '%s' -> '%s'"):format(context, result))
    return true, result
end

function AnkiConnect:set_forvo_audio(field, word, language)
    logger.info(("Querying Forvo audio for '%s' in language: %s"):format(word, language))
    local ok, forvo_url = forvo.get_pronunciation_url(word, language)
    if not ok then
        if forvo_url == "FORVO_403" then
            -- For 403 errors, return true but no audio data
            logger.warn("Forvo returned 403 error - continuing without audio")
            return true, nil
        end
        return false, ("Could not connect to forvo: %s"):format(forvo_url)
    end
    return true, forvo_url and {
        url = forvo_url,
        filename = string.format("forvo_%s.ogg", word),
        fields = { field }
    } or nil
end

function AnkiConnect:set_image_data(field, img_path)
    if not img_path then
        return true
    end
    local _,filename = util.splitFilePathName(img_path)
    local img_f = io.open(img_path, 'rb')
    if not img_f then
        return true
    end
    local data = forvo.base64e(img_f:read("*a"))
    logger.info(("added %d bytes of base64 encoded data"):format(#data))
    os.remove(img_path)
    return true, {
        data = data,
        filename = filename,
        fields = { field }
    }
end

function AnkiConnect:handle_callbacks(note, on_err_func)
    local field_callbacks = note.field_callbacks
    for param, mod in pairs(field_callbacks) do
        if mod.field_name then
            local _, ok, result_or_err = pcall(self[mod.func], self, mod.field_name, unpack(mod.args))
            if not ok then
                return on_err_func(result_or_err)
            end
            if param == "fields" then
                note.data.fields[mod.field_name] = result_or_err
            else
                assert(note.data[param] == nil, ("unexpected result: note property '%s' was already present!"):format(param))
                note.data[param] = result_or_err
            end
            field_callbacks[param] = nil
        end
    end
    return true
end

--[[
-- The one moment the plugin talks to Anki. Everything the notes still owe - the Forvo
-- audio, the translated context - is fetched here rather than when the note was made,
-- so a single wake of the WiFi pays for the whole queue.
--]]
function AnkiConnect:sync_notes()
    if NetworkMgr:willRerunWhenOnline(function() self:sync_notes() end) then
        return
    end

    local can_sync, err = self:is_running(conf.url:get_value())
    if not can_sync then
        return self:show_popup(string.format("Synchronizing failed!\n%s", err), 3, true)
    end

    -- a queued note was written into its book's sidecar when it was made, and syncing
    -- does not change its identity, so there is no fingerprint bookkeeping to do here
    local synced, failed, errs = {}, {}, u.defaultdict(0)
    for _,note in ipairs(self.local_notes) do
        local sync_ok = self:handle_callbacks(note, function(callback_err)
            errs[callback_err] = errs[callback_err] + 1
        end)
        if sync_ok then
            local _, request_err = self:request_add_note(note.data)
            if request_err then
                sync_ok = false
                errs[request_err] = errs[request_err] + 1
            end
        end
        table.insert(sync_ok and synced or failed, note)
    end
    self.local_notes = failed
    self:update_notes_count()
    -- written even when nothing failed, this way it also gets rid of the notes which we
    -- managed to sync, no need to keep those around
    self:write_notes()
    local sync_message_parts = {}
    if #synced > 0 then
        -- the notes which went are Anki's now: there is nothing left here to undo or edit
        table.insert(sync_message_parts, ("Finished synchronizing %d note(s)."):format(#synced))
    end
    if #failed > 0 then
        table.insert(sync_message_parts, ("%d note(s) failed to sync:"):format(#failed))
        for error_msg, count in pairs(errs) do
            table.insert(sync_message_parts, (" - %s (%d)"):format(error_msg, count))
        end
        return UIManager:show(ConfirmBox:new {
            text = table.concat(sync_message_parts, "\n"),
            icon = "notice-warning",
            font = Font:getFace("smallinfofont", 9),
            ok_text = "Discard failures",
            cancel_text = "Keep",
            ok_callback = function()
                os.remove(self.notes_filename)
                -- the user threw these away on purpose: take them back out of the books
                -- they were made from, otherwise an identical note stays refused forever
                for _, note in ipairs(failed) do
                    self:forget_fingerprint(self:note_fingerprint(note), note.doc_path)
                end
                self.local_notes = {}
                self:update_notes_count()
            end
        })
    end
    self:show_popup(table.concat(sync_message_parts, " "), 3, true)
end

function AnkiConnect:show_popup(text, timeout, show_always)
    -- don't reinform the user for something we already showed them
    if not (show_always or false) and self.last_message_text == text then
        return
    end
    logger.info(("Displaying popup with message: '%s'"):format(text))
    self.last_message_text = text
    UIManager:show(InfoMessage:new { text = text, timeout = timeout })
end

--[[
-- Adds a note to the queue. Nothing is asked of the network here, so this cannot fail
-- for the want of a connection and does not have to wait to find out: the only note
-- turned away is one the book has given before.
--]]
function AnkiConnect:add_note(anki_note)
    local ok, note = pcall(anki_note.build, anki_note)
    if not ok then
        self:show_popup(string.format("Error while creating note:\n\n%s", note), 10, true)
        return false, "build_failed"
    end

    local fingerprint = self:note_fingerprint(note)
    if self.known_fingerprints[fingerprint] then
        self:show_popup("Identical note already exists; skipping duplicate.", 6, true)
        return false, "duplicate_note"
    end

    self.known_fingerprints[fingerprint] = true
    note.fingerprint = fingerprint -- worked out under this note's profile, see queued_fingerprint
    table.insert(self.local_notes, note)
    self:update_notes_count()
    u.open_file(self.notes_filename, 'a', function(f) f:write(json.encode(note) .. '\n') end)
    -- nothing is shown here: adding is confirmed by whatever the user tapped to get
    -- here, and the menu carries the count of what is waiting
    logger.info(("note queued: %s (%d waiting)"):format(note.data.fields[note.identifier], #self.local_notes))
    return true, "queued"
end

--[[
-- Rewrites the passage a queued note was made from, instead of adding a second note for
-- a word the book already gave. Everything the note still owes Anki - its audio, its
-- translated context - is owed on the new passage now, and is fetched at sync time as
-- it would have been anyway, so there is nothing to redo here.
--
-- @param old_fingerprint: the note's identity as it stands, i.e. before the new context
-- @param anki_note: the note with the new context set on it, not built yet
--]]
function AnkiConnect:update_note_context(old_fingerprint, anki_note)
    local _, queue_idx = self:queued_note(old_fingerprint)
    if not queue_idx then
        self:show_popup("This note has already been synced; edit it in Anki.", 5, true)
        return false, "already_synced"
    end

    local ok, note = pcall(anki_note.build, anki_note)
    if not ok then
        self:show_popup(string.format("Error while creating note:\n\n%s", note), 10, true)
        return false, "build_failed"
    end
    local fingerprint = self:note_fingerprint(note)
    if fingerprint == old_fingerprint then
        self:show_popup("The context did not change; nothing to update.", 3, true)
        return false, "unchanged"
    end
    if self.known_fingerprints[fingerprint] then
        self:show_popup("A note with this context already exists; skipping duplicate.", 6, true)
        return false, "duplicate_note"
    end

    note.fingerprint = fingerprint
    self.local_notes[queue_idx] = note
    self:move_fingerprint(old_fingerprint, fingerprint, note.doc_path)
    self:write_notes()
    self:show_popup("Updated the note's context.", 3, true)
    return true, "queued"
end

-- drops a queued note, and with it the claim its book had on that passage
function AnkiConnect:remove_queued_note(index)
    local note = self.local_notes[index]
    if not note then
        return false
    end
    local fingerprint = self:queued_fingerprint(note)
    table.remove(self.local_notes, index)
    self:update_notes_count()
    self:forget_fingerprint(fingerprint, note.doc_path)
    self:write_notes()
    return true
end

--[[
-- The queue is shared by every book, and its notes are already known to the books they
-- were made from, so nothing here goes into known_fingerprints: that belongs to the book
-- being read, and seeding it from the queue would blindly cover other books' notes too.
--]]
function AnkiConnect:load_notes()
    self.local_notes = {}
    local seen = {} -- scoped to this read: it only guards against a doubled line
    u.open_file(self.notes_filename, 'r', function(f)
        for note_json in f:lines() do
            local note, err = json.decode(note_json)
            assert(note, ("Could not parse note '%s': %s"):format(note_json, err))
            local fingerprint = self:note_fingerprint(note)
            if not seen[fingerprint] then
                table.insert(self.local_notes, note)
                seen[fingerprint] = true
            else
                logger.info("Skipped duplicate offline note (all fields match).")
            end
        end
    end)
    self:update_notes_count()
    self:write_notes() -- drops the duplicates that were skipped, if there were any
    logger.dbg(("Loaded %d notes from disk."):format(#self.local_notes))
end

-- Keep the menu count cheap to read, and refresh an already open menu only when it changes.
function AnkiConnect:update_notes_count()
    local count = #self.local_notes
    if count == self.notes_count then
        return
    end
    self.notes_count = count
    if self.notes_changed_callback then
        self.notes_changed_callback()
    end
end

-- the queue on disk is the queue in memory: always write the whole thing back
function AnkiConnect:write_notes()
    u.open_file(self.notes_filename, 'w', function(f)
        for _, note in ipairs(self.local_notes) do
            f:write(json.encode(note), '\n')
        end
    end)
end

function AnkiConnect:onNetworkConnected()
    self.wifi_connected = true
end

function AnkiConnect:onNetworkDisconnected()
    self.wifi_connected = false
end

return AnkiConnect
