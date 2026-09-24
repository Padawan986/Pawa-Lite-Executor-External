<script lang="ts">
    import { Icon } from "svelte-hero-icons";

    interface Props {
        categories: Array<{ label: string, icon?: any }>,
        active: string,
        onSelect: (cat: string) => void;
    }

    let { 
        categories,
        active,
        onSelect
    }: Props = $props();
</script>

<div class="flex flex-wrap gap-2">
    {#each categories as cat}
        <button
            onclick={() => onSelect(cat.label)}
            class={`transition-all rounded-tl-xl rounded-br-xl h-8 text-center rounded-bl-md rounded-tr-md flex items-center pl-3 pr-4 py-1.5 gap-1.5 text-xs ${cat.label === active ? 'bg-zinc-800 text-[#FBC470]/90' : 'bg-zinc-800/20 text-zinc-400 hover:bg-zinc-800/70'} cursor-pointer`}
        >
            {#if cat.icon}
                <Icon src={cat.icon} class="size-4"/>
            {/if}
            <span class="truncate max-w-32 font-inter">{cat.label}</span>
        </button>
    {/each}
</div>