<script lang="ts">
    import { notifs } from "$lib/stores/notification";
    import Notifcation from "./Notifcation.svelte";

</script>

<div class="fixed top-14 right-4 max-w-sm z-200 flex flex-col pointer-events-none">
    <div class="pointer-events-auto">
      {#each $notifs as notif (notif.id)}
        <Notifcation notif={notif} />
      {/each}
    </div>
</div>