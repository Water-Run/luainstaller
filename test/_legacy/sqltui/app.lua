local ltui        = require("ltui")
local application = ltui.application
local DB          = require("db")
local UI          = require("ui")

local app         = application()
local db          = DB.new()

function app:init()
    application.init(self, "sqltui")
    self:background_set("blue")
    self:insert(UI.main_menu(self, db))
    return true
end

return app
