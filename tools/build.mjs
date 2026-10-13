import { copyFileSync, existsSync, lstatSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { dirname, isAbsolute, join, relative, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const config = JSON.parse(readFileSync(join(root, 'project.json'), 'utf8'));
const allowed = resolve(process.env.PZ_BUILD_ROOT || join(root, 'build'));
if (typeof config.title !== 'string' || !config.title || /[/\\]/.test(config.title)
    || config.title === '.' || config.title === '..') throw new Error('Invalid Workshop title');
const target = resolve(allowed, config.title);
const toSource = relative(target, root);
const fromMod = relative(join(root, 'Apocalipsebr-regions'), target);
if (dirname(target) !== allowed || target === root
    || (toSource && !toSource.startsWith('..') && !isAbsolute(toSource))
    || (!fromMod.startsWith('..') && !isAbsolute(fromMod))
    || (existsSync(target) && lstatSync(target).isSymbolicLink())) {
    throw new Error('Invalid build target');
}
if (process.argv.includes('--clean')) {
    if (existsSync(target)) rmSync(target, { recursive: true });
    console.log(`Cleaned ${target}`);
} else {
    // Use the pinned PZ Studio builder without changing the user's global .pzstudio
    // output setting. Its build command already removes previous output, whereas
    // `pzstudio clean && pzstudio build` fails on a fresh checkout.
    mkdirSync(allowed, { recursive: true });
    process.chdir(root);
    const require = createRequire(import.meta.url);
    const helper = require('pzstudio/dist/lib/helper.js');
    helper.getOutDir = () => allowed;
    await require('pzstudio/dist/lib/commands/build.js').buildCmd();
    // Preserve the existing game mod ID and the case-sensitive Workshop asset path.
    copyFileSync(join(root, "Apocalipsebr-regions/42.14/mod.info"), join(target, "Contents/mods/Apocalipsebr-regions/mod.info"));
    copyFileSync(join(root, "Workshop/preview.png"), join(target, "preview.png"));
    const metadata = readFileSync(join(target, 'workshop.txt'), 'utf8')
        .split(/\r?\n/).filter(line => !line.startsWith('description=')).join('\n');
    const description = readFileSync(join(root, 'Workshop/description.txt'), 'utf8')
        .split(/\r?\n/).map(line => `description=${line}`).join('\n');
    writeFileSync(join(target, 'workshop.txt'), `${metadata}\n${description}\n`);
    console.log(`Workshop output: ${target}`);
}
