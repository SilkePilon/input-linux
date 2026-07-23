import { ipcMain } from "electron";
import { execFile } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { chmod, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

if (process.platform === "linux") {
  const UDEV_CHANNEL = "input-linux:udev";
  const RULES_PATH = "/etc/udev/rules.d/99-worklouder.rules";
  const PKEXEC_PATH = "/usr/bin/pkexec";
  const INSTALLER_NAME = "install-udev-worklouder.sh";
  const OWNER_READ_WRITE_EXECUTE = 0o700;
  const INSTALL_TIMEOUT_MS = 120000;

  const run = promisify(execFile);
  const bundledInstaller = join(
    dirname(fileURLToPath(import.meta.url)),
    "../scripts",
    INSTALLER_NAME
  );

  const stageInstaller = async () => {
    const stagedPath = join(tmpdir(), `input-linux-${process.pid}-${INSTALLER_NAME}`);
    await writeFile(stagedPath, readFileSync(bundledInstaller));
    await chmod(stagedPath, OWNER_READ_WRITE_EXECUTE);
    return stagedPath;
  };

  const status = () => ({
    rulesInstalled: existsSync(RULES_PATH),
    canElevate: existsSync(PKEXEC_PATH),
    rulesPath: RULES_PATH,
  });

  ipcMain.handle(UDEV_CHANNEL, async (_event, action) => {
    try {
      if (action === "status") {
        return status();
      }

      if (action === "stage") {
        return { ok: true, path: await stageInstaller() };
      }

      if (action === "install") {
        if (!existsSync(PKEXEC_PATH)) {
          return { ok: false, error: "pkexec is not available on this system" };
        }
        const stagedPath = await stageInstaller();
        await run(PKEXEC_PATH, ["bash", stagedPath], { timeout: INSTALL_TIMEOUT_MS });
        return { ok: existsSync(RULES_PATH), ...status() };
      }

      return { ok: false, error: `unknown action: ${action}` };
    } catch (error) {
      const message = (error && error.message) || String(error);
      console.warn(`|linux_udev| ${action} failed: ${message}`);
      return { ok: false, error: message, ...status() };
    }
  });
}
