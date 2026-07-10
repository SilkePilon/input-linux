// From Input-Linux Patch
import { app } from 'electron';
import { fileURLToPath } from 'url';
import { dirname } from 'path';

if (process.env.APPIMAGE) {
  app.commandLine.appendSwitch('no-sandbox');
}

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
