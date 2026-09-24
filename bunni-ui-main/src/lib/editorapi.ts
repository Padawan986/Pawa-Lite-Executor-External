import { get } from "svelte/store";
import { editorStr, monacoInstance, type File } from "./stores/editor";
import { VConsole } from "./console";
import { invoke } from "@tauri-apps/api/core";
import { bumpExecutes } from "./stores/stats";

export interface EditorAPI {
    getContent(): string,
    getActiveID(): string,
    getFileContent(id: string): string | null,
    getFiles(): { id: string; name: string; content: string }[],
    updateFileContent(id: string, content: string): void,
    getInstance(): any,
    executeFile(): void,
    createFile(name: string, content: string): string,
    setActive(id: string): void,
}

export const api: EditorAPI = {
    getContent(): string {
        const str = get(editorStr);
        const file = str.files.find(f => f.id === str.active);
        return file?.content || "";
    },

    getFileContent(id: string): string {
        const str = get(editorStr);
        const file = str.files.find(f => f.id === id);
        return file?.content || "";
    },

    getFiles() {
        return get(editorStr).files.map(({ id, name, content }) => ({ id, name, content }));
    },

    updateFileContent(id: string, content: string) {
        editorStr.update(v => ({
            ...v,
            files: v.files.map(f => f.id === id ? { ...f, content } : f)
        }));
    },

    getInstance() {
        return get(monacoInstance);
    },

    async executeFile() {
        const content = this.getContent();
        if (!content.trim()) {
            VConsole.error("Nothing to execute (empty script)");
            return;
        }

        try {
            const result = await invoke<string>("execute", { script: content });
            bumpExecutes();
            VConsole.success(`Executed: ${result}`);
        } catch (e) {
            VConsole.error(`Error occured during execution: ${e}`);
        }
    },

    createFile(name: string, content: string): string {
        const timestamp = Date.now();
        const id = `file-${timestamp}`;

        editorStr.update(v => ({
            ...v,
            files: [
                ...v.files,
                {
                    id,
                    name,
                    content,
                    state: {}
                }
            ]
        }));

        VConsole.success(`Created file ${id}`);
        return id;
    },

    setActive(id: string) {
        const str = get(editorStr);
        const exists = str.files.some(f => f.id === id);
    
        if (exists) {
            editorStr.update(v => {
                VConsole.info(`Setting active file to ${id}`);
                return {
                    ...v,
                    active: id
                };
            });
        } else {
            VConsole.error(`File '${id}' not found`);
        }
    },

    getActiveID(): string {
        const str = get(editorStr);
        return str.active;
    }
};