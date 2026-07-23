(() => {
  if (process.platform !== "linux") return;

  const { contextBridge, ipcRenderer } = require("electron");
  const WINDOW_CHANNEL = "input-linux:window";
  const WINDOW_STATE_CHANNEL = "input-linux:window-state";
  const MENU_CHANNEL = "input-linux:menu";
  const MENU_INVOKE_CHANNEL = "input-linux:menu-invoke";
  const UDEV_CHANNEL = "input-linux:udev";

  try {
    contextBridge.exposeInMainWorld("inputLinuxWindow", {
      minimize: () => ipcRenderer.invoke(WINDOW_CHANNEL, "minimize"),
      toggleMaximize: () => ipcRenderer.invoke(WINDOW_CHANNEL, "toggle-maximize"),
      close: () => ipcRenderer.invoke(WINDOW_CHANNEL, "close"),
      getState: () => ipcRenderer.invoke(WINDOW_CHANNEL, "state"),
      onStateChange: (callback) => {
        const listener = (_event, state) => callback(state);
        ipcRenderer.on(WINDOW_STATE_CHANNEL, listener);
        return () => ipcRenderer.removeListener(WINDOW_STATE_CHANNEL, listener);
      },
      getMenu: () => ipcRenderer.invoke(MENU_CHANNEL),
      invokeMenuItem: (path) => ipcRenderer.invoke(MENU_INVOKE_CHANNEL, path),
      getUdevStatus: () => ipcRenderer.invoke(UDEV_CHANNEL, "status"),
      installUdevRules: () => ipcRenderer.invoke(UDEV_CHANNEL, "install"),
      stageUdevInstaller: () => ipcRenderer.invoke(UDEV_CHANNEL, "stage"),
    });
  } catch (error) {
    console.warn(`|linux_window_controls| could not expose bridge: ${error.message}`);
  }
})();
