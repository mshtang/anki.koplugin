local util = require("util")
local List = require("lua_utils.list")
-- utility which wraps a dictionary sub-entry (the popup shown when looking up a word)
-- with some extra functionality which isn't there by default
local DictEntryWrapper = {
    -- currently unused but might come in handy, scavenged from yomichan
    kana = 'うゔ-かが-きぎ-くぐ-けげ-こご-さざ-しじ-すず-せぜ-そぞ-ただ-ちぢ-つづ-てで-とど-はばぱひびぴふぶぷへべぺほぼぽワヷ-ヰヸ-ウヴ-ヱヹ-ヲヺ-カガ-キギ-クグ-ケゲ-コゴ-サザ-シジ-スズ-セゼ-ソゾ-タダ-チヂ-ツヅ-テデ-トド-ハバパヒビピフブプヘベペホボポ',
    kana_word_pattern = "(.*)【.*】",
    kanji_word_pattern = "【(.*)】",
    kanji_sep_chr = '・',
    -- A pattern can be provided which for each dictionary extracts the kana reading(s) of the word which was looked up.
    -- This is used to determine which dictionary entries should be added to the card (e.g. 帰り vs 帰る: if the noun was selected, the verb is skipped)
    -- if no pattern is provided for a given dictionary, we fall back on the patterns listed above
    kana_pattern = {
        -- key: dictionary name as displayed in KOreader (received from dictionary's .ifo file)
        -- value: a table containing 2 entries:
        -- 1) the dictionary field to look for the kana reading in (either 'word' or 'description')
        -- 2) a pattern which should return the kana reading(s) (the pattern will be looked for multiple times!)
        ["JMdict Rev. 1.9"] = {"definition", "<font color=\"green\">(.-)</font>"},
    },
    -- A pattern can be provided which for each dictionary extracts the kanji reading(s) of the word which was looked up.
    -- This is used to store in the `word_field` defined above
    kanji_pattern = {
        -- key: dictionary name as displayed in KOreader (received from dictionary's .ifo file)
        -- value: a table containing 2 entries:
        -- 1) the dictionary field to look for the kanji in (either 'word' or 'description')
        -- 2) a pattern which should return the kanji
        ["JMdict Rev. 1.9"] = {"word", ".*"},
    }
}


function DictEntryWrapper.extend_dictionaries(results, config)
    local extended = {}
    for idx,dict in ipairs(results) do
        extended[idx] = DictEntryWrapper:new{
            dict = dict,
            conf = config
        }
    end
    return extended
end

function DictEntryWrapper:new(opts)
    local wrapper = self
    local index = function(data, k)
        return rawget(data, k) or rawget(wrapper, k) or rawget(data.dictionary, k)
    end
    local kana_dictionary_field, kana_pattern = unpack(self.kana_pattern[opts.dict.dict] or {})
    local kanji_dictionary_field, kanji_pattern  = unpack(self.kanji_pattern[opts.dict.dict] or {})
    local data = {
        dictionary = opts.dict,
        conf = opts.conf,
        kana_pattern = kana_pattern or self.kana_word_pattern,
        kana_dict_field = kana_dictionary_field or "word",
        kanji_pattern = kanji_pattern or self.kanji_word_pattern,
        kanji_dict_field = kanji_dictionary_field or "word",
    }
    return setmetatable(data, { __index = function(table, k) return index(table, k) end })
end

function DictEntryWrapper:get_kana_words()
    local value = self.dictionary[self.kana_dict_field]
    if type(value) ~= "string" then
        return List:new({ self.dictionary.word or "" })
    end
    local entries = List:from_iter(value:gmatch(self.kana_pattern))
    -- if the pattern doesn't match, return the plain word, chances are it's already in kana
    return entries:is_empty() and List:new({self.dictionary.word}) or entries
end

function DictEntryWrapper:get_kanji_words()
    local value = self.dictionary[self.kanji_dict_field]
    if type(value) ~= "string" then
        return List:new({})
    end
    local kanji_entries_str = value:match(self.kanji_pattern)
    if not kanji_entries_str then
        return List:new({})
    end
    local brackets = { ['('] = 0, [')'] = 0, ['（'] = 0, ['）'] = 0 }
    -- word entries often look like this: ある【有る・在る】
    -- the kanji_match_pattern will give us: 有る・在る
    -- these 2 entries still need to be separated
    local kanji_entries, current = {}, {}
    for _,ch in pairs(util.splitToChars(kanji_entries_str)) do
        if ch == self.kanji_sep_chr then
            table.insert(kanji_entries, table.concat(current))
            current = {}
        elseif brackets[ch] then
            -- some entries look like this: '振（り）方', the brackets should be ignored
        else
            table.insert(current, ch)
        end
    end
    if #current > 0 then
        table.insert(kanji_entries, table.concat(current))
    end
    return List:new(kanji_entries)
end

function DictEntryWrapper:as_string()
    local fmt_string = "DictEntryWrapper: (%s) word: %s, kana: %s, kanji: %s"
    return fmt_string:format(self.dictionary.dict, self.dictionary.word, self:get_kana_words(), self:get_kanji_words())
end

return DictEntryWrapper
