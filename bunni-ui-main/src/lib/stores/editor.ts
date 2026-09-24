import { get, writable } from "svelte/store";

export interface EditorState {
    cursorPos?: { lineNumber: number, column: number },
    scrollPos?: { scrollTop: number, scrollLeft: number },
    vstate?: any,   // view state
}

export interface File {
    id: string,
    name: string,
    content: string,
    state: EditorState,
}

const template: File = {
    id: "untitled1",
    name: "untitled1.lua",
    content: "-- Pawa-Lite(Beta)V2",
    state: {}
};

export const editorStr = writable<{ files: File[], active: string}>({
    files: [ template ],
    active: template.id,
});

export const monacoInstance: any = writable<any>(null);

export function getEditorsCurrentFile(): File | undefined {
    const str = get(editorStr);
    return str.files.find(f => f.id === str.active);
}

export function setActiveFile(id: string): boolean {
    const str = get(editorStr);
    const exists = str.files.some(f => f.id === id);

    if (exists) {
        editorStr.update(s => ({ ...s, active: id }));
        return true;
    }

    return false;
}

export function createFile(name: string, content: string = "-- Pawa-Lite(Beta)V2"): string {
    const id = `file-${Date.now()}`;
    const file: File = {
        id,
        name,
        content,
        state: {}
    };

    editorStr.update(s => ({
        ...s,
        files: [...s.files, file],
        active: id
    }));

    return id;
}

export function deleteFile(id: string): boolean {
    const str = get(editorStr);

    if (str.files.length <= 1) return false;
    
    const idx = str.files.findIndex(f => f.id === id);
    if (idx === -1) return false;

    editorStr.update(s => {
        const files = s.files.filter(f => f.id !== id);
        let active = s.active;
        if (active === id) {
            const newidx = Math.min(idx, files.length - 1);
            active = files[newidx]?.id || files[0]?.id || "";
        }

        return { files, active };
    });

    return true;
}

export function renameFile(id: string, newName: string): boolean {
    editorStr.update(s => ({
        ...s,
        files: s.files.map(f => f.id === id ? { ...f, name: newName } : f)
    }));

    return true;
}

export function getEditorsFiles(): File[] {
    return get(editorStr).files;
}

export function updateFileContent(id: string, content: string): void {
    editorStr.update(v => ({ ...v, files: v.files.map(f => f.id === id ? { ...f, content } : f) }));
}

export function updateFileState(id: string, state: EditorState): void {
    editorStr.update(v => ({ ...v, files: v.files.map(f => f.id === id ? { ...f, state: { ...f.state, ...state } } : f) }));
}