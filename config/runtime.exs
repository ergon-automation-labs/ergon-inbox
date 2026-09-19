import Config

# Runtime configuration — evaluated when the app starts, not at compile time
# This allows environment variables set by launchd/Salt to be read properly

if config_env() != :test do
  # Bot specific settings can be added here using BotArmyLibraryRuntime.ConfigLoader.get/2
end
