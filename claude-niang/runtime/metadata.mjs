import fs from 'node:fs';

// Runtime, installer and the Claude Desktop extension report this version.
const manifest = JSON.parse(fs.readFileSync(new URL('../package.json', import.meta.url), 'utf8').replace(/^﻿/, ''));
export const pluginVersion = manifest.version;
