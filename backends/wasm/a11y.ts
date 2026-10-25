// The screen-reader mirror of the sw_ui semantic tree (REQ-A11Y-001).
//
// A canvas UI has no DOM, so a screen reader finds nothing in it. The wasm
// build sends the semantic tree here (libs/sw_ui/src/web_mirror.zig), and
// this file keeps a tree of hidden DOM elements in sync with it:
//
// - group: <div>, with role="group" and aria-label when it has a name
// - text: <div>, with aria-live="polite" for a live region (REQ-A11Y-003)
// - button: <button>
// - list: <ul> with aria-label, list item: <li>
// - text field: <input type="text"> with aria-label and the value
// - image: <div role="img"> with aria-label
//
// The element of the focused node gets DOM focus, so a screen reader follows
// the focus of the game (REQ-A11Y-002). The elements have tabindex -1: the
// game moves the focus, not the browser. The keys still go to the game,
// because events.ts listens on the window.
//
// The mirror is visually hidden with the standard clip CSS, not with
// display: none, because the browser removes a display: none element from
// the accessibility tree (REQ-A11Y-004).
//
// The wasm build sends the tree only when it changes (REQ-A11Y-005). This
// file changes only the DOM attributes that differ. A live region then
// speaks only when its text changes.
//
// Text fields: while the game has text input on, events.ts gives DOM focus
// to its own hidden <input> for the input method. This file then gives that
// input the name of the field and does not take the focus from it.

import { setTextInputLabel, textInputHasFocus } from './events';

/** The role byte of the wire format: the same order as roleCode in Zig. */
const ROLES = [
  'group',
  'text',
  'button',
  'list',
  'list_item',
  'text_field',
  'image',
] as const;
export type A11yRole = (typeof ROLES)[number];

const FLAG_FOCUSED = 1 << 0;
const FLAG_DISABLED = 1 << 1;
const FLAG_SELECTED = 1 << 2;
const FLAG_LIVE = 1 << 3;

export interface A11yNode {
  id: number;
  role: A11yRole;
  name: string;
  value: string;
  focused: boolean;
  disabled: boolean;
  selected: boolean;
  live: boolean;
  /** Indices into the node list. */
  children: number[];
}

/** The ID of the mirror root element. */
export const A11Y_ROOT_ID = 'swindowzig-a11y';

// The standard visually-hidden CSS. The element stays in the accessibility
// tree and takes focus, but has no visible area.
const VISUALLY_HIDDEN: Partial<CSSStyleDeclaration> = {
  position: 'absolute',
  width: '1px',
  height: '1px',
  padding: '0',
  margin: '-1px',
  overflow: 'hidden',
  clip: 'rect(0, 0, 0, 0)',
  clipPath: 'inset(50%)',
  whiteSpace: 'nowrap',
  border: '0',
};

const decoder = new TextDecoder();

/** Decode the wire format of web_mirror.zig. */
export function decodeTree(bytes: Uint8Array): A11yNode[] {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  let at = 0;
  const u32 = (): number => {
    const v = view.getUint32(at, true);
    at += 4;
    return v;
  };
  const str = (): string => {
    const len = u32();
    const s = decoder.decode(bytes.subarray(at, at + len));
    at += len;
    return s;
  };

  const count = u32();
  const nodes: A11yNode[] = [];
  for (let i = 0; i < count; i++) {
    const id = u32();
    const role = ROLES[view.getUint8(at)] ?? 'group';
    const flags = view.getUint8(at + 1);
    at += 2;
    const name = str();
    const value = str();
    const childCount = u32();
    const children: number[] = [];
    for (let c = 0; c < childCount; c++) children.push(u32());
    nodes.push({
      id,
      role,
      name,
      value,
      focused: (flags & FLAG_FOCUSED) !== 0,
      disabled: (flags & FLAG_DISABLED) !== 0,
      selected: (flags & FLAG_SELECTED) !== 0,
      live: (flags & FLAG_LIVE) !== 0,
      children,
    });
  }
  return nodes;
}

interface Entry {
  el: HTMLElement;
  role: A11yRole;
  live: boolean;
}

function setAttr(el: HTMLElement, name: string, value: string | null): void {
  if (value === null) {
    if (el.hasAttribute(name)) el.removeAttribute(name);
  } else if (el.getAttribute(name) !== value) {
    el.setAttribute(name, value);
  }
}

function setText(el: HTMLElement, text: string): void {
  if (el.textContent !== text) el.textContent = text;
}

function createElement(node: A11yNode): HTMLElement {
  switch (node.role) {
    case 'button': {
      const b = document.createElement('button');
      b.type = 'button';
      return b;
    }
    case 'list':
      return document.createElement('ul');
    case 'list_item':
      return document.createElement('li');
    case 'text_field': {
      const input = document.createElement('input');
      input.type = 'text';
      // No on-screen keyboard: the game decides when text input is on.
      input.inputMode = 'none';
      input.autocomplete = 'off';
      return input;
    }
    default:
      return document.createElement('div');
  }
}

/** Write the state of `node` into its element. */
function updateElement(el: HTMLElement, node: A11yNode): void {
  setAttr(el, 'data-sw-id', String(node.id));
  setAttr(el, 'aria-disabled', node.disabled ? 'true' : null);
  const name = node.name === '' ? null : node.name;
  switch (node.role) {
    case 'group':
      setAttr(el, 'role', name === null ? null : 'group');
      setAttr(el, 'aria-label', name);
      break;
    case 'text':
      setAttr(el, 'aria-live', node.live ? 'polite' : null);
      setText(el, node.name);
      break;
    case 'button':
      setAttr(el, 'tabindex', '-1');
      setText(el, node.name);
      break;
    case 'list':
      setAttr(el, 'aria-label', name);
      break;
    case 'list_item':
      setAttr(el, 'tabindex', '-1');
      setAttr(el, 'aria-current', node.selected ? 'true' : null);
      setText(el, node.name);
      break;
    case 'text_field': {
      const input = el as HTMLInputElement;
      setAttr(el, 'tabindex', '-1');
      setAttr(el, 'aria-label', name);
      if (input.value !== node.value) input.value = node.value;
      break;
    }
    case 'image':
      setAttr(el, 'role', 'img');
      setAttr(el, 'aria-label', name);
      break;
  }
}

/** Put `children` into `parent` in this order, and remove other children. */
function arrangeChildren(parent: HTMLElement, children: HTMLElement[]): void {
  children.forEach((child, i) => {
    const at = parent.children[i] ?? null;
    if (at !== child) parent.insertBefore(child, at);
  });
  while (parent.children.length > children.length) {
    parent.lastElementChild?.remove();
  }
}

/** The hidden DOM tree. There is one on a page. */
class Mirror {
  private root: HTMLElement | null = null;
  private entries = new Map<number, Entry>();

  private ensureRoot(): HTMLElement {
    if (this.root?.isConnected) return this.root;
    const root = document.createElement('div');
    root.id = A11Y_ROOT_ID;
    Object.assign(root.style, VISUALLY_HIDDEN);
    document.body.appendChild(root);
    this.root = root;
    return root;
  }

  /** Remove the mirror. */
  clear(): void {
    this.root?.remove();
    this.root = null;
    this.entries.clear();
    setTextInputLabel(null);
  }

  update(nodes: A11yNode[]): void {
    if (nodes.length === 0) {
      this.clear();
      return;
    }
    const root = this.ensureRoot();

    // Make or update the element of each node. Node 0 is the root of the
    // tree, and the mirror root element stands for it.
    const elements: HTMLElement[] = [root];
    const seen = new Set<number>();
    for (let i = 1; i < nodes.length; i++) {
      const node = nodes[i];
      seen.add(node.id);
      let entry = this.entries.get(node.id);
      if (!entry || entry.role !== node.role || entry.live !== node.live) {
        // A new node, or a node with another element type. A live region
        // must exist before its text changes, so it is not made again.
        entry?.el.remove();
        entry = { el: createElement(node), role: node.role, live: node.live };
        this.entries.set(node.id, entry);
      }
      updateElement(entry.el, node);
      elements.push(entry.el);
    }

    // Put the elements into the tree order.
    nodes.forEach((node, i) => {
      arrangeChildren(
        elements[i],
        node.children.map((c) => elements[c]),
      );
    });

    // Remove the elements of nodes that are gone.
    for (const [id, entry] of this.entries) {
      if (!seen.has(id)) {
        entry.el.remove();
        this.entries.delete(id);
      }
    }

    this.syncFocus(nodes, elements, root);
  }

  private syncFocus(
    nodes: A11yNode[],
    elements: HTMLElement[],
    root: HTMLElement,
  ): void {
    const index = nodes.findIndex((n) => n.focused);
    const focused = index > 0 ? nodes[index] : null;

    // The input-method <input> of events.ts gets the name of a focused text
    // field.
    setTextInputLabel(focused?.role === 'text_field' ? focused.name : null);

    if (focused) {
      const el = elements[index];
      // While text input is on, the input-method <input> keeps the focus.
      if (focused.role === 'text_field' && textInputHasFocus()) return;
      if (document.activeElement !== el) el.focus({ preventScroll: true });
    } else if (
      document.activeElement instanceof HTMLElement &&
      root.contains(document.activeElement)
    ) {
      document.activeElement.blur();
    }
  }
}

const mirror = new Mirror();

/** The "a11y" wasm imports. */
export function createA11yImports(getMemory: () => WebAssembly.Memory): {
  jsA11yUpdate: (ptr: number, len: number) => void;
} {
  return {
    jsA11yUpdate: (ptr: number, len: number): void => {
      if (len === 0) {
        mirror.clear();
        return;
      }
      // Copy the bytes: the wasm memory can grow while the DOM updates.
      const bytes = new Uint8Array(getMemory().buffer, ptr, len).slice();
      mirror.update(decodeTree(bytes));
    },
  };
}
