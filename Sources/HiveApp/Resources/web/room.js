/* Classroom view: draws live sessions as characters. Where a character stands comes from real session state.
   The room is a tile grid (room-model.js): the saved arrangement, or the automatic one when nothing is saved. */
"use strict";
const Room = (() => {
  const BODY = ["#4C6FD6","#C9562F","#17948A","#8A5CD1","#D0457F","#5B9A38","#2E8BC7","#5A6680"];
  const LABEL = {read:"Reading", write:"Writing", run:"Running a command", web:"On the web", think:"Thinking", tool:"Using a tool", subagents:"With helpers"};
  const ASK = {question:"Question", permission:"Needs OK", plan:"Approve plan", other:"Waiting"};
  const NAP_AFTER = 6 * 3600;
  const T = RoomModel.TILE, CAT = RoomModel.CATALOGUE;
  const hash = s => { let h = 7; for(const c of String(s)) h = (h * 31 + c.charCodeAt(0)) >>> 0; return h; };
  let placed = [], keepOut = [], plates = [], plateRects = [], cv, ctx, agents = new Map(), board = null, active = false, last = 0, sel = null, hover = null, onPick = () => {}, k = 1, ox = 0, oy = 0;
  const calm = matchMedia("(prefers-reduced-motion:reduce)");
  // saved: the room from /api/classroom, or null for the automatic one. G: everything derived from the room in use.
  let deskState = {deskCount:0, layoutAt:0, assign:{}}, saved = null, problem = null, G = null, W = 0, H = 0;
  // Edit mode (room-editor.js): the draft being edited, and what to show on it ({selected, ghost}).
  let draft = null, view = {};
  let palette = {};
  // Kept in a variable: an unreferenced MediaQueryList can be collected, and its listener with it.
  const darkQuery = matchMedia("(prefers-color-scheme:dark)");
  darkQuery.addEventListener("change", () => { palette = {}; });
  const css = n => palette[n] ??= getComputedStyle(document.documentElement).getPropertyValue(n).trim();
  const centre = p => ({x:(p.x + .5)*T, y:(p.y + .5)*T});
  const tileOf = p => ({x:Math.floor(p.x / T), y:Math.floor(p.y / T)});
  // Where a desk's sitter and plate are drawn, in room units, for a desk slot in tiles.
  const deskPt = d => ({x:(d.x + 1.5)*T, y:d.y*T + 30});

  // How many desks a saved room needs: one per assigned session.
  const needed = () => Object.values(deskState.assign).reduce((m, i) => Math.max(m, i + 1), 0);
  function build(){
    const room = saved || RoomModel.autoRoom(deskState.deskCount);
    const grid = RoomModel.walkGrid(room), spots = RoomModel.spots(room), want = saved ? needed() : deskState.deskCount;
    const slots = RoomModel.deskSlots(room, want);
    const front = room.rows - RoomModel.FRONT_ROWS, RH = room.rows*T;
    // Tiles for sessions that get no desk because the floor is full: open floor, away from the activity spots.
    const busy = new Set(Object.values(spots).flat().map(p => p.x + "," + p.y));
    const stand = [];
    for(let y = RoomModel.WALL_ROWS; y < front; y++) for(let x = 0; x < room.cols; x++) if(grid.ok(x, y) && !busy.has(x + "," + y)) stand.push({x, y});
    const mid = {x:room.cols/2, y:(RoomModel.WALL_ROWS + front)/2};
    stand.sort((p, q) => Math.hypot(p.x - mid.x, p.y - mid.y) - Math.hypot(q.x - mid.x, q.y - mid.y));
    const dt = RoomModel.doorTile(room) || {x:room.cols - 3, y:RoomModel.WALL_ROWS};
    G = {room, grid, spots, slots, want, stand, door:centre(dt), ...frontOf(room)};
    dims();
  }
  // The fixed front of the room: the "needs you" mat, the queue on it, and your desk.
  const frontOf = room => ({queueY:room.rows*T - 84, matTop:room.rows*T - 160, matBottom:room.rows*T - 55, yourDeskY:room.rows*T - 48});
  // The drawing's size follows the draft while editing, otherwise the room in use.
  function dims(){ const r = draft || G.room; W = r.cols*T; H = r.rows*T; }
  // A new room or desk count moves desks and spots, so everyone picks a destination again and walks there.
  function relayout(){
    build();
    for(const a of agents.values()){
      a.x = Math.max(20, Math.min(W - 20, a.x)); a.y = Math.max(RoomModel.WALL_ROWS*T + 10, Math.min(H - 20, a.y));
      a.path = []; a.nextMove = 0; a.retry = 0;
      if(!a.leaving) a.dest = null;
    }
    if(cv) size();
  }

  // Walks over free tiles. A character on a blocked tile (at its desk, or furniture moved under it) first steps to the nearest free one.
  function route(a, to){
    const g = G.grid, pts = [];
    let from = tileOf(a);
    if(!g.ok(from.x, from.y)){
      const out = RoomPath.nearestOpen(g, from);
      if(!out) return [{x:to.x, y:to.y}];
      pts.push(centre(out)); from = out;
    }
    let goal = tileOf(to);
    if(!g.ok(goal.x, goal.y)) goal = RoomPath.nearestOpen(g, goal) || goal;
    const steps = RoomPath.findPath(g, from, goal);
    if(steps) for(const s of steps) pts.push(centre(s));
    const end = pts[pts.length - 1];
    if(!end || Math.hypot(end.x - to.x, end.y - to.y) > .5) pts.push({x:to.x, y:to.y});
    return pts;
  }
  function go(a, dest){
    a.dest = dest;
    if(calm.matches){ a.x = dest.x; a.y = dest.y; a.path = []; return; }
    a.path = route(a, dest);
  }
  // Activity spots hold one character each.
  function freeSlot(kind, a){
    const list = G.spots[kind] || [];
    const taken = new Set([...agents.values()].filter(o => o !== a && o.dest?.kind === kind).map(o => o.dest.i));
    const open = list.map((_,i) => i).filter(i => !taken.has(i));
    if(!open.length) return null;
    const i = open[Math.floor(Math.random()*open.length)], p = centre(list[i]);
    return {kind, i, x:p.x, y:p.y};
  }
  // Subagents are small enough to share a spot.
  function anySlot(kind){
    const list = G.spots[kind] || [];
    if(!list.length) return null;
    const p = centre(list[Math.floor(Math.random()*list.length)]);
    return {kind, i:-1, x:p.x + (Math.random() - .5)*18, y:p.y + (Math.random() - .5)*12};
  }
  const HELPER_SPOTS = [-52, 52, -26, 26, -78, 78];
  // A session's desk index; a subagent uses its parent's.
  const deskOf = a => deskState.assign[a.s.isSub ? a.s.parent : a.s.id];
  function seatOf(a){
    const i = deskOf(a);
    if(i === undefined) return {kind:"door", i:-1, ...G.door};
    const slot = G.slots[i];
    if(!slot){
      // No floor left for a desk: stand on a free tile instead of on furniture.
      const p = G.stand.length ? centre(G.stand[(i - G.slots.length) % G.stand.length]) : G.door;
      return {kind:a.s.isSub ? "helper" : "desk", i, x:p.x + (a.s.isSub ? HELPER_SPOTS[a.slot % 6]/3 : 0), y:p.y, standing:true};
    }
    const seat = deskPt(slot);
    if(a.s.isSub) return {kind:"helper", i:-1, x:seat.x + HELPER_SPOTS[a.slot % 6], y:seat.y - 46};
    return {kind:"desk", i, x:seat.x, y:seat.y - 12};
  }
  function plan(a, now, queue){
    const s = a.s;
    if(a.leaving){
      if(a.dest?.kind !== "door"){
        const parent = a.s.parent && agents.get(a.s.parent);
        go(a, parent && !parent.leaving ? {kind:"door", x:parent.x, y:parent.y} : {kind:"door", ...G.door});
      }
      return;
    }
    if(s.group === "needs"){
      const i = queue.indexOf(s.id), n = queue.length, step = Math.min(150, (W - 300) / Math.max(1, n - 1));   // wide enough for name tags side by side
      const x = W/2 + (i - (n-1)/2) * step, y = G.queueY;
      if(a.dest?.kind !== "queue" || a.dest.x !== x || a.dest.y !== y) go(a, {kind:"queue", x, y});
      return;
    }
    if(s.group === "working"){
      const kind = {read:"read", run:"run", web:"web"}[s.doing];
      if(kind && !s.quiet && G.spots[kind].length){
        if(a.dest?.kind !== kind && now >= a.retry){
          a.retry = now + 5;    // a full spot sends it home, so don't turn it around every frame
          go(a, (s.isSub ? anySlot(kind) : freeSlot(kind, a)) || seatOf(a));
        }
      } else {
        // No item offers this activity (or it's desk work): it happens at the desk.
        const home = seatOf(a);
        if(a.dest?.kind !== home.kind || a.dest.x !== home.x || a.dest.y !== home.y) go(a, home);
      }
      return;
    }
    const idleFor = Date.now()/1000 - (s.lastTs || 0);
    if(idleFor > NAP_AFTER){
      if(a.dest?.kind !== "nap" && a.dest?.kind !== "desk"){ go(a, freeSlot("nap", a) || seatOf(a)); }
      a.napping = true;
      return;
    }
    a.napping = false;
    if(a.path.length || now < a.nextMove) return;
    a.nextMove = now + 6 + Math.random()*14;
    if(calm.matches){ if(a.dest?.kind !== "desk") go(a, seatOf(a)); return; }
    const kinds = ["stroll","stroll","stroll","stroll","read","desk"], pick = kinds[Math.floor(Math.random()*kinds.length)];
    go(a, pick === "desk" ? seatOf(a) : freeSlot(pick, a) || seatOf(a));
  }
  function update(b){
    board = b;
    if(!G) build();
    const live = (b.sessions || []).filter(s => s.live && s.group !== "ended");
    const helpers = [];
    for(const s of live) for(const h of (s.helpers || []).slice(0, 6)){
      helpers.push({id:"sub:" + h.id, isSub:true, parent:s.id, name:h.description, project:s.project, group:"working", doing:h.doing,
        headline:`Subagent of ${s.name}${h.task ? ": " + h.task : ""}`, subagents:{}, lastTs:s.lastTs});
    }
    const ids = new Set(live.map(s => s.id).concat(helpers.map(h => h.id)));
    // Three misses in a row before someone leaves, so one bad refresh can't empty the room.
    for(const a of agents.values()){ if(ids.has(a.s.id)) a.missed = 0; else if(++a.missed >= 3) a.leaving = true; }
    for(const s of live){ const have = agents.get(s.id); if(have){ have.s = s; have.leaving = false; } }
    // Everyone still in the room keeps a desk, including a session missing from one refresh.
    const inRoom = new Map(live.map(s => [s.id, s]));
    for(const a of agents.values()) if(!a.s.isSub && !a.leaving && !inRoom.has(a.s.id)) inRoom.set(a.s.id, a.s);
    const order = [...inRoom.values()].sort((x,y) => (x.startedAt||0) - (y.startedAt||0) || (x.id < y.id ? -1 : 1)).map(s => s.id);
    const before = deskState.deskCount;
    deskState = ClassroomLayout.assignDesks(deskState, order, Date.now()/1000);
    if(deskState.deskCount !== before) relayout();
    else if(saved && needed() !== G.want) build();    // an arrival in a saved room may need an extra desk
    const first = agents.size === 0;
    const make = (s, x, y, extra) => {
      const h = hash(s.id);
      agents.set(s.id, {s, seed:h % 1000, color:BODY[hash(s.project) % BODY.length], hat:s.isSub ? 0 : h % 4, path:[], face:1, dest:null,
        nextMove:0, missed:0, retry:0, x, y, ...extra});
    };
    for(const s of live){
      if(agents.has(s.id)) continue;
      const seat = first ? seatOf({s}) : null;
      make(s, first ? seat.x : G.door.x, first ? seat.y : G.door.y);
    }
    for(const s of helpers){
      const have = agents.get(s.id);
      if(have){ have.s = s; have.leaving = false; continue; }
      const parent = agents.get(s.parent);
      if(!parent) continue;
      // The lowest stool beside the parent's desk that no other running subagent has.
      const taken = new Set([...agents.values()].filter(a => a.s.parent === s.parent && !a.leaving).map(a => a.slot % 6));
      let slot = 0; while(taken.has(slot) && slot < 6) slot++;
      make(s, parent.x, parent.y, {slot});
    }
  }
  // The saved room, or null for the automatic one. A saved room that breaks the rules is ignored, and problem() says why.
  function setRoom(room){
    problem = null;
    if(room){
      const v = RoomModel.validate(room);
      if(!v.ok){ problem = v.errors[0]; room = null; }
    }
    saved = room ? JSON.parse(JSON.stringify(room)) : null;
    relayout();
  }

  function hex(x, y, r){ ctx.beginPath(); for(let i = 0; i < 6; i++){ const t = Math.PI/3*i - Math.PI/2; ctx.lineTo(x + r*Math.cos(t), y + r*Math.sin(t)); } ctx.closePath(); }
  function box(x, y, w, h, r, fill){ ctx.fillStyle = fill; ctx.beginPath(); ctx.roundRect(x, y, w, h, r); ctx.fill(); }
  const font = (px, weight) => `${weight || ""} ${px}px Avenir Next,Avenir,system-ui,sans-serif`.trim();
  const CHALK = px => `${px}px "Chalkboard SE","Chalkboard",sans-serif`;
  function drawFloor(room){
    const c = ctx, top = RoomModel.WALL_ROWS*T, own = room.floor.color;
    box(0, 0, W, top, 0, room.wall.color || css("--rm-wall"));
    box(0, top, W, H - top, 0, own || css("--rm-floor"));
    c.strokeStyle = own ? "rgba(0,0,0,.08)" : css("--rm-tile"); c.fillStyle = c.strokeStyle; c.lineWidth = 1;
    const style = room.floor.style;
    c.beginPath();
    if(style === "wood"){
      for(let y = top, row = 0; y < H; y += 20, row++){ c.moveTo(0, y); c.lineTo(W, y); for(let x = (row % 4)*40; x < W; x += 160){ c.moveTo(x, y); c.lineTo(x, y + 20); } }
      c.stroke();
    } else if(style === "carpet"){
      c.stroke();
      for(let y = top + 10; y < H; y += 20) for(let x = 10 + ((y - top)/20 % 2)*10; x < W; x += 20) c.fillRect(x, y, 2, 2);
    } else {
      for(let y = top; y < H; y += 2*T){ c.moveTo(0, y); c.lineTo(W, y); } for(let x = 0; x < W; x += 2*T){ c.moveTo(x, top); c.lineTo(x, H); }
      c.stroke();
    }
    c.fillStyle = "rgba(0,0,0,.10)"; c.fillRect(0, top - 3, W, 3);    // skirting
  }
  // Wall items and flat floor items (rugs), drawn before anything that stands on the floor.
  function drawFlat(it, t){
    const c = ctx, px = it.x*T, py = it.y*T, w = CAT[it.kind].w*T, h = CAT[it.kind].h*T;
    if(it.kind === "window"){
      box(px + 2, py - 6, w - 4, h + 12, 4, css("--rm-wood")); box(px + 8, py, w - 16, h, 2, css("--rm-sky")); box(px + w/2 - 2, py, 4, h, 0, css("--rm-wood"));
    } else if(it.kind === "board"){
      const mid = px + w/2, half = w/2 - 8, step = Math.min(160, half * .65), n = board?.counts || {};
      box(px + 8, 18, w - 16, 124, 6, css("--rm-wood")); box(px + 16, 26, w - 32, 108, 3, css("--rm-board"));
      c.textAlign = "center"; c.fillStyle = "#EEF3EE"; c.font = CHALK(15);
      c.fillText(fit(new Date().toLocaleDateString([], {weekday:"long", month:"long", day:"numeric"}), half*2 - 30), mid, 52);
      [[n.needs||0,"need you","#F5B700",mid-step],[n.working||0,"working","#EEF3EE",mid],[n.idle||0,"idle","#EEF3EE",mid+step]].forEach(([v,label,col,x]) => {
        c.fillStyle = col; c.font = CHALK(34); c.fillText(v, x, 94);
        c.font = CHALK(15); c.fillText(label, x, 118);
      });
    } else if(it.kind === "clock"){
      const d = new Date(), cx = px + 20, cy = py + 20; c.fillStyle = css("--rm-panel"); c.beginPath(); c.arc(cx, cy, 18, 0, 7); c.fill();
      c.strokeStyle = css("--ink"); c.lineWidth = 2; c.stroke(); c.lineCap = "round";
      for(const [ang,len] of [[(d.getHours()%12 + d.getMinutes()/60)/12, 9],[d.getMinutes()/60, 13]]){ const r = ang*2*Math.PI - Math.PI/2; c.beginPath(); c.moveTo(cx,cy); c.lineTo(cx + len*Math.cos(r), cy + len*Math.sin(r)); c.stroke(); }
    } else if(it.kind === "poster"){
      box(px + 6, py + 4, w - 12, h - 8, 3, css("--rm-panel"));
      box(px + 12, py + 10, w - 24, h - 34, 2, BODY[hash(it.id) % BODY.length]);
      for(let i = 0; i < 2; i++) box(px + 12, py + h - 20 + i*7, (w - 24)*(i ? .6 : 1), 3, 1, css("--rm-tile"));
      c.fillStyle = "#D0457F"; c.beginPath(); c.arc(px + w/2, py + 6, 3, 0, 7); c.fill();
    } else if(it.kind === "door"){
      const dx = px + w/2, open = !draft && [...agents.values()].some(a => Math.hypot(a.x - dx, a.y - G.door.y) < 80);
      box(dx - 48, 40, 96, 120, 3, open ? css("--rm-dark") : css("--rm-wood"));
      if(!open){ c.fillStyle = css("--rm-sky"); c.fillRect(dx - 20, 56, 40, 34); c.fillStyle = css("--rm-dark"); c.beginPath(); c.arc(dx + 36, 108, 4, 0, 7); c.fill(); }
      c.fillStyle = css("--ink2"); c.font = font(13); c.textAlign = "center"; c.fillText(`${board?.counts?.ended || 0} went home`, dx, 32);
    } else if(it.kind === "rug"){
      c.fillStyle = css("--rm-rug"); c.beginPath(); c.ellipse(px + w/2, py + h/2, w/2, h/2 - 4, 0, 0, 7); c.fill();
    }
  }
  // Floor furniture that stands up, drawn in order of its front edge so characters pass in front of and behind it.
  // A soft shadow on the floor under furniture.
  function shade(x, y, w){
    ctx.fillStyle = "rgba(0,0,0,.07)"; ctx.beginPath(); ctx.ellipse(x + w/2, y, w/2 + 6, 9, 0, 0, 7); ctx.fill();
    ctx.fillStyle = "rgba(0,0,0,.06)"; ctx.beginPath(); ctx.ellipse(x + w/2, y, w/2 - 4, 5, 0, 0, 7); ctx.fill();
  }
  function drawStanding(it, t){
    const c = ctx, px = it.x*T, py = it.y*T, w = CAT[it.kind].w*T, h = CAT[it.kind].h*T;
    if(it.kind !== "lamp") shade(px + 2, py + h - 2, w - 4); else shade(px + 10, py + 34, 20);
    if(it.kind === "shelf"){
      // Low enough to leave a window above it in view.
      const top = py + h - 74;
      box(px, top, w, py + h - top, 4, css("--rm-wood2"));
      const books = BODY.concat(BODY), n = Math.floor((w - 20)/12.6), rows = 2, rowH = (py + h - top - 12)/rows;
      for(let row = 0; row < rows; row++) for(let i = 0; i < n; i++) box(px + 10 + i*12.6, top + 8 + row*rowH, 9, rowH - 6, 1, books[(i*5 + row*3) % books.length]);
    } else if(it.kind === "plant"){
      box(px + 5, py + 14, 30, 24, 4, css("--rm-wood2")); c.fillStyle = "#5B9A38";
      for(const [x,y] of [[20,0],[9,8],[31,8]]){ c.beginPath(); c.ellipse(px + x, py + y, 10, 15, 0, 0, 7); c.fill(); }
    } else if(it.kind === "globe"){
      const cx = px + w/2;
      c.fillStyle = css("--rm-wood"); c.beginPath(); c.ellipse(cx, py + 66, 30, 11, 0, 0, 7); c.fill();
      c.fillStyle = "#2E8BC7"; c.beginPath(); c.arc(cx, py + 40, 24, 0, 7); c.fill(); c.fillStyle = "#5B9A38"; c.beginPath(); c.ellipse(cx - 6, py + 34, 9, 6, .4, 0, 7); c.ellipse(cx + 8, py + 48, 7, 5, 0, 0, 7); c.fill();
    } else if(it.kind === "machine"){
      box(px + 5, py + 5, w - 10, h - 8, 5, css("--rm-dark")); box(px + 5, py + h - 9, w - 10, 6, 3, "rgba(0,0,0,.25)");
      for(let i = 0; i < 6; i++) for(let j = 0; j < 4; j++){ const on = Math.sin(t*(2 + (i*j)%3) + i*2 + j) > 0; box(px + 15 + j*13, py + 18 + i*16, 8, 8, 2, on ? css("--work") : css("--rm-tile")); }
    } else if(it.kind === "fountain"){
      box(px - 2, py + 22, w + 4, h - 24, 5, css("--rm-panel")); box(px + 10, py + 4, 20, 20, 3, "#7FC6E8");
    } else if(it.kind === "beanbag"){
      c.fillStyle = BODY[hash(it.id) % BODY.length]; c.beginPath(); c.ellipse(px + 20, py + 24, 19, 14, 0, 0, 7); c.fill();
      c.fillStyle = "rgba(255,255,255,.18)"; c.beginPath(); c.ellipse(px + 15, py + 18, 8, 5, -.3, 0, 7); c.fill();
    } else if(it.kind === "couch"){
      const col = BODY[hash(it.id) % BODY.length];
      box(px + 2, py + 6, w - 4, 30, 8, col); box(px + 2, py + 30, w - 4, h - 36, 8, col);
      c.globalAlpha = .25; box(px + 12, py + 34, w - 24, h - 46, 5, "#FFFFFF"); c.globalAlpha = 1;
      box(px - 2, py + 20, 14, h - 24, 6, col); box(px + w - 12, py + 20, 14, h - 24, 6, col);
    } else if(it.kind === "lamp"){
      c.fillStyle = css("--rm-dark"); c.beginPath(); c.ellipse(px + 20, py + 34, 10, 4, 0, 0, 7); c.fill();
      box(px + 18, py - 10, 4, 44, 2, css("--rm-dark"));
      c.fillStyle = "#F5D27A"; c.beginPath(); c.moveTo(px + 8, py - 2); c.lineTo(px + 32, py - 2); c.lineTo(px + 26, py - 22); c.lineTo(px + 14, py - 22); c.closePath(); c.fill();
    }
  }
  function drawFront(geo){
    const c = ctx, mid = W/2, n = board?.counts || {};
    // the front of the room, where sessions come when they need you
    box(120, geo.matTop, W - 240, geo.matBottom - geo.matTop, 12, css("--honey-soft"));
    c.fillStyle = css("--ink"); c.font = font(14, 600); c.textAlign = "left"; c.fillText("Needs you", 136, geo.matTop + 22);
    if(draft) return;
    if(!(n.needs)){ c.textAlign = "center"; c.fillStyle = css("--ink2"); c.font = font(15); c.fillText("Nobody is waiting on you right now.", mid, G.matTop + 60); }
    if(board?.ready && !agents.size && G.slots[0]){ c.textAlign = "center"; c.fillStyle = css("--ink2"); c.font = font(15); c.fillText("No sessions are open, so the room is empty.", mid, deskPt(G.slots[0]).y + 70); }
  }
  // Every desk has a chair. A desk with an owner also has a laptop and a name plate on its front.
  // Extra desks, added because the saved room has fewer desks than sessions, have a dashed outline.
  function drawDesk(slot, owner, t){
    const {x, y} = deskPt(slot);
    shade(x - 55, y + 30, 110);
    box(x-22, y-52, 44, 30, 6, css("--rm-chair"));
    box(x-50, y+8, 7, 28, 2, css("--rm-wood2")); box(x+43, y+8, 7, 28, 2, css("--rm-wood2"));
    box(x-55, y-22, 110, 32, 5, css("--rm-wood")); box(x-55, y+5, 110, 5, 2, css("--rm-wood2"));
    if(slot.extra){ ctx.save(); ctx.setLineDash([6, 5]); ctx.strokeStyle = css("--ink2"); ctx.lineWidth = 2; ctx.beginPath(); ctx.roundRect(x-58, y-25, 116, 38, 7); ctx.stroke(); ctx.restore(); }
    if(!owner) return;
    box(x-24, y-42, 48, 26, 3, css("--rm-dark")); box(x-28, y-17, 56, 5, 2, css("--rm-tile"));
    const atDesk = owner.s.group === "working" && !owner.path.length && owner.dest?.kind === "desk";
    ctx.globalAlpha = atDesk ? .6 + .4*Math.sin(t*4) : .35; ctx.fillStyle = atDesk ? css("--work") : css("--rm-tile"); hex(x, y-29, 7); ctx.fill(); ctx.globalAlpha = 1;
    // Text grows as the room shrinks, the same as the floating tags, and the plate grows with it up to the desk pitch.
    const ts = textScale(), s = owner.s;
    ctx.font = font(Math.round(12*ts), 600); ctx.textAlign = "center";
    const extra = (s.helpers?.length || 0) > 6 ? ` +${s.helpers.length - 6}` : "";
    const max = 146, name = fit(s.name || "", max - 12 - (extra ? ctx.measureText(extra).width : 0)) + extra;
    const pw = Math.min(max, Math.max(96, ctx.measureText(name).width + 14)), ph = 16*ts + 2;
    // Placed with the rest of the text, after the needs-you bubbles.
    plates.push({x:x - pw/2, y:y - 6, w:pw, h:ph, draw(px, py){
      ctx.font = font(Math.round(12*ts), 600); ctx.textAlign = "center";
      box(px, py, pw, ph, 4, css("--rm-panel"));
      box(px, py + ph - 3, pw, 3, 2, owner.color);
      ctx.fillStyle = css("--ink"); ctx.fillText(name, px + pw/2, py + ph/2 + 4*ts);
    }});
  }
  // A running subagent has a stool beside its session's desk, and sits on it while it is at home.
  const onStool = a => a.s.isSub && !a.path.length && a.dest?.kind === "helper" && !a.dest.standing;
  function drawStool(x, y){
    box(x-12, y-6, 3, 7, 1, css("--rm-wood2")); box(x+9, y-6, 3, 7, 1, css("--rm-wood2"));
    ctx.fillStyle = css("--rm-wood"); ctx.beginPath(); ctx.ellipse(x, y-6, 14, 4.5, 0, 0, 7); ctx.fill();
  }
  function drawAgent(a, t){
    const c = ctx, s = a.s, walking = a.path.length > 0, ph = t*9 + a.seed;
    const sitting = !walking && a.dest?.kind === "desk" && !a.dest.standing, nap = a.napping && !walking, stool = onStool(a);
    c.save(); c.translate(a.x, a.y - (walking ? Math.abs(Math.sin(ph))*3 : 0));
    if(s.isSub) c.scale(.62, .62);
    if(!stool){ c.fillStyle = "rgba(0,0,0,.16)"; c.beginPath(); c.ellipse(0, walking ? Math.abs(Math.sin(ph))*3 : 0, 19, 6, 0, 0, 7); c.fill(); }
    if(stool) c.translate(0, 3);    // sitting: legs tucked away, body down on the seat
    if(sel === s.id || hover === s.id){ c.strokeStyle = css("--accent"); c.lineWidth = 3; c.beginPath(); c.ellipse(0, 0, 27, 10, 0, 0, 7); c.stroke(); }
    c.scale(a.face, 1);
    const swing = walking ? Math.sin(ph)*4 : 0;
    if(!stool){ box(-10, -13 + Math.max(0, swing), 7, 13 - Math.max(0, swing), 2, "#2A3042"); box(3, -13 + Math.max(0, -swing), 7, 13 - Math.max(0, -swing), 2, "#2A3042"); }
    box(-14, -39, 28, 28, 8, a.color);
    if(s.provider === "google" && !s.isSub){
      const dots = ["#4285F4", "#EA4335", "#FBBC05", "#34A853"];
      dots.forEach((col, idx) => {
        c.fillStyle = col; c.beginPath(); c.arc(-4.5 + idx*3, -25, 1.3, 0, 7); c.fill();
      });
    }
    c.strokeStyle = a.color; c.lineWidth = 6; c.lineCap = "round";
    const hand = s.group === "needs" && !walking, typing = sitting && s.group === "working";
    c.beginPath(); c.moveTo(-14,-33); c.lineTo(-19 , typing ? -24 + Math.sin(t*14+a.seed)*2 : -19 + swing); c.stroke();
    c.beginPath(); c.moveTo(14,-33);
    if(hand){ const w = Math.sin(t*6 + a.seed)*5; c.lineTo(21 + w, -72); c.stroke(); c.fillStyle = "#F7EFD9"; c.beginPath(); c.arc(21 + w, -75, 4.5, 0, 7); c.fill(); }
    else { c.lineTo(19, typing ? -24 - Math.sin(t*14+a.seed)*2 : -19 - swing); c.stroke(); }
    if(a.dest?.kind === "read" && !walking){ box(-13, -33, 26, 15, 2, "#F7EFD9"); box(-1, -33, 2, 15, 0, a.color); }
    if(nap) { c.translate(0,-36); c.rotate(.28); c.translate(0,36); }
    c.strokeStyle = a.color; c.lineWidth = 2.5; c.beginPath(); c.moveTo(0,-76); c.lineTo(0,-84); c.stroke();
    c.fillStyle = s.group === "needs" ? "#F5B700" : s.group === "working" ? css("--work") : "#9AA3B5"; c.beginPath(); c.arc(0,-86, 3.5, 0, 7); c.fill();
    c.fillStyle = a.color; hex(0, -56, 22); c.fill(); c.fillStyle = "#FBF6EA"; hex(0, -56, 17); c.fill();
    const blink = (t + a.seed) % 4.3 < .13 || nap, look = walking ? 1.5 : Math.sin(t*.7 + a.seed)*1.2;
    c.fillStyle = "#1C2130"; c.strokeStyle = "#1C2130"; c.lineWidth = 2;
    for(const ex of [-6, 6]){ if(blink){ c.beginPath(); c.moveTo(ex-3+look,-57); c.lineTo(ex+3+look,-57); c.stroke(); } else { c.beginPath(); c.arc(ex+look, -58, 2.5, 0, 7); c.fill(); } }
    c.beginPath(); if(s.quiet){ c.moveTo(-4,-49); c.lineTo(4,-49); } else c.arc(look, -51, 3.5, .2, Math.PI-.2); c.stroke();
    if(a.hat === 1){ c.fillStyle = a.color; c.beginPath(); c.moveTo(-16,-69); c.lineTo(0,-80); c.lineTo(16,-69); c.closePath(); c.fill(); }
    if(a.hat === 2){ c.lineWidth = 1.5; for(const ex of [-6,6]){ c.beginPath(); c.arc(ex+look,-58,5,0,7); c.stroke(); } }
    c.restore();
  }
  // The spot already says what kind of work it is, so the bubble only says what the work is.
  function taskOf(text){
    const rest = String(text || "").replace(/^(Running|Reading|Editing|Writing|Searching|Fetching|Starting|Using|Sending|Opening|Taking|Waiting on|Run|Read|Write|Search|Call)\s+/i, "");
    return rest.charAt(0).toUpperCase() + rest.slice(1);
  }
  function textOf(a){
    const s = a.s;
    if(s.isSub) return "";
    const n = s.questions?.length || 0;
    const ask = s.reason === "questions" && n ? `${n} question${n === 1 ? "" : "s"}` : ASK[s.reason] || "Waiting";
    if(s.group === "needs") return ask + ", " + shortAge(Date.now()/1000 - (s.statusSince || s.lastTs));
    if(s.group === "working") return s.quiet ? "Gone quiet" : taskOf(s.headline) || LABEL[s.doing] || "Working";
    return "";
  }
  function shortAge(sec){ return sec < 3600 ? Math.max(1, Math.round(sec/60)) + "m" : sec < 86400 ? Math.round(sec/3600) + "h" : Math.round(sec/86400) + "d"; }
  function fit(text, max){
    let out = text;
    while(ctx.measureText(out).width > max && out.length > 4) out = out.slice(0, -2) + "…";
    return out;
  }
  function lines(text, max){
    const out = [];
    let cur = "";
    for(const word of text.split(/\s+/)){
      const next = cur ? cur + " " + word : word;
      if(!cur || ctx.measureText(next).width <= max) cur = next;
      else { out.push(cur); cur = word; }
    }
    out.push(cur);
    if(out.length > 2) out.splice(1, out.length, out[1] + "…");
    return out.map(l => fit(l, max));
  }
  // Text placement. One pass per frame, in priority order: needs-you bubbles, name plates, thought bubbles,
  // walking name tags. Each piece goes to the nearest free spot within 60 units of where it wants to be, inside
  // the room and off the chalkboard; a piece with no free spot is left out for that frame.
  const OFFSETS = (() => { const out = []; for(let dy = -60; dy <= 60; dy += 6) for(let dx = -60; dx <= 60; dx += 6){ const d = Math.hypot(dx, dy); if(d <= 60) out.push({dx, dy, d}); } return out.sort((p, q) => p.d - q.d); })();
  const hits = (r, list, pad) => list.some(p => r.x < p.x + p.w + pad && r.x + r.w + pad > p.x && r.y < p.y + p.h + pad && r.y + r.h + pad > p.y);
  function spot(x, y, w, h, up){
    let best = null;
    for(const o of OFFSETS){
      if(best && o.d > best.d) break;
      const r = {x:x + o.dx, y:y + o.dy, w, h};
      if(r.x < 2 || r.y < 2 || r.x + w > W - 2 || r.y + h > H - 2 || hits(r, keepOut, 2) || hits(r, placed, 3)) continue;
      // Among spots as near as each other, bubbles prefer to move up and tags down.
      if(!best || (up ? o.dy < best.dy : o.dy > best.dy)) best = {...r, d:o.d, dy:o.dy};
    }
    if(!best) return null;
    const r = {x:best.x, y:best.y, w, h};
    placed.push(r);
    return r;
  }
  // Text grows as the room shrinks, so it stays readable in a small window.
  const textScale = () => Math.max(1, .8/k);
  const fontOf = ts => px => font(Math.round(px*ts), 600);
  function needBubble(a){
    const c = ctx, ts = textScale(), raw = textOf(a);
    if(!raw) return;
    c.font = fontOf(ts)(13);
    const b = fit(raw, 170), bw = c.measureText(b).width + 14, bh = 23*ts;
    const at = spot(Math.max(6, Math.min(W - bw - 6, a.x - bw/2)), a.y - 96 - bh, bw, bh, true);
    if(!at) return;
    box(at.x, at.y, bw, bh, 7, "#F5B700");
    c.textAlign = "center"; c.fillStyle = "#2A1F00"; c.fillText(b, at.x + bw/2, at.y + 16*ts);
  }
  function cloud(a){
    const c = ctx, ts = textScale(), lh = 17*ts, text = textOf(a);
    if(!text) return;
    c.font = fontOf(ts)(13);
    const rows = lines(text, 165), w = Math.max(...rows.map(l => c.measureText(l).width)) + 26, h = rows.length*lh + 14;
    // The bumps stick out 10 units above and below the body, so they are part of the space it needs.
    const room = spot(Math.max(12, Math.min(W - w - 12, a.x - w/2)), a.y - 116 - h - 11, w, h + 22, true);
    if(!room) return;
    const at = {x:room.x, y:room.y + 11};
    const bottom = at.y + h, mid = at.x + w/2, tail = [[.4, 5.5], [.75, 3.5]];
    const shape = grow => {
      c.beginPath();
      c.roundRect(at.x - grow, at.y - grow, w + grow*2, h + grow*2, h/2 + grow);
      for(let x = at.x + 15; x < at.x + w - 8; x += 22){
        c.moveTo(x + 10 + grow, at.y); c.arc(x, at.y, 10 + grow, 0, 7);
        c.moveTo(x + 10 + grow, bottom); c.arc(x, bottom, 10 + grow, 0, 7);
      }
      for(const [f, rad] of tail){
        const tx = mid + (a.x + 6 - mid)*f, ty = bottom + 8 + (a.y - 92 - bottom - 8)*f;
        if(ty < bottom + 6 || hits({x:tx - rad, y:ty - rad, w:rad*2, h:rad*2}, plateRects, 0)) continue;   // never over a name
        c.moveTo(tx + rad + grow, ty); c.arc(tx, ty, rad + grow, 0, 7);
      }
      c.fill();
    };
    c.fillStyle = css("--line"); shape(1.5);
    c.fillStyle = css("--rm-panel"); shape(0);
    c.fillStyle = css("--ink"); c.textAlign = "center";
    rows.forEach((l, i) => c.fillText(l, mid, at.y + 7 + lh*(i + .75)));
  }
  const seatedAt = a => !a.path.length && a.dest?.kind === "desk" && !a.dest.standing;
  // A session within a tile of its own desk is named by the desk's plate.
  function nearOwnDesk(a){
    const slot = G.slots[deskOf(a)];
    if(a.s.isSub || !slot) return false;
    const t = tileOf(a), dx = Math.max(slot.x - t.x, 0, t.x - (slot.x + 2)), dy = Math.max(slot.y - t.y, 0, t.y - (slot.y + 1));
    return Math.max(dx, dy) <= 1;
  }
  // Everyone else gets a name tag under their feet.
  function drawTag(a){
    const c = ctx, s = a.s, ts = textScale(), font = fontOf(ts);
    if(s.isSub ? onStool(a) : seatedAt(a) || nearOwnDesk(a)) return;    // seated subagents are named in the hover tip and the list
    c.font = font(s.isSub ? 12 : 14); c.textAlign = "center";
    const extra = (s.helpers?.length || 0) > 6 ? ` +${s.helpers.length - 6}` : "";
    const name = fit(s.name || "", s.isSub ? 92 : 128 - (extra ? 24 : 0)) + extra;
    const w = c.measureText(name).width + 12, h = 18*ts;
    const at = spot(Math.max(4, Math.min(W - w - 4, a.x - w/2)), a.y + (s.isSub ? 13 : 18) - 13*ts, w, h, false);
    if(!at) return;
    box(at.x, at.y, w, h, 5, css("--rm-panel"));
    c.fillStyle = css("--ink"); c.fillText(name, at.x + w/2, at.y + 13*ts + 1);
  }
  function drawZ(a, t){
    if(!a.napping || a.path.length) return;
    ctx.fillStyle = css("--ink2"); ctx.font = fontOf(textScale())(15); ctx.textAlign = "center";
    ctx.fillText("z".repeat(1 + Math.floor(t*1.2 + a.seed) % 3), a.x + 26, a.y - 88);
  }
  // Edit mode: the draft with a tile grid, the fixed front shaded, characters frozen and faded, the selected item
  // outlined, and the item being dragged shown where it would go (red, with the reason, if it can't go there).
  function drawEdit(t){
    const room = draft, c = ctx, geo = frontOf(room), frontTop = (room.rows - RoomModel.FRONT_ROWS)*T, g = view.ghost;
    const shown = room.items.filter(it => CAT[it.kind] && !(g && g.id === it.id));
    drawFloor(room);
    for(const it of shown) if(CAT[it.kind].zone === "wall" || it.kind === "rug") drawFlat(it, t);
    drawFront(geo);
    box(W/2 - 220, geo.yourDeskY, 440, 48, 8, css("--rm-wood"));
    c.fillStyle = css("--ink"); c.font = font(15, 600); c.textAlign = "center"; c.fillText("Your desk", W/2, geo.yourDeskY + 30);
    const drawItem = it => it.kind === "desk" ? drawDesk({x:it.x, y:it.y, extra:false}, null, t) : drawStanding(it, t);
    shown.filter(it => CAT[it.kind].zone === "floor" && it.kind !== "rug").sort((p, q) => (p.y + CAT[p.kind].h) - (q.y + CAT[q.kind].h)).forEach(drawItem);
    c.globalAlpha = .3;
    [...agents.values()].sort((p, q) => p.y - q.y).forEach(a => drawAgent(a, t));
    c.globalAlpha = 1;
    // The grid over everywhere things can go; the front is fixed.
    c.strokeStyle = css("--ink3"); c.globalAlpha = .28; c.lineWidth = 1; c.beginPath();
    for(let x = 0; x <= W; x += T){ c.moveTo(x, 0); c.lineTo(x, frontTop); }
    for(let y = 0; y <= frontTop; y += T){ c.moveTo(0, y); c.lineTo(W, y); }
    c.stroke(); c.globalAlpha = 1;
    c.fillStyle = "rgba(120,120,140,.16)"; c.fillRect(0, frontTop, W, H - frontTop);
    c.fillStyle = css("--ink2"); c.font = font(13, 600); c.textAlign = "right"; c.fillText("Fixed: the queue and your desk", W - 12, frontTop + 20);
    const outline = (it, colour, fill) => {
      const cw = CAT[it.kind].w*T, ch = CAT[it.kind].h*T;
      if(fill){ c.fillStyle = fill; c.fillRect(it.x*T, it.y*T, cw, ch); }
      c.strokeStyle = colour; c.lineWidth = 3; c.beginPath(); c.roundRect(it.x*T + 1.5, it.y*T + 1.5, cw - 3, ch - 3, 5); c.stroke();
    };
    const sel = room.items.find(it => it.id === view.selected);
    if(sel && !(g && g.id === sel.id)) outline(sel, css("--accent"));
    if(g){
      const it = {id:g.id || "new", kind:g.kind, x:g.x, y:g.y};
      c.globalAlpha = .75;
      if(CAT[g.kind].zone === "wall" || g.kind === "rug") drawFlat(it, t); else drawItem(it);
      c.globalAlpha = 1;
      outline(it, g.bad ? "#D23B3B" : css("--accent"), g.bad ? "rgba(210,59,59,.28)" : "rgba(80,140,255,.12)");
      if(g.bad){
        c.font = font(13, 600); c.textAlign = "center";
        const text = fit(g.bad.charAt(0).toUpperCase() + g.bad.slice(1), 360), w = c.measureText(text).width + 16;
        const x = Math.max(4, Math.min(W - w - 4, (g.x + CAT[g.kind].w/2)*T - w/2)), below = (g.y + CAT[g.kind].h)*T + 6;
        const y = below + 24 < H ? below : g.y*T - 30;
        box(x, y, w, 24, 6, "#D23B3B"); c.fillStyle = "#FFFFFF"; c.fillText(text, x + w/2, y + 16.5);
      }
    }
  }
  function frame(ms){
    if(!active) return;
    requestAnimationFrame(frame);
    if(document.hidden || ms - last < 30) return;
    const dt = Math.min(.25, (ms - last)/1000); last = ms;
    const t = ms/1000;
    if(!G) build();
    if(draft){
      ctx.setTransform(k*devicePixelRatio, 0, 0, k*devicePixelRatio, ox*devicePixelRatio, oy*devicePixelRatio);
      ctx.clearRect(-ox/k, -oy/k, cv.width, cv.height);
      drawEdit(t);
      return;
    }
    const queue = [...agents.values()].filter(a => a.s.group === "needs" && !a.leaving).sort((x,y) => (x.s.statusSince||0) - (y.s.statusSince||0)).map(a => a.s.id);
    for(const a of [...agents.values()]){
      plan(a, t, queue);
      const speed = a.s.isSub ? 165 : a.s.group === "idle" ? 85 : 135;
      let left = speed * dt;
      while(left > 0 && a.path.length){
        const p = a.path[0], dx = p.x-a.x, dy = p.y-a.y, dist = Math.hypot(dx,dy);
        if(Math.abs(dx) > 1) a.face = dx < 0 ? -1 : 1;
        if(dist <= left){ a.x = p.x; a.y = p.y; a.path.shift(); left -= dist; } else { a.x += dx/dist*left; a.y += dy/dist*left; left = 0; }
      }
      if(a.leaving && !a.path.length && a.dest?.kind === "door") agents.delete(a.s.id);
    }
    ctx.setTransform(k*devicePixelRatio, 0, 0, k*devicePixelRatio, ox*devicePixelRatio, oy*devicePixelRatio);
    ctx.clearRect(-ox/k, -oy/k, cv.width, cv.height);
    placed = []; plates = []; plateRects = [];
    const room = G.room;
    // Text never covers the chalkboard or your desk.
    keepOut = room.items.filter(it => it.kind === "board").map(it => ({x:it.x*T + 8, y:18, w:CAT.board.w*T - 16, h:124}))
      .concat({x:W/2 - 220, y:G.yourDeskY, w:440, h:48}, {x:130, y:G.matTop + 6, w:90, h:22},
        room.items.filter(it => it.kind === "door").map(it => ({x:it.x*T + 10, y:18, w:100, h:20})));
    if(!board?.counts?.needs) keepOut.push({x:W/2 - 150, y:G.matTop + 42, w:300, h:26});
    drawFloor(room);
    for(const it of room.items) if(CAT[it.kind] && (CAT[it.kind].zone === "wall" || it.kind === "rug")) drawFlat(it, t);
    drawFront(G);
    const owners = new Map([...agents.values()].filter(a => !a.s.isSub && !a.leaving && deskOf(a) !== undefined).map(a => [deskOf(a), a]));
    const stools = [...agents.values()].filter(a => a.s.isSub && !a.leaving).map(seatOf).filter(h => h.kind === "helper" && !h.standing);
    const standing = room.items.filter(it => CAT[it.kind] && CAT[it.kind].zone === "floor" && it.kind !== "rug" && it.kind !== "desk");
    const draw = G.slots.map((d, i) => ({y:deskPt(d).y, f:() => drawDesk(d, owners.get(i), t)}))
      .concat(standing.map(it => ({y:(it.y + CAT[it.kind].h)*T - 12, f:() => drawStanding(it, t)})),
        stools.map(h => ({y:h.y - .5, f:() => drawStool(h.x, h.y)})), [...agents.values()].map(a => ({y:a.y, f:() => drawAgent(a, t)})));
    draw.sort((p,q) => p.y - q.y).forEach(o => o.f());
    box(W/2 - 220, G.yourDeskY, 440, 48, 8, css("--rm-wood"));
    ctx.fillStyle = css("--ink"); ctx.font = font(15, 600); ctx.textAlign = "center"; ctx.fillText("Your desk", W/2, G.yourDeskY + 30);
    const front = [...agents.values()].sort((m,n) => n.y - m.y || m.seed - n.seed);
    const queued = front.filter(a => a.s.group === "needs" && !a.s.isSub);
    queued.forEach(needBubble);
    for(const p of plates){ const at = spot(p.x, p.y, p.w, p.h, false); if(at){ p.draw(at.x, at.y); plateRects.push(at); } }
    front.filter(a => a.s.group === "working" && !a.s.isSub).forEach(cloud);
    front.forEach(drawTag);
    front.forEach(a => drawZ(a, t));
  }
  function size(){
    if(!G) build();
    const area = cv.parentElement.getBoundingClientRect();
    if(!area.width) return;
    const narrow = area.width < 620, cw = Math.max(area.width, 620), ch = narrow ? cw*H/W : area.height;
    k = Math.min(cw/W, ch/H); ox = (cw - W*k)/2; oy = 0;
    const pw = Math.round(cw*devicePixelRatio), ph = Math.round(ch*devicePixelRatio);
    if(cv.width !== pw || cv.height !== ph){ cv.width = pw; cv.height = ph; cv.style.width = cw + "px"; cv.style.height = ch + "px"; }
  }
  function at(e){
    const r = cv.getBoundingClientRect(), x = (e.clientX - r.left - ox)/k, y = (e.clientY - r.top - oy)/k;
    let found = null;
    // A seated session can also be picked by its name plate.
    for(const a of agents.values()) if(Math.abs(x-a.x) < (a.s.isSub ? 20 : 30) && y > a.y - (a.s.isSub ? 62 : 95) && y < a.y + (!a.s.isSub && seatedAt(a) ? 32 : 10) && (!found || a.y > found.y)) found = a;
    return found;
  }
  function init(canvas, pick){
    cv = canvas; ctx = cv.getContext("2d"); onPick = pick;
    new ResizeObserver(size).observe(cv.parentElement);
    cv.addEventListener("click", e => { if(draft) return; const s = at(e)?.s; onPick(s?.parent || s?.id || null); });
    cv.addEventListener("pointermove", e => {
      if(draft) return;
      const a = at(e); hover = a?.s.id || null; cv.style.cursor = a ? "pointer" : "default";
      const tip = document.getElementById("tip");
      if(a){ tip.textContent = ""; const b = document.createElement("b"); b.textContent = a.s.name; tip.append(b, document.createElement("br"), a.s.headline || ""); tip.style.display = "block"; tip.style.left = Math.min(innerWidth - tip.offsetWidth - 8, e.clientX + 14) + "px"; tip.style.top = e.clientY + 14 + "px"; }
      else tip.style.display = "none";
    });
    cv.addEventListener("pointerleave", () => { hover = null; document.getElementById("tip").style.display = "none"; });
  }
  // Enters edit mode with a draft room, or leaves it with null. view: {selected: id, ghost: {id, kind, x, y, bad}}.
  function edit(d, v){
    const was = draft;
    draft = d || null; view = v || {};
    if(!G) build();
    dims();
    if(cv && (!was !== !draft || was?.cols !== draft?.cols || was?.rows !== draft?.rows)) size();
    if(draft){ hover = null; const tip = document.getElementById("tip"); if(tip) tip.style.display = "none"; }
    else if(cv) cv.style.cursor = "default";
    if(!draft && was){ for(const a of agents.values()){ a.path = []; a.nextMove = 0; a.retry = 0; if(!a.leaving) a.dest = null; } }
  }
  // The tile under a pointer event, in room tiles.
  function tileAt(e){
    const r = cv.getBoundingClientRect();
    return {x:Math.floor((e.clientX - r.left - ox)/k/T), y:Math.floor((e.clientY - r.top - oy)/k/T)};
  }
  const themeColour = name => { const v = css(name); return /^#[0-9a-f]{6}$/i.test(v) ? v : "#cccccc"; };
  return {init, update, setRoom, edit, tileAt, themeColour, editing:() => !!draft, problem:() => problem, room:() => (G || (build(), G)).room, saved:() => saved,
    setActive(on){ if(on === active) return; active = on; if(on){ size(); requestAnimationFrame(frame); } }, select(id){ sel = id; }, highlight(id){ hover = id; }, say:a => textOf({s:a})};
})();
