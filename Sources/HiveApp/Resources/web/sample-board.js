/* Made-up boards in the /api/board shape, for checking the Classroom at any size (?sample=N). Pure: no network, no clock. */
"use strict";
(function(root){
  const FIRST = ["Mac", "Ada", "Juniper", "Orbit", "Pixel", "Maple", "Comet", "Willow", "Quartz", "Harbor", "Nova", "Ember"];
  const SECOND = ["Docs", "Billing", "Search", "Onboarding", "Release", "Android", "Website", "Payments", "Reports", "Sync", "Login", "Charts"];
  const PROJECTS = ["sunrise-app", "harbor-api", "ledger-web", "atlas-ios", "meadow-cli", "beacon-docs", "orchard-ml"];
  const WORK = [
    ["write", "Editing src/components/Header.tsx"], ["read", "Reading the payments module"], ["run", "Running the test suite"],
    ["web", "Searching the web for the API changelog"], ["think", "Thinking"], ["tool", "Using the browser"], ["write", "Writing the migration"],
  ];
  const ASKS = [["question", "Asked which database to use"], ["permission", "Wants to run a deploy script"], ["plan", "Plan ready for review"]];
  const HELPERS = [["Explore", "Find every caller of the old API", "read"], ["general-purpose", "Fix the failing login test", "run"],
    ["Plan", "Draft the rollout steps", "think"], ["general-purpose", "Check the docs site links", "web"]];
  const LONG = "A very long session name that will never fit on its name plate";

  // Small seeded random numbers (mulberry32), so the same seed always gives the same board.
  function rng(seed){
    let a = seed >>> 0;
    return () => { a = (a + 0x6D2B79F5) >>> 0; let t = a; t = Math.imul(t ^ t >>> 15, t | 1); t ^= t + Math.imul(t ^ t >>> 7, t | 61); return ((t ^ t >>> 14) >>> 0) / 4294967296; };
  }

  // n live sessions, spread over needs you, working and idle. now is the clock to stamp times against.
  function make(n, seed, now){
    const rand = rng(seed || 1), pick = list => list[Math.floor(rand() * list.length)];
    const clock = Math.floor(now || 1800000000 + (seed || 1) * 1000);
    const count = Math.max(0, Math.floor(n) || 0), sessions = [];
    let working = 0;
    for(let i = 0; i < count; i++){
      const group = ["working", "idle", "needs", "working", "idle", "working"][i % 6];
      const project = pick(PROJECTS), started = clock - 600 - Math.floor(rand() * 20000) - i;
      const name = i === 4 ? LONG : `${FIRST[i % FIRST.length]} ${SECOND[(i * 5 + Math.floor(i / FIRST.length)) % SECOND.length]}`;
      const row = {id: `sample-${seed}-${i}`, pid: 90000 + i, name, project, worktree: null, branch: i % 3 ? "main" : `feature/${i}`,
        cwd: `/sample/${project}`, group, reason: null, headline: "", doing: null, statusSince: clock - 30 - Math.floor(rand() * 900),
        lastTs: clock - Math.floor(rand() * 120), model: "claude-sample", effort: "high", subagents: {running: 0, total: 0}, helpers: [],
        plan: null, hostId: null, entry: "sample", version: "sample", startedAt: started, uptime: clock - started, live: true};
      if(group === "needs"){ const [reason, text] = pick(ASKS); row.reason = reason; row.headline = text; }
      else if(group === "working"){
        const [doing, text] = pick(WORK); row.doing = doing; row.headline = text;
        if(working++ % 3 === 0){
          const k = 1 + Math.floor(rand() * 3);
          for(let h = 0; h < k; h++){ const [type, description, hdoing] = HELPERS[(i + h) % HELPERS.length]; row.helpers.push({id: `${row.id}-h${h}`, type, description, doing: hdoing, task: ""}); }
          row.subagents = {running: k, total: k + Math.floor(rand() * 5)};
          row.doing = "subagents"; row.headline = `Waiting on ${k} subagent${k > 1 ? "s" : ""}`;
        }
      } else {
        row.headline = "Finished the last request";
        // Every fifth idle session has been idle long enough to nap.
        if(i % 5 === 1) row.lastTs = clock - 7 * 3600 - Math.floor(rand() * 3600);
      }
      sessions.push(row);
    }
    const counts = {needs: 0, working: 0, idle: 0, ended: 0};
    for(const s of sessions) counts[s.group]++;
    return {ready: true, sessions, counts, generatedAt: clock, sample: true};
  }

  const api = {make};
  if(typeof module === "object" && module.exports) module.exports = api;
  else root.SampleBoard = api;
})(typeof globalThis !== "undefined" ? globalThis : this);
