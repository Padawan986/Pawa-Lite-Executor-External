<script lang="ts">
    import { invoke } from "@tauri-apps/api/core";
    import { VConsole } from "$lib/console";
    import { api } from "$lib/editorapi";
    import { setActive as setActiveTab } from "$lib/stores/tabs";
    import { bumpExecutes } from "$lib/stores/stats";
    import { notifs } from "$lib/stores/notification";
    import { onMount } from "svelte";

    interface HubEntry {
        name: string;
        description: string;
        url: string;
        custom?: boolean;
        /** Ready-to-execute loadstring (ScriptBlox results). Wins over url. */
        code?: string;
        meta?: string;
    }

    interface BloxHit {
        title: string;
        game: string;
        keyless: boolean;
        verified: boolean;
        likes: number;
        code: string;
    }

    type Provider = "hub" | "blox";
    let provider: Provider = "hub";
    let bloxQuery = "";
    let bloxLoading = false;
    let bloxHits: BloxHit[] = [];

    const CURATED: HubEntry[] = [
        {
            name: "Infinite Yield",
            description: "Admin commands, ESP, fly, btools and much more.",
            url: "https://raw.githubusercontent.com/EdgeIY/infiniteyield/master/source",
        },
    ];

    const STORE_KEY = "pawa-hub-custom";

    let entries: HubEntry[] = [...CURATED];
    let filter = "";
    let newName = "";
    let newUrl = "";

    function loadCustom() {
        try {
            const raw = localStorage.getItem(STORE_KEY);
            if (!raw) return;
            const parsed = JSON.parse(raw);
            if (Array.isArray(parsed)) {
                const customs: HubEntry[] = parsed
                    .filter((e) => e && typeof e.name === "string" && typeof e.url === "string")
                    .map((e) => ({ name: e.name, description: e.description || "Custom entry", url: e.url, custom: true }));
                entries = [...CURATED, ...customs];
            }
        } catch {
            // corrupted storage -> curated only
        }
    }

    function saveCustom() {
        try {
            localStorage.setItem(
                STORE_KEY,
                JSON.stringify(entries.filter((e) => e.custom))
            );
        } catch {
            // storage blocked -> custom entries just don't survive restart
        }
    }

    onMount(loadCustom);

    $: visible = entries.filter((e) => {
        const q = filter.trim().toLowerCase();
        return (
            !q ||
            e.name.toLowerCase().includes(q) ||
            e.description.toLowerCase().includes(q)
        );
    });

    function loader(entry: HubEntry): string {
        return entry.code ?? `loadstring(game:HttpGet("${entry.url}"))()`;
    }

    async function run(entry: HubEntry) {
        VConsole.info(`Executing ${entry.name}...`);
        try {
            const result = await invoke<string>("execute", { script: loader(entry) });
            bumpExecutes();
            VConsole.success(`${entry.name}: ${result}`);
            notifs.success(`Executed ${entry.name}`, { title: "Script Hub" });
        } catch (e) {
            VConsole.error(`${entry.name} failed: ${e}`);
            notifs.warning(`${entry.name} failed`, { title: "Script Hub" });
        }
    }

    async function openInEditor(entry: HubEntry) {
        const open = (id: string) => {
            api.setActive(id);
            setActiveTab("editor");
        };
        if (entry.code) {
            const id = api.createFile(entry.name.replace(/[^\w\-. ]+/g, "") + ".lua", entry.code + "\n");
            open(id);
            VConsole.success(`Opened ${entry.name} in editor`);
            return;
        }
        try {
            const res = await fetch(entry.url);
            if (!res.ok) throw new Error(`HTTP ${res.status}`);
            const content = await res.text();
            const id = api.createFile(entry.name.replace(/[^\w\-. ]+/g, "") + ".lua", content);
            open(id);
            VConsole.success(`Opened ${entry.name} in editor`);
        } catch {
            // offline or CORS-blocked -> drop the loader stub instead so it
            // still runs at runtime
            const id = api.createFile(entry.name.replace(/[^\w\-. ]+/g, "") + ".lua", loader(entry) + "\n");
            open(id);
            VConsole.info(`Could not fetch ${entry.name}, inserted loader stub`);
        }
    }

    async function searchBlox() {
        const q = bloxQuery.trim();
        if (q.length < 2) {
            VConsole.error("Type at least 2 characters to search ScriptBlox");
            return;
        }
        bloxLoading = true;
        try {
            bloxHits = await invoke<BloxHit[]>("hub_search", { query: q });
            VConsole.info(`ScriptBlox: ${bloxHits.length} hits for "${q}"`);
        } catch (e) {
            VConsole.error(`ScriptBlox search failed: ${e}`);
            bloxHits = [];
        } finally {
            bloxLoading = false;
        }
    }

    function bloxToEntry(hit: BloxHit): HubEntry {
        const tags = [
            hit.game || "Universal",
            hit.keyless ? "keyless" : "key",
            hit.verified ? "verified" : null,
            `${hit.likes} likes`,
        ]
            .filter(Boolean)
            .join(" · ");
        return { name: hit.title, description: tags, url: "", code: hit.code, meta: tags };
    }

    async function copyUrl(entry: HubEntry) {
        try {
            await navigator.clipboard.writeText(entry.url);
            VConsole.success("URL copied");
        } catch {
            VConsole.error("Could not access clipboard");
        }
    }

    function addCustom() {
        const name = newName.trim();
        const url = newUrl.trim();
        if (!name || !url) {
            VConsole.error("Name and URL are required");
            return;
        }
        if (!/^https?:\/\//i.test(url)) {
            VConsole.error("URL must start with http(s)://");
            return;
        }
        entries = [...entries, { name, description: "Custom entry", url, custom: true }];
        saveCustom();
        newName = "";
        newUrl = "";
        VConsole.success(`Added ${name} to hub`);
    }

    function removeCustom(entry: HubEntry) {
        entries = entries.filter((e) => e !== entry);
        saveCustom();
    }
</script>

<div class="flex flex-col gap-3 h-full w-full overflow-hidden p-4">
    <div class="flex items-center gap-2">
        <div class="flex bg-zinc-800/50 rounded-lg p-0.5 text-xs">
            <button
                class="px-3 h-8 rounded-md cursor-pointer {provider === 'hub'
                    ? 'bg-zinc-700 text-zinc-100'
                    : 'text-zinc-400'}"
                on:click={() => (provider = "hub")}>Hub</button
            >
            <button
                class="px-3 h-8 rounded-md cursor-pointer {provider === 'blox'
                    ? 'bg-zinc-700 text-zinc-100'
                    : 'text-zinc-400'}"
                on:click={() => (provider = "blox")}>ScriptBlox</button
            >
        </div>
        {#if provider === "hub"}
            <input
                type="text"
                placeholder="Search hub..."
                bind:value={filter}
                class="flex-1 h-9 bg-zinc-800/50 rounded-lg px-3 placeholder-zinc-500 text-zinc-200 text-sm outline-1 outline-zinc-800 focus:outline-zinc-700"
            />
        {:else}
            <input
                type="text"
                placeholder="Search ScriptBlox..."
                bind:value={bloxQuery}
                on:keydown={(e) => e.key === "Enter" && searchBlox()}
                class="flex-1 h-9 bg-zinc-800/50 rounded-lg px-3 placeholder-zinc-500 text-zinc-200 text-sm outline-1 outline-zinc-800 focus:outline-zinc-700"
            />
            <button
                class="h-9 px-3 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-xs cursor-pointer disabled:opacity-50"
                disabled={bloxLoading}
                on:click={searchBlox}>{bloxLoading ? "..." : "Search"}</button
            >
        {/if}
    </div>

    {#if provider === "hub"}
        <div class="flex-1 overflow-y-auto flex flex-col gap-2 pr-1">
        {#each visible as entry (entry.name + entry.url)}
            <div class="bg-zinc-900 border border-zinc-700/50 rounded-xl p-3 flex flex-col gap-1">
                <div class="flex items-center gap-2">
                    <span class="font-semibold text-zinc-200 text-sm">{entry.name}</span>
                    {#if entry.custom}
                        <span class="text-[10px] px-1.5 py-0.5 rounded bg-zinc-700/60 text-zinc-300">custom</span>
                    {/if}
                </div>
                <p class="text-xs text-zinc-400">{entry.description}</p>
                <p class="text-[11px] text-zinc-500 truncate" title={entry.url}>{entry.url}</p>
                <div class="flex gap-2 mt-1">
                    <button
                        class="h-7 px-3 rounded-lg bg-[#FBC470] hover:bg-[#FBC470]/80 text-zinc-900 text-xs font-semibold cursor-pointer"
                        on:click={() => run(entry)}>Execute</button
                    >
                    <button
                        class="h-7 px-3 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-300 text-xs cursor-pointer"
                        on:click={() => openInEditor(entry)}>Open in editor</button
                    >
                    <button
                        class="h-7 px-3 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-300 text-xs cursor-pointer"
                        on:click={() => copyUrl(entry)}>Copy URL</button
                    >
                    {#if entry.custom}
                        <button
                            class="h-7 px-3 rounded-lg bg-zinc-800 hover:bg-red-900/60 text-zinc-300 text-xs cursor-pointer"
                            on:click={() => removeCustom(entry)}>Remove</button
                        >
                    {/if}
                </div>
            </div>
        {:else}
            <p class="text-zinc-500 text-sm">No scripts found.</p>
        {/each}
        </div>

        <div class="bg-zinc-900 border border-zinc-700/50 rounded-xl p-3 flex flex-col gap-2">
            <span class="text-xs font-semibold text-zinc-300">Add custom script</span>
            <div class="flex gap-2">
                <input
                    type="text"
                    placeholder="Name"
                    bind:value={newName}
                    class="flex-1 h-8 bg-zinc-800/50 rounded-lg px-3 placeholder-zinc-500 text-zinc-200 text-xs outline-1 outline-zinc-800 focus:outline-zinc-700"
                />
                <input
                    type="text"
                    placeholder="https://... (.lua raw URL)"
                    bind:value={newUrl}
                    class="flex-[2] h-8 bg-zinc-800/50 rounded-lg px-3 placeholder-zinc-500 text-zinc-200 text-xs outline-1 outline-zinc-800 focus:outline-zinc-700"
                />
                <button
                    class="h-8 px-3 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-xs cursor-pointer"
                    on:click={addCustom}>Add</button
                >
            </div>
        </div>
    {:else}
        <div class="flex-1 overflow-y-auto flex flex-col gap-2 pr-1">
            {#each bloxHits as hit (hit.title + hit.code.slice(0, 32))}
                {@const entry = bloxToEntry(hit)}
                <div class="bg-zinc-900 border border-zinc-700/50 rounded-xl p-3 flex flex-col gap-1">
                    <div class="flex items-center gap-2">
                        <span class="font-semibold text-zinc-200 text-sm">{entry.name}</span>
                        {#if hit.verified}
                            <span class="text-[10px] px-1.5 py-0.5 rounded bg-green-900/60 text-green-300">verified</span>
                        {/if}
                        {#if hit.keyless}
                            <span class="text-[10px] px-1.5 py-0.5 rounded bg-zinc-700/60 text-zinc-300">keyless</span>
                        {/if}
                    </div>
                    <p class="text-xs text-zinc-400">{entry.description}</p>
                    <div class="flex gap-2 mt-1">
                        <button
                            class="h-7 px-3 rounded-lg bg-[#FBC470] hover:bg-[#FBC470]/80 text-zinc-900 text-xs font-semibold cursor-pointer"
                            on:click={() => run(entry)}>Execute</button
                        >
                        <button
                            class="h-7 px-3 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-300 text-xs cursor-pointer"
                            on:click={() => openInEditor(entry)}>Open in editor</button
                        >
                        <button
                            class="h-7 px-3 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-300 text-xs cursor-pointer"
                            on:click={() => copyUrl({ ...entry, url: entry.code ?? "" })}>Copy code</button
                        >
                    </div>
                </div>
            {:else}
                <p class="text-zinc-500 text-sm">
                    {bloxLoading ? "Searching…" : "Search ScriptBlox above."}
                </p>
            {/each}
        </div>
    {/if}
</div>
