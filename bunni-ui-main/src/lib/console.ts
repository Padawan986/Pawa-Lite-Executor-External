import { writable } from "svelte/store";

export type LogType = "info" | "warn" | "error" | "success";

export interface Log {
    id: string,
    timestamp: Date,
    type: LogType,
    msg: string,
    data?: any,
}

export const logs = writable<Log[]>([]);

const newLog = (type: LogType, msg: string, data?: any) => {
    const log: Log = {
        id: Math.random().toString(36).substring(2, 10),
        timestamp: new Date(),
        type, msg, data
    };

    logs.update(s => {
        const updated = [log, ...s]
        return updated.slice(0, 100); // 100 is max logs
    });

    return log;
}

export const VConsole = {
    info: (msg: string, data?: any) => newLog("info", msg, data),
    warn: (msg: string, data?: any) => newLog("warn", msg, data),
    error: (msg: string, data?: any) => newLog("error", msg, data),
    success: (msg: string, data?: any) => newLog("success", msg, data),
    clear: () => logs.set([])
};
