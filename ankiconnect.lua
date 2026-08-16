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
-- A fingerprint maps to the id of the Anki note it made, which is what lets its passage
-- be rewritten later. `true` stands for a note whose id we don't have: one still waiting
-- in the offline queue, or one made before the ids were kept.
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
-- Undo of the above, for a note that was thrown away again. The queue is shared by every
-- book, so the note being dropped is not necessarily one of the book being read: when it
-- is not, its book is opened just far enough to take the fingerprint back out. Its sidecar
-- is written right away, since nothing else is going to flush it for us.
--]]
function AnkiConnect:forget_fingerprint(fingerprint, doc_path)
    if not doc_path then
        return -- queued by a version that did not record where the note came from
    end
    if doc_path == self.fingerprints_doc_path then
        self.known_fingerprints[fingerprint] = nil
        return
    end
    local doc_settings = DocSettings:open(doc_path)
    local fingerprints = doc_settings:readSetting(FINGERPRINTS_KEY)
    if fingerprints and fingerprints[fingerprint] then
        fingerprints[fingerprint] = nil
        doc_settings:flush()
    end
end

--[[
-- The note stayed the same note but not the same identity: it is the passage which
-- identifies it, and that is exactly what an edit changes.
--]]
function AnkiConnect:move_fingerprint(old_fingerprint, fingerprint)
    self.known_fingerprints[old_fingerprint] = nil
    self.known_fingerprints[fingerprint] = true
    local latest = self.latest_note
    if latest and latest.fingerprint == old_fingerprint then
        latest.fingerprint = fingerprint
    end
end

-- the queued note a fingerprint belongs to, when it is one that hasn't been synced yet
function AnkiConnect:queued_note(fingerprint)
    for i, note in ipairs(self.local_notes) do
        if self:note_fingerprint(note) == fingerprint then
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
    -- written even when nothing failed, this way it also gets rid of the notes which we
    -- managed to sync, no need to keep those around
    self:write_notes()
    local sync_message_parts = {}
    if #synced > 0 then
        -- the notes which went are Anki's now: there is nothing left here to undo or edit
        self.latest_note = nil
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
                self.latest_note = nil -- it was in the queue we just dropped
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
-- Undo of the last note made, which is a local matter: it is still sitting in the queue.
-- Once it has been synced it is Anki's, and the menu entry that gets here is greyed out.
--]]
function AnkiConnect:delete_latest_note()
    local latest = self.latest_note
    if not latest then
        return
    end
    -- looked up by identity rather than taken off the end: the queue is only ever
    -- appended to today, but "drop the last one" would quietly throw away somebody
    -- else's note the moment that stops being true
    local _, queue_idx = self:queued_note(latest.fingerprint)
    if not queue_idx then
        self.latest_note = nil
        return self:show_popup("That note is no longer in the queue.", 3, true)
    end
    table.remove(self.local_notes, queue_idx)
    self:forget_fingerprint(latest.fingerprint, latest.doc_path)
    self:write_notes()
    self:show_popup(("Removed note (word: %s)"):format(latest.word), 3, true)
    self.latest_note = nil
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
    table.insert(self.local_notes, note)
    u.open_file(self.notes_filename, 'a', function(f) f:write(json.encode(note) .. '\n') end)
    self.latest_note = {
        word = note.data.fields[note.identifier],
        fingerprint = fingerprint,
        doc_path = note.doc_path,
    }
    -- nothing is shown here: adding is confirmed by whatever the user tapped to get
    -- here, and the menu carries the count of what is waiting
    logger.info(("note queued: %s (%d waiting)"):format(self.latest_note.word, #self.local_notes))
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

    self.local_notes[queue_idx] = note
    self:move_fingerprint(old_fingerprint, fingerprint)
    self:write_notes()
    self:show_popup("Updated the note's context.", 3, true)
    return true, "queued"
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
    self:write_notes() -- drops the duplicates that were skipped, if there were any
    logger.dbg(("Loaded %d notes from disk."):format(#self.local_notes))
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
