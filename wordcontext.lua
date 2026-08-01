--[[
-- Decides how much of the text around the looked up word ends up on the card, and
-- renders it so that a quotation is never shown half open.
--
--  * start from the sentence the selection is in
--  * while that is shorter than `min_words`, add whole sentences: previous ones
--    first, then following ones, then (once) the previous paragraph, then (once)
--    the next one, never going past `max_sentences`
--  * paragraph breaks become <br>, so two speakers never end up on the same line
--  * quotation marks are always completed, and material left out inside a
--    quotation is marked with […], so the card never pretends to be the full quote
--
-- There are deliberately no KOReader dependencies here: this is plain string
-- handling, and it can be reasoned about (and tried out) without a device.
--
-- It runs on e-ink hardware, so:
--  * the context stays a string, it is never exploded into a per character table
--  * each buffer is scanned once by a single string.find byte class, which only
--    lands on the few characters that can matter (sentence enders, newlines, quote
--    marks); everything after that walks the resulting short event list
--  * the character sets are compiled into lookup tables once per session
--]]

local byte, sub, find, schar, concat = string.byte, string.sub, string.find, string.char, table.concat

local WordContext = {}

-- Sentence enders and quote pairs are configurable, because they are a property of
-- the language (and of the publisher): German prints »…« and puts the full stop
-- inside the quotes, Japanese prints 「…」 and puts it before the closing mark.
-- Quote marks are listed as flattened pairs: open, close, open, close, ...
WordContext.DEFAULTS = {
    terminators = ".?!…。？！",
    quotes = "»«„“›‹‚‘「」『』",
    -- a full stop directly after one of these is not the end of a sentence.
    -- single letters ("z. B.", "S. 42", "A. Schmidt") and digits ("18. Jahrhundert",
    -- "13.30 Uhr") are handled by rule and don't need to be listed
    abbreviations = "Dr Prof Nr Bd Abs Art Str Hr Fr St Mio Mrd Jh Jhd Anm Abb Kap Aufl Tel Ing bzw ca evtl ggf inkl max min sog usw vgl etc",
    min_words = 10,
    max_sentences = 3,
}

local MARKER = "[…]"
local PARAGRAPH_BREAK = "<br>"

----------------------------------------------------------------------------
-- characters
----------------------------------------------------------------------------

local function char_len(b)
    if b < 0xC0 then return 1
    elseif b < 0xE0 then return 2
    elseif b < 0xF0 then return 3
    else return 4 end
end

local function char_at(s, i)
    local b = byte(s, i)
    if not b then return nil, 0 end
    local len = char_len(b)
    return sub(s, i, i + len - 1), len
end

-- A sentence never continues into a lowercase letter or a digit; used to tell a real
-- sentence end from an abbreviation, an ordinal, or a quote inside a longer sentence.
local function lower_or_digit_at(s, i)
    local b = byte(s, i)
    if not b then return false end
    if b < 128 then
        return (b >= 97 and b <= 122) or (b >= 48 and b <= 57)
    end
    if b == 0xC3 then -- ä ö ü ß é ... (and their uppercase forms, which we don't want)
        local b2 = byte(s, i + 1) or 0
        if b2 == 0x9F then return true end -- ß
        return b2 >= 0xA0 and b2 <= 0xBF and b2 ~= 0xB7
    end
    return false
end

local function skip_blanks(s, i)
    while true do
        local b = byte(s, i)
        if b == 32 or b == 9 then i = i + 1 else return i end
    end
end

----------------------------------------------------------------------------
-- character sets -> lookup tables (done once per session)
----------------------------------------------------------------------------

local compiled = {}

local function compile(opts)
    local terminators = opts.terminators or WordContext.DEFAULTS.terminators
    local quotes = opts.quotes or WordContext.DEFAULTS.quotes
    local abbreviations = opts.abbreviations or WordContext.DEFAULTS.abbreviations
    local key = terminators .. "\1" .. quotes .. "\1" .. abbreviations
    local cfg = compiled[key]
    if cfg then return cfg end

    cfg = { types = {}, closer_of = {}, opener_of = {}, abbrev = {} }
    local leads = {}
    local function add(ch, ty)
        cfg.types[ch] = ty
        leads[byte(ch, 1)] = true
    end

    local i = 1
    while i <= #terminators do
        local ch, len = char_at(terminators, i)
        add(ch, "t")
        i = i + len
    end
    i = 1
    while i <= #quotes do
        local open, open_len = char_at(quotes, i)
        local close, close_len = char_at(quotes, i + open_len)
        if not close then break end
        add(open, "o")
        add(close, "c")
        cfg.closer_of[open] = close
        cfg.opener_of[close] = open
        i = i + open_len + close_len
    end
    add("\n", "n")
    add("\r", "n")

    -- one byte class that lands on every character we might care about: the scan
    -- below is a single C level find per hit instead of a Lua loop per character
    local parts = {}
    for b in pairs(leads) do
        local c = schar(b)
        parts[#parts + 1] = (b < 128 and find(c, "%p")) and ("%" .. c) or c
    end
    cfg.class = "[" .. concat(parts) .. "]"

    for w in abbreviations:gmatch("%S+") do cfg.abbrev[w] = true end

    compiled[key] = cfg
    return cfg
end

----------------------------------------------------------------------------
-- one pass over a buffer, collecting the characters that matter
-- parallel arrays instead of a table per event, to keep allocations down
----------------------------------------------------------------------------

local function scan(s, cfg)
    local E = { pos = {}, len = {}, ty = {}, ch = {}, n = 0 }
    local class, types = cfg.class, cfg.types
    local i = 1
    while true do
        local p = find(s, class, i)
        if not p then break end
        local len = char_len(byte(s, p))
        local ch = len == 1 and sub(s, p, p) or sub(s, p, p + len - 1)
        local ty = types[ch]
        if ty then
            local n = E.n + 1
            E.n, E.pos[n], E.len[n], E.ty[n], E.ch[n] = n, p, len, ty, ch
        end
        i = p + len
    end
    return E
end

local function closer_len_at(s, i, cfg)
    local ch, len = char_at(s, i)
    if ch and cfg.types[ch] == "c" then return len end
end

----------------------------------------------------------------------------
-- sentence boundaries
----------------------------------------------------------------------------

-- "?!", "!!!", "..." and ". . ." are one sentence end, not several
local function joined(s, E, a, b)
    local gap_at = E.pos[a] + E.len[a]
    local gap = E.pos[b] - gap_at
    if gap == 0 then return true end
    return gap == 1 and byte(s, gap_at) == 32
        and byte(s, E.pos[a]) == 46 and byte(s, E.pos[b]) == 46
end

local function run_bounds(s, E, k)
    local first, last = k, k
    while last < E.n and E.ty[last + 1] == "t" and joined(s, E, last, last + 1) do last = last + 1 end
    while first > 1 and E.ty[first - 1] == "t" and joined(s, E, first - 1, first) do first = first - 1 end
    return first, last
end

local function abbreviation_before(s, dot, cfg)
    local b = byte(s, dot - 1)
    if not b then return false end
    -- "18. Jahrhundert", "am 3. Oktober", "13.30 Uhr", "1.500 Euro": a full stop
    -- glued to a number is never treated as a sentence end
    if b >= 48 and b <= 57 then return true end
    local i, stop = dot - 1, math.max(1, dot - 14)
    while i >= stop do
        local c = byte(s, i)
        if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) then i = i - 1 else break end
    end
    local token = sub(s, i + 1, dot - 1)
    if #token == 0 then return false end
    if #token == 1 then return true end -- initials, "z. B.", "d. h.", "S. 42"
    return cfg.abbrev[token] == true
end

-- is the terminator run made up of events [first,last] a real sentence end?
local function is_boundary(s, E, first, last, cfg)
    local run_start = E.pos[first]
    local run_end = E.pos[last] + E.len[last] - 1
    local q = run_end + 1
    while true do -- closing marks and blanks don't decide anything
        q = skip_blanks(s, q)
        local len = closer_len_at(s, q, cfg)
        if len then q = q + len else break end
    end
    if lower_or_digit_at(s, q) then return false end
    if first == last and run_end == run_start and byte(s, run_start) == 46
        and abbreviation_before(s, run_start, cfg) then
        return false
    end
    return true, run_start, run_end
end

-- where the sentence following a terminator starts: a closing mark left over from
-- the previous sentence ("...zurück.« Ich nickte") belongs to that sentence, not ours
local function sentence_start_after(s, p, cfg)
    while true do
        p = skip_blanks(s, p)
        local len = closer_len_at(s, p, cfg)
        if len then p = p + len else return p end
    end
end

-- where a sentence ends: the closing mark after the full stop is part of it
-- ("...hatten.«", and "werdet ... «" for publishers that space their guillemets)
local function sentence_end_at(s, run_end, cfg)
    local e, p = run_end, run_end + 1
    while true do
        local q = skip_blanks(s, p)
        local len = closer_len_at(s, q, cfg)
        if len then e = q + len - 1; p = e + 1 else return e end
    end
end

local function has_text(s, from, to)
    if to < from then return false end
    local q = find(s, "%S", from)
    return q ~= nil and q <= to
end

--[[
-- Sentence starts in the text before the selection, nearest one first.
-- Returns start, wall_from, wall_to, at_buffer_edge (nil when there is nothing left);
-- the wall is the nearest paragraph break walked past so far, which is how the caller
-- tells whether taking this stop means crossing into another paragraph.
-- A paragraph break is a sentence end as well: the last sentence of a paragraph
-- often has no full stop at all. The text at the very edge of the buffer is offered
-- as a last stop, flagged, because we cannot know whether it is a whole sentence:
-- taking it is what makes the caller ask the book for more text.
--]]
local function prev_stops(s, E, cfg)
    local k, limit, wall_from, wall_to, edge_done = E.n, #s + 1, nil, nil, false
    return function()
        while k >= 1 do
            local ty = E.ty[k]
            local start
            if ty == "n" then
                local first = k
                while first > 1 and E.ty[first - 1] == "n"
                    and E.pos[first] == E.pos[first - 1] + E.len[first - 1] do first = first - 1 end
                -- the paragraph we are in starts here; anything further out is a crossing
                start = sentence_start_after(s, E.pos[k] + E.len[k], cfg)
                wall_from, wall_to = E.pos[first], E.pos[k] + E.len[k] - 1
                k = first - 1
            elseif ty == "t" then
                local first, last = run_bounds(s, E, k)
                local ok, _, run_end = is_boundary(s, E, first, last, cfg)
                k = first - 1
                if ok then start = sentence_start_after(s, run_end + 1, cfg) end
            else
                k = k - 1
            end
            -- skip stops that would add nothing (a paragraph ending in a full stop
            -- yields both a terminator and a wall at practically the same place)
            if start and has_text(s, start, limit - 1) then
                limit = start
                return start, wall_from, wall_to
            end
        end
        if not edge_done then
            edge_done = true
            local start = sentence_start_after(s, 1, cfg)
            if has_text(s, start, limit - 1) then
                return start, wall_from, wall_to, true
            end
        end
        return nil
    end
end

-- mirror image: sentence ends in the text after the selection, nearest one first
local function next_stops(s, E, cfg)
    local k, limit, wall_from, wall_to, edge_done = 1, 0, nil, nil, false
    return function()
        while k <= E.n do
            local ty = E.ty[k]
            local stop
            if ty == "n" then
                local last = k
                while last < E.n and E.ty[last + 1] == "n"
                    and E.pos[last + 1] == E.pos[last] + E.len[last] do last = last + 1 end
                stop = E.pos[k] - 1
                wall_from, wall_to = E.pos[k], E.pos[last] + E.len[last] - 1
                k = last + 1
            elseif ty == "t" then
                local first, last = run_bounds(s, E, k)
                local ok, _, run_end = is_boundary(s, E, first, last, cfg)
                k = last + 1
                if ok then stop = sentence_end_at(s, run_end, cfg) end
            else
                k = k + 1
            end
            if stop and has_text(s, limit + 1, stop) then
                limit = stop
                return stop, wall_from, wall_to
            end
        end
        if not edge_done then
            edge_done = true
            if has_text(s, limit + 1, #s) then
                return #s, wall_from, wall_to, true
            end
        end
        return nil
    end
end

----------------------------------------------------------------------------
-- how long is what we have so far
----------------------------------------------------------------------------

-- Words, as far as a card is concerned: quote marks and […] don't count. Japanese
-- and Chinese don't separate words by spaces, so two of their characters count as one.
-- Korean is CJK too, but is already space-separated like any alphabet, so a token
-- holding Hangul counts once, the same as a Latin, Cyrillic or Arabic token.
local function count_words(s, from, to)
    if not s or (from and to and to < from) then return 0 end
    local text = from and sub(s, from, to) or s
    local n = 0
    for token in text:gmatch("%S+") do
        local cjk = 0
        for _ in token:gmatch("[\227-\233\239]") do cjk = cjk + 1 end
        if cjk > 0 then
            n = n + cjk / 2
        elseif find(token, "%w") or find(token, "[\195-\223]") or find(token, "[\234-\237]") then
            n = n + 1
        end
    end
    return n
end

----------------------------------------------------------------------------
-- rendering: pieces of text, one per paragraph
----------------------------------------------------------------------------

-- Splits [from,to] at every paragraph break; each piece also knows the bounds of the
-- paragraph it sits in, which is what the quote handling below needs. The last piece
-- is kept even when it is empty: it still carries the paragraph break in front of it
-- and the closing marks after it.
local function split_pieces(s, E, from, to)
    local pieces = {}
    local para_from, piece_from, k = 1, from, 1
    while k <= E.n and E.pos[k] < from do
        if E.ty[k] == "n" then para_from = E.pos[k] + E.len[k] end
        k = k + 1
    end
    while k <= E.n and E.pos[k] <= to do
        if E.ty[k] == "n" then
            local wall_from, last = E.pos[k], k
            while last < E.n and E.ty[last + 1] == "n"
                and E.pos[last + 1] == E.pos[last] + E.len[last] do last = last + 1 end
            if wall_from - 1 >= piece_from then
                pieces[#pieces + 1] = { from = piece_from, to = wall_from - 1,
                                        para_from = para_from, para_to = wall_from - 1, more = true }
            end
            piece_from = E.pos[last] + E.len[last]
            para_from = piece_from
            k = last + 1
        else
            k = k + 1
        end
    end
    local para_to = #s
    for j = k, E.n do
        if E.ty[j] == "n" then para_to = E.pos[j] - 1; break end
    end
    pieces[#pieces + 1] = { from = piece_from, to = to,
                            para_from = para_from, para_to = para_to, more = para_to < #s }
    return pieces
end

-- which quotations are open at `from`, given that its paragraph starts at `para_from`
local function open_quotes(s, E, para_from, from, cfg)
    local stack = {}
    for k = 1, E.n do
        local p = E.pos[k]
        if p >= from then break end
        if p >= para_from then
            local ty = E.ty[k]
            if ty == "o" then
                stack[#stack + 1] = { ch = E.ch[k], after = p + E.len[k] }
            elseif ty == "c" and #stack > 0 then
                stack[#stack] = nil
            end
        end
    end
    return stack
end

-- the opening marks to print in front of a piece, plus […] when the quotation
-- really did start earlier (so the marker is never mere decoration)
local function prefix_for(s, stack, from)
    local n = #stack
    if n == 0 then return "" end
    local out = {}
    for i = 1, n do out[i] = stack[i].ch end
    local q = find(s, "%S", stack[n].after)
    if q and q < from then out[n + 1] = " " .. MARKER .. " " end
    return concat(out)
end

--[[
-- Appends [from,to], updating `stack`.
-- Returns an opening mark that should be printed in front of the piece: that happens
-- when the piece contains a closing mark whose opening mark we never saw (speech
-- running over several paragraphs, or a book with a mark missing).
--]]
local function emit_body(out, s, E, from, to, stack, cfg)
    if to < from then return nil end
    local owed, last = nil, from
    for k = 1, E.n do
        local p = E.pos[k]
        if p > to then break end
        if p >= from then
            local ty = E.ty[k]
            if ty == "o" then
                stack[#stack + 1] = { ch = E.ch[k], after = p + E.len[k] }
            elseif ty == "c" then
                if #stack > 0 then
                    stack[#stack] = nil
                else
                    local q = find(s, "%S", last)
                    if not q or q >= p then
                        -- nothing but blanks before it: a leftover, drop it
                        out[#out + 1] = sub(s, last, p - 1)
                        last = p + E.len[k]
                    else
                        owed = owed or cfg.opener_of[E.ch[k]]
                    end
                end
            end
        end
    end
    out[#out + 1] = sub(s, last, to)
    return owed
end

-- closes whatever is still open at the end of a piece, with […] when the quotation
-- carries on (later in this paragraph, or in the next one for multi paragraph speech)
local function emit_suffix(out, s, E, to, para_to, more_paragraphs, stack, cfg)
    if #stack == 0 then return end
    local dropped, q = false, to + 1
    while q <= para_to do
        local ch, len = char_at(s, q)
        if not ch then break end
        if cfg.types[ch] == "c" or ch == " " or ch == "\t" then
            q = q + len
        else
            dropped = true
            break
        end
    end
    if not dropped and more_paragraphs then dropped = true end
    if dropped then out[#out + 1] = " " .. MARKER end
    for i = #stack, 1, -1 do
        out[#out + 1] = cfg.closer_of[stack[i].ch] or ""
        stack[i] = nil
    end
end

-- returns the index of the slot reserved for the opening marks, and an opening mark
-- the body turned out to owe (see emit_body)
local function emit_piece(out, s, E, piece, stack, cfg, do_open, do_close)
    local slot
    if do_open then
        local opened = open_quotes(s, E, piece.para_from, piece.from, cfg)
        slot = #out + 1
        out[slot] = prefix_for(s, opened, piece.from)
        for i = 1, #opened do stack[#stack + 1] = opened[i] end
    end
    local owed = emit_body(out, s, E, piece.from, piece.to, stack, cfg)
    if do_close then
        emit_suffix(out, s, E, piece.to, piece.para_to, piece.more, stack, cfg)
    end
    return slot, owed
end

--[[
-- Renders the text before and after the selection. The quote state is carried from
-- the last piece before the word into the first piece after it: those two are parts
-- of the same paragraph, and a quotation opened in one has to be closed in the other -
-- which is also why an opening mark owed by the text after the word is printed in
-- front of the text before it.
--]]
local function render(prev, prevE, before_pieces, word, nxt, nxtE, after_pieces, cfg)
    local stack, before_out = {}, {}
    local mid_slot
    for i, piece in ipairs(before_pieces) do
        if i > 1 then before_out[#before_out + 1] = PARAGRAPH_BREAK end
        local slot, owed = emit_piece(before_out, prev, prevE, piece, stack, cfg, true, i < #before_pieces)
        if owed and slot and before_out[slot] == "" then
            before_out[slot] = owed .. " " .. MARKER .. " "
        end
        mid_slot = slot
    end

    if find(word, cfg.class) then -- the selection itself may hold a quote mark
        emit_body({}, word, scan(word, cfg), 1, #word, stack, cfg)
    end

    local after_out = {}
    for i, piece in ipairs(after_pieces) do
        if i > 1 then after_out[#after_out + 1] = PARAGRAPH_BREAK end
        local slot, owed = emit_piece(after_out, nxt, nxtE, piece, stack, cfg, i > 1, true)
        if owed then
            if i == 1 and mid_slot and before_out[mid_slot] == "" then
                before_out[mid_slot] = owed .. " " .. MARKER .. " "
            elseif slot and after_out[slot] == "" then
                after_out[slot] = owed .. " " .. MARKER .. " "
            end
        end
    end
    return concat(before_out), concat(after_out)
end

----------------------------------------------------------------------------
-- entry points
----------------------------------------------------------------------------

--[[
-- Automatic mode: the sentence the selection is in, extended until it is long
-- enough to be useful on a card.
--
-- @param prev: the text before the selection
-- @param word: the selection itself
-- @param nxt:  the text after the selection
-- @param opts: character sets and the two limits (see WordContext.DEFAULTS)
-- @return before, after, need_more (need_more: the buffer ran out, refill and retry)
--]]
local function pull(it)
    local pos, wall_from, wall_to, edge = it()
    if pos == nil then return nil end
    return { pos = pos, wall_from = wall_from, wall_to = wall_to, edge = edge }
end

-- does taking this stop mean leaving the paragraph we already have?
local function crosses_back(stop, p_start)
    return stop.wall_from ~= nil and stop.wall_from >= stop.pos and stop.wall_from < p_start
end

local function crosses_forward(stop, n_end)
    return stop.wall_to ~= nil and stop.wall_to <= stop.pos and stop.wall_to > n_end
end

function WordContext.extract(prev, word, nxt, opts)
    local cfg = compile(opts)
    local min_words = tonumber(opts.min_words) or WordContext.DEFAULTS.min_words
    local max_sentences = tonumber(opts.max_sentences) or WordContext.DEFAULTS.max_sentences
    local prevE, nxtE = scan(prev, cfg), scan(nxt, cfg)
    local prev_it, next_it = prev_stops(prev, prevE, cfg), next_stops(nxt, nxtE, cfg)
    local need_more = false

    -- the sentence the selection is in
    local p_start, n_end
    local ps, ns = pull(prev_it), pull(next_it)
    if ps == nil then
        p_start, need_more = 1, true -- nothing to go by: the buffer may be too small
    elseif crosses_back(ps, #prev + 1) then
        p_start = #prev + 1 -- the selection starts its paragraph
    else
        p_start, need_more = ps.pos, need_more or ps.edge
        ps = pull(prev_it)
    end
    if ns == nil then
        n_end, need_more = #nxt, true
    elseif crosses_forward(ns, 0) then
        n_end = 0
    else
        n_end, need_more = ns.pos, need_more or ns.edge
        ns = pull(next_it)
    end

    -- ... extended with whole sentences until it carries enough words. Sentences
    -- before the selection first (they are what disambiguates a word), then ones
    -- after it, then one paragraph back, then one forward.
    local words = count_words(prev, p_start, #prev) + count_words(word) + count_words(nxt, 1, n_end)
    local sentences, back_crossed, forward_crossed = 1, false, false
    while words < min_words and sentences < max_sentences do
        if ps and not crosses_back(ps, p_start) then
            words = words + count_words(prev, ps.pos, p_start - 1)
            p_start, need_more = ps.pos, need_more or ps.edge
            ps = pull(prev_it)
        elseif ns and not crosses_forward(ns, n_end) then
            words = words + count_words(nxt, n_end + 1, ns.pos)
            n_end, need_more = ns.pos, need_more or ns.edge
            ns = pull(next_it)
        elseif ps and not back_crossed then
            back_crossed = true
            words = words + count_words(prev, ps.pos, ps.wall_from - 1)
            p_start, need_more = ps.pos, need_more or ps.edge
            ps = pull(prev_it)
        elseif ns and not forward_crossed then
            forward_crossed = true
            words = words + count_words(nxt, ns.wall_to + 1, ns.pos)
            n_end, need_more = ns.pos, need_more or ns.edge
            ns = pull(next_it)
        else
            -- out of text rather than out of budget: worth another look at the book
            if not ps or not ns then need_more = true end
            break
        end
        sentences = sentences + 1
    end

    local before, after = render(prev, prevE, split_pieces(prev, prevE, p_start, #prev),
                                word, nxt, nxtE, split_pieces(nxt, nxtE, 1, n_end), cfg)
    return before, after, need_more
end

-- first byte of the character that byte `i` is part of
local function char_start(s, i)
    while i > 1 do
        local b = byte(s, i)
        if b < 0x80 or b >= 0xC0 then break end
        i = i - 1
    end
    return i
end

-- moves the start of the context n characters to the left (n < 0: to the right)
local function move_start(s, i, n)
    while n > 0 and i > 1 do
        i, n = char_start(s, i - 1), n - 1
    end
    while n < 0 and i <= #s do
        i, n = i + char_len(byte(s, i)), n + 1
    end
    return i
end

-- moves the end of the context n characters to the right (n < 0: to the left)
local function move_end(s, e, n)
    while n > 0 do
        local b = byte(s, e + 1)
        if not b then break end
        e, n = e + char_len(b), n - 1
    end
    while n < 0 and e >= 1 do
        e, n = char_start(s, e) - 1, n + 1
    end
    return e
end

--[[
-- Manual mode, for the context menu: exactly the amount of text that was asked for,
-- no extending and nothing left out, but the quote marks are still completed.
--]]
function WordContext.manual(prev, word, nxt, opts, pre_s, pre_c, post_s, post_c)
    local cfg = compile(opts)
    local prevE, nxtE = scan(prev, cfg), scan(nxt, cfg)
    local prev_it, next_it = prev_stops(prev, prevE, cfg), next_stops(nxt, nxtE, cfg)
    local need_more = false

    local p_start = #prev + 1
    for _ = 1, pre_s do
        local stop = pull(prev_it)
        if not stop then need_more = true; break end
        p_start, need_more = stop.pos, need_more or stop.edge
    end
    local n_end = 0
    for _ = 1, post_s do
        local stop = pull(next_it)
        if not stop then need_more = true; break end
        n_end, need_more = stop.pos, need_more or stop.edge
    end

    if pre_c ~= 0 then
        p_start = move_start(prev, p_start, pre_c)
        if p_start == 1 then need_more = true end
    end
    if post_c ~= 0 then
        n_end = move_end(nxt, n_end, post_c)
        if n_end >= #nxt then need_more = true end
    end

    local before, after = render(prev, prevE, split_pieces(prev, prevE, p_start, #prev),
                                word, nxt, nxtE, split_pieces(nxt, nxtE, 1, n_end), cfg)
    return before, after, need_more
end

-- Characters that look fine on the e-reader and like rubbish on a card: soft hyphens
-- from line breaking, zero width spaces, footnote markers, and any leftover markup.
local JUNK = {
    "\194\173",                 -- soft hyphen
    "\226\128\139",             -- zero width space
    "\226\129\160",             -- word joiner
    "\194[\178\179\185]",       -- ¹ ² ³
    "\226\129[\176\180-\185]",  -- ⁰ ⁴ - ⁹
}

function WordContext.clean(s)
    if not s or #s == 0 then return s or "" end
    for _, pattern in ipairs(JUNK) do
        if find(s, pattern) then s = s:gsub(pattern, "") end
    end
    if find(s, "<", 1, true) then s = s:gsub("<[^>]*>", "") end
    return s
end

return WordContext
