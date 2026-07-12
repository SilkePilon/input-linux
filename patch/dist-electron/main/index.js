// From Input-Linux Patch
import { app } from 'electron';

if (process.env.APPIMAGE) {
  app.commandLine.appendSwitch('no-sandbox');
}

// ^^^^^^^^^^^^^^^^^^^^^^^^^^^^
