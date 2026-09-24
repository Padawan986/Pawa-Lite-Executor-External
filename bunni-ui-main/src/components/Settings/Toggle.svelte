<script lang="ts">
    interface Props {
        title: string,
        description: string,
        checked: boolean,
        onChange: (v: boolean) => void;
    }

    let { 
        title,
        description,
        checked = $bindable(),
        onChange
    }: Props = $props();
</script>

<div class="flex items-center justify-between">
    <div>
        <h3 class="text-zinc-200 font-medium">{title}</h3>
        <p class="text-xs text-zinc-400">{description}</p>
    </div>
    <label class="relative inline-flex items-center cursor-pointer">
        <input 
            type="checkbox" 
            class="sr-only peer" 
            bind:checked 
            onchange={() => onChange(checked)}
        >
        
        <div class="w-9 h-5 bg-zinc-700 peer-focus:outline-none rounded-full peer peer-checked:after:translate-x-full rtl:peer-checked:after:-translate-x-full after:content-[''] after:absolute after:top-[2px] after:start-[2px] after:bg-zinc-100 after:border-zinc-300 after:rounded-full after:h-4 after:w-4 after:transition-all peer-checked:bg-[#FBC470]"></div>
    </label>
</div>