import { app } from 'electron';

if (process.env.APPIMAGE) {
  app.commandLine.appendSwitch('no-sandbox');
}

if (process.platform === 'linux') {
  app.commandLine.appendSwitch('enable-transparent-visuals');
}
