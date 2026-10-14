import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createContext, runInContext } from 'node:vm';
test('join page immediately strips the invitation fragment, copies full link and never fetches', async () => {
    let source = '';
    try {
        source = await readFile(new URL('../public/join.js', import.meta.url), 'utf8');
    }
    catch {
    }
    assert.ok(source, 'join page script must exist');
    let stripped = false, copied = '', fetches = 0;
    const elements = new Map<string, any>();
    const element = (id: string) => {
        if (!elements.has(id)) {
            elements.set(id, {
                textContent: '', disabled: false, addEventListener(_event: string, handler: any) {
                    this.handler = handler;
                }
            });
        }
        return elements.get(id);
    };
    const context = createContext({
        URLSearchParams, location: {
            hash: '#token=private', origin: 'https://demo.test', pathname: '/join.html'
        }, history: { replaceState(_a: any, _b: any, url: string) {
                assert.equal(url, '/join.html');
                stripped = true;
            } }, document: { getElementById: element }, navigator: { clipboard: { async writeText(value: string) {
                    copied = value;
                } } }, fetch() {
            fetches++;
            throw Error('join must never use API');
        }
    });
    runInContext(source, context);
    assert.equal(stripped, true);
    await element('copy-invitation').handler();
    assert.equal(copied, 'https://demo.test/join.html#token=private');
    assert.equal(fetches, 0);
});
