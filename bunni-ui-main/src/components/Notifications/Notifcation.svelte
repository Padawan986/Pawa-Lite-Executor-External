<script lang="ts">
    import { fly, fade } from "svelte/transition";
    import { notifs, type Notif } from "$lib/stores/notification";
    import { Icon, CheckCircle, XCircle, InformationCircle, ExclamationTriangle, XMark } from "svelte-hero-icons";

    let { notif }: { notif: Notif } = $props();

    function getIcon(type: Notif["type"]) {
        switch (type) {
            case "success":         return CheckCircle;
            case "error":           return XCircle;
            case "warning":         return ExclamationTriangle;
            case "info": default:   return InformationCircle;
        }
    }

    function getColor(type: Notif["type"]) {
        switch (type) {
            case "success":         return "text-green-400";
            case "error":           return "text-red-400";
            case "warning":         return "text-yellow-400";
            case "info": default:   return "text-zinc-300";
        }
    }

    function dismiss() { notifs.del(notif.id); }
</script>

<div
    in:fly={{ x: 300, duration: 300 }}
    out:fly={{ x: 300, duration: 300 }}
    class="flex items-start gap-3 p-3 mb-2 min-w-56 max-w-72 backdrop-blur-sm rounded-lg bg-zinc-700/10"
>
    <div class={`flex-shrink-0 mt-0.5 ${getColor(notif.type)}`}>
        <Icon src={getIcon(notif.type)} solid class="size-5" />
    </div>

    <div class="flex-1 overflow-hidden">
        {#if notif.title}
            <h3 class="font-medium text-zinc-200 mb-1 break-words">{notif.title}</h3>
        {/if}

        <p class="text-sm text-zinc-300 break-words whitespace-normal">{notif.msg}</p>
    </div>

    {#if notif.dismissible}
        <button
            onclick={dismiss}
            class="flex-shrink-0 text-zinc-400 hover:text-zinc-200 transition-colors ml-1"
            aria-label="dismiss"
        >
            <Icon src={XMark} class="size-4" />
        </button>
    {/if}
</div>