local conf = require("anki_configuration")
return { run = function(self, note) note.fields[conf.def_field:get_value()] = "" return note end }