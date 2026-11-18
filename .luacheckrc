std = "lua51"
max_line_length = false
exclude_files = { "spec/**" }
-- WoW API globals the addon reads or writes
read_globals = {
  "C_AddOns", "C_Item", "C_Map", "C_Timer", "CreateFrame", "GameFontNormal", "GameFontNormalSmall",
  "GameFontHighlightSmall", "GetBuildInfo", "GetAddOnMetadata", "GetItemInfo", "GetProfessionInfo", "GetProfessions",
  "Item", "C_CurrencyInfo", "GetCoinTextureString", "C_Spell", "GetSpellInfo", "geterrorhandler", "seterrorhandler", "debugstack", "UnitName", "GetRealmName", "GetMerchantNumItems", "GetMerchantItemLink", "GetMerchantItemInfo", "C_MerchantFrame", "C_TradeSkillUI", "IsAddOnLoaded", "InCombatLockdown", "IsShiftKeyDown", "GameTooltip", "TooltipDataProcessor", "Enum", "IsPlayerSpell", "UnitFactionGroup", "C_Container", "BackdropTemplateMixin", "IsAddOnLoaded", "OpenWorldMap", "UIParent", "UISpecialFrames", "UnitLevel", "WOW_PROJECT_ID",
  "CreateVector2D", "GetNumTrainerServices", "GetTrainerServiceInfo", "GetTrainerServiceSkillReq", "GetTrainerServiceCost", "GetTrainerServiceItemLink", "IsTradeskillTrainer", "UiMapPoint", "C_SuperTrack", "Auctionator", "GatherMate2", "date", "time", "tinsert", "wipe",
}
globals = { "GoldCompassDB", "SLASH_GOLDCOMPASS1", "SlashCmdList" }
