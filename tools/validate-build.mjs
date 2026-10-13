import assert from 'node:assert/strict';
import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const config = JSON.parse(readFileSync(join(root, 'project.json'), 'utf8'));
const target = join(resolve(process.env.PZ_BUILD_ROOT || join(root, 'build')), config.title);
const source = join(root, 'Apocalipsebr-regions');
const mod = join(target, 'Contents/mods/Apocalipsebr-regions');
function files(dir, prefix = '') {
    return readdirSync(dir, { withFileTypes: true }).flatMap(entry => {
        const relative = join(prefix, entry.name);
        return entry.isDirectory() ? files(join(dir, entry.name), relative) : [relative];
    });
}
const expected = files(source).filter(file => !file.endsWith('.gitkeep')).sort();
const actual = files(mod).filter(file => file !== 'mod.info').sort();
assert.deepEqual(actual, expected, 'Packaged file list differs from source');
for (const relative of expected) {
    assert.ok(readFileSync(join(source, relative)).equals(readFileSync(join(mod, relative))), relative);
}
for (const version of ['', '42.14', '42.18']) {
    assert.match(readFileSync(join(mod, version, 'mod.info'), 'utf8'), /^id=ApocalipseBR_Regioes$/m);
}
assert.match(readFileSync(join(target, 'workshop.txt'), 'utf8'), new RegExp(`^id=${config.workshop.id}$`, 'm'));
const description = readFileSync(join(root, 'Workshop/description.txt'), 'utf8')
    .split(/\r?\n/).map(line => `description=${line}`).join('\n');
assert.ok(readFileSync(join(target, 'workshop.txt'), 'utf8').includes(description), 'Workshop description differs from source');
assert.ok(readFileSync(join(target, 'preview.png')).equals(readFileSync(join(root, 'Workshop/preview.png'))));
const result = spawnSync(process.execPath, ['tests/regions_spec.cjs'], { cwd: root, stdio: 'inherit', env: { ...process.env, REGIONS_MOD: mod } });
assert.equal(result.status, 0, 'Packaged Lua behavior failed');
console.log(`Validated ${expected.length} byte-identical mod files, mod ID, preview and Workshop ID.`);
