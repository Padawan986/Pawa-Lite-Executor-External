<script lang="ts">
    import { stats, sessionUptime } from "$lib/stores/stats";
    import { keyverified, attaching } from "$lib/stores/global";
    import { VConsole } from "$lib/console";
    import Logo from "$lib/assets/pawa-logo.svg";
    import { onMount, onDestroy } from "svelte";

    let uptime = sessionUptime();
    let timer: ReturnType<typeof setInterval> | null = null;

    onMount(() => {
        timer = setInterval(() => {
            uptime = sessionUptime();
        }, 1000);
    });

    onDestroy(() => {
        if (timer) clearInterval(timer);
    });

    async function copyText(text: string, label: string) {
        try {
            await navigator.clipboard.writeText(text);
            VConsole.success(`${label} copied`);
        } catch {
            VConsole.error("Could not access clipboard");
        }
    }
</script>

<div class="flex flex-col gap-3 h-full w-full overflow-y-auto p-4">
    <div class="bg-zinc-900 border border-zinc-700/50 rounded-xl p-4 flex items-center gap-4">
        <img src={Logo} alt="Pawa-Lite(Beta)V2" class="size-14 invert" />
        <div class="flex flex-col">
            <span class="font-bold text-zinc-100 text-lg">Pawa-Lite(Beta)V2</span>
            <span class="text-xs text-zinc-400">External executor UI · v2.0 · keyless</span>
            <span class="text-[11px] mt-1 {$keyverified ? 'text-green-400' : 'text-red-400'}">
                {$keyverified ? "● Key verified" : "● Key missing"}
            </span>
        </div>
    </div>

    <div class="bg-zinc-900 border border-zinc-700/50 rounded-xl p-4 flex flex-col gap-2">
        <span class="text-xs font-semibold text-zinc-300 uppercase tracking-wide">Session</span>
        <div class="grid grid-cols-3 gap-2 text-center">
            <div class="bg-zinc-800/50 rounded-lg p-2">
                <div class="text-xl font-bold text-zinc-100">{$stats.attaches}</div>
                <div class="text-[11px] text-zinc-400">Attaches</div>
            </div>
            <div class="bg-zinc-800/50 rounded-lg p-2">
                <div class="text-xl font-bold text-zinc-100">{$stats.executes}</div>
                <div class="text-[11px] text-zinc-400">Executes</div>
            </div>
            <div class="bg-zinc-800/50 rounded-lg p-2">
                <div class="text-xl font-bold text-zinc-100">{uptime}</div>
                <div class="text-[11px] text-zinc-400">Uptime</div>
            </div>
        </div>
        {#if $attaching}
            <span class="text-xs text-orange-400">Attaching in progress…</span>
        {/if}
    </div>

    <div class="bg-zinc-900 border border-zinc-700/50 rounded-xl p-4 flex flex-col gap-2">
        <span class="text-xs font-semibold text-zinc-300 uppercase tracking-wide">Executor identity</span>
        <p class="text-[11px] text-zinc-500">
            What <span class="text-zinc-300 font-mono">identifyexecutor()</span> reports ingame.
        </p>
        <div class="flex gap-2">
            <code class="flex-1 text-xs font-mono bg-zinc-800/50 rounded-lg px-3 py-2 text-zinc-200 overflow-x-auto whitespace-nowrap"
                >identifyexecutor() --&gt; "Pawa-Lite(Beta)V2", "v2.0"</code
            >
            <button
                class="h-8 px-3 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-xs cursor-pointer"
                on:click={() => copyText('identifyexecutor()', 'Snippet')}
                >Copy</button
            >
        </div>
        <div class="flex gap-2">
            <code class="flex-1 text-xs font-mono bg-zinc-800/50 rounded-lg px-3 py-2 text-zinc-200 overflow-x-auto whitespace-nowrap"
                >loadstring(game:HttpGet(url))()</code
            >
            <button
                class="h-8 px-3 rounded-lg bg-zinc-800 hover:bg-zinc-700 text-zinc-200 text-xs cursor-pointer"
                on:click={() => copyText('loadstring(game:HttpGet("URL"))()', 'Snippet')}
                >Copy</button
            >
        </div>
    </div>
</div>
