<!-- @component Mobile tab bar for switching between terminal shells. -->
<script lang="ts">
  import { createEventDispatcher, tick } from "svelte";
  import { PlusIcon, XIcon } from "svelte-feather-icons";

  import type { WsWinsize } from "$lib/protocol";

  export let shells: [number, WsWinsize][] = [];
  export let activeId: number | null = null;
  export let titles: Record<number, string> = {};
  export let connected = false;
  export let canCreate = false;
  export let canClose = false;

  const dispatch = createEventDispatcher<{
    select: number;
    create: void;
    close: number;
  }>();

  let scrollerEl: HTMLDivElement;

  // Keep a stable left-to-right order (creation order), independent of the
  // server-side z-order used by the desktop canvas.
  $: tabs = [...shells].sort((a, b) => a[0] - b[0]);

  // Make sure the active tab stays visible in the horizontally scrolled list.
  $: if (activeId !== null && scrollerEl) {
    tick().then(() => {
      scrollerEl
        ?.querySelector(`[data-sid="${activeId}"]`)
        ?.scrollIntoView({ inline: "nearest", block: "nearest" });
    });
  }
</script>

<div class="panel flex min-w-0 items-stretch pointer-events-auto pr-1">
  <div
    class="scroller flex min-w-0 flex-1 items-center gap-1 overflow-x-auto overscroll-x-contain px-1.5 py-1"
    bind:this={scrollerEl}
    role="tablist"
  >
    <span
      class="ml-0.5 h-2 w-2 flex-shrink-0 rounded-full {connected
        ? 'bg-green-400'
        : 'bg-zinc-500'}"
      title={connected ? "Connected" : "Disconnected"}
    />
    {#each tabs as [id], i (id)}
      <div class="relative flex flex-shrink-0 items-center" data-sid={id}>
        <button
          type="button"
          role="tab"
          aria-selected={id === activeId}
          class="tab"
          class:active={id === activeId}
          on:click={() => dispatch("select", id)}
        >
          <span class="badge">{i + 1}</span>
          <span class="label">{titles[id] || "Terminal"}</span>
        </button>
        {#if id === activeId && canClose}
          <button
            type="button"
            class="close"
            aria-label="Close terminal"
            title="Close terminal"
            on:click|stopPropagation={() => dispatch("close", id)}
          >
            <XIcon size="12" />
          </button>
        {/if}
      </div>
    {/each}
    {#if tabs.length === 0}
      <span class="whitespace-nowrap px-2 text-xs text-zinc-400">
        No terminals
      </span>
    {/if}
  </div>

  <button
    type="button"
    class="create"
    disabled={!canCreate}
    title={canCreate ? "New terminal" : "Cannot create a terminal"}
    aria-label="New terminal"
    on:click={() => dispatch("create")}
  >
    <PlusIcon size="16" />
  </button>
</div>

<style lang="postcss">
  .scroller {
    scrollbar-width: none;
  }
  .scroller::-webkit-scrollbar {
    display: none;
  }

  .tab {
    @apply flex items-center gap-1.5 whitespace-nowrap rounded-md py-1 pl-1.5 pr-2 text-xs transition-colors;
    @apply text-zinc-400 hover:bg-zinc-700/60 hover:text-zinc-200;
  }
  .tab.active {
    @apply bg-indigo-700 pr-6 text-white;
  }
  .badge {
    @apply flex h-4 min-w-[1rem] items-center justify-center rounded-sm bg-black/20 px-1 text-[10px] font-medium;
  }
  .label {
    @apply max-w-[9rem] truncate;
  }
  .close {
    @apply absolute right-0.5 top-1/2 -translate-y-1/2 rounded p-0.5 text-white/70;
    @apply hover:bg-black/25 hover:text-white;
  }
  .create {
    @apply my-1 ml-1 flex flex-shrink-0 items-center justify-center rounded-md px-1.5 text-zinc-300;
    @apply transition-colors hover:bg-zinc-700 active:bg-indigo-700;
    @apply disabled:bg-transparent disabled:opacity-40;
  }
</style>
