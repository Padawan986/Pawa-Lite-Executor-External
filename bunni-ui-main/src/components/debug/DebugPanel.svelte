<script lang="ts">
    import { editorStr } from "$lib/stores/editor";
    import { VConsole } from "$lib/console";

    let isOpen = false;
    
    function toggleDebug() {
        isOpen = !isOpen;
    }
    
    function refreshEditor() {
        const monaco = $editorStr.files.find(f => f.id === $editorStr.active);
        if (monaco) {
            VConsole.info(`Refreshing editor: ${monaco.id}, content length: ${monaco.content.length}`);
        }
    }
    
    function logEditorState() {
        VConsole.info('Current editor state:', $editorStr);
    }
</script>

<div class="fixed bottom-4 right-4 z-50">
    <button 
        on:click={toggleDebug}
        class="bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-md px-3 py-1 text-sm font-medium"
    >
        {isOpen ? 'Hide Debug' : 'Show Debug'}
    </button>
    
    {#if isOpen}
        <div class="mt-2 p-4 bg-zinc-900/90 backdrop-blur-sm rounded-md border border-zinc-700 w-96 max-h-96 overflow-y-auto">
            <div class="flex justify-between mb-3">
                <h3 class="text-zinc-200 font-medium">Editor Debug</h3>
                <div class="flex gap-2">
                    <button 
                        on:click={refreshEditor}
                        class="bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-md px-2 py-0.5 text-xs"
                    >
                        Refresh
                    </button>
                    <button 
                        on:click={logEditorState}
                        class="bg-zinc-800 hover:bg-zinc-700 text-zinc-300 rounded-md px-2 py-0.5 text-xs"
                    >
                        Log State
                    </button>
                </div>
            </div>
            
            <div class="space-y-2">
                <div class="text-zinc-400 text-xs">
                    <div><span class="text-zinc-500">Active File:</span> {$editorStr.active}</div>
                    <div><span class="text-zinc-500">File Count:</span> {$editorStr.files.length}</div>
                </div>
                
                <div class="border-t border-zinc-800 pt-2">
                    <h4 class="text-zinc-400 text-xs mb-1">Files:</h4>
                    {#each $editorStr.files as file}
                        <div class="bg-zinc-800/50 rounded-md p-2 mb-2 text-xs">
                            <div class="flex justify-between">
                                <span class="text-zinc-300 font-medium">{file.name}</span>
                                <span class="text-zinc-500">{file.id}</span>
                            </div>
                            <div class="text-zinc-400 mt-1">
                                <div>
                                    <span class="text-zinc-500">Content Length:</span> 
                                    {file.content.length} chars
                                </div>
                                <div>
                                    <span class="text-zinc-500">Active:</span> 
                                    {file.id === $editorStr.active ? '✓' : '✗'}
                                </div>
                                <div>
                                    <span class="text-zinc-500">State:</span> 
                                    {Object.keys(file.state || {}).length > 0 ? '✓' : '✗'}
                                </div>
                            </div>
                            <div class="mt-1 bg-zinc-900/70 p-1 rounded overflow-x-auto max-h-12">
                                <pre class="text-zinc-400 text-2xs whitespace-pre-wrap">{file.content.substring(0, 100)}{file.content.length > 100 ? '...' : ''}</pre>
                            </div>
                        </div>
                    {/each}
                </div>
            </div>
        </div>
    {/if}
</div>

<style>
    .text-2xs {
        font-size: 0.7rem;
    }
</style>