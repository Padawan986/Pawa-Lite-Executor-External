import { writable, get } from "svelte/store";

export interface SessionStats {
    attaches: number;
    executes: number;
    sessionStart: number;
}

const KEY = "pawa-stats";

function load(): SessionStats {
    try {
        const raw = localStorage.getItem(KEY);
        if (raw) {
            const parsed = JSON.parse(raw);
            return {
                attaches: Number(parsed.attaches) || 0,
                executes: Number(parsed.executes) || 0,
                sessionStart: Date.now(),
            };
        }
    } catch {
        // corrupted storage -> start fresh
    }
    return { attaches: 0, executes: 0, sessionStart: Date.now() };
}

function persist(s: SessionStats) {
    try {
        localStorage.setItem(
            KEY,
            JSON.stringify({ attaches: s.attaches, executes: s.executes })
        );
    } catch {
        // storage full/blocked -> stats just don't survive restart
    }
}

export const stats = writable<SessionStats>(load());

export function bumpAttaches() {
    stats.update((s) => {
        const next = { ...s, attaches: s.attaches + 1 };
        persist(next);
        return next;
    });
}

export function bumpExecutes() {
    stats.update((s) => {
        const next = { ...s, executes: s.executes + 1 };
        persist(next);
        return next;
    });
}

export function sessionUptime(): string {
    const secs = Math.floor((Date.now() - get(stats).sessionStart) / 1000);
    const h = Math.floor(secs / 3600);
    const m = Math.floor((secs % 3600) / 60);
    const s = secs % 60;
    if (h > 0) return `${h}h ${m}m`;
    if (m > 0) return `${m}m ${s}s`;
    return `${s}s`;
}
