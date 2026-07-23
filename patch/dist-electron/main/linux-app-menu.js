import { app, BrowserWindow, Menu, ipcMain } from "electron";

if (process.platform === "linux") {
  const MENU_CHANNEL = "input-linux:menu";
  const MENU_INVOKE_CHANNEL = "input-linux:menu-invoke";

  const ROLE_ACTIONS = {
    about: () => app.showAboutPanel(),
    quit: () => app.quit(),
    close: (win) => win.close(),
    minimize: (win) => win.minimize(),
    reload: (win) => win.webContents.reload(),
    forcereload: (win) => win.webContents.reloadIgnoringCache(),
    toggledevtools: (win) => win.webContents.toggleDevTools(),
    togglefullscreen: (win) => win.setFullScreen(!win.isFullScreen()),
    undo: (win) => win.webContents.undo(),
    redo: (win) => win.webContents.redo(),
    cut: (win) => win.webContents.cut(),
    copy: (win) => win.webContents.copy(),
    paste: (win) => win.webContents.paste(),
    pasteandmatchstyle: (win) => win.webContents.pasteAndMatchStyle(),
    delete: (win) => win.webContents.delete(),
    selectall: (win) => win.webContents.selectAll(),
    resetzoom: (win) => win.webContents.setZoomLevel(0),
    zoomin: (win) => win.webContents.setZoomLevel(win.webContents.getZoomLevel() + 1),
    zoomout: (win) => win.webContents.setZoomLevel(win.webContents.getZoomLevel() - 1),
  };

  const DEFAULT_ROLE_ACCELERATORS = {
    about: "",
    quit: "Ctrl+Q",
    close: "Ctrl+W",
    minimize: "Ctrl+M",
    reload: "Ctrl+R",
    forcereload: "Ctrl+Shift+R",
    toggledevtools: "Ctrl+Shift+I",
    togglefullscreen: "F11",
    undo: "Ctrl+Z",
    redo: "Ctrl+Shift+Z",
    cut: "Ctrl+X",
    copy: "Ctrl+C",
    paste: "Ctrl+V",
    selectall: "Ctrl+A",
    resetzoom: "Ctrl+0",
    zoomin: "Ctrl+=",
    zoomout: "Ctrl+-",
  };

  const roleOf = (item) => (item.role || "").toLowerCase();

  const displayAccelerator = (item) =>
    (item.accelerator || DEFAULT_ROLE_ACCELERATORS[roleOf(item)] || "").replace(
      /CmdOrCtrl|CommandOrControl/g,
      "Ctrl"
    );

  const serialize = (items, path) =>
    items
      .filter((item) => item.visible !== false)
      .map((item, index) => {
        const itemPath = path.concat(index);
        return {
          path: itemPath,
          label: item.label || "",
          type: item.type,
          role: item.role || null,
          enabled: item.enabled !== false,
          checked: item.checked === true,
          accelerator: displayAccelerator(item),
          submenu:
            item.submenu && item.submenu.items
              ? serialize(item.submenu.items, itemPath)
              : null,
        };
      });

  const findItem = (menu, path) => {
    let items = menu.items;
    let found = null;
    for (const index of path) {
      if (!items || !items[index]) return null;
      found = items[index];
      items = found.submenu ? found.submenu.items : null;
    }
    return found;
  };

  ipcMain.handle(MENU_CHANNEL, () => {
    try {
      const menu = Menu.getApplicationMenu();
      return menu ? serialize(menu.items, []) : [];
    } catch (error) {
      console.warn(`|linux_app_menu| could not read menu: ${error && error.message}`);
      return [];
    }
  });

  ipcMain.handle(MENU_INVOKE_CHANNEL, (event, path) => {
    try {
      const win = BrowserWindow.fromWebContents(event.sender);
      const menu = Menu.getApplicationMenu();
      if (!win || !menu || !Array.isArray(path)) return false;

      const item = findItem(menu, path);
      if (!item || item.enabled === false) return false;

      if (typeof item.click === "function" && !item.role) {
        item.click(item, win, {});
        return true;
      }

      const performRole = ROLE_ACTIONS[roleOf(item)];
      if (performRole) {
        performRole(win);
        return true;
      }

      console.warn(`|linux_app_menu| no handler for role: ${item.role}`);
      return false;
    } catch (error) {
      console.warn(`|linux_app_menu| invoke failed: ${error && error.message}`);
      return false;
    }
  });
}
