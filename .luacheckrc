std = "lua51"
max_line_length = false
exclude_files = { "spec/**" }
-- WoW API globals the addon reads or writes
read_globals = {
  "C_AddOns", "C_Item", "C_Map", "C_Timer", "CreateFrame", "GameFontNormal", "GameFontNormalSmall",
  "GameFontHighlightSmall", "GetBuildInfo", "GetAddOnMetadata", "GetItemInfo", "GetProfessionInfo", "GetProfessions",
  "Item", "OpenWorldMap", "UIParent", "UISpecialFrames", "UnitLevel", "WOW_PROJECT_ID",
  "Auctionator", "GatherMate2", "date", "time", "tinsert", "wipe",
}
globals = { "GoldCompassDB", "SLASH_GOLDCOMPASS1", "SlashCmdList" }
