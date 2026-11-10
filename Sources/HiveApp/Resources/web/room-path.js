/* Walking on the classroom's tile grid: A* path-finding. Pure functions, used by room.js in the browser and by tests in Node. */
"use strict";
(function(root){
  // A walkable grid. blocked(x, y) says whether a tile inside the room can't be walked on.
  function grid(cols, rows, blocked){
    const cells = new Uint8Array(cols * rows);
    for(let y = 0; y < rows; y++) for(let x = 0; x < cols; x++) cells[y * cols + x] = blocked(x, y) ? 0 : 1;
    const ok = (x, y) => Number.isInteger(x) && Number.isInteger(y) && x >= 0 && y >= 0 && x < cols && y < rows && cells[y * cols + x] === 1;
    return {cols, rows, ok};
  }

  const STEPS = [[1,0],[-1,0],[0,1],[0,-1],[1,1],[1,-1],[-1,1],[-1,-1]];
  const octile = (ax, ay, bx, by) => { const dx = Math.abs(ax - bx), dy = Math.abs(ay - by); return Math.max(dx, dy) + (Math.SQRT2 - 1) * Math.min(dx, dy); };

  // Tiles from the first step after `from` through `to`, in 8 directions, never cutting a blocked corner.
  // null when `to` is blocked or can't be reached. `from` itself may be blocked (a character standing on furniture).
  function findPath(g, from, to){
    if(!g.ok(to.x, to.y)) return null;
    if(from.x === to.x && from.y === to.y) return [];
    const W = g.cols, key = (x, y) => y * W + x, start = key(from.x, from.y), goal = key(to.x, to.y);
    const cost = new Map([[start, 0]]), came = new Map(), done = new Set();
    // A small binary heap keyed on f = cost + octile distance.
    const heap = [];
    const push = (f, k) => { heap.push([f, k]); let i = heap.length - 1; while(i > 0){ const p = (i - 1) >> 1; if(heap[p][0] <= heap[i][0]) break; [heap[p], heap[i]] = [heap[i], heap[p]]; i = p; } };
    const pop = () => { const top = heap[0], end = heap.pop(); if(heap.length){ heap[0] = end; let i = 0; for(;;){ const l = 2*i + 1, r = l + 1; let m = i; if(l < heap.length && heap[l][0] < heap[m][0]) m = l; if(r < heap.length && heap[r][0] < heap[m][0]) m = r; if(m === i) break; [heap[m], heap[i]] = [heap[i], heap[m]]; i = m; } } return top; };
    push(octile(from.x, from.y, to.x, to.y), start);
    while(heap.length){
      const [, k] = pop();
      if(done.has(k)) continue;
      if(k === goal) break;
      done.add(k);
      const x = k % W, y = (k - x) / W, base = cost.get(k);
      for(const [dx, dy] of STEPS){
        const nx = x + dx, ny = y + dy;
        if(!g.ok(nx, ny)) continue;
        if(dx && dy && (!g.ok(x + dx, y) || !g.ok(x, y + dy))) continue;
        const nk = key(nx, ny), c = base + (dx && dy ? Math.SQRT2 : 1);
        if(c < (cost.has(nk) ? cost.get(nk) : Infinity)){ cost.set(nk, c); came.set(nk, k); push(c + octile(nx, ny, to.x, to.y), nk); }
      }
    }
    if(!came.has(goal)) return null;
    const out = [];
    for(let k = goal; k !== start; k = came.get(k)){ const x = k % W; out.push({x, y: (k - x) / W}); }
    return out.reverse();
  }

  // The closest walkable tile to `at` (breadth-first over the whole grid), or null if none is walkable.
  function nearestOpen(g, at){
    const cx = Math.max(0, Math.min(g.cols - 1, Math.round(at.x))), cy = Math.max(0, Math.min(g.rows - 1, Math.round(at.y)));
    if(g.ok(cx, cy) && cx === at.x && cy === at.y) return {x: cx, y: cy};
    const seen = new Uint8Array(g.cols * g.rows), queue = [[cx, cy]];
    seen[cy * g.cols + cx] = 1;
    for(let i = 0; i < queue.length; i++){
      const [x, y] = queue[i];
      if(g.ok(x, y)) return {x, y};
      for(const [dx, dy] of STEPS){
        const nx = x + dx, ny = y + dy;
        if(nx < 0 || ny < 0 || nx >= g.cols || ny >= g.rows || seen[ny * g.cols + nx]) continue;
        seen[ny * g.cols + nx] = 1; queue.push([nx, ny]);
      }
    }
    return null;
  }

  const api = {grid, findPath, nearestOpen};
  if(typeof module === "object" && module.exports) module.exports = api;
  else root.RoomPath = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
