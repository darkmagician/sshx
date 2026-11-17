<script lang="ts">
  import {
    onDestroy,
    onMount,
    tick,
    beforeUpdate,
    afterUpdate,
    createEventDispatcher,
  } from "svelte";
  import { fade } from "svelte/transition";
  import { debounce, throttle } from "lodash-es";

  import { Encrypt } from "./encrypt";
  import { createLock } from "./lock";
  import { Srocket } from "./srocket";
  import type { WsClient, WsServer, WsUser, WsWinsize } from "./protocol";
  import { makeToast } from "./toast";
  import Chat, { type ChatMessage } from "./ui/Chat.svelte";
  import ChooseName from "./ui/ChooseName.svelte";
  import NameList from "./ui/NameList.svelte";
  import NetworkInfo from "./ui/NetworkInfo.svelte";
  import Settings from "./ui/Settings.svelte";
  import Toolbar from "./ui/Toolbar.svelte";
  import XTerm from "./ui/XTerm.svelte";
  import Avatars from "./ui/Avatars.svelte";
  import LiveCursor from "./ui/LiveCursor.svelte";
  import SessionTabs from "./ui/SessionTabs.svelte";
  import { slide } from "./action/slide";
  import { TouchZoom, INITIAL_ZOOM, MIN_ZOOM } from "./action/touchZoom";
  import { arrangeNewTerminal } from "./arrange";
  import { settings } from "./settings";
  import { EyeIcon } from "svelte-feather-icons";

  export let id: string;

  const dispatch = createEventDispatcher<{ receiveName: string }>();

  // The magic numbers "left" and "top" are used to approximately center the
  // terminal at the time that it is first created.
  const CONSTANT_OFFSET_LEFT = 378;
  const CONSTANT_OFFSET_TOP = 240;

  const OFFSET_LEFT_CSS = `calc(50vw - ${CONSTANT_OFFSET_LEFT}px)`;
  const OFFSET_TOP_CSS = `calc(50vh - ${CONSTANT_OFFSET_TOP}px)`;
  const OFFSET_TRANSFORM_ORIGIN_CSS = `calc(-1 * ${OFFSET_LEFT_CSS}) calc(-1 * ${OFFSET_TOP_CSS})`;

  // Terminal width and height limits.
  const TERM_MIN_ROWS = 8;
  const TERM_MIN_COLS = 32;

  // The mobile single-session layout is enabled automatically on narrow or
  // touch-primary devices.
  const MOBILE_MEDIA_QUERY = "(max-width: 767px), (pointer: coarse)";
  // The mobile terminal is edge-to-edge so that as many columns as possible fit.
  const MOBILE_FIT_PADDING = 0;
  const MOBILE_MIN_ZOOM = 0.12;

  function getConstantOffset() {
    return [
      0.5 * window.innerWidth - CONSTANT_OFFSET_LEFT,
      0.5 * window.innerHeight - CONSTANT_OFFSET_TOP,
    ];
  }

  let fabricEl: HTMLElement;
  let touchZoom: TouchZoom;
  let center = [0, 0];
  let zoom = INITIAL_ZOOM;

  let showChat = false; // @hmr:keep
  let settingsOpen = false; // @hmr:keep
  let showNetworkInfo = false; // @hmr:keep

  // Mobile single-session layout state.
  let mobile = false;
  let activeId: number | null = null;
  let titles: Record<number, string> = {};
  let pendingCreate = false;
  let readyShells = new Set<number>();
  let headerEl: HTMLDivElement;
  let safeAreaBottom = 0;
  let desktopView: { center: number[]; zoom: number } | null = null;
  let fitRaf = 0;
  let resizeSendTimer: number | undefined;
  let lastFitKey = "";
  let lastFitActiveId: number | null = null;

  // Keyboard-aware panning/scrollbar state for the mobile layout.
  let keyboardOpen = false;
  let mobileScrollTop = 0;
  let lastScrollActiveId: number | null = null;
  let scrollInfo = {
    visible: false,
    visibleTop: 0,
    visibleHeight: 0,
    maxScroll: 0,
    thumbHeight: 0,
    thumbOffset: 0,
  };
  let baselineWidth = 0;
  let baselineHeight = 0;

  onMount(() => {
    touchZoom = new TouchZoom(fabricEl);
    touchZoom.onMove((manual) => {
      center = touchZoom.center;
      zoom = touchZoom.zoom;

      // Programmatic fits must not disturb an active terminal or hide panels.
      if (!manual) return;

      // Keep the scrollbar in sync when the user pans/pinches the terminal.
      if (mobile && keyboardOpen) {
        syncScrollFromCamera();
      }

      // Blur if the user is currently focused on a terminal.
      //
      // This makes it so that panning does not stop when the cursor happens to
      // intersect with the textarea, which absorbs wheel and touch events.
      if (document.activeElement) {
        const classList = [...document.activeElement.classList];
        if (classList.includes("xterm-helper-textarea")) {
          (document.activeElement as HTMLElement).blur();
        }
      }

      showNetworkInfo = false;
    });

    // Automatically switch to the single-session layout on phones/tablets.
    const query = window.matchMedia(MOBILE_MEDIA_QUERY);
    setMobile(query.matches);
    const onMediaChange = (event: MediaQueryListEvent) =>
      setMobile(event.matches);
    query.addEventListener("change", onMediaChange);

    // Refit and reflow the terminal when the visible viewport changes:
    // orientation changes, window resizes, and the soft keyboard opening or
    // closing (visualViewport shrinks by the keyboard height).
    const onViewportResize = debounce(() => {
      if (mobile) scheduleFit(false);
    }, 150);
    window.addEventListener("resize", onViewportResize);
    window.addEventListener("orientationchange", onViewportResize);
    window.visualViewport?.addEventListener("resize", onViewportResize);
    window.visualViewport?.addEventListener("scroll", onViewportResize);

    // Refit when the top bar changes height (status banner, network info, ...).
    const headerObserver = new ResizeObserver(() => {
      if (mobile) scheduleFit(false);
    });
    if (headerEl) {
      headerObserver.observe(headerEl);
    }

    return () => {
      query.removeEventListener("change", onMediaChange);
      window.removeEventListener("resize", onViewportResize);
      window.removeEventListener("orientationchange", onViewportResize);
      window.visualViewport?.removeEventListener("resize", onViewportResize);
      window.visualViewport?.removeEventListener("scroll", onViewportResize);
      headerObserver.disconnect();
    };
  });

  function resetScrollState() {
    keyboardOpen = false;
    mobileScrollTop = 0;
    lastScrollActiveId = null;
    baselineWidth = 0;
    baselineHeight = 0;
    scrollInfo = {
      visible: false,
      visibleTop: 0,
      visibleHeight: 0,
      maxScroll: 0,
      thumbHeight: 0,
      thumbOffset: 0,
    };
  }

  function setMobile(next: boolean) {
    if (next === mobile || !touchZoom) return;
    resetScrollState();
    if (next) {
      desktopView = { center: [...center], zoom };
      if (activeId === null && shells.length) {
        activeId = shells[shells.length - 1][0];
      }
      mobile = true;
      lastFitActiveId = null;
      lastFitKey = "";
      touchZoom.setMinZoom(MOBILE_MIN_ZOOM);
    } else {
      mobile = false;
      lastFitKey = "";
      lastFitActiveId = null;
      touchZoom.setMinZoom(MIN_ZOOM);
      if (desktopView) {
        touchZoom.setView(desktopView.center, desktopView.zoom);
        desktopView = null;
      }
    }
  }

  /**
   * The largest visual-viewport height seen at the current width. This is the
   * height available without a soft keyboard, so the terminal grid does not
   * change when the keyboard opens.
   */
  function getKeyboardFreeHeight() {
    const width = window.innerWidth;
    const height = window.visualViewport?.height ?? window.innerHeight;
    if (width !== baselineWidth) {
      baselineWidth = width;
      baselineHeight = height;
    } else if (height > baselineHeight) {
      baselineHeight = height;
    }
    return baselineHeight;
  }

  /**
   * Layout area used for sizing the terminal: full width and the keyboard-free
   * height below the top bar. The keyboard never changes this region.
   */
  function getMobileRegion() {
    const headerBottom = headerEl?.getBoundingClientRect().bottom ?? 0;
    return {
      left: MOBILE_FIT_PADDING,
      right: window.innerWidth - MOBILE_FIT_PADDING,
      top: headerBottom + MOBILE_FIT_PADDING,
      bottom: getKeyboardFreeHeight() - safeAreaBottom - MOBILE_FIT_PADDING,
    };
  }

  /**
   * Compute terminal dimensions for the active terminal. Column count fills
   * the screen width; row count is either the manual setting or the number of
   * rows that fill the visible height.
   */
  function computeMobileTarget(id: number) {
    const entry = shells.find(([sid]) => sid === id);
    const wrapper = termWrappers[id];
    const termEl = termElements[id];
    if (!entry || !wrapper || !termEl) return null;
    const ws = entry[1];
    const screenEl = termEl.querySelector(
      ".xterm-screen",
    ) as HTMLElement | null;
    if (!screenEl || !ws.cols || !ws.rows) return null;

    const screenW = screenEl.offsetWidth;
    const screenH = screenEl.offsetHeight;
    if (screenW < 10 || screenH < 10) return null;

    const cellW = screenW / ws.cols;
    const cellH = screenH / ws.rows;
    if (cellW <= 0 || cellH <= 0) return null;

    const chromeW = wrapper.offsetWidth - screenW;
    const chromeH = wrapper.offsetHeight - screenH;
    const region = getMobileRegion();
    const regionW = region.right - region.left;
    const regionH = region.bottom - region.top;
    if (regionW <= 0 || regionH <= 0) return null;

    const autoRows = Math.max(
      TERM_MIN_ROWS,
      Math.floor((regionH - chromeH) / cellH),
    );
    const rows =
      $settings.mobileRows > 0
        ? Math.max($settings.mobileRows, TERM_MIN_ROWS)
        : autoRows;

    // With a manual row count the terminal may be taller than the region, so
    // it gets scaled down to fit. Compensate by fitting more columns, keeping
    // both the width and height filled.
    const zoom = Math.min(1, regionH / (rows * cellH + chromeH));
    const cols = Math.max(
      TERM_MIN_COLS,
      Math.floor((regionW / zoom - chromeW) / cellW),
    );
    return { cols, rows };
  }

  /**
   * Let the phone own the (shared) terminal size: resize the active PTY so it
   * fills the visible screen. Debounced so that a collaborator dragging a
   * window does not cause a resize message per frame.
   */
  function syncMobileSize() {
    if (!mobile || activeId === null || hasWriteAccess !== true) return;
    const target = computeMobileTarget(activeId);
    const entry = shells.find(([sid]) => sid === activeId);
    if (!target || !entry) return;
    const ws = entry[1];
    if (target.rows === ws.rows && target.cols === ws.cols) return;

    const id = activeId;
    window.clearTimeout(resizeSendTimer);
    resizeSendTimer = window.setTimeout(() => {
      if (!mobile || activeId !== id) return;
      const current = shells.find(([sid]) => sid === id)?.[1];
      if (
        !current ||
        (current.rows === target.rows && current.cols === target.cols)
      ) {
        return;
      }
      srocket?.send({
        move: [id, { ...current, rows: target.rows, cols: target.cols }],
      });
    }, 150);
  }

  /**
   * Scroll position that keeps the terminal cursor just above the keyboard.
   */
  function getCursorScrollTop(
    id: number,
    ws: WsWinsize,
    wrapper: HTMLDivElement,
    termHeight: number,
    fittedZoom: number,
    visibleTop: number,
    visibleBottom: number,
    visibleHeight: number,
    maxScroll: number,
  ) {
    if (maxScroll <= 0) return 0;
    const row = termHandles[id]?.getCursorRow?.();
    const termEl = termElements[id];
    const screenEl = termEl?.querySelector(
      ".xterm-screen",
    ) as HTMLElement | null;
    if (
      typeof row !== "number" ||
      !Number.isFinite(row) ||
      !screenEl ||
      !ws.rows
    ) {
      return maxScroll;
    }

    const cellH = screenEl.offsetHeight / ws.rows;
    const chromeH = wrapper.offsetHeight - screenEl.offsetHeight;
    const cursorFromTop =
      chromeH / 2 + Math.min(Math.max(row, 0), ws.rows - 1) * cellH;
    const margin = Math.min(48, visibleHeight * 0.1);
    const desiredTop = visibleBottom - margin - fittedZoom * cursorFromTop;
    const centeredTop =
      visibleTop + Math.max(0, (visibleHeight - termHeight) / 2);
    return Math.min(Math.max(centeredTop - desiredTop, 0), maxScroll);
  }

  /** Move and zoom the camera so the active terminal fits the viewport. */
  function fitActive(animated = false, forceReady = false) {
    if (!mobile || activeId === null || !touchZoom) return;
    if (!forceReady && !readyShells.has(activeId)) return;
    if (touchZoom.isPinching) {
      window.setTimeout(() => scheduleFit(animated), 250);
      return;
    }

    const entry = shells.find(([sid]) => sid === activeId);
    const el = termWrappers[activeId];
    if (!entry || !el) return;
    const [, ws] = entry;
    const width = el.offsetWidth;
    const height = el.offsetHeight;
    if (width < 10 || height < 10) return;

    const region = getMobileRegion();
    const regionW = region.right - region.left;
    const regionH = region.bottom - region.top;
    if (regionW <= 0 || regionH <= 0) return;

    const fittedZoom = Math.max(
      MOBILE_MIN_ZOOM,
      Math.min(1, regionW / width, regionH / height),
    );

    // The visible part of the screen. The keyboard covers the bottom, so the
    // terminal is taller than the visible area; keep its font size/zoom and
    // pan it upwards instead of resizing it.
    const vv = window.visualViewport;
    const vvTop = vv?.offsetTop ?? 0;
    const vvBottom = vvTop + (vv?.height ?? window.innerHeight);
    const visibleTop = Math.max(region.top, vvTop);
    const visibleBottom = Math.min(region.bottom, vvBottom);
    const visibleHeight = Math.max(0, visibleBottom - visibleTop);
    const termHeight = height * fittedZoom;
    const maxScroll = Math.max(0, termHeight - visibleHeight);

    // A larger shrink than a browser toolbar means the soft keyboard is open.
    const keyboardNow = regionH - visibleHeight > 120;
    const keyboardChanged = keyboardNow !== keyboardOpen;

    if (keyboardChanged || activeId !== lastScrollActiveId) {
      keyboardOpen = keyboardNow;
      lastScrollActiveId = activeId;
      mobileScrollTop = keyboardNow
        ? getCursorScrollTop(
            activeId,
            ws,
            el,
            termHeight,
            fittedZoom,
            visibleTop,
            visibleBottom,
            visibleHeight,
            maxScroll,
          )
        : 0;
    } else {
      mobileScrollTop = Math.min(
        Math.max(mobileScrollTop, 0),
        keyboardNow ? maxScroll : 0,
      );
    }

    const scroll = keyboardNow ? mobileScrollTop : 0;
    const thumbHeight =
      maxScroll > 0
        ? Math.max(24, visibleHeight * (visibleHeight / termHeight))
        : 0;
    const thumbOffset =
      maxScroll > 0 ? (scroll / maxScroll) * (visibleHeight - thumbHeight) : 0;
    scrollInfo = {
      visible: keyboardNow && maxScroll > 1,
      visibleTop,
      visibleHeight,
      maxScroll,
      thumbHeight,
      thumbOffset,
    };

    const [ox, oy] = getConstantOffset();
    const left = region.left + Math.max(0, (regionW - width * fittedZoom) / 2);
    const top =
      visibleTop + Math.max(0, (visibleHeight - termHeight) / 2) - scroll;
    const nextCenter = [
      ox + ws.x - left / fittedZoom,
      oy + ws.y - top / fittedZoom,
    ];

    if (animated || keyboardChanged) {
      touchZoom.moveTo(nextCenter, fittedZoom);
    } else {
      touchZoom.setView(nextCenter, fittedZoom);
    }
  }

  function scheduleFit(animated = false) {
    cancelAnimationFrame(fitRaf);
    fitRaf = requestAnimationFrame(async () => {
      await tick();
      // Reflow the PTY first when we own the terminal size; the resulting
      // shells update schedules another fit with the new dimensions.
      syncMobileSize();
      fitActive(animated);
    });
  }

  function markReady(id: number) {
    if (readyShells.has(id)) return;
    if (mobile && id === activeId) {
      // Fit while the wrapper is still hidden by the measuring gate.
      fitActive(false, true);
    }
    readyShells = new Set(readyShells).add(id);
    if (mobile && id === activeId) {
      // Reflow now that the terminal has real dimensions.
      scheduleFit(false);
    }
  }

  let scrollbarEl: HTMLDivElement;

  /** Drag/click the mobile scrollbar to pan the active terminal vertically. */
  function setMobileScrollFromPointer(event: PointerEvent) {
    if (!scrollbarEl || !scrollInfo.visible) return;
    const rect = scrollbarEl.getBoundingClientRect();
    const usable = rect.height - scrollInfo.thumbHeight;
    if (usable <= 0) return;
    const y = event.clientY - rect.top - scrollInfo.thumbHeight / 2;
    const fraction = Math.min(1, Math.max(0, y / usable));
    mobileScrollTop = fraction * scrollInfo.maxScroll;
    fitActive(false);
  }

  /** Keep the scrollbar thumb in sync after a manual pan or pinch. */
  function syncScrollFromCamera() {
    if (!mobile || !keyboardOpen || activeId === null) return;
    const entry = shells.find(([sid]) => sid === activeId);
    const el = termWrappers[activeId];
    if (!entry || !el || scrollInfo.visibleHeight <= 0) return;

    const termHeight = el.offsetHeight * zoom;
    const maxScroll = Math.max(0, termHeight - scrollInfo.visibleHeight);
    const [, oy] = getConstantOffset();
    const screenTop = zoom * (entry[1].y - center[1] + oy);
    mobileScrollTop = Math.min(
      Math.max(scrollInfo.visibleTop - screenTop, 0),
      maxScroll,
    );

    const thumbHeight =
      maxScroll > 0
        ? Math.max(
            24,
            scrollInfo.visibleHeight * (scrollInfo.visibleHeight / termHeight),
          )
        : 0;
    const thumbOffset =
      maxScroll > 0
        ? (mobileScrollTop / maxScroll) *
          (scrollInfo.visibleHeight - thumbHeight)
        : 0;
    scrollInfo = { ...scrollInfo, maxScroll, thumbHeight, thumbOffset };
  }

  function watchShellSize(node: HTMLElement) {
    sizeObserver ??= new ResizeObserver((entries) => {
      const currentId = activeId;
      if (!mobile || currentId === null) return;
      if (entries.some((entry) => entry.target === termWrappers[currentId])) {
        scheduleFit(false);
      }
    });
    sizeObserver.observe(node);
    return {
      destroy() {
        sizeObserver?.unobserve(node);
      },
    };
  }

  let sizeObserver: ResizeObserver;

  function selectShell(id: number) {
    if (id === activeId) return;
    const activeElement = document.activeElement;
    if (
      activeElement instanceof HTMLElement &&
      activeElement.closest(".term-container")
    ) {
      activeElement.blur();
    }
    focused = [];
    activeId = id;
    showNetworkInfo = false;
  }

  function closeShell(id: number) {
    if (hasWriteAccess === true && connected) {
      srocket?.send({ close: id });
    }
  }

  /** Returns the mouse position in infinite grid coordinates, offset transformations and zoom. */
  function normalizePosition(event: MouseEvent): [number, number] {
    const [ox, oy] = getConstantOffset();
    return [
      Math.round(center[0] + event.pageX / zoom - ox),
      Math.round(center[1] + event.pageY / zoom - oy),
    ];
  }

  let encrypt: Encrypt;
  let srocket: Srocket<WsServer, WsClient> | null = null;

  let connected = false;
  let exitReason: string | null = null;

  /** Bound "write" method for each terminal. */
  const writers: Record<number, (data: string) => void> = {};
  const termWrappers: Record<number, HTMLDivElement> = {};
  const termElements: Record<number, HTMLDivElement> = {};
  const termHandles: Record<number, any> = {};
  const chunknums: Record<number, number> = {};
  const locks: Record<number, any> = {};
  let userId = 0;
  let users: [number, WsUser][] = [];
  let shells: [number, WsWinsize][] = [];
  let subscriptions = new Set<number>();

  // May be undefined before `users` is first populated.
  $: hasWriteAccess = users.find(([uid]) => uid === userId)?.[1]?.canWrite;

  let moving = -1; // Terminal ID that is being dragged.
  let movingOrigin = [0, 0]; // Coordinates of mouse at origin when drag started.
  let movingSize: WsWinsize; // New [x, y] position of the dragged terminal.
  let movingIsDone = false; // Moving finished but hasn't been acknowledged.

  let resizing = -1; // Terminal ID that is being resized.
  let resizingOrigin = [0, 0]; // Coordinates of top-left origin when resize started.
  let resizingCell = [0, 0]; // Pixel dimensions of a single terminal cell.
  let resizingSize: WsWinsize; // Last resize message sent.

  let chatMessages: ChatMessage[] = [];
  let newMessages = false;

  let serverLatencies: number[] = [];
  let shellLatencies: number[] = [];

  onMount(async () => {
    // The page hash sets the end-to-end encryption key.
    const key = window.location.hash?.slice(1).split(",")[0] ?? "";
    const writePassword = window.location.hash?.slice(1).split(",")[1] ?? null;

    encrypt = await Encrypt.new(key);
    const encryptedZeros = await encrypt.zeros();

    const writeEncryptedZeros = writePassword
      ? await (await Encrypt.new(writePassword)).zeros()
      : null;

    srocket = new Srocket<WsServer, WsClient>(`/api/s/${id}`, {
      onMessage(message) {
        if (message.hello) {
          userId = message.hello[0];
          dispatch("receiveName", message.hello[1]);
          makeToast({
            kind: "success",
            message: `Connected to the server.`,
          });
          exitReason = null;
        } else if (message.invalidAuth) {
          exitReason =
            "The URL is not correct, invalid end-to-end encryption key.";
          srocket?.dispose();
        } else if (message.chunks) {
          let [id, seqnum, chunks] = message.chunks;
          locks[id](async () => {
            await tick();
            chunknums[id] += chunks.length;
            for (const data of chunks) {
              const buf = await encrypt.segment(
                0x100000000n | BigInt(id),
                BigInt(seqnum),
                data,
              );
              seqnum += data.length;
              writers[id](new TextDecoder().decode(buf));
            }
          });
        } else if (message.users) {
          users = message.users;
        } else if (message.userDiff) {
          const [id, update] = message.userDiff;
          users = users.filter(([uid]) => uid !== id);
          if (update !== null) {
            users = [...users, [id, update]];
          }
        } else if (message.shells) {
          applyShells(message.shells);
        } else if (message.hear) {
          const [uid, name, msg] = message.hear;
          chatMessages.push({ uid, name, msg, sentAt: new Date() });
          chatMessages = chatMessages;
          if (!showChat) newMessages = true;
        } else if (message.shellLatency !== undefined) {
          const shellLatency = Number(message.shellLatency);
          shellLatencies = [...shellLatencies, shellLatency].slice(-10);
        } else if (message.pong !== undefined) {
          const serverLatency = Date.now() - Number(message.pong);
          serverLatencies = [...serverLatencies, serverLatency].slice(-10);
        } else if (message.error) {
          console.warn("Server error: " + message.error);
        }
      },

      onConnect() {
        srocket?.send({ authenticate: [encryptedZeros, writeEncryptedZeros] });
        if ($settings.name) {
          srocket?.send({ setName: $settings.name });
        }
        connected = true;
      },

      onDisconnect() {
        connected = false;
        pendingCreate = false;
        subscriptions.clear();
        users = [];
        serverLatencies = [];
        shellLatencies = [];
      },

      onClose(event) {
        if (event.code === 4404) {
          exitReason = "Failed to connect: " + event.reason;
        } else if (event.code === 4500) {
          exitReason = "Internal server error: " + event.reason;
        }
      },
    });
  });

  onDestroy(() => {
    srocket?.dispose();
    if (typeof window !== "undefined") {
      window.clearTimeout(resizeSendTimer);
      cancelAnimationFrame(fitRaf);
    }
  });

  // Send periodic ping messages for latency estimation.
  onMount(() => {
    const pingIntervalId = window.setInterval(() => {
      if (srocket?.connected) {
        srocket.send({ ping: BigInt(Date.now()) });
      }
    }, 2000);
    return () => window.clearInterval(pingIntervalId);
  });

  function integerMedian(values: number[]) {
    if (values.length === 0) {
      return null;
    }
    const sorted = values.toSorted();
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 !== 0
      ? sorted[mid]
      : Math.round((sorted[mid - 1] + sorted[mid]) / 2);
  }

  $: if ($settings.name) {
    srocket?.send({ setName: $settings.name });
  }

  /** Update the shell list, keeping the mobile active selection consistent. */
  function applyShells(next: [number, WsWinsize][]) {
    const prevIds = new Set(shells.map(([sid]) => sid));
    const prevIndex = shells.findIndex(([sid]) => sid === activeId);
    const added = next.filter(([sid]) => !prevIds.has(sid));

    shells = next;
    if (movingIsDone) {
      moving = -1;
    }
    for (const [id] of next) {
      if (!subscriptions.has(id)) {
        chunknums[id] ??= 0;
        locks[id] ??= createLock();
        subscriptions.add(id);
        srocket?.send({ subscribe: [id, chunknums[id]] });
      }
    }

    if (!mobile) return;
    if (pendingCreate && added.length) {
      pendingCreate = false;
      activeId = added[added.length - 1][0];
    } else if (activeId === null || !next.some(([sid]) => sid === activeId)) {
      activeId = next.length
        ? next[Math.min(Math.max(prevIndex, 0), next.length - 1)][0]
        : null;
    }
  }

  // Fallbacks for shells arriving before the media query is evaluated, and
  // for the active shell being closed or removed by someone else.
  $: if (
    mobile &&
    shells.length > 0 &&
    !shells.some(([sid]) => sid === activeId)
  ) {
    activeId = shells[shells.length - 1][0];
  }
  $: if (shells.length === 0 && activeId !== null) {
    activeId = null;
  }

  // Animate the camera to a newly selected shell, and refit when its shared
  // geometry changes (e.g. another user moves or resizes it).
  $: if (mobile && activeId !== null) {
    const ws = shells.find(([sid]) => sid === activeId)?.[1];
    if (ws) {
      const key = `${activeId}:${ws.x},${ws.y}:${ws.rows}x${ws.cols}:${
        hasWriteAccess === true
      }:${$settings.mobileRows}`;
      if (key !== lastFitKey) {
        const animated =
          lastFitActiveId !== null && activeId !== lastFitActiveId;
        lastFitKey = key;
        lastFitActiveId = activeId;
        scheduleFit(animated);
      }
    }
  }

  let counter = 0n;

  async function handleCreate() {
    if (hasWriteAccess === false) {
      makeToast({
        kind: "info",
        message: "You are in read-only mode and cannot create new terminals.",
      });
      return;
    }
    if (shells.length >= 14) {
      makeToast({
        kind: "error",
        message: "You can only create up to 14 terminals.",
      });
      return;
    }
    const existing = shells.map(([id, winsize]) => ({
      x: winsize.x,
      y: winsize.y,
      width: termWrappers[id].clientWidth,
      height: termWrappers[id].clientHeight,
    }));
    const { x, y } = arrangeNewTerminal(existing);
    if (mobile) {
      pendingCreate = true;
    }
    srocket?.send({ create: [x, y] });
    if (!mobile) {
      touchZoom.moveTo([x, y], INITIAL_ZOOM);
    }
  }

  async function handleInput(id: number, data: Uint8Array) {
    if (counter === 0n) {
      // On the first call, initialize the counter to a random 64-bit integer.
      const array = new Uint8Array(8);
      crypto.getRandomValues(array);
      counter = new DataView(array.buffer).getBigUint64(0);
    }
    const offset = counter;
    counter += BigInt(data.length); // Must increment before the `await`.
    const encrypted = await encrypt.segment(0x200000000n, offset, data);
    srocket?.send({ data: [id, encrypted, offset] });
  }

  // Stupid hack to preserve input focus when terminals are reordered.
  // See: https://github.com/sveltejs/svelte/issues/3973
  let activeElement: Element | null = null;

  beforeUpdate(() => {
    activeElement = document.activeElement;
  });

  afterUpdate(() => {
    if (!(activeElement instanceof HTMLElement)) return;
    if (mobile) {
      // Never restore focus to a terminal that is currently hidden, or to
      // arbitrary controls affected by the tab re-render.
      if (!activeElement.closest(".term-container")) return;
      if (
        activeId === null ||
        !termWrappers[activeId]?.contains(activeElement)
      ) {
        return;
      }
    }
    activeElement.focus();
  });

  // Global mouse handler logic follows, attached to the window element for smoothness.
  onMount(() => {
    // 50 milliseconds between successive terminal move updates.
    const sendMove = throttle((message: WsClient) => {
      srocket?.send(message);
    }, 50);

    // 80 milliseconds between successive cursor updates.
    const sendCursor = throttle((message: WsClient) => {
      srocket?.send(message);
    }, 80);

    function handleMouse(event: MouseEvent) {
      if (moving !== -1 && !movingIsDone) {
        const [x, y] = normalizePosition(event);
        movingSize = {
          ...movingSize,
          x: Math.round(x - movingOrigin[0]),
          y: Math.round(y - movingOrigin[1]),
        };
        sendMove({ move: [moving, movingSize] });
      }

      if (resizing !== -1) {
        const cols = Math.max(
          Math.floor((event.pageX - resizingOrigin[0]) / resizingCell[0]),
          TERM_MIN_COLS, // Minimum number of columns.
        );
        const rows = Math.max(
          Math.floor((event.pageY - resizingOrigin[1]) / resizingCell[1]),
          TERM_MIN_ROWS, // Minimum number of rows.
        );
        if (rows !== resizingSize.rows || cols !== resizingSize.cols) {
          resizingSize = { ...resizingSize, rows, cols };
          srocket?.send({ move: [resizing, resizingSize] });
        }
      }

      sendCursor({ setCursor: normalizePosition(event) });
    }

    function handleMouseEnd(event: MouseEvent) {
      if (moving !== -1) {
        movingIsDone = true;
        sendMove.cancel();
        srocket?.send({ move: [moving, movingSize] });
      }

      if (resizing !== -1) {
        resizing = -1;
      }

      if (event.type === "mouseleave") {
        sendCursor.cancel();
        srocket?.send({ setCursor: null });
      }
    }

    window.addEventListener("mousemove", handleMouse);
    window.addEventListener("mouseup", handleMouseEnd);
    document.body.addEventListener("mouseleave", handleMouseEnd);
    return () => {
      window.removeEventListener("mousemove", handleMouse);
      window.removeEventListener("mouseup", handleMouseEnd);
      document.body.removeEventListener("mouseleave", handleMouseEnd);
    };
  });

  let focused: number[] = [];
  $: setFocus(focused);

  // Wait a small amount of time, since blur events happen before focus events.
  const setFocus = debounce((focused: number[]) => {
    srocket?.send({ setFocus: focused[0] ?? null });
  }, 20);
</script>

<!-- Wheel handler stops native macOS Chrome zooming on pinch. -->
<main
  class={mobile ? "fixed inset-0 overflow-hidden p-0" : "p-8"}
  class:cursor-nwse-resize={!mobile && resizing !== -1}
  on:wheel={(event) => event.preventDefault()}
>
  <div
    bind:this={headerEl}
    class="absolute inset-x-0 z-20 flex flex-col items-center pointer-events-none {mobile
      ? 'top-0'
      : 'top-8'}"
    style:padding-top={mobile
      ? "calc(env(safe-area-inset-top) + 0.5rem)"
      : undefined}
  >
    <Toolbar
      {mobile}
      {connected}
      {newMessages}
      {hasWriteAccess}
      on:create={handleCreate}
      on:chat={() => {
        showChat = !showChat;
        newMessages = false;
      }}
      on:settings={() => {
        settingsOpen = true;
      }}
      on:networkInfo={() => {
        showNetworkInfo = !showNetworkInfo;
        if (mobile) scheduleFit(false);
      }}
    />

    {#if mobile}
      <div class="mt-1.5 w-full px-2">
        <SessionTabs
          {shells}
          {activeId}
          {titles}
          {connected}
          canCreate={connected && hasWriteAccess === true && shells.length < 14}
          canClose={connected && hasWriteAccess === true}
          on:select={({ detail }) => selectShell(detail)}
          on:create={handleCreate}
          on:close={({ detail }) => closeShell(detail)}
        />
      </div>
      {#if !connected || hasWriteAccess === false || exitReason}
        <div
          class="panel mt-1 px-3 py-0.5 text-xs pointer-events-auto {exitReason
            ? 'text-red-400'
            : hasWriteAccess === false
            ? 'text-yellow-200'
            : 'text-yellow-400'}"
        >
          {exitReason ??
            (hasWriteAccess === false ? "Read-only" : "Reconnecting…")}
        </div>
      {/if}
    {/if}

    {#if showNetworkInfo}
      <div
        class={mobile
          ? "mt-1 w-72 max-w-[calc(100vw-16px)] pointer-events-auto"
          : "absolute top-20 translate-x-[116.5px]"}
      >
        <NetworkInfo
          status={connected
            ? "connected"
            : exitReason
            ? "no-shell"
            : "no-server"}
          serverLatency={integerMedian(serverLatencies)}
          shellLatency={integerMedian(shellLatencies)}
        />
      </div>
    {/if}
  </div>

  {#if mobile && shells.length === 0}
    <div
      class="absolute inset-0 z-10 flex items-center justify-center px-6 pointer-events-none"
      style:padding-top="calc(env(safe-area-inset-top) + 6rem)"
    >
      <div
        class="panel p-4 text-center text-sm text-zinc-300 pointer-events-auto"
      >
        {#if exitReason}
          <span class="text-red-400">{exitReason}</span>
        {:else if !connected}
          Connecting…
        {:else}
          No terminals yet.
          {#if hasWriteAccess === true}
            <br />Tap + to create one.
          {/if}
        {/if}
      </div>
    </div>
  {/if}

  {#if mobile && scrollInfo.visible}
    <div
      class="mobile-scrollbar"
      style:top="{scrollInfo.visibleTop}px"
      style:height="{scrollInfo.visibleHeight}px"
      bind:this={scrollbarEl}
      on:pointerdown={(event) => {
        event.preventDefault();
        scrollbarEl.setPointerCapture(event.pointerId);
        setMobileScrollFromPointer(event);
      }}
      on:pointermove={(event) => {
        if (scrollbarEl.hasPointerCapture(event.pointerId)) {
          setMobileScrollFromPointer(event);
        }
      }}
      on:pointerup={(event) =>
        scrollbarEl.releasePointerCapture(event.pointerId)}
      on:pointercancel={(event) =>
        scrollbarEl.releasePointerCapture(event.pointerId)}
    >
      <div
        class="mobile-scrollbar-thumb"
        style:top="{scrollInfo.thumbOffset}px"
        style:height="{scrollInfo.thumbHeight}px"
      />
    </div>
  {/if}

  {#if showChat}
    <div
      class="absolute flex flex-col justify-end pointer-events-none z-10 {mobile
        ? 'inset-y-2 left-2 right-2'
        : 'inset-y-4 right-4 w-80'}"
      style:padding-bottom={mobile ? "env(safe-area-inset-bottom)" : undefined}
    >
      <Chat
        {userId}
        messages={chatMessages}
        on:chat={(event) => srocket?.send({ chat: event.detail })}
        on:close={() => (showChat = false)}
      />
    </div>
  {/if}

  <Settings open={settingsOpen} on:close={() => (settingsOpen = false)} />

  <ChooseName />

  <!--
    Dotted circle background appears underneath the rest of the elements, but
    moves and zooms with the fabric of the canvas.
  -->
  {#if !mobile}
    <div
      class="absolute inset-0 -z-10"
      style:background-image="radial-gradient(#333 {zoom}px, transparent 0)"
      style:background-size="{24 * zoom}px {24 * zoom}px"
      style:background-position="{-zoom * center[0]}px {-zoom * center[1]}px"
    />
  {/if}

  {#if !mobile}
    <div class="py-2">
      {#if exitReason !== null}
        <div class="text-red-400">{exitReason}</div>
      {:else if connected}
        <div class="flex items-center">
          <div class="text-green-400">You are connected!</div>
          {#if userId && hasWriteAccess === false}
            <div
              class="bg-yellow-900 text-yellow-200 px-1 py-0.5 rounded ml-3 inline-flex items-center gap-1"
            >
              <EyeIcon size="14" />
              <span class="text-xs">Read-only</span>
            </div>
          {/if}
        </div>
      {:else}
        <div class="text-yellow-400">Connecting…</div>
      {/if}

      <div class="mt-4">
        <NameList {users} />
      </div>
    </div>
  {/if}

  <!-- Bottom safe-area probe for fitting the terminal above the home indicator. -->
  <div
    class="pointer-events-none fixed bottom-0 left-0 w-px"
    style:height="env(safe-area-inset-bottom, 0px)"
    bind:clientHeight={safeAreaBottom}
  />

  <div class="absolute inset-0 overflow-hidden touch-none" bind:this={fabricEl}>
    {#each shells as [id, winsize] (id)}
      {@const ws = id === moving ? movingSize : winsize}
      <div
        class="absolute"
        class:measuring={!readyShells.has(id)}
        class:invisible={mobile && id !== activeId}
        class:pointer-events-none={mobile && id !== activeId}
        aria-hidden={mobile && id !== activeId}
        style:left={OFFSET_LEFT_CSS}
        style:top={OFFSET_TOP_CSS}
        style:transform-origin={OFFSET_TRANSFORM_ORIGIN_CSS}
        use:watchShellSize
        transition:fade|local
        use:slide={{ x: ws.x, y: ws.y, center, zoom, immediate: id === moving }}
        bind:this={termWrappers[id]}
      >
        <XTerm
          {mobile}
          rows={ws.rows}
          cols={ws.cols}
          bind:this={termHandles[id]}
          bind:write={writers[id]}
          bind:termEl={termElements[id]}
          on:titleChange={({ detail }) =>
            (titles = { ...titles, [id]: detail })}
          on:ready={() => markReady(id)}
          on:data={({ detail: data }) =>
            hasWriteAccess && handleInput(id, data)}
          on:close={() => srocket?.send({ close: id })}
          on:shrink={() => {
            if (!hasWriteAccess) return;
            const rows = Math.max(ws.rows - 4, TERM_MIN_ROWS);
            const cols = Math.max(ws.cols - 10, TERM_MIN_COLS);
            if (rows !== ws.rows || cols !== ws.cols) {
              srocket?.send({ move: [id, { ...ws, rows, cols }] });
            }
          }}
          on:expand={() => {
            if (!hasWriteAccess) return;
            const rows = ws.rows + 4;
            const cols = ws.cols + 10;
            srocket?.send({ move: [id, { ...ws, rows, cols }] });
          }}
          on:bringToFront={() => {
            if (!hasWriteAccess || mobile) return;
            showNetworkInfo = false;
            srocket?.send({ move: [id, null] });
          }}
          on:startMove={({ detail: event }) => {
            if (!hasWriteAccess || mobile) return;
            const [x, y] = normalizePosition(event);
            moving = id;
            movingOrigin = [x - ws.x, y - ws.y];
            movingSize = ws;
            movingIsDone = false;
          }}
          on:focus={() => {
            if (!hasWriteAccess) return;
            focused = [...focused, id];
          }}
          on:blur={() => {
            focused = focused.filter((i) => i !== id);
          }}
        />

        {#if !mobile}
          <!-- User avatars -->
          <div class="absolute bottom-2.5 right-2.5 pointer-events-none">
            <Avatars
              users={users.filter(
                ([uid, user]) => uid !== userId && user.focus === id,
              )}
            />
          </div>

          <!-- Interactable element for resizing -->
          <div
            class="absolute w-5 h-5 -bottom-1 -right-1 cursor-nwse-resize"
            on:mousedown={(event) => {
              const canvasEl = termElements[id].querySelector(".xterm-screen");
              if (canvasEl) {
                resizing = id;
                const r = canvasEl.getBoundingClientRect();
                resizingOrigin = [
                  event.pageX - r.width,
                  event.pageY - r.height,
                ];
                resizingCell = [r.width / ws.cols, r.height / ws.rows];
                resizingSize = ws;
              }
            }}
            on:pointerdown={(event) => event.stopPropagation()}
          />
        {/if}
      </div>
    {/each}

    {#if !mobile}
      {#each users.filter(([id, user]) => id !== userId && user.cursor !== null) as [id, user] (id)}
        <div
          class="absolute"
          style:left={OFFSET_LEFT_CSS}
          style:top={OFFSET_TOP_CSS}
          style:transform-origin={OFFSET_TRANSFORM_ORIGIN_CSS}
          transition:fade|local={{ duration: 200 }}
          use:slide={{
            x: user.cursor?.[0] ?? 0,
            y: user.cursor?.[1] ?? 0,
            center,
            zoom,
          }}
        >
          <LiveCursor {user} />
        </div>
      {/each}
    {/if}
  </div>
</main>

<style lang="postcss">
  /*
   * Hide a terminal until xterm has measured its font and called resize().
   *
   * xterm measures character size with getBoundingClientRect(), which is
   * affected by the canvas transform. Rendering at identity scale (while
   * hidden) prevents terminals created at a zoomed-out camera from measuring
   * tiny character cells and rendering incorrectly.
   */
  .measuring {
    transform: none !important;
    visibility: hidden !important;
  }

  /* Vertical scrollbar shown while the soft keyboard reduces the viewport. */
  .mobile-scrollbar {
    position: absolute;
    right: 0;
    z-index: 15;
    width: 16px;
    touch-action: none;
    pointer-events: auto;
  }

  .mobile-scrollbar-thumb {
    position: absolute;
    right: 5px;
    width: 5px;
    border-radius: 9999px;
    background: rgb(255 255 255 / 0.35);
  }
</style>
