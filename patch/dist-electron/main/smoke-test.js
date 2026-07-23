import { app, BrowserWindow, Menu } from "electron";
import { existsSync } from "node:fs";
import { writeFile } from "node:fs/promises";

if (process.env.INPUT_SMOKE_TEST === "1") {
  const TIMEOUT_MS = Number(process.env.INPUT_SMOKE_TEST_TIMEOUT_MS || "60000");
  const REQUIRED_GLOBALS = (
    process.env.INPUT_SMOKE_TEST_GLOBALS ||
    "localStorageChannel,commonChannel,fsChannel,rpcChannel,updateChannel,connectedDeviceChannel,devicesManagerChannel"
  )
    .split(",")
    .map((name) => name.trim())
    .filter(Boolean);

  const BROKEN_BUNDLE_CONSOLE_PATTERNS = [
    /ReferenceError/,
    /is not defined/,
    /SyntaxError/,
    /Unexpected token/,
    /Failed to fetch dynamically imported module/,
    /Failed to load resource/,
  ];

  const TRANSPARENT_COLORS = ["rgba(0, 0, 0, 0)", "transparent"];
  const UDEV_RULES_PATH = "/etc/udev/rules.d/99-worklouder.rules";
  const REQUIRED_WINDOW_BUTTONS = ["minimize", "maximize", "close"];
  const STARTUP_SETTLE_MS = 2000;
  const MENU_ANIMATION_MS = 400;

  const problems = [];
  const warnings = [];
  const deadline = Date.now() + TIMEOUT_MS;
  const delay = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  process.on("unhandledRejection", (reason) => {
    problems.push(`main-process unhandled rejection: ${(reason && reason.stack) || reason}`);
  });
  process.on("uncaughtException", (error) => {
    problems.push(`main-process uncaught exception: ${(error && error.stack) || error}`);
  });

  const finish = (details) => {
    const failed = problems.length > 0;
    console.log("");
    console.log(failed ? "SMOKE_TEST_FAIL" : "SMOKE_TEST_OK");
    if (details) {
      console.log(`SMOKE_TEST_DETAILS ${JSON.stringify(details)}`);
    }
    for (const problem of problems) {
      console.log(`SMOKE_TEST_PROBLEM ${problem}`);
    }
    for (const warning of [...new Set(warnings)]) {
      console.log(`SMOKE_TEST_WARNING ${warning}`);
    }
    app.exit(failed ? 1 : 0);
  };

  const isMainWindow = (win) => {
    if (win.isDestroyed()) return false;
    const url = win.webContents.getURL() || "";
    return url.includes("index.html") || url === "";
  };

  const watchConsole = (webContents) => {
    webContents.on("console-message", (...args) => {
      const first = args[0];
      const isDetailsObject = first && typeof first === "object" && "message" in first;
      const level = isDetailsObject ? first.level : args[1];
      const message = isDetailsObject ? first.message : args[2];
      if (level !== "error" && level !== 3) return;
      const text = String(message);
      const brokenBundle = BROKEN_BUNDLE_CONSOLE_PATTERNS.some((p) => p.test(text));
      (brokenBundle ? problems : warnings).push(`renderer console error: ${text}`);
    });
  };

  const waitForMainWindow = async () => {
    while (Date.now() < deadline) {
      const win = BrowserWindow.getAllWindows().find(isMainWindow);
      if (win) return win;
      await delay(250);
    }
    return null;
  };

  const probeRenderer = (webContents) =>
    webContents.executeJavaScript(
      `(() => {
        const root = document.querySelector("#root");
        return {
          url: location.href,
          readyState: document.readyState,
          rootChildren: root ? root.children.length : -1,
          textLength: ((document.body && document.body.innerText) || "").trim().length,
          windowBridge: typeof window.inputLinuxWindow === "object",
          windowButtons: Array.from(
            document.querySelectorAll("#input-linux-window-controls button")
          ).map((b) => b.dataset.action),
          hamburger: !!document.querySelector(
            '#input-linux-window-controls button[data-action="menu"]'
          ),
          udevPopupVisible: (() => {
            const popup = document.getElementById("udev-popup");
            return popup ? popup.classList.contains("show") : null;
          })(),
          rootRadius: (() => {
            if (!root) return null;
            return Math.round(parseFloat(getComputedStyle(root).borderTopLeftRadius) || 0);
          })(),
          backgrounds: {
            html: getComputedStyle(document.documentElement).backgroundColor,
            body: getComputedStyle(document.body).backgroundColor,
            root: root ? getComputedStyle(root).backgroundColor : null,
          },
          rootFills: (() => {
            if (!root) return false;
            const r = root.getBoundingClientRect();
            return (
              Math.round(r.width) >= window.innerWidth - 1 &&
              Math.round(r.height) >= window.innerHeight - 1
            );
          })(),
          navbar: (() => {
            const bar = document.querySelector('[class*="_navbar_"]');
            if (!bar) return null;
            const style = getComputedStyle(bar);
            return {
              height: Math.round(bar.getBoundingClientRect().height),
              paddingRight: Math.round(parseFloat(style.paddingRight) || 0),
            };
          })(),
          channelGlobals: Object.keys(window).filter((k) => /Channel$/.test(k)).sort(),
          missingGlobals: ${JSON.stringify(REQUIRED_GLOBALS)}.filter(
            (k) => typeof window[k] === "undefined"
          ),
        };
      })()`,
      true
    );

  const probeMenu = (webContents, keepOpen) =>
    webContents.executeJavaScript(
      `(async () => {
        const trigger = document.querySelector(
          '#input-linux-window-controls button[data-action="menu"]'
        );
        if (!trigger) return { opened: false };
        trigger.click();
        await new Promise((r) => setTimeout(r, ${MENU_ANIMATION_MS}));

        const panel = document.getElementById("input-linux-menu-panel");
        if (!panel || !panel.classList.contains("is-open")) return { opened: false };

        const panelRect = panel.getBoundingClientRect();
        const items = Array.from(panel.querySelectorAll(".input-linux-menu-item"));
        const labels = Array.from(panel.querySelectorAll(".input-linux-menu-label"));

        const result = {
          opened: true,
          items: items.length,
          headings: Array.from(panel.querySelectorAll(".input-linux-menu-heading"))
            .map((h) => h.textContent),
          width: Math.round(panelRect.width),
          onScreen:
            panelRect.left >= 0 &&
            panelRect.top >= 0 &&
            panelRect.right <= window.innerWidth + 1,
          escaping: items.filter((item) => {
            const r = item.getBoundingClientRect();
            return r.left < panelRect.left - 1 || r.right > panelRect.right + 1;
          }).length,
          clipped: labels
            .filter((l) => l.scrollWidth > l.clientWidth + 1)
            .map((l) => l.textContent),
        };

        if (!${keepOpen ? "true" : "false"}) trigger.click();
        return result;
      })()`,
      true
    );

  const checkLinuxWindowChrome = async (win, report) => {
    report.menuBarVisible = win.isMenuBarVisible();
    report.resizable = win.isResizable();

    if (report.menuBarVisible) {
      problems.push("the GTK menu bar is still visible above the app header");
    }
    if (!report.windowBridge) {
      problems.push(
        "window.inputLinuxWindow is missing — the preload bridge did not load"
      );
    }

    const missingButtons = REQUIRED_WINDOW_BUTTONS.filter(
      (action) => !report.windowButtons.includes(action)
    );
    if (missingButtons.length > 0) {
      problems.push(
        `window buttons missing from the app header: ${missingButtons.join(", ")} ` +
          `(found: ${report.windowButtons.join(", ") || "none"})`
      );
    }
    if (!report.resizable) {
      problems.push(
        "the window is not resizable — transparency for the rounded corners broke it"
      );
    }
    if (!report.rootRadius) {
      problems.push("#root has no border-radius — the window corners are square");
    }
    if (report.backgrounds && !TRANSPARENT_COLORS.includes(report.backgrounds.html)) {
      problems.push(
        `the root element paints ${report.backgrounds.html}, which covers the whole ` +
          "canvas and hides the rounded corners"
      );
    }
    if (report.backgrounds && !TRANSPARENT_COLORS.includes(report.backgrounds.body)) {
      problems.push(
        `body paints ${report.backgrounds.body}, which hides the rounded corners`
      );
    }
    if (!report.rootFills) {
      problems.push("#root does not fill the window — the corners would not line up");
    }
    if (!report.hamburger) {
      problems.push("the hamburger menu button is missing from the app header");
    }

    report.udevRulesInstalled = existsSync(UDEV_RULES_PATH);
    if (report.udevRulesInstalled && report.udevPopupVisible) {
      problems.push(
        "the udev setup popup is showing even though the rules are already installed"
      );
    }

    const appMenu = Menu.getApplicationMenu();
    report.menuSections = appMenu ? appMenu.items.map((item) => item.label) : [];
    if (report.menuSections.length === 0) {
      problems.push(
        "the application menu is empty — the hamburger would have nothing to show"
      );
    }

    try {
      const menu = await probeMenu(
        win.webContents,
        process.env.INPUT_SMOKE_TEST_OPEN_MENU === "1"
      );
      report.menu = menu;
      if (!menu.opened) {
        problems.push("the hamburger menu did not open");
        return;
      }
      if (menu.items === 0) {
        problems.push("the hamburger menu opened but rendered no items");
      }
      if (menu.escaping > 0) {
        problems.push(`${menu.escaping} menu item(s) render outside the dropdown panel`);
      }
      if (menu.clipped.length > 0) {
        problems.push(`menu labels are clipped: ${menu.clipped.join(", ")}`);
      }
      if (!menu.onScreen) {
        problems.push("the dropdown is positioned partly off-screen");
      }
    } catch (error) {
      problems.push(`could not probe the hamburger menu: ${error && error.message}`);
    }
  };

  const captureScreenshot = async (win) => {
    const screenshotPath = process.env.INPUT_SMOKE_TEST_SCREENSHOT;
    if (!screenshotPath) return;
    try {
      const image = await win.webContents.capturePage();
      await writeFile(screenshotPath, image.toPNG());
      console.log(`SMOKE_TEST_SCREENSHOT ${screenshotPath}`);
    } catch (error) {
      warnings.push(`could not capture screenshot: ${error && error.message}`);
    }
  };

  const waitForLoad = (win) =>
    new Promise((resolve) => {
      win.webContents.once("did-finish-load", resolve);
      win.webContents.once("did-fail-load", (_event, code, description, url) => {
        problems.push(`renderer failed to load ${url}: ${description} (${code})`);
        resolve();
      });
      setTimeout(resolve, Math.max(0, deadline - Date.now()));
    });

  const waitForRendererToMount = async (win) => {
    let report = null;
    while (Date.now() < deadline) {
      try {
        report = await probeRenderer(win.webContents);
      } catch (error) {
        problems.push(`could not probe renderer: ${error && error.message}`);
        return report;
      }
      if (report.rootChildren > 0 && report.missingGlobals.length === 0) return report;
      await delay(500);
    }
    return report;
  };

  app.whenReady().then(async () => {
    const win = await waitForMainWindow();
    if (!win) {
      problems.push(`no main window appeared within ${TIMEOUT_MS}ms`);
      return finish(null);
    }

    watchConsole(win.webContents);

    if (win.webContents.isLoading()) {
      await waitForLoad(win);
    }

    let report = await waitForRendererToMount(win);
    if (!report) return finish(null);

    if (report.rootChildren === -1) {
      problems.push("renderer has no #root element — wrong document loaded?");
    } else if (report.rootChildren === 0) {
      problems.push("renderer mounted nothing into #root (blank window)");
    }
    if (report.missingGlobals.length > 0) {
      problems.push(
        `preload did not expose: ${report.missingGlobals.join(", ")} ` +
          `(exposed: ${report.channelGlobals.join(", ") || "none"})`
      );
    }

    await delay(STARTUP_SETTLE_MS);
    report = await probeRenderer(win.webContents).catch(() => report);

    if (process.platform === "linux") {
      await checkLinuxWindowChrome(win, report);
    }

    await captureScreenshot(win);
    finish(report);
  });
}
