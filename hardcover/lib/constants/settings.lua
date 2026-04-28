local Settings = {
  ALWAYS_SYNC = "always_sync",
  BOOKS = "books",
  COMPATIBILITY_MODE = "compatibility_mode",
  ENABLE_WIFI = "enable_wifi",
  LINK_BY_ISBN = "link_by_isbn",
  LINK_BY_TITLE = "link_by_title",
  MENU_CONFIRMATION = "menu_confirmation",
  SYNC = "sync",
  TRACK_FREQUENCY = "track_frequency",
  TRACK_METHOD = "track_method",
  TRACK_PERCENTAGE = "track_percentage",
  TRACK = {
    FREQUENCY = "frequency",
    PROGRESS = "progress",
  },
  USER_ID = "user_id",
  SESSION_COOKIE = "session_cookie",
  REMEMBER_TOKEN = "remember_token",
  INCLUDE_LOCATION_IN_NOTES = "include_location_in_notes",
  IGNORE_VERSION_BLOCK = "ignore_version_block",
  SHOW_VERSION_DIALOG = "show_version_dialog",
  VERSION_CHECK_INTERVAL = "version_check_interval",
  LAST_VERSION_CHECK = "last_version_check",
  SKIP_BEHIND_PROGRESS = "skip_behind_progress",
  SYNC_BY_REMOTE_PAGES = "sync_by_remote_pages",
}

Settings.AUTOLINK_OPTIONS = { Settings.LINK_BY_ISBN, Settings.LINK_BY_TITLE }

return Settings
