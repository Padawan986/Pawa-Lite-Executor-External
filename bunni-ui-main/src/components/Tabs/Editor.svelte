<script>
    import { fade } from "svelte/transition";
    import DebugPanel from "../debug/DebugPanel.svelte";
    import Console from "../Editor/Console.svelte";
    import EditorControlsBar from "../Editor/EditorControlsBar.svelte";
    import EditorTabsBar from "../Editor/EditorTabsBar.svelte";
    import MonacoEditor from "../Editor/MonacoEditor.svelte";
    import { onDestroy } from "svelte";
    import { saveTabs } from "$lib/restore";

    onDestroy(() => saveTabs());
</script>

<div in:fade={{ duration: 250 }} class="flex flex-col gap-2 h-screen w-full overflow-hidden">
    <EditorTabsBar />
    <EditorControlsBar />
    <div class="flex-1 w-full min-h-0 overflow-hidden"> <!-- Added w-full and overflow-hidden -->
        <MonacoEditor editorOptions={{minimap: { enabled: false }}} />
    </div>
    <div class="h-12 w-full min-h-0"> <!-- Fixed height in pixels instead of ratio -->
        <Console />
    </div>
    <!-- <DebugPanel /> -->
</div>