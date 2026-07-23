import { app, BrowserWindow, ipcMain } from "electron";

if (process.platform === "linux") {
  const WINDOW_CHANNEL = "input-linux:window";
  const WINDOW_STATE_CHANNEL = "input-linux:window-state";

  const broadcastState = (win) => {
    if (!win || win.isDestroyed() || win.webContents.isDestroyed()) return;
    win.webContents.send(WINDOW_STATE_CHANNEL, { maximized: win.isMaximized() });
  };

  ipcMain.handle(WINDOW_CHANNEL, (event, action) => {
    const win = BrowserWindow.fromWebContents(event.sender);
    if (!win || win.isDestroyed()) return null;

    switch (action) {
      case "minimize":
        win.minimize();
        return null;
      case "toggle-maximize":
        if (win.isMaximized()) {
          win.unmaximize();
        } else {
          win.maximize();
        }
        return { maximized: win.isMaximized() };
      case "close":
        win.close();
        return null;
      case "state":
        return { maximized: win.isMaximized(), maximizable: win.isMaximizable() };
      default:
        return null;
    }
  });

  app.on("browser-window-created", (_event, win) => {
    try {
      win.on("maximize", () => broadcastState(win));
      win.on("unmaximize", () => broadcastState(win));
    } catch (error) {
      console.warn(`|linux_window_controls| setup failed: ${error && error.message}`);
    }
  });
}
