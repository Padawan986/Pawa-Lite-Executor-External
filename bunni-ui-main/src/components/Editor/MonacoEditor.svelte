<script lang="ts">
    import { onMount, onDestroy } from "svelte";
    import type * as Monaco from "monaco-editor/esm/vs/editor/editor.api";
    import { editorStr, monacoInstance, updateFileContent, type EditorState } from "$lib/stores/editor";
    import { fade, fly } from "svelte/transition";
    import { VConsole } from "$lib/console";
    import { settings } from "$lib/settings";
    import { get } from "svelte/store";
    
    let {
        language = "lua",
        onChange = (value: string) => {}
    } = $props();
    
    let editor: Monaco.editor.IStandaloneCodeEditor;
    let monaco: typeof Monaco;
    let container: HTMLElement;
    let fileData: Record<string, {
        model: Monaco.editor.ITextModel | null,
        state: Monaco.editor.ICodeEditorViewState | null
    }> = {};
    
    let currentFileId: string | null = null;
    let files = $derived($editorStr.files);
    let activeFileId = $derived($editorStr.active);
    let activeFile = $derived(files.find(f => f.id === activeFileId));
    
    function switchToFile(fileId: string) {
        if (!editor || !monaco || !fileId) return;

        const file = files.find(f => f.id === fileId);
        if (!file) return;

        if (currentFileId && currentFileId !== fileId) {
            const currentState = editor.saveViewState();
            if (fileData[currentFileId]) {
                fileData[currentFileId].state = currentState;
                
                // save content
                const currentModel = editor.getModel();
                if (currentModel) {
                    const content = currentModel.getValue();
                    updateFileContent(currentFileId, content);
                }
            }
        }

        if (!fileData[fileId]) {
            fileData[fileId] = {
                model: monaco.editor.createModel(file.content, language),
                state: null
            };
        }

        editor.setModel(fileData[fileId].model);
        
        if (fileData[fileId].state) {
            editor.restoreViewState(fileData[fileId].state);
        }
        
        currentFileId = fileId;
        
        editor.layout();
        editor.focus();
    }
    
    onMount(async () => {
        monaco = ((await import("$lib/monaco")).default);

        // await init();

        monaco.editor.defineTheme("pawa-default", {
            base: "vs-dark",
            inherit: true,
            rules: [
                { token: '', background: '191919' },
                { token: 'comment', foreground: '6c6c7a' },
                { token: 'string', foreground: 'f1fa8c' },
                { token: "keyword", foreground: "FBC470" },
            ],
            colors: {
                'editor.foreground': '#f8f8f2',
                'editor.background': '#18181B',
                'editor.selectionBackground': '#252525',
                'editor.lineHighlightBackground': '#242429',
                'editorCursor.foreground': '#f8f8f0',
                'editorWhitespace.foreground': '#3B3A32',
                'editorIndentGuide.activeBackground': '#9D550FB0',
                'editor.selectionHighlightBorder': '#222218'
            }
        });

        monaco.editor.setTheme("pawa-default");

        editor = monaco.editor.create(container, {
            model: null,
            automaticLayout: true,
            smoothScrolling: true,
            useShadowDOM: false,
            tabCompletion: "on",
            minimap: { enabled: get(settings).enableMinimap },
            cursorSmoothCaretAnimation: "on",
            cursorBlinking: "smooth",
            cursorStyle: "line",
            autoIndent: "advanced",
            codeLens: true,
            lineNumbersMinChars: 0,
            lineDecorationsWidth: 20,
            lineNumbers: "on",
            glyphMargin: false,
            folding: false,
            fontFamily: '"JetBrainsMono Nerd Font"'
        });

        monacoInstance.set(editor);

        editor.onDidChangeModelContent(() => {
            if (!currentFileId) {
                return;
            }
            
            const model = editor.getModel();
            if (model) {
                const content = model.getValue();
                updateFileContent(currentFileId, content);
                onChange(content);
            }
        });

        if (editor) editor.getAction("editor.action.formatDocument")?.run();

        if (activeFileId) {
            switchToFile(activeFileId);
        }
    });

    $effect(() => {
        // explicity ref vars, which forces the update.
        // TODO: Rewrite how the tabbed monaco system works, this is not ideal.
        const currentActive = activeFileId;
        
        if (!editor || !monaco) {
            return;
        }
        
        if (currentActive && currentActive !== currentFileId) {
            switchToFile(currentActive);
        }
    });

    $effect(() => {
        if (!editor || !monaco || !activeFileId || !activeFile) {
            // VConsole.warn("Cannot sync content: Editor, Monaco, activeFileId, or activeFile not available");
            return;
        }

        if (fileData[activeFileId] && fileData[activeFileId].model) {
            const model = fileData[activeFileId].model;
            const currentModelContent = model.getValue();
            const storeContent = activeFile.content;

            if (currentModelContent !== storeContent) {
                // VConsole.info(`Syncing model content for file ${activeFileId}. Store content: ${storeContent}`);
                model.setValue(storeContent);
                editor.layout();
                editor.focus();
            }
        }
    });

    onDestroy(() => {
        if (currentFileId && editor) {
            const currentState = editor.saveViewState();
            if (fileData[currentFileId]) {
                fileData[currentFileId].state = currentState;
                const currentModel = editor.getModel();
                if (currentModel) {
                    const content = currentModel.getValue();
                    updateFileContent(currentFileId, content);
                    // VConsole.info(`Saved state and content for file ${currentFileId} on destroy`);
                }
            }
        }

        Object.values(fileData).forEach(data => {
            if (data.model) {
                data.model.dispose();
            }
        });
        
        if (editor) {
            editor.dispose();
            // disposeLSP();
        }
    });
</script>

<div class="editor-container w-full h-full">
    <div class="container w-full h-full pl-2" bind:this={container}></div>
</div>