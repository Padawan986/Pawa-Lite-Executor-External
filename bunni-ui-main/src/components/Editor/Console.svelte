<script lang="ts">
    import { ChevronDown, CommandLine, Icon, Trash } from "svelte-hero-icons";
    import { logs, VConsole, type LogType } from "$lib/console";
    import { fade } from "svelte/transition";

    let open: boolean = false;

    function getColor(type: LogType) {
        switch (type) {
            case "error":
                return "text-red-400";
            case "warn":
                return "text-yellow-500";
            case "success":
                return "text-green-400";
            case "info":
            default:
                return "text-zinc-300";
        }
    }
</script>

<div class="relative z-99 h-10 bg-black/5 rounded-lg">
    <div
        class={`absolute bottom-0 w-full rounded-lg border border-zinc-800 backdrop-blur-xl transition-all duration-300 ${
            open ? "h-36" : "h-10"
        }`}
    >
        <div class="flex flex-col h-full overflow-hidden rounded-lg">
            <!-- svelte-ignore a11y_click_events_have_key_events -->
            <!-- svelte-ignore a11y_no_static_element_interactions -->
            <div
                class="flex justify-between px-2.5 p-2 cursor-pointer"
                onclick={() => (open = !open)}
            >
                <div class="flex gap-2 items-center">
                    <Icon
                        src={CommandLine}
                        class="text-zinc-400 size-5"
                        solid
                    />
                    <span class="text-zinc-400 font-inter text-sm">Console</span
                    >
                </div>    
                <div
                    class="flex justify-end gap-2"
                >
                    <button
                        onclick={() => VConsole.clear()}
                        class={`transition-opacity cursor-pointer duration-500 text-xs text-zinc-400 ${open ? "opacity-100" : "opacity-0 pointer-events-none"}`}
                    >
                        <Icon 
                            src={Trash}
                            class="text-zinc-400 p-0.5 size-6 hover:bg-zinc-700/40 transition-all rounded-sm"
                            solid
                        />
                    </button>
                    <Icon
                        src={ChevronDown}
                        class={`text-zinc-400 p-0.5 size-6 hover:bg-zinc-700/40 transition-all rounded-sm ${open ? "rotate-180" : "rotate-0"}`}
                        solid
                    />
                </div>
            </div>

            <div
                class={`overflow-hidden transition-all duration-300 ${
                    open ? "max-h-24 opacity-100" : "max-h-0 opacity-0"
                }`}
            >
                <div class="overflow-y-auto max-h-24">
                    <div class="px-2 py-1">
                        {#each [...$logs].reverse() as log (log.id)}
                            <div
                                class={`flex items-start gap-2 py-1 border-zinc-800 ${getColor(log.type)}`}
                            >
                                <span class="log-msg text-xs">
                                    [{log.timestamp.toLocaleTimeString([], {
                                        hour: "2-digit",
                                        minute: "2-digit",
                                        second: "2-digit",
                                    })}]
                                </span>
                                <span class="text-xs log-msg break-all">
                                    {log.msg}
                                </span>
                                {#if log.data}
                                    <span class="text-xs log-msg">
                                        {JSON.stringify(log.data)}
                                    </span>
                                {/if}
                            </div>
                        {/each}

                        {#if $logs.length === 0}
                            <div class="text-zinc-500 text-xs italic p-2">
                                No logs to display
                            </div>
                        {/if}
                    </div>
                </div>
            </div>
        </div>
    </div>
</div>

<style>
    .overflow-y-auto {
        -ms-overflow-style: none;
        scrollbar-width: none;
    }
    .overflow-y-auto::-webkit-scrollbar {
        display: none;
    }

    .log-msg {
        font-family: var(--font-monospace-code);
        font-weight: 500;
        font-size: 13px;
    }
</style>
