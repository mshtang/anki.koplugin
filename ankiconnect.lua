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

local AnkiConnect = require("ui/widget/widget"):extend{
    -- NetworkMgr func is device dependent, assume it's true when not implemented.
    wifi_connected = NetworkMgr.isWifiOn and NetworkMgr:isWifiOn() or true,
    -- contains notes which we could not sync yet
    local_notes = {},
    --[[
    -- Fingerprints of the notes made from the book being read, whether they reached
    -- Anki or are still queued. A note whose fingerprint is in here is refused as a
    -- duplicate. This is the very table held in the book's sidecar settings, so adding
    -- to it is all it takes to have it saved with the rest of the book's metadata.
    -- Empty while no book is open, which is also when no note can be made.
    --]]
    known_fingerprints = {},
    -- path of notes stored locally when WiFi isn't available
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

function AnkiConnect:sync_offline_notes()
    if NetworkMgr:willRerunWhenOnline(function() self:sync_offline_notes() end) then
        return
    end

    local can_sync, err = self:is_running(conf.url:get_value())
    if not can_sync then
        return self:show_popup(string.format("Synchronizing failed!\n%s", err), 3, true)
    end

    -- a queued note is already in known_fingerprints (put there when it was stored, or
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
        -- if any notes were synced succesfully, reset the latest added note (since it's not actually latest anymore)
        -- no point in saving the actual latest synced note, since the user won't know which note that was anyway
        self.latest_synced_note = nil
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
                if self.latest_synced_note and self.latest_synced_note.state == "offline" then
                    self.latest_synced_note = nil -- it was in the queue we just dropped
                end
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

function AnkiConnect:delete_latest_note()
    local latest = self.latest_synced_note
    if not latest then
        return
    end
    if latest.state == "online" then
        local can_sync, err = self:is_running(conf.url:get_value())
        if not can_sync then
            return self:show_popup(("Could not delete synced note: %s"):format(err), 3, true)
        end
        local api_key = conf.api_key:get_value()
        -- don't use rapidjson, the anki note ids are 64bit integers, they are turned into different numbers by the json library
        -- presumably because 32 vs 64 bit architecture
        local delete_request = ([[{"action": "deleteNotes", "version": 6, "params": {"notes": [%d]}, "key": %s }]]):format(latest.id, api_key and ([["%s"]]):format(api_key) or "null")
        local _, err = self:POST { payload = delete_request, url = conf.url:get_value() }
        if err then
            return self:show_popup(("Couldn't delete note: %s!"):format(err), 3, true)
        end
        self:show_popup(("Removed note (id: %s)"):format(latest.id), 3, true)
        if latest.fingerprint then
            self:forget_fingerprint(latest.fingerprint, latest.doc_path)
        end
    else
        -- looked up by identity rather than taken off the end: the queue is only ever
        -- appended to today, but "drop the last one" would quietly throw away somebody
        -- else's note the moment that stops being true
        local removed
        for i = #self.local_notes, 1, -1 do
            if self:note_fingerprint(self.local_notes[i]) == latest.fingerprint then
                removed = table.remove(self.local_notes, i)
                break
            end
        end
        if not removed then
            self.latest_synced_note = nil
            return self:show_popup("That note is no longer in the queue.", 3, true)
        end
        self:forget_fingerprint(latest.fingerprint, latest.doc_path)
        self:write_notes()
        self:show_popup(("Removed note (word: %s)"):format(latest.id), 3, true)
    end
    self.latest_synced_note = nil
end

function AnkiConnect:add_note(anki_note)
    local ok, note = pcall(anki_note.build, anki_note)
    if not ok then
        self:show_popup(string.format("Error while creating note:\n\n%s", note), 10, true)
        return false, "build_failed"
    end

    -- taken before the callbacks below, which cost a request each: no point fetching
    -- audio or a translation for a note we are about to refuse
    local fingerprint = self:note_fingerprint(note)
    if self.known_fingerprints[fingerprint] then
        self:show_popup("Identical note already exists; skipping duplicate.", 6, true)
        return false, "duplicate_note"
    end

    local can_sync, err = self:is_running(conf.url:get_value())
    if not can_sync then
        return self:store_offline(note, fingerprint, err)
    end

    if #self.local_notes > 0 then
        UIManager:show(ConfirmBox:new {
            text = "There are offline notes which can be synced!",
            ok_text = "Synchronize",
            cancel_text = "Cancel",
            ok_callback = function()
                self:sync_offline_notes()
            end
        })
    end
    local callback_ok = self:handle_callbacks(note, function(callback_err)
        return self:show_popup(string.format("Error while handling callbacks:\n\n%s", callback_err), 3, true)
    end)
    if not callback_ok then return false, "callback_failed" end

    local result, request_err = self:request_add_note(note.data)
    if request_err then
        self:show_popup(string.format("Error while synchronizing note:\n\n%s", request_err), 3, true)
        return false, "sync_failed"
    end
    self.known_fingerprints[fingerprint] = true
    self.latest_synced_note = { state = "online", id = result, fingerprint = fingerprint, doc_path = note.doc_path }
    self.last_message_text = "" -- if we manage to sync once, a following error should be shown again
    logger.info("note added succesfully: " .. result)
    return true, "online"
end

-- the caller has already fingerprinted the note and checked it for duplicates
function AnkiConnect:store_offline(note, fingerprint, reason)
    local id = note.data.fields[note.identifier]
    self.known_fingerprints[fingerprint] = true
    table.insert(self.local_notes, note)
    u.open_file(self.notes_filename, 'a', function(f) f:write(json.encode(note) .. '\n') end)
    self.latest_synced_note = { state = "offline", id = id, fingerprint = fingerprint, doc_path = note.doc_path }
    self:show_popup(string.format("%s\nStored note offline", reason), 3, false)
    return true, "offline"
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
