const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

// Exercise the shipped plugin's output boundary without a browser or network.
function renderNote(note) {
  const created = [];
  const appended = [];
  class Element {
    constructor(html = '') { this.html = html; this.textContent = ''; this.styles = {}; }
    css(values) { Object.assign(this.styles, values); return this; }
    text(value) { this.textContent = value; return this; }
    offset() { return { left: 0, top: 0 }; }
    width() { return 100; }
    height() { return 100; }
    hover() { return this; }
    attr(key, value) { this[key] = value; return this; }
    off() { return this; }
    on() { return this; }
    remove() { return this; }
    resize() { return this; }
    append(value) { appended.push(value); return this; }
  }
  function jquery(value) {
    if (value instanceof Element) return value;
    if (Array.isArray(value)) return { each(fn) { value.forEach(item => fn.call(item)); } };
    const element = new Element(typeof value === 'string' ? value : '');
    if (element.html.startsWith('<')) created.push(element);
    return element;
  }
  jquery.fn = {};
  const context = vm.createContext({ jQuery: jquery, window: {} });
  const script = resolve(__dirname, '../../../ext/notes/lib/jquery.imgnotes-1.0.min.js');
  vm.runInContext(readFileSync(script, 'utf8'), context);
  jquery.fn.imgNotes.call(new Element(), {
    notes: [{ note_id: 42, x1: 2, y1: 3, width: 20, height: 10, note }]
  });
  return { created, appended };
}

test('note HTML is treated as text, including existing script and event attributes', () => {
  const payload = '<img src=x onerror="window.noteAuditMarker=1"></script><script>test</script>';
  const { created, appended } = renderNote(payload);
  assert.equal(created.length, 2);
  assert.ok(created.every(element => !element.html.includes(payload)));
  assert.equal(appended[1].textContent, payload);
});

test('note text preserves punctuation, line breaks and placement', () => {
  const note = 'A < B & C\nsecond line';
  const { appended } = renderNote(note);
  assert.equal(appended[1].textContent, note);
  assert.equal(appended[1].styles.whiteSpace, 'pre-wrap');
  assert.equal(appended[0].styles.left, '2px');
  assert.equal(appended[0].styles.width, '20px');
  assert.equal(appended[0]['data-note-id'], '42');
});
