local Hardcover = {
  STATUS = {
    TO_READ = 1,
    READING = 2,
    FINISHED = 3,
    PAUSED = 4,
    DNF = 5,
  },
  CATEGORY = {
    TAG = "Tag",
  },
  ERROR = {
    JWT = "invalid-jwt",
    TOKEN = "Unable to verify token",
  }
}

return Hardcover
