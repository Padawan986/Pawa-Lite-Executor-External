<!-- EditorTabsBar.svelte -->
<script lang="ts">
    import { editorStr } from "$lib/stores/editor";
    import { type File } from "$lib/stores/editor";
    import { fly, scale } from "svelte/transition";
    import { get } from "svelte/store";
    import { Bars3BottomLeft, Icon } from "svelte-hero-icons";
    import { notifs } from "$lib/stores/notification";

    let files: File[] = [];
    let active: string;

    editorStr.subscribe((s) => {
        files = s.files;
        active = s.active;
    });

    function setActive(id: string) {
        editorStr.update((s) => ({
            ...s,
            active: id
        }));
    }

    function closeFile(id: string) {
        if (get(editorStr).files.length === 1) return;

        editorStr.update((s) => {
            const updated = s.files.filter(f => f.id !== id);
            let activeNew = s.active;

            if (id === s.active) {
                const idx = s.files.findIndex(f => f.id === id);
                
                if (idx > 0) {
                    activeNew = updated[idx - 1].id;
                } else if (updated.length > 0) {
                    activeNew = updated[0].id;
                } else {
                    activeNew = "";
                }
            }

            return {
                ...s,
                files: updated,
                active: activeNew,
            };
        });
    }

    function newFile() {
        const maxidx = files.reduce((max, file) => {
            const match = file.name.match(/^untitled(\d+)\.lua$/);
            if (match) {
                const index = parseInt(match[1], 10);
                return Math.max(max, index);
            }

            return max;
        }, 0);

        const newidx = maxidx + 1;
        const name = `untitled${newidx}.lua`;
        const id = `file-${Date.now()}`;

        editorStr.update((s) => ({
            ...s,
            files: [
                ...s.files,
                { 
                    id: id, 
                    name: name, 
                    content: "-- Pawa-Lite(Beta)V2",
                    state: {}
                }
            ],
            active: id
        }));
    }

    let tabs: HTMLDivElement | null = null;
    function handlescroll(e: WheelEvent) {
        if (e.deltaX === 0 && e.deltaY !== 0 && tabs !== null) { 
            e.preventDefault();
            tabs.scrollTo({ left: tabs.scrollLeft + e.deltaY , behavior: "smooth" });
        }
    }
</script>

<div 
    bind:this={tabs}
    onwheel={handlescroll}
    class="flex border-zinc-700/50 bg-zinc-900 overflow-x-auto hscroll gap-1 items-center h-8">
    {#each files as file, i}
        <!-- svelte-ignore a11y_click_events_have_key_events -->
        <!-- svelte-ignore a11y_no_static_element_interactions -->

        <!-- oncontextmenu={handleCtx} -->
        <div
            in:scale={{start: 0, duration: 100}}
            out:scale={{start: 0.5, duration: 100}}
        >
            <div
            class="transition-all rounded-tl-xl rounded-br-xl h-full rounded-bl-md rounded-tr-md flex items-center px-2 py-1.5 gap-1.5 text-xs {active === file.id ? 'bg-zinc-800 text-[#FBC470]/90' : 'bg-zinc-800/20 text-zinc-400 hover:bg-zinc-800/70'} cursor-pointer"
            in:fly={{x: -100, duration: 200}}
            out:fly={{x: -100, duration: 200}}
            onclick={() => setActive(file.id)}
        >
            <Icon src={Bars3BottomLeft} class="size-4"/>
            <span class="truncate max-w-32 font-inter">{file.name}</span>
            <button 
                class="ml-2 text-zinc-500 hover:text-white"
                onclick={(e) => { e.stopPropagation(); closeFile(file.id)} }
            >
                ×
            </button>
        </div>
        </div>
    {/each}

    <button class="bg-zinc-900 text-zinc-400 hover:bg-zinc-800 text-xs size-5 min-w-5 mr-2 rounded-md transition-transform" onclick={newFile}>+</button>
</div>