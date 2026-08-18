# Development notes
The repository hosts a plugin for KOReader. The plugin enables user to create an Anki note. It's designed as off-line first. A simple note viewer is included to let user inspect the queued notes.

The repository has a KOReader checkout at `../koreader`. Use it when implementing or testing changes that depend on KOReader APIs or widgets.

When building a new feature, doing a code review or fixing a bug, always put code efficiency first, because this plugin will be run on an e-ink device.

 - Enforce Scoping: Always use local variables. Never pollute the global Lua namespace.
 - Optimize E-ink UI: Avoid any animations, smooth scrolling, or rapid flashing. Use native widgets (Widget, Menu, Notification) instead of custom drawing.
 - Prevent UI Blocking: Run network requests and heavy I/O operations asynchronously via Dispatcher. Never block the main thread.
 - Manage Lifecycle: Explicitly clear timers, unbind events, and close file handles in onClose or onDestroy to avoid memory leaks.
 - Reduce GC Pressure: Reuse tables and objects in high-frequency events to minimize LuaJIT garbage collection spikes.
 - Standardize Structure: Ensure the plugin folder strictly contains a main.lua and a valid _meta.lua definition.
 - Use Native Logging: Implement logger.dbg() and logger.info() from the logger module for all debugging output