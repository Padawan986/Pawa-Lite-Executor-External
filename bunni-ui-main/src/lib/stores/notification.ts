import { writable } from "svelte/store";

export type NotifType = "info" | "success" | "warning" | "error";

export interface Notif {
    id: string,
    type: NotifType,
    msg: string,
    title?: string,
    duration?: number,
    dismissible?: boolean,
}

// create the store
function initNotifications() {
    const { subscribe, update } = writable<Notif[]>([]);

    function post(notif: Omit<Notif, "id">) {
        const props = { duration: 5000, dismissible: true };
        const obj: Notif = { ...props, ...notif, id: Date.now().toString() };

        update(v => [obj, ...v]);

        if (obj.duration && obj.duration > 0) setTimeout(() => { del(obj.id); }, obj.duration);

        return obj.id;
    }

    function del(id: string) {
        update(v => v.filter(n => n.id !== id));
    }

    function clear() {
        update(() => []);
    }

    return {
        subscribe,
        post,
        del,
        clear,
        info: (msg: string, props = {}) => post({ type: 'info', msg, ...props }),
        success: (msg: string, props = {}) => post({ type: 'success', msg, ...props }),
        warning: (msg: string, props = {}) => post({ type: 'warning', msg, ...props }),
        error: (msg: string, props = {}) => post({ type: 'error', msg, ...props }),
    }
}

export const notifs = initNotifications();