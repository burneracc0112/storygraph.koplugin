# StoryGraph for KOReader

A KOReader plugin to synchronize your reading progress, notes, and status to [The StoryGraph](https://thestorygraph.com).

> [!NOTE]
> This plugin is a fork of the [Hardcover.app for KOReader](https://github.com/Billiam/hardcoverapp.koplugin) by [Billiam](https://github.com/Billiam). It has been redesigned to support StoryGraph.

> [!CAUTION]
> **Disclaimer**: This plugin uses an unofficial API based on session cookies. Because of this, it is inherently brittle and may break if StoryGraph updates their website or cookie structure. If sync stops working, please ensure you are using the latest version of the plugin and try re-fetching your session tokens.

> [!IMPORTANT]
> **Compatibility**: This plugin **cannot** be installed simultaneously with the original Hardcover plugin. 
> 
> **Rationale**: I've kept the internal folder structure and code namespace identical to the original repository. This was done to ensure that any upstream improvements, bug fixes, or new features from the original Hardcover plugin can be easily merged into this fork.

## Installation

1. Download the latest release and extract it to your KOReader `plugins/` folder.
2. Rename `hardcover_config.example.lua` to `hardcover_config.lua`.
3. **Authentication**:
   - Log in to [thestorygraph.com](https://thestorygraph.com) in your browser.
   - Open your browser's Developer Tools (F12) -> Application/Storage -> Cookies.
   - Copy the value of the `_story_graph_session` cookie and paste it into the `session_cookie` field in `hardcover_config.lua`.
   - Copy the value of the `remember_user_token` cookie and paste it into the `remember_user_token` field in `hardcover_config.lua`.

## Usage

The StoryGraph menu is located in the **Bookmark** top menu when a document is active.

### Updating Progress & Notes
The plugin provides a unified **"Update progress: [XX]%"** menu item. This opens a powerful dialog where you can:
- **Set Progress**: Tap the progress button to open a native picker showing both your **KOReader** and **StoryGraph** synced percentages.
- **Add a Note**: Write your thoughts directly in the note field.
- **Set Date**: Tap the date button to use a beautiful side-by-side **Year-Month-Day** picker.
- **Location Context**: By default, notes sent via the highlight menu automatically include your current **Chapter, Page, and Percentage**. You can enable this for regular notes in the settings.

### Linking a Book
Before updates can be sent, the plugin needs to link your document to a StoryGraph book.
- Use **"Link book"** to search by metadata or ISBN.
- Use **"Change edition"** to select the specific version (Physical, Digital, etc.) that matches your document.

### Automatically Track Progress
When enabled, the plugin will periodically sync your progress to StoryGraph:
- Updates are sent when paging, no more than once per minute (configurable).
- When reaching the end of the document, the book is automatically marked as "Read" on StoryGraph.
- For EPUBs, the plugin converts your local progress to a percentage based on the StoryGraph edition's total pages.

## Settings

- **Include location info in regular notes**: Automatically append Chapter, Page, and % info to your regular notes.
- **Automatically link by ISBN/Title**: Attempt to find matching books on StoryGraph automatically when opening a new document.
- **Enable wifi on demand**: Briefly enable wifi for background syncs to preserve battery life.
- **Confirm changes**: Prompt for confirmation before changing a book's status (e.g., Want to Read -> Read).

## Versioning & Mandatory Updates

To prevent data corruption and ensure compatibility with StoryGraph's unofficial API, the plugin includes a remote versioning system.

- **Automatic Checks**: The plugin periodically checks for mandatory updates via GitHub. If the StoryGraph API changes in a way that breaks older versions, the plugin will automatically disable sync to prevent errors.
- **Smart Blocking**: When a mandatory update is required, the plugin menus will be greyed out.
- **Configurable Frequency**: Use the **"Version check frequency"** slider to choose how often the plugin checks for updates (from 1 to 20 days). Default is 1 day.
- **Manual Override**: You can enable **"Ignore version blocks"** to bypass mandatory update requirements. Use this with caution as older versions may break sync if the StoryGraph API changes.
- **Silent Mode**: Disable **"Show version alert dialog"** if you prefer the plugin to silently stop working when an update is required, rather than showing a notification.
