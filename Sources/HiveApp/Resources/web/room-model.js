/* The classroom as a tile grid: catalogue, automatic room, rules, desk slots and activity spots.
   Pure functions, used by room.js and room-editor.js in the browser and by tests in Node. */
"use strict";
(function(root){
  const RoomPath = root.RoomPath || (typeof require === "function" ? require("./room-path.js") : null);
  const TILE = 40, WALL_ROWS = 4, FRONT_ROWS = 6;
  const MIN_COLS = 16, MAX_COLS = 48, MIN_ROWS = 12, MAX_ROWS = 36, MAX_ITEMS = 400;
  const FLOORS = ["tile", "wood", "carpet"];
  // Footprint in tiles, zone, whether it blocks walking, the activity it offers, and the id prefix for new ones.
  const CATALOGUE = {
    desk:     {w: 3, h: 2, zone: "floor", blocks: true,  activity: null,     label: "Desk",     prefix: "d"},
    shelf:    {w: 4, h: 1, zone: "floor", blocks: true,  activity: "read",   label: "Bookshelf", prefix: "s"},
    globe:    {w: 2, h: 2, zone: "floor", blocks: true,  activity: "web",    label: "Globe",    prefix: "g"},
    machine:  {w: 2, h: 3, zone: "floor", blocks: true,  activity: "run",    label: "Machine",  prefix: "m"},
    rug:      {w: 5, h: 3, zone: "floor", blocks: false, activity: "nap",    label: "Rug",      prefix: "r"},
    beanbag:  {w: 1, h: 1, zone: "floor", blocks: true,  activity: "nap",    label: "Beanbag",  prefix: "bb"},
    couch:    {w: 3, h: 2, zone: "floor", blocks: true,  activity: "stroll", label: "Couch",    prefix: "c"},
    plant:    {w: 1, h: 1, zone: "floor", blocks: true,  activity: "stroll", label: "Plant",    prefix: "p"},
    fountain: {w: 1, h: 2, zone: "floor", blocks: true,  activity: "stroll", label: "Water fountain", prefix: "f"},
    lamp:     {w: 1, h: 1, zone: "floor", blocks: true,  activity: null,     label: "Lamp",     prefix: "l"},
    window:   {w: 3, h: 2, zone: "wall",  blocks: false, activity: "stroll", label: "Window",   prefix: "w"},
    board:    {w: 12, h: 3, zone: "wall", blocks: false, activity: "stroll", label: "Chalkboard", prefix: "b"},
    door:     {w: 3, h: 4, zone: "wall",  blocks: false, activity: null,     label: "Door",     prefix: "door"},
    poster:   {w: 2, h: 2, zone: "wall",  blocks: false, activity: null,     label: "Poster",   prefix: "ps"},
    clock:    {w: 1, h: 1, zone: "wall",  blocks: false, activity: null,     label: "Clock",    prefix: "k"},
  };
  const ACTIVITIES = ["read", "web", "run", "nap", "stroll"];
  const isInt = n => Number.isInteger(n);
  const name = it => `${it.kind} ${it.id}`;
  const floorBottom = room => room.rows - FRONT_ROWS;   // first front row; the floor is WALL_ROWS .. floorBottom-1
  const seatTile = d => ({x: d.x + 1, y: d.y - 1});
  const doorTile = room => { const d = room.items.find(i => i.kind === "door"); return d ? {x: d.x + 1, y: WALL_ROWS} : null; };
  const overlaps = (a, b) => { const A = CATALOGUE[a.kind], B = CATALOGUE[b.kind];
    return a.x < b.x + B.w && b.x < a.x + A.w && a.y < b.y + B.h && b.y < a.y + A.h; };

  function newId(room, kind){
    const p = CATALOGUE[kind].prefix, used = new Set(room.items.map(i => i.id));
    for(let n = 1; ; n++) if(!used.has(p + n)) return p + n;
  }

  // The room the page builds when nothing is saved: one desk per session plus a spare, as today.
  function autoRoom(deskCount){
    const n = Math.max(1, Math.floor(deskCount) || 0);
    const R = Math.ceil(n / 6), C = Math.ceil(n / R);
    const cols = Math.max(24, 12 + 4 * C), rows = Math.max(18, 13 + 3 * R);
    const items = [];
    for(let r = R - 1; r >= 0; r--){                 // front row first
      const k = r === 0 ? n - (R - 1) * C : C, x0 = Math.floor((cols - (4 * k - 1)) / 2), mid = x0 + (4 * k - 1) / 2;
      const row = [];
      for(let c = 0; c < k; c++) row.push({x: x0 + 4 * c, y: 6 + 3 * r, i: c});
      // Centre outwards; the left one first when two are as close.
      row.sort((p, q) => Math.abs(p.x + 1.5 - mid) - Math.abs(q.x + 1.5 - mid) || p.i - q.i);
      for(const d of row) items.push({id: "d" + (items.length + 1), kind: "desk", x: d.x, y: d.y});
    }
    const add = (id, kind, x, y) => items.push({id, kind, x, y});
    add("s1", "shelf", 1, 4); add("p1", "plant", 1, 6); add("g1", "globe", 2, 7); add("r1", "rug", 1, rows - 9);
    add("m1", "machine", cols - 4, 5); add("f1", "fountain", cols - 3, rows - 9);
    add("w1", "window", 1, 1); add("b1", "board", Math.floor(cols / 2) - 6, 0); add("k1", "clock", cols - 6, 1);
    add("door", "door", cols - 4, 0);
    if(cols >= 32) add("w2", "window", Math.floor(cols / 2) + 7, 1);
    return {version: 1, cols, rows, floor: {style: "tile", color: null}, wall: {color: null}, items};
  }

  // Tiles covered by blocking floor items, as a Set of y*cols+x.
  function blockedSet(room, extra){
    const out = new Set();
    for(const it of room.items.concat(extra || [])){
      const c = CATALOGUE[it.kind];
      if(!c || !c.blocks || c.zone !== "floor") continue;
      for(let y = it.y; y < it.y + c.h; y++) for(let x = it.x; x < it.x + c.w; x++) out.add(y * room.cols + x);
    }
    return out;
  }
  function walkGrid(room, extra){
    const b = blockedSet(room, extra);
    return RoomPath.grid(room.cols, room.rows, (x, y) => y < WALL_ROWS || b.has(y * room.cols + x));
  }

  // Every tile reachable from (sx, sy), as a Uint8Array over the grid.
  function reach(g, from){
    const seen = new Uint8Array(g.cols * g.rows);
    if(!from || !g.ok(from.x, from.y)) return seen;
    const q = [[from.x, from.y]]; seen[from.y * g.cols + from.x] = 1;
    for(let i = 0; i < q.length; i++){
      const [x, y] = q[i];
      for(const [dx, dy] of [[1,0],[-1,0],[0,1],[0,-1]]){
        const nx = x + dx, ny = y + dy;
        if(g.ok(nx, ny) && !seen[ny * g.cols + nx]){ seen[ny * g.cols + nx] = 1; q.push([nx, ny]); }
      }
    }
    return seen;
  }

  // Problems with one item on its own: kind, coordinates, bounds, zone.
  function itemError(room, it){
    if(!it || typeof it !== "object") return "an item is not an object";
    if(typeof it.id !== "string" || !it.id || it.id.length > 40) return "an item has no id";
    const c = CATALOGUE[it.kind];
    if(!c) return `item ${it.id} is of an unknown kind`;
    if(!isInt(it.x) || !isInt(it.y)) return `${name(it)} must sit on whole tiles`;
    if(it.x < 0 || it.y < 0 || it.x + c.w > room.cols || it.y + c.h > room.rows) return `${name(it)} is outside the room`;
    if(c.zone === "wall" && it.y + c.h > WALL_ROWS) return `${name(it)} must go on the wall`;
    if(c.zone === "floor" && it.y < WALL_ROWS) return `${name(it)} must stand on the floor, not the wall`;
    if(c.zone === "floor" && it.y + c.h > floorBottom(room)) return `${name(it)} can't go in the front of the room`;
    if(it.kind === "shelf" && it.y !== WALL_ROWS) return `${name(it)} must stand against the back wall`;
    return null;
  }

  // Desks whose seat can't be reached from the door, and whether the door itself is blocked.
  function reachErrors(room){
    const g = walkGrid(room), door = doorTile(room);
    if(!door) return [];
    if(!g.ok(door.x, door.y)) return ["the way in from the door is blocked"];
    const seen = reach(g, door), out = [];
    for(const d of room.items) if(d.kind === "desk"){
      const s = seatTile(d);
      if(!g.ok(s.x, s.y) || !seen[s.y * room.cols + s.x]) out.push(`${name(d)} can't be reached from the door`);
    }
    return out;
  }

  function validate(room){
    const errors = [];
    if(!room || typeof room !== "object" || Array.isArray(room)) return {ok: false, errors: ["the room is not an object"]};
    if(room.version !== 1) errors.push("the room file is from another version of Agent Hive");
    if(!isInt(room.cols) || room.cols < MIN_COLS || room.cols > MAX_COLS) errors.push(`the room must be ${MIN_COLS} to ${MAX_COLS} tiles wide`);
    if(!isInt(room.rows) || room.rows < MIN_ROWS || room.rows > MAX_ROWS) errors.push(`the room must be ${MIN_ROWS} to ${MAX_ROWS} tiles deep`);
    const colour = c => c === null || (typeof c === "string" && /^#[0-9a-fA-F]{6}$/.test(c));
    if(!room.floor || !FLOORS.includes(room.floor.style) || !colour(room.floor.color)) errors.push("the floor style or colour is not one Agent Hive knows");
    if(!room.wall || !colour(room.wall.color)) errors.push("the wall colour is not one Agent Hive knows");
    if(!Array.isArray(room.items)) errors.push("the room has no item list");
    else if(room.items.length > MAX_ITEMS) errors.push(`the room has more than ${MAX_ITEMS} items`);
    if(errors.length) return {ok: false, errors};
    const ids = new Set();
    let good = true;
    for(const it of room.items){
      const e = itemError(room, it);
      if(e){ errors.push(e); good = false; continue; }
      if(ids.has(it.id)){ errors.push(`two items are called ${it.id}`); good = false; }
      ids.add(it.id);
    }
    if(!good) return {ok: false, errors};
    for(let i = 0; i < room.items.length; i++) for(let j = 0; j < i; j++){
      const a = room.items[i], b = room.items[j];
      if(CATALOGUE[a.kind].zone === CATALOGUE[b.kind].zone && overlaps(a, b)) errors.push(`${name(a)} overlaps ${name(b)}`);
    }
    const doors = room.items.filter(i => i.kind === "door").length;
    if(doors !== 1) errors.push(doors ? "the room must have exactly one door" : "the room must have exactly one door, and it has none");
    if(!errors.length) errors.push(...reachErrors(room));
    return {ok: !errors.length, errors};
  }

  const fail = (room, error) => ({ok: false, room, error});

  // Adds the item, or moves the one with the same id. The original room is never changed.
  function place(room, item){
    const it = {id: item.id, kind: item.kind, x: item.x, y: item.y};
    const e = itemError(room, it);
    if(e) return fail(room, e);
    const have = room.items.findIndex(i => i.id === it.id);
    if(have >= 0 && room.items[have].kind !== it.kind) return fail(room, `another item is already called ${it.id}`);
    if(have < 0 && it.kind === "door" && room.items.some(i => i.kind === "door")) return fail(room, "the room must have exactly one door");
    const zone = CATALOGUE[it.kind].zone;
    const hit = room.items.find(o => o.id !== it.id && CATALOGUE[o.kind].zone === zone && overlaps(it, o));
    if(hit) return fail(room, `${name(it)} overlaps ${name(hit)}`);
    const items = room.items.slice();
    if(have >= 0) items[have] = it; else items.push(it);
    const next = {...room, items};
    const v = validate(next);
    if(!v.ok) return fail(room, v.errors.find(x => x.includes(it.id)) || v.errors[0]);
    return {ok: true, room: next, error: null};
  }

  function remove(room, id){
    const it = room.items.find(i => i.id === id);
    if(!it) return fail(room, `there is no item ${id}`);
    if(it.kind === "door") return fail(room, "the door can't be removed, only moved");
    return {ok: true, room: {...room, items: room.items.filter(i => i.id !== id)}, error: null};
  }

  // Where each session sits: placed desks in item order, then extra desks on free floor nearest the last placed one.
  function deskSlots(room, sessionCount){
    const placed = room.items.filter(i => i.kind === "desk");
    const slots = placed.map(d => ({x: d.x, y: d.y, extra: false}));
    const want = Math.max(0, Math.floor(sessionCount) || 0);
    if(slots.length >= want) return slots;
    const D = CATALOGUE.desk, top = WALL_ROWS + 1, bottom = floorBottom(room) - D.h;
    const anchor = placed.length ? placed[placed.length - 1] : {x: Math.floor((room.cols - D.w) / 2), y: top};
    const extras = [];
    const cands = [];
    for(let y = top; y <= bottom; y++) for(let x = 0; x <= room.cols - D.w; x++) cands.push({x, y, d: Math.hypot(x - anchor.x, (y - anchor.y) * 1.3)});
    cands.sort((p, q) => p.d - q.d || p.y - q.y || p.x - q.x);
    const door = doorTile(room);
    const seats = () => placed.concat(extras).map(seatTile);
    // A spot is free when the desk (and with margin, a tile all round it) covers no item, no seat and not the door's way in.
    const free = (c, margin) => {
      const m = margin ? 1 : 0, x0 = c.x - m, x1 = c.x + D.w - 1 + m, y0 = c.y - 1, y1 = c.y + D.h - 1 + m;
      if(x0 < 0 || x1 >= room.cols) return false;
      for(const o of room.items.concat(extras)){
        const oc = CATALOGUE[o.kind];
        if(oc.zone !== "floor") continue;
        if(o.x <= x1 && o.x + oc.w > x0 && o.y <= y1 && o.y + oc.h > y0) return false;
      }
      for(const s of seats()) if(s.x >= c.x && s.x < c.x + D.w && s.y >= c.y && s.y < c.y + D.h) return false;
      if(door && door.x >= c.x && door.x < c.x + D.w && door.y >= c.y && door.y < c.y + D.h) return false;
      return true;
    };
    const stillReachable = c => {
      if(!door) return true;
      const g = walkGrid(room, extras.concat({kind: "desk", x: c.x, y: c.y})), seen = reach(g, door);
      return placed.concat(extras, {x: c.x, y: c.y}).every(d => { const s = seatTile(d); return g.ok(s.x, s.y) && seen[s.y * room.cols + s.x]; });
    };
    for(const margin of [true, false]){
      for(const c of cands){
        if(slots.length + extras.length >= want) break;
        if(free(c, margin) && stillReachable(c)) extras.push({kind: "desk", x: c.x, y: c.y});
      }
    }
    return slots.concat(extras.map(e => ({x: e.x, y: e.y, extra: true})));
  }

  // Walkable floor tiles where each activity happens: next to the items that offer it, the side facing the room first.
  function spots(room){
    const g = walkGrid(room), out = {read: [], web: [], run: [], nap: [], stroll: []}, seen = {};
    for(const a of ACTIVITIES) seen[a] = new Set();
    const seatKeys = new Set(room.items.filter(i => i.kind === "desk").map(d => { const s = seatTile(d); return s.y * room.cols + s.x; }));
    const fb = floorBottom(room);
    const add = (a, x, y) => {
      const k = y * room.cols + x;
      if(!g.ok(x, y) || y >= fb || seatKeys.has(k) || seen[a].has(k)) return;
      seen[a].add(k); out[a].push({x, y});
    };
    for(const it of room.items){
      const c = CATALOGUE[it.kind];
      if(!c || !c.activity) continue;
      if(it.kind === "rug"){ for(let y = it.y; y < it.y + c.h; y++) for(let x = it.x; x < it.x + c.w; x++) add("nap", x, y); continue; }
      if(c.zone === "wall"){
        // Stand below it, on the first walkable tile of each column.
        for(let x = it.x; x < it.x + c.w; x++) for(let y = WALL_ROWS; y < WALL_ROWS + 2; y++) if(g.ok(x, y)){ add(c.activity, x, y); break; }
        continue;
      }
      const below = it.y + c.h, above = it.y - 1, left = it.x - 1, right = it.x + c.w;
      for(let x = it.x; x < it.x + c.w; x++) add(c.activity, x, below);
      for(let y = it.y + c.h - 1; y >= it.y; y--){ add(c.activity, left, y); add(c.activity, right, y); }
      add(c.activity, left, below); add(c.activity, right, below);
      for(let x = it.x; x < it.x + c.w; x++) add(c.activity, x, above);
    }
    return out;
  }

  const api = {TILE, WALL_ROWS, FRONT_ROWS, MIN_COLS, MAX_COLS, MIN_ROWS, MAX_ROWS, MAX_ITEMS, FLOORS, CATALOGUE,
    autoRoom, walkGrid, doorTile, seatTile, validate, place, remove, deskSlots, spots, newId};
  if(typeof module === "object" && module.exports) module.exports = api;
  else root.RoomModel = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
