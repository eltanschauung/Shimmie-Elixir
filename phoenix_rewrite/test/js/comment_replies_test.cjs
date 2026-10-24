const assert = require('node:assert/strict');
const { readFileSync } = require('node:fs');
const { resolve } = require('node:path');
const { test } = require('node:test');
const vm = require('node:vm');

function reply({ missingForm = false, modifiers = {} } = {}) {
  const box = { value: 'before ', focus() { this.focused = true; } };
  let handler;
  const username = 'legacy");window.replyAuditMarker=1;//';
  const link = { dataset: { imageId: '101', commentId: '901', username } };
  const document = {
    addEventListener(type, callback) { assert.equal(type, 'click'); handler = callback; },
    getElementById(id) { return !missingForm && id === 'comment_on_101' ? box : null; }
  };
  const window = {};
  vm.runInNewContext(readFileSync(resolve(__dirname, '../../../ext/comment/replies.js'), 'utf8'), { document, window });
  const event = { button: 0, target: { closest: () => link }, preventDefault() { this.defaultPrevented = true; }, ...modifiers };
  handler(event);
  return { box, event, window, username };
}

test('replies append literal user names without executing them', () => {
  const { box, event, window, username } = reply();
  assert.equal(box.value, `before [url=site://post/view/101#c901]@${username}[/url]: `);
  assert.equal(box.focused, true);
  assert.equal(event.defaultPrevented, true);
  assert.equal(window.replyAuditMarker, undefined);
});

test('without an inline form the normal post link remains usable', () => {
  const { event } = reply({ missingForm: true });
  assert.equal(event.defaultPrevented, undefined);
});

test('modified clicks retain native link behavior', () => {
  for (const modifiers of [{ ctrlKey: true }, { metaKey: true }, { button: 1 }]) {
    const { box, event } = reply({ modifiers });
    assert.equal(box.value, 'before ');
    assert.equal(event.defaultPrevented, undefined);
  }
});
