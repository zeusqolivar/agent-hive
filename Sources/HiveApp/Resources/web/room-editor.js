/* Classroom edit mode. createSession is pure (tested in Node); open() wires it to the canvas and the editor panel. */
"use strict";
(function(root){
  const RoomModel = root.RoomModel || (typeof require === "function" ? require("./room-model.js") : null);
  const MAX_BYTES = 64 * 1024;
  const copy = room => JSON.parse(JSON.stringify(room));
  const bytes = text => typeof TextEncoder === "function" ? new TextEncoder().encode(text).length : text.length;

  // One edit session over a copy of the room. Every change returns an error string and leaves the draft as it
  // was, or returns null; undo goes back one change at a time for the whole session.
  function createSession(room){
    let draft = copy(room), selected = null;
    const history = [];
    const commit = next => { history.push(draft); draft = next; return null; };
    const kindOf = id => draft.items.find(i => i.id === id)?.kind;
    function move(id, x, y){
      const kind = kindOf(id);
      if(!kind) return `there is no item ${id}`;
      const res = RoomModel.place(draft, {id, kind, x, y});
      return res.ok ? commit(res.room) : res.error;
    }
    function add(kind, x, y){
      if(!RoomModel.CATALOGUE[kind]) return `unknown kind ${kind}`;
      const id = RoomModel.newId(draft, kind), res = RoomModel.place(draft, {id, kind, x, y});
      if(!res.ok) return res.error;
      selected = id;
      return commit(res.room);
    }
    // Adds on the nearest free tiles to the middle of its zone (for adding without dragging).
    function addNear(kind){
      const c = RoomModel.CATALOGUE[kind];
      if(!c) return `unknown kind ${kind}`;
      const top = c.zone === "wall" ? 0 : RoomModel.WALL_ROWS, bottom = c.zone === "wall" ? RoomModel.WALL_ROWS : draft.rows - RoomModel.FRONT_ROWS;
      const mx = (draft.cols - c.w) / 2, my = c.zone === "wall" ? 0 : (top + bottom - c.h) / 2, spots = [];
      for(let y = top; y + c.h <= bottom; y++) for(let x = 0; x + c.w <= draft.cols; x++) spots.push({x, y, d:Math.hypot(x - mx, (y - my) * 1.5)});
      spots.sort((p, q) => p.d - q.d);
      for(const p of spots) if(!add(kind, p.x, p.y)) return null;
      return `there is no free space for a ${c.label.toLowerCase()}`;
    }
    function remove(id){
      const res = RoomModel.remove(draft, id);
      if(!res.ok) return res.error;
      if(selected === id) selected = null;
      return commit(res.room);
    }
    function nudge(dx, dy){
      if(!selected || !kindOf(selected)) return "select an item first";
      const it = draft.items.find(i => i.id === selected);
      return move(selected, it.x + dx, it.y + dy);
    }
    function change(next){
      const v = RoomModel.validate(next);
      return v.ok ? commit(next) : v.errors[0];
    }
    function setSize(cols, rows){
      cols = Number(cols); rows = Number(rows);
      if(!Number.isInteger(cols) || cols < RoomModel.MIN_COLS || cols > RoomModel.MAX_COLS) return `the width must be ${RoomModel.MIN_COLS} to ${RoomModel.MAX_COLS} tiles`;
      if(!Number.isInteger(rows) || rows < RoomModel.MIN_ROWS || rows > RoomModel.MAX_ROWS) return `the depth must be ${RoomModel.MIN_ROWS} to ${RoomModel.MAX_ROWS} tiles`;
      if(cols === draft.cols && rows === draft.rows) return null;
      return change({...draft, cols, rows});
    }
    const setFloor = (style, color) => change({...draft, floor:{style, color:color ?? null}});
    const setWall = color => change({...draft, wall:{color:color ?? null}});
    function undo(){ if(history.length){ draft = history.pop(); if(selected && !kindOf(selected)) selected = null; } }
    function importJSON(text){
      if(typeof text !== "string") return "that file couldn't be read";
      if(bytes(text) > MAX_BYTES) return "that file is larger than 64 KB, so it can't be a room";
      let data;
      try { data = JSON.parse(text); } catch { return "that file isn't JSON, so it can't be read as a room"; }
      if(data && typeof data === "object" && !Array.isArray(data) && data.room && !data.items) data = data.room;
      if(!data || typeof data !== "object" || Array.isArray(data)) return "that file doesn't hold a room";
      if(typeof data.version === "number" && data.version > 1) return "that room was saved by a newer version of Agent Hive";
      const v = RoomModel.validate(data);
      if(!v.ok) return "that room can't be used: " + v.errors[0];
      selected = null;
      return commit(copy(data));
    }
    const exportJSON = () => JSON.stringify(draft, null, 2);
    return {
      get draft(){ return draft; }, get selected(){ return selected; }, get canUndo(){ return history.length > 0; },
      select(id){ selected = id && kindOf(id) ? id : null; },
      move, add, addNear, remove, nudge, setSize, setFloor, setWall, undo, importJSON, exportJSON,
    };
  }

  // ---------------------------------------------------------------- the editor on the page

  // env: {room, problem, canvas, save(room) -> Promise<error|null>, reset() -> Promise<error|null>, exit()}
  let live = null;
  function open(env){
    if(live) return;
    const $ = id => document.getElementById(id), session = createSession(env.room), CAT = RoomModel.CATALOGUE;
    let drag = null, ghost = null, busy = false;
    const off = [];
    const on = (el, type, fn, opts) => { el.addEventListener(type, fn, opts); off.push(() => el.removeEventListener(type, fn, opts)); };
    const say = (text, bad) => { const el = $("edStatus"); el.textContent = text ? text.charAt(0).toUpperCase() + text.slice(1) + (/[.?!]$/.test(text) ? "" : ".") : ""; el.classList.toggle("bad", !!bad); };
    const label = it => `${CAT[it.kind].label} ${it.id}`;
    function show(){
      const d = session.draft, sel = d.items.find(i => i.id === session.selected);
      Room.edit(d, {selected:session.selected, ghost});
      $("edUndo").disabled = !session.canUndo || busy;
      if(document.activeElement !== $("edCols")) $("edCols").value = d.cols;
      if(document.activeElement !== $("edRows")) $("edRows").value = d.rows;
      $("edFloor").value = d.floor.style;
      $("edFloorColor").value = d.floor.color || Room.themeColour("--rm-floor");
      $("edWallColor").value = d.wall.color || Room.themeColour("--rm-wall");
      $("edFloorTheme").disabled = !d.floor.color; $("edWallTheme").disabled = !d.wall.color;
      const box = $("edSelected");
      if(sel){
        box.hidden = false;
        $("edSelName").textContent = label(sel);
        $("edRemove").disabled = sel.kind === "door";
        $("edSelHint").textContent = sel.kind === "door" ? "Arrow keys move it. The room needs its door, so it can't be removed." : "Arrow keys move it; Delete removes it.";
      } else box.hidden = true;
      for(const b of document.querySelectorAll("#roomEditor button, #roomEditor input, #roomEditor select")) if(!["edUndo", "edRemove", "edFloorTheme", "edWallTheme"].includes(b.id)) b.disabled = busy;
    }
    const act = err => { if(err) say(err, true); else say(""); show(); return err; };

    // The catalogue: drag a kind onto the room, or click it to add near the middle.
    const cat = $("edCatalogue");
    cat.textContent = "";
    for(const [kind, c] of Object.entries(CAT)){
      if(kind === "door") continue;
      const b = document.createElement("button");
      b.type = "button"; b.className = "btn ed-kind"; b.dataset.kind = kind;
      b.innerHTML = `<span></span><small></small>`;
      b.firstChild.textContent = c.label; b.lastChild.textContent = `${c.w}×${c.h}${c.zone === "wall" ? ", wall" : ""}`;
      b.title = `Drag onto the room, or click to add ${c.label.toLowerCase()} near the middle`;
      cat.append(b);
    }
    const overCanvas = e => { const r = env.canvas.getBoundingClientRect(); return e.clientX >= r.left && e.clientX <= r.right && e.clientY >= r.top && e.clientY <= r.bottom; };
    const origin = (e, d) => { const t = Room.tileAt(e); return {x:t.x - d.dx, y:t.y - d.dy}; };
    function preview(e){
      if(!drag) return;
      if(drag.fresh && !overCanvas(e)){ ghost = null; show(); return; }
      const p = origin(e, drag);
      if(ghost && ghost.x === p.x && ghost.y === p.y) return;
      const id = drag.id || RoomModel.newId(session.draft, drag.kind), res = RoomModel.place(session.draft, {id, kind:drag.kind, ...p});
      ghost = {id:drag.id || null, kind:drag.kind, ...p, bad:res.ok ? null : res.error};
      say(ghost.bad || "", !!ghost.bad);
      show();
    }
    on(cat, "pointerdown", e => {
      const b = e.target.closest(".ed-kind");
      if(!b || busy || e.button !== 0) return;
      const c = CAT[b.dataset.kind];
      drag = {fresh:true, kind:b.dataset.kind, dx:Math.floor(c.w/2), dy:Math.floor(c.h/2), startX:e.clientX, startY:e.clientY, button:b};
      try { b.setPointerCapture(e.pointerId); } catch {}
    });
    on(cat, "pointermove", e => { if(drag?.fresh && Math.hypot(e.clientX - drag.startX, e.clientY - drag.startY) > 4) preview(e); });
    on(cat, "pointerup", e => {
      if(!drag?.fresh) return;
      const d = drag, g = ghost, far = Math.hypot(e.clientX - d.startX, e.clientY - d.startY) > 4;
      drag = null; ghost = null;
      if(!far){ act(session.addNear(d.kind)); return; }
      if(g && overCanvas(e)) act(g.bad ? g.bad + "; it wasn't added" : session.add(d.kind, g.x, g.y));
      else show();
    });
    on(cat, "pointercancel", () => { drag = null; ghost = null; show(); });
    // Keyboard users: Enter or Space on a catalogue button adds near the middle (a click without a pointer).
    on(cat, "click", e => { const b = e.target.closest(".ed-kind"); if(b && e.detail === 0 && !busy) act(session.addNear(b.dataset.kind)); });

    // On the room: click selects, drag moves.
    const itemAt = t => { const d = session.draft; for(let i = d.items.length - 1; i >= 0; i--){ const it = d.items[i], c = CAT[it.kind]; if(c && t.x >= it.x && t.x < it.x + c.w && t.y >= it.y && t.y < it.y + c.h) return it; } return null; };
    on(env.canvas, "pointerdown", e => {
      if(busy || e.button !== 0) return;
      const t = Room.tileAt(e), it = itemAt(t);
      session.select(it ? it.id : null);
      if(it){ drag = {id:it.id, kind:it.kind, dx:t.x - it.x, dy:t.y - it.y, x0:it.x, y0:it.y}; try { env.canvas.setPointerCapture(e.pointerId); } catch {} }
      say(""); show();
    });
    on(env.canvas, "pointermove", e => {
      if(drag && !drag.fresh){ preview(e); return; }
      env.canvas.style.cursor = itemAt(Room.tileAt(e)) ? "grab" : "default";
    });
    on(env.canvas, "pointerup", () => {
      if(!drag || drag.fresh) return;
      const d = drag, g = ghost;
      drag = null; ghost = null;
      if(!g || (g.x === d.x0 && g.y === d.y0)){ show(); return; }
      // An invalid drop snaps back: the draft is unchanged and the reason stays on screen.
      act(g.bad ? g.bad + "; it went back where it was" : session.move(d.id, g.x, g.y));
    });
    on(env.canvas, "pointercancel", () => { drag = null; ghost = null; show(); });

    // Keys: Delete or Backspace removes, arrows nudge, Cmd/Ctrl+Z undoes, Escape deselects. View shortcuts are
    // off while editing, so a stray key can't throw the edit away.
    on(window, "keydown", e => {
      if(busy || /INPUT|TEXTAREA|SELECT/.test(document.activeElement?.tagName || "")) return;
      const mod = e.metaKey || e.ctrlKey;
      let handled = true;
      if(mod && e.key.toLowerCase() === "z"){ session.undo(); say(""); show(); }
      else if(mod || e.altKey) handled = false;
      else if((e.key === "Delete" || e.key === "Backspace") && session.selected) act(session.remove(session.selected));
      else if(e.key.startsWith("Arrow") && session.selected) act(session.nudge(e.key === "ArrowLeft" ? -1 : e.key === "ArrowRight" ? 1 : 0, e.key === "ArrowUp" ? -1 : e.key === "ArrowDown" ? 1 : 0));
      else if(e.key === "Escape"){ session.select(null); show(); }
      else if(!/^[1-7jko/f]$/.test(e.key)) handled = false;
      if(handled){ e.preventDefault(); e.stopImmediatePropagation(); }
    }, true);

    on($("edRemove"), "click", () => { if(session.selected) act(session.remove(session.selected)); });
    on($("edUndo"), "click", () => { session.undo(); say(""); show(); });
    const size = () => act(session.setSize(+$("edCols").value, +$("edRows").value));
    on($("edCols"), "change", size); on($("edRows"), "change", size);
    on($("edFloor"), "change", () => act(session.setFloor($("edFloor").value, session.draft.floor.color)));
    on($("edFloorColor"), "input", () => act(session.setFloor(session.draft.floor.style, $("edFloorColor").value)));
    on($("edWallColor"), "input", () => act(session.setWall($("edWallColor").value)));
    on($("edFloorTheme"), "click", () => act(session.setFloor(session.draft.floor.style, null)));
    on($("edWallTheme"), "click", () => act(session.setWall(null)));
    on($("edExport"), "click", () => {
      const url = URL.createObjectURL(new Blob([session.exportJSON()], {type:"application/json"}));
      const a = document.createElement("a"); a.href = url; a.download = "agent-hive-classroom.json"; document.body.append(a); a.click(); a.remove();
      setTimeout(() => URL.revokeObjectURL(url), 5000);
      say("Exported the room as agent-hive-classroom.json");
    });
    on($("edImport"), "click", () => $("edFile").click());
    on($("edFile"), "change", async () => {
      const f = $("edFile").files[0];
      $("edFile").value = "";
      if(!f) return;
      if(f.size > MAX_BYTES){ say("that file is larger than 64 KB, so it can't be a room", true); return; }
      let text;
      try { text = await f.text(); } catch { say("that file couldn't be read", true); return; }
      const err = session.importJSON(text);
      if(err) say(err, true); else say(`Loaded ${f.name}. Done saves it`);
      show();
    });
    const run = async (fn, okText) => {
      busy = true; show();
      let err;
      try { err = await fn(); } catch(x){ err = x.message || "that didn't work"; }
      busy = false;
      if(err){ say(err, true); show(); return; }
      close();
      if(okText) env.toast?.(okText);
    };
    on($("edDone"), "click", () => {
      const v = RoomModel.validate(session.draft);
      if(!v.ok){ say(v.errors[0], true); return; }
      run(() => env.save(session.draft), "Room saved");
    });
    on($("edReset"), "click", () => {
      if(!confirm("Go back to the automatic room? The saved arrangement is deleted, here and in the app.")) return;
      run(() => env.reset(), "Back to the automatic room");
    });
    on($("edCancel"), "click", () => close());

    live = {env, off};
    $("edNote").textContent = env.problem ? `Your saved room couldn't be used (${env.problem}), so this is the automatic room. Done saves over it.` : "";
    $("edNote").hidden = !env.problem;
    say("");
    show();
  }
  // Leaves edit mode without saving.
  function close(){
    if(!live) return;
    const {env, off} = live;
    live = null;
    off.forEach(f => f());
    Room.edit(null);
    env.exit();
  }

  const api = {createSession, open, close, isOpen:() => !!live, MAX_BYTES};
  if(typeof module === "object" && module.exports) module.exports = api;
  else root.RoomEditor = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
