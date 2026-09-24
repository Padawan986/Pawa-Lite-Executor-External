import { get, writable } from "svelte/store";
import { type IconSource } from "svelte-hero-icons";

export interface Tab {
    id: string,
    label: string,
    icon: IconSource,
    disabled: boolean,
    comp: any,
    pos?: number, // this is the order the tab will be placed in the cotainer
}

export const tabs = writable<Tab[]>([]);
export const active = writable<string | null>(null);

export function register(tab: Tab): void {
    tabs.update(t => {
        // find if it exists
        const idx = t.findIndex(t => t.id === tab.id);
        if (idx >= 0) {
            t[idx] = tab;
            return [...t];
        }

        return [...t, tab].sort((x, y) => (x.pos || 100) - (y.pos || 100));
    });

    if (get(tabs).length === 1) setActive(tab.id);
}

export function unregister(id: string): void {
    tabs.update(ts => ts.filter(t => t.id !== id));

    // select another tab is current was delted
    const currentIdx = get(active);
    if (currentIdx === id) {
        const tabz = get(tabs)
        if (tabz.length > 0) setActive(tabz[0].id);
        else active.set(null);
    }
}

export function setActive(id: string): void {
    const tabz = get(tabs);
    const exists = tabz.some(t => t.id === id);

    if (exists) active.set(id);
    // here we can output to the console
    else console.warn(`tab ${id} does not exist.`);
}

export function getTab(id: string): Tab | undefined {
    return get(tabs).find(t => t.id === id);
}